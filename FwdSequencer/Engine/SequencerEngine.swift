import Foundation

// MARK: - Playable views
//
// The tick loop triggers against these lightweight per-track views rather than a
// whole Track, so the same code path serves both a looping pattern and a song's
// sequence of sections. (Note: the tick loop does not read key/scale — those are
// edit-time constraints only.)

struct PlayTrack {
    let id: UUID
    let tempoDivision: TempoDivision
    let notePool: [NoteEntry]
    let steps: [Step]
    let isMuted: Bool
    let isSoloed: Bool

    init(id: UUID, tempoDivision: TempoDivision, notePool: [NoteEntry],
         steps: [Step], isMuted: Bool, isSoloed: Bool) {
        self.id = id; self.tempoDivision = tempoDivision
        self.notePool = notePool; self.steps = steps
        self.isMuted = isMuted; self.isSoloed = isSoloed
    }

    init(from t: Track) {
        self.init(id: t.id, tempoDivision: t.tempoDivision, notePool: t.notePool,
                  steps: t.steps, isMuted: t.mixer.isMuted, isSoloed: t.mixer.isSoloed)
    }
}

/// One section of a song, flattened for playback.
struct SequencerSection {
    let numberOfBars: Int
    let tracks: [PlayTrack]
}

class SequencerEngine {
    var audioEngine: AudioEngineManager?
    var onNotePlayed: ((UUID, Int?) -> Void)?
    var onBarChange: ((Int) -> Void)?
    var onStepChange: ((UUID, Int) -> Void)?
    /// Fires on every beat. `true` = downbeat (beat 1 of bar), `false` = all other beats.
    var onBeat: ((Bool) -> Void)?
    /// Song mode only: fires when playback advances to a new section (by index).
    var onSectionChange: ((Int) -> Void)?
    /// Song mode only: fires when a non-looping song plays past its last section.
    var onSongFinished: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private var sequencerQueue: DispatchQueue?
    private var states: [UUID: TrackState] = [:]
    private var pendingNoteOffs: [UUID: DispatchWorkItem] = [:]
    private var globalStep = 0
    private let stepsPerBeat = 8   // ticks per beat = 32nd-note resolution

    // Thread-safe live project — updated from main thread, read on sequencer thread
    private let projectQueue = DispatchQueue(label: "com.fwd.project")
    private var _project: Project = Project()

    // Song mode — additive playback path. Guarded by projectQueue like _project.
    // `isSongMode` selects which source the tick loop reads; `sectionIndex` is
    // sequencer-thread-only state (like globalStep).
    private var isSongMode = false
    private var songLoops = true
    private var sectionIndex = 0
    private var _songSections: [SequencerSection] = []
    private var _songTempo: Double = 120
    private var _songTimeSignature = TimeSignature()

    // A resolved snapshot the tick loop plays against, from either source.
    private struct Frame {
        let tempo: Double
        let timeSignature: TimeSignature
        let numberOfBars: Int
        let tracks: [PlayTrack]
    }

    func updateProject(_ project: Project) {
        projectQueue.async { self._project = project }
    }

    private var liveProject: Project {
        projectQueue.sync { _project }
    }

    // Resolve the snapshot the tick loop plays against: the live project (pattern
    // mode) or the current section (song mode).
    private func currentFrame() -> Frame {
        if isSongMode {
            return projectQueue.sync {
                guard !_songSections.isEmpty else {
                    return Frame(tempo: _songTempo, timeSignature: _songTimeSignature,
                                 numberOfBars: 1, tracks: [])
                }
                let idx = min(max(0, sectionIndex), _songSections.count - 1)
                let s = _songSections[idx]
                return Frame(tempo: _songTempo, timeSignature: _songTimeSignature,
                             numberOfBars: s.numberOfBars, tracks: s.tracks)
            }
        } else {
            let p = liveProject
            return Frame(tempo: p.tempo, timeSignature: p.timeSignature,
                         numberOfBars: p.numberOfBars, tracks: p.tracks.map(PlayTrack.init(from:)))
        }
    }

