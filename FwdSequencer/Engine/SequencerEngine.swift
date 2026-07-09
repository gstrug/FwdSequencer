import Foundation

class SequencerEngine {
    var audioEngine: AudioEngineManager?
    var onNotePlayed: ((UUID, Int?) -> Void)?
    var onBarChange: ((Int) -> Void)?
    var onStepChange: ((UUID, Int) -> Void)?
    /// Fires on every beat. `true` = downbeat (beat 1 of bar), `false` = all other beats.
    var onBeat: ((Bool) -> Void)?

    private var timer: DispatchSourceTimer?
    private var states: [UUID: TrackState] = [:]
    private var globalStep = 0
    private let stepsPerBeat = 4

    // Thread-safe live project — updated from main thread, read on sequencer thread
    private let projectQueue = DispatchQueue(label: "com.fwd.project")
    private var _project: Project = Project()

    func updateProject(_ project: Project) {
        projectQueue.async { self._project = project }
    }

    private var liveProject: Project {
        projectQueue.sync { _project }
    }

    private struct TrackState {
        var stepIndex: Int = 0
        var notePtr: Int = 0
        var lastMidiNote: Int? = nil
    }

    // MARK: - Lifecycle

    func start(project: Project) {
        globalStep = 0
        updateProject(project)
        states = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, TrackState()) })
        startTimer(tempo: project.tempo)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        globalStep = 0
        for key in states.keys { states[key] = TrackState() }
        onBarChange?(0)
    }

    func pause() {
        timer?.cancel()
        timer = nil
        // globalStep and states intentionally preserved
    }

    func resume(tempo: Double) {
        guard timer == nil else { return }
        startTimer(tempo: tempo)
    }

    func rewind() {
        globalStep = 0
        for key in states.keys { states[key] = TrackState() }
        onBarChange?(0)
    }

    func updateTempo(_ tempo: Double) {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        startTimer(tempo: tempo)
    }

    private func startTimer(tempo: Double) {
        let interval = 60.0 / tempo / Double(stepsPerBeat)
        let queue = DispatchQueue(label: "com.fwd.sequencer", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - Tick

    private func tick() {
        let project = liveProject
        let interval = 60.0 / project.tempo / Double(stepsPerBeat)

        // How many 16th-note steps make one bar given the time signature.
        // Formula: numerator beats × (16 steps per whole note / denominator)
        let stepsPerBar = max(1, project.timeSignature.numerator * 16 / project.timeSignature.denominator)
        let totalSteps  = stepsPerBar * max(1, project.numberOfBars)

        // Fire bar-change callback at the start of each new bar
        if globalStep % stepsPerBar == 0 {
            onBarChange?(globalStep / stepsPerBar)
        }

        // Loop: reset all track states at the end of the last bar
        if globalStep >= totalSteps {
            for key in states.keys { states[key] = TrackState() }
            globalStep = 0
            onBarChange?(0)
        }

        // Beat indicator — fires every beat; true = downbeat (beat 1 of bar)
        let stepsPerBeatTS = max(1, 16 / project.timeSignature.denominator)
        if globalStep % stepsPerBeatTS == 0 {
            let isDownbeat = (globalStep % stepsPerBar) == 0
            onBeat?(isDownbeat)
        }

        let anySoloed = project.tracks.contains(where: { $0.mixer.isSoloed })

        for track in project.tracks {
            guard !track.notePool.isEmpty else { continue }

            let triggerEvery: Int
            switch track.tempoDivision {
            case .breve:     triggerEvery = stepsPerBeat * 8
            case .whole:     triggerEvery = stepsPerBeat * 4
            case .half:      triggerEvery = stepsPerBeat * 2
            case .quarter:   triggerEvery = stepsPerBeat
            case .eighth:    triggerEvery = max(1, stepsPerBeat / 2)
            case .sixteenth: triggerEvery = 1
            }

            guard globalStep % triggerEvery == 0 else { continue }
            guard var state = states[track.id] else { continue }

            if let last = state.lastMidiNote {
                audioEngine?.stopNote(trackID: track.id, midiNote: UInt8(last))
                state.lastMidiNote = nil
            }

            if !track.steps.isEmpty {
                onStepChange?(track.id, state.stepIndex % track.steps.count)
            }

            let shouldSound = !track.mixer.isMuted && (!anySoloed || track.mixer.isSoloed)
            let poolIndex = executeStep(track: track, state: &state)

            if shouldSound, let idx = poolIndex {
                let entry = track.notePool[idx]
                let midiNote = UInt8(entry.midiNote)
                let gate = entry.gateLength * interval * Double(triggerEvery)

                audioEngine?.setVolume(track.mixer.volume, for: track.id)
                audioEngine?.setPan(track.mixer.pan, for: track.id)
                audioEngine?.playNote(trackID: track.id, midiNote: midiNote, velocity: UInt8(entry.velocity))
                state.lastMidiNote = entry.midiNote

                onNotePlayed?(track.id, entry.midiNote)

                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + gate) { [weak self] in
                    self?.audioEngine?.stopNote(trackID: track.id, midiNote: midiNote)
                }
            } else {
                onNotePlayed?(track.id, nil)
            }

            states[track.id] = state
        }

        globalStep += 1
    }

    // MARK: - Step Execution

    private func executeStep(track: Track, state: inout TrackState) -> Int? {
        let noteCount = track.notePool.count
        let stepCount = track.steps.count
        guard noteCount > 0 else { return nil }

        guard stepCount > 0 else {
            state.notePtr = state.notePtr % noteCount
            let idx = state.notePtr
            state.notePtr = (state.notePtr + 1) % noteCount
            return idx
        }

        // Clamp pointer in case the note pool shrank since last tick
        state.notePtr = state.notePtr % noteCount

        let si = state.stepIndex % stepCount
        let step = track.steps[si]
        state.stepIndex = (si + 1) % stepCount

        switch step.type {
        case .fwd:
            let idx = state.notePtr
            state.notePtr = (state.notePtr + max(1, step.n)) % noteCount
            return idx
        case .back:
            let idx = state.notePtr
            let n = max(1, step.n)
            state.notePtr = ((state.notePtr - n) % noteCount + noteCount) % noteCount
            return idx
        case .skip:
            state.notePtr = (state.notePtr + 1) % noteCount
            return nil
        case .rep:
            return state.notePtr
        case .random:
            let idx = state.notePtr
            state.notePtr = noteCount > 1 ? Int.random(in: 0..<noteCount) : 0
            return idx
        }
    }
}