    private func songSectionCount() -> Int {
        projectQueue.sync { _songSections.count }
    }

    private struct TrackState {
        var stepIndex: Int = 0
        var notePtr: Int = 0
        var lastMidiNotes: [Int] = []   // notes currently ringing (>1 for a chord)
        var repRemaining: Int = 0       // ticks left in a rep burst (0 = not in burst)
    }

    // MARK: - Lifecycle

    func start(project: Project) {
        globalStep = 0
        isSongMode = false
        updateProject(project)
        states = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, TrackState()) })
        startTimer(tempo: project.tempo)
    }

    /// Start song playback: play `sections` in order, looping back to the first.
    /// `trackIDs` are the stable SongTrack ids (instrument keys) so per-track state
    /// carries across sections. Additive — does not disturb the pattern path.
    func startSong(sections: [SequencerSection], tempo: Double,
                   timeSignature: TimeSignature, trackIDs: [UUID], loop: Bool) {
        globalStep = 0
        sectionIndex = 0
        isSongMode = true
        songLoops = loop
        projectQueue.sync {
            _songSections = sections
            _songTempo = tempo
            _songTimeSignature = timeSignature
        }
        states = Dictionary(uniqueKeysWithValues: trackIDs.map { ($0, TrackState()) })
        onSectionChange?(0)
        startTimer(tempo: tempo)
    }

    /// Push edited section data during song playback (main thread → sequencer thread).
    func updateSongSections(_ sections: [SequencerSection]) {
        projectQueue.async { self._songSections = sections }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        globalStep = 0
        sectionIndex = 0
        for key in states.keys { states[key] = TrackState() }
        pendingNoteOffs.values.forEach { $0.cancel() }
        pendingNoteOffs.removeAll()
        audioEngine?.allNotesOff()
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
        sectionIndex = 0
        for key in states.keys { states[key] = TrackState() }
        pendingNoteOffs.values.forEach { $0.cancel() }
        pendingNoteOffs.removeAll()
        audioEngine?.allNotesOff()
        onBarChange?(0)
        if isSongMode { onSectionChange?(0) }
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
        sequencerQueue = queue
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: - Tick

    private func tick() {
        var frame = currentFrame()
        let interval = 60.0 / frame.tempo / Double(stepsPerBeat)

        // How many 16th-note steps make one bar given the time signature.
        // Formula: numerator beats × (16 steps per whole note / denominator)
        var stepsPerBar = max(1, frame.timeSignature.numerator * 32 / frame.timeSignature.denominator)
        var totalSteps  = stepsPerBar * max(1, frame.numberOfBars)

        // Fire bar-change callback at the start of each new bar
        if globalStep % stepsPerBar == 0 {
            onBarChange?(globalStep / stepsPerBar)
        }

        // Loop point: end of the current pattern/section.
        if globalStep >= totalSteps {
            for key in states.keys { states[key] = TrackState() }
            globalStep = 0
            if isSongMode {
                let count = songSectionCount()
                if count > 0 {
                    // End of the last section with looping off → finish and stop.
                    if sectionIndex + 1 >= count && !songLoops {
                        finishSong()
                        return
                    }
                    // Advance to the next section (wrap → song loops), then re-resolve
                    // the frame so this same tick plays the new section's first step.
                    sectionIndex = (sectionIndex + 1) % count
                    onSectionChange?(sectionIndex)
                    frame = currentFrame()
                    stepsPerBar = max(1, frame.timeSignature.numerator * 32 / frame.timeSignature.denominator)
                    totalSteps  = stepsPerBar * max(1, frame.numberOfBars)
                }
            }
            onBarChange?(0)
        }

        // Beat indicator — fires every beat; true = downbeat (beat 1 of bar)
        let stepsPerBeatTS = max(1, 32 / frame.timeSignature.denominator)
        if globalStep % stepsPerBeatTS == 0 {
            let isDownbeat = (globalStep % stepsPerBar) == 0
            onBeat?(isDownbeat)
        }

        let anySoloed = frame.tracks.contains(where: { $0.isSoloed })

        for track in frame.tracks {
            guard !track.notePool.isEmpty else { continue }

            let triggerEvery: Int
            switch track.tempoDivision {
            case .breve:          triggerEvery = stepsPerBeat * 8   // 64 ticks
            case .whole:          triggerEvery = stepsPerBeat * 4   // 32
            case .half:           triggerEvery = stepsPerBeat * 2   // 16
            case .quarter:        triggerEvery = stepsPerBeat        // 8
            case .eighth:         triggerEvery = stepsPerBeat / 2    // 4
            case .sixteenth:      triggerEvery = stepsPerBeat / 4    // 2
            case .thirtysecond:   triggerEvery = 1
            }

            guard globalStep % triggerEvery == 0 else { continue }
            guard var state = states[track.id] else { continue }

            if !track.steps.isEmpty {
                onStepChange?(track.id, state.stepIndex % track.steps.count)
            }

            let shouldSound = !track.isMuted && (!anySoloed || track.isSoloed)
            let (poolIndices, stopPrev) = executeStep(track: track, state: &state)

            let stepDuration = interval * Double(triggerEvery)

            if stopPrev {
                // Cancel pending gate and stop all ringing notes immediately.
                pendingNoteOffs[track.id]?.cancel()
                pendingNoteOffs.removeValue(forKey: track.id)
                for last in state.lastMidiNotes {
                    audioEngine?.stopNote(trackID: track.id, midiNote: UInt8(last))
                }
                state.lastMidiNotes = []
            } else if pendingNoteOffs[track.id] != nil {
                // Skip — gate is still pending (notes still ringing): extend by one step.
                // Both this tick and the gate item run on the same serial queue so
                // pendingNoteOffs[id] != nil reliably means the gate hasn't fired yet.
                pendingNoteOffs[track.id]?.cancel()
                let notes = state.lastMidiNotes.map { UInt8($0) }
                scheduleNoteOff(trackID: track.id, midiNotes: notes, delay: stepDuration)
            }
            // else: Skip but gate already fired — notes are off, nothing to extend

            if shouldSound, !poolIndices.isEmpty {
                // Play every note in the (possibly chord) step at once, releasing them
                // together after the longest gate among them.
                var played: [UInt8] = []
                var maxGate = 0.0
                for idx in poolIndices {
                    let entry = track.notePool[idx]
                    let midiNote = UInt8(entry.midiNote)
                    audioEngine?.playNote(trackID: track.id, midiNote: midiNote, velocity: UInt8(entry.velocity))
                    played.append(midiNote)
                    maxGate = max(maxGate, entry.gateLength)
                }
                state.lastMidiNotes = poolIndices.map { track.notePool[$0].midiNote }
                onNotePlayed?(track.id, track.notePool[poolIndices[0]].midiNote)   // highlight the root

                pendingNoteOffs[track.id]?.cancel()
                scheduleNoteOff(trackID: track.id, midiNotes: played, delay: maxGate * stepDuration)
            } else if poolIndices.isEmpty && stopPrev {
                onNotePlayed?(track.id, nil)
            }

            states[track.id] = state
        }

        globalStep += 1
    }

    // Non-looping song reached its end: stop the timer and signal completion.
    private func finishSong() {
        timer?.cancel()
        timer = nil
        globalStep = 0
        sectionIndex = 0
        for key in states.keys { states[key] = TrackState() }
        pendingNoteOffs.values.forEach { $0.cancel() }
        pendingNoteOffs.removeAll()
        audioEngine?.allNotesOff()
        onSongFinished?()
    }

    // Schedule a note-off on the sequencer queue so it serialises with ticks.
    // Self-removes from pendingNoteOffs when it fires, making the nil-check in skip reliable.
    private func scheduleNoteOff(trackID: UUID, midiNotes: [UInt8], delay: Double) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for note in midiNotes { audioEngine?.stopNote(trackID: trackID, midiNote: note) }
            pendingNoteOffs.removeValue(forKey: trackID)
            states[trackID]?.lastMidiNotes = []
        }
        pendingNoteOffs[trackID] = item
        sequencerQueue?.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Step Execution
    // Returns (notePoolIndex, stopPreviousNote).
    // notePoolIndex nil = don't play. stopPreviousNote false = let current note ring (Skip).

    private func advanceStepIndex(_ si: Int, stepCount: Int, state: inout TrackState) {
        state.stepIndex = (si + 1) % stepCount
        // notePtr intentionally NOT reset on wrap — generative patterns rely on the
        // pointer continuing to evolve across step-list loops.
    }

    // Resolve a Play step to the 0-indexed pool positions it triggers. A chord
    // (chordPositions with >1 valid entry) returns several; otherwise a single note
    // from `n`. Positions are clamped/filtered to the pool and de-duplicated, so an
    // out-of-range or oversized chord can never crash or index past the pool.
    private func playIndices(for step: Step, noteCount: Int) -> [Int] {
        if step.chordPositions.count > 1 {
            var seen = Set<Int>()
            var result: [Int] = []
            for pos in step.chordPositions {
                let idx = pos - 1
                if idx >= 0, idx < noteCount, seen.insert(idx).inserted { result.append(idx) }
            }
            if !result.isEmpty { return result }
        }
        return [min(max(0, step.n - 1), noteCount - 1)]
    }

    private func executeStep(track: PlayTrack, state: inout TrackState) -> ([Int], Bool) {
        let noteCount = track.notePool.count
        let stepCount = track.steps.count
        guard noteCount > 0 else { return ([], true) }

        guard stepCount > 0 else {
            return ([state.notePtr % noteCount], true)
        }

        state.notePtr = state.notePtr % noteCount

        let si = state.stepIndex % stepCount
        let step = track.steps[si]

        switch step.type {

        case .fwd:
            // Play current note FIRST, then advance. This way note[0] is always reachable
            // and Back (which moves silently) leaves the pointer at the note to play next.
            let idx = state.notePtr
            state.notePtr = (state.notePtr + max(1, step.n)) % noteCount
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            return ([idx], true)

        case .back:
            // Play current note, then move pointer back n positions.
            let idx = state.notePtr
            let n = max(1, step.n)
            state.notePtr = ((state.notePtr - n) % noteCount + noteCount) % noteCount
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            return ([idx], true)

        case .rep:
            // Play current note n times total. repRemaining tracks ticks remaining after this one.
            let count = max(1, step.n)
            if count == 1 {
                advanceStepIndex(si, stepCount: stepCount, state: &state)
                state.repRemaining = 0
            } else if state.repRemaining == 0 {
                state.repRemaining = count - 1   // first hit: start burst
            } else {
                state.repRemaining -= 1
                if state.repRemaining == 0 {
                    advanceStepIndex(si, stepCount: stepCount, state: &state)
                }
            }
            return ([state.notePtr], true)

        case .play:
            // Play one or more absolute pool positions (a chord). Pointer lands on the
            // first so a following Fwd/Back continues sensibly from the chord root.
            let indices = playIndices(for: step, noteCount: noteCount)
            state.notePtr = indices[0]
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            return (indices, true)

        case .skip:
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            return ([], false)

        case .random:
            // Jump to a random step, align note pointer, then execute that step's logic
            let r = stepCount > 1 ? Int.random(in: 0..<stepCount) : 0
            let target = track.steps[r]
            state.stepIndex = (r + 1) % stepCount
            state.notePtr = r % noteCount

            switch target.type {
            case .fwd:
                let idx = state.notePtr
                state.notePtr = (state.notePtr + max(1, target.n)) % noteCount
                return ([idx], true)
            case .back:
                let idx = state.notePtr
                let n = max(1, target.n)
                state.notePtr = ((state.notePtr - n) % noteCount + noteCount) % noteCount
                return ([idx], true)
            case .play:
                let indices = playIndices(for: target, noteCount: noteCount)
                state.notePtr = indices[0]
                return (indices, true)
            case .rep:
                return ([state.notePtr], true)
            case .skip:
                return ([], false)
            case .random:
                let idx = state.notePtr
                state.notePtr = (state.notePtr + 1) % noteCount
                return ([idx], true)
            }
        }
    }
}
