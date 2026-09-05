import Foundation

/// The real-time sequencer only needs these three MIDI operations. Keeping that
/// boundary independent of AVFoundation lets the deterministic scheduler run in
/// portable tests with a recording fake.
nonisolated protocol SequencerAudioOutput: AnyObject {
    func playNote(trackID: UUID, midiNote: UInt8, velocity: UInt8)
    func stopNote(trackID: UUID, midiNote: UInt8)
    func allNotesOff()
}

// MARK: - Playable views
//
// The tick loop triggers against these lightweight per-track views rather than a
// whole Track. (Note: the tick loop does not read key/scale — those are edit-time
// constraints only.)

nonisolated struct PlayTrack {
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
}

/// One section of a song, flattened for playback.
nonisolated struct SequencerSection {
    let id: UUID
    let numberOfBars: Int
    let tracks: [PlayTrack]
}

/// Mutable playback state is confined to `sequencerQueue`; callbacks are installed
/// during SongStore initialization and hand UI work back to the main queue.
nonisolated final class SequencerEngine: @unchecked Sendable {
    var audioEngine: SequencerAudioOutput?
    var onNotePlayed: ((UUID, [Int]) -> Void)?   // notes now sounding ([] = none)
    var onBarChange: ((Int) -> Void)?
    var onStepChange: ((UUID, Int) -> Void)?
    /// Fires on every beat. `true` = downbeat (beat 1 of bar), `false` = all other beats.
    var onBeat: ((Bool) -> Void)?
    /// Fires when playback advances to a new section (by index).
    var onSectionChange: ((Int) -> Void)?
    /// Fires when a non-looping song plays past its last section.
    var onSongFinished: (() -> Void)?

    /// Owns every mutable scheduler field below. Public commands enqueue work here;
    /// timer ticks and note-offs already execute here, eliminating UI/timer races.
    private let sequencerQueue = DispatchQueue(label: "com.fwd.sequencer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var states: [UUID: TrackState] = [:]
    // Per-track pending note-offs, keyed by a unique id so each note releases on its
    // own schedule (a chord's notes can have different gate lengths). Each work item
    // removes its own entry when it fires, so a non-empty map means notes still ring.
    private var pendingNoteOffs: [UUID: [Int: DispatchWorkItem]] = [:]
    private var noteOffSeq = 0

    private func cancelPendingNoteOffs(for trackID: UUID) {
        pendingNoteOffs[trackID]?.values.forEach { $0.cancel() }
        pendingNoteOffs.removeValue(forKey: trackID)
    }

    private func cancelAllPendingNoteOffs() {
        for items in pendingNoteOffs.values { items.values.forEach { $0.cancel() } }
        pendingNoteOffs.removeAll()
    }
    private var globalStep = 0
    /// Tick resolution: 24 per quarter note.
    ///
    /// It was 8, which is a 32nd-note grid and divides only by two — so nothing in the
    /// sequencer could express a triplet, and swing was therefore impossible. 24 is the
    /// smallest value divisible by both 8 (for 32nds) and 3 (for triplets), so every
    /// division below lands on a whole tick.
    ///
    /// Musical durations are unchanged by this: the tick interval is
    /// 60 / tempo / stepsPerBeat, so tripling the resolution thirds the interval and a
    /// quarter note still lasts a quarter note.
    private let stepsPerBeat = 24
    /// Ticks per whole note — the unit the time signature's denominator divides.
    private var ticksPerWholeNote: Int { stepsPerBeat * 4 }

    // Live playback snapshot. All access is sequencerQueue-only. `sectionIndex` is
    // queue-owned state, like globalStep.
    private var songLoops = true
    /// When set, playback repeats this one section instead of moving through the
    /// arrangement — the editing "Hold". Keyed by section ID rather than index so that
    /// reordering or deleting sections cannot silently hold the wrong one.
    private var heldSectionID: UUID?
    private var sectionIndex = 0
    private var _songSections: [SequencerSection] = []
    private var _songTempo: Double = 120
    private var _songTimeSignature = TimeSignature()
    private var initialRandomSeed: UInt64 = 0x465744
    private var random = SeededRandomGenerator(seed: 0x465744)

    // A resolved snapshot the tick loop plays against.
    private struct Frame {
        let tempo: Double
        let timeSignature: TimeSignature
        let numberOfBars: Int
        let tracks: [PlayTrack]
    }

    /// The snapshot the tick loop plays against: the section currently sounding.
    private func currentFrame() -> Frame {
        guard !_songSections.isEmpty else {
            return Frame(tempo: _songTempo, timeSignature: _songTimeSignature,
                         numberOfBars: 1, tracks: [])
        }
        let idx = min(max(0, sectionIndex), _songSections.count - 1)
        let s = _songSections[idx]
        return Frame(tempo: _songTempo, timeSignature: _songTimeSignature,
                     numberOfBars: s.numberOfBars, tracks: s.tracks)
    }

    private func songSectionCount() -> Int {
        _songSections.count
    }

    private struct TrackState {
        var stepIndex: Int = 0
        var notePtr: Int = 0
        var lastMidiNotes: [Int] = []   // notes currently ringing (>1 for a chord)
        var dwellRemaining: Int = 0     // triggers left dwelling on the current step
                                        // (Rep replays, Hold holds, Pause rests) — 0 = not dwelling
        // Set of pool positions the current chord occupies. nil = single-note mode.
        var voicing: [Int]? = nil
        // False until the first note is played. The first Fwd/Back plays the starting
        // note in place (so a plain Fwd,Fwd,… run begins on note 1); every step after
        // moves the pointer first, then plays — so Play→Rep→Fwd/Back doesn't replay.
        var hasPlayed: Bool = false
        // A Hold/Pause dwell carried over from the previous section. While set, the
        // track ignores the new section's steps and keeps holding/resting until the
        // dwell finishes — so a Hold on the last beat spans into the next section.
        var carry: StepType? = nil
    }

    // MARK: - Lifecycle

    /// Start song playback: play `sections` in order, looping back to the first.
    /// `trackIDs` are the stable SongTrack ids (instrument keys) so per-track state
    /// carries across sections.
    func startSong(sections: [SequencerSection], tempo: Double,
                   timeSignature: TimeSignature, trackIDs: [UUID], loop: Bool,
                   randomSeed: UInt64 = 0x465744, heldSection: UUID? = nil) {
        sequencerQueue.async { [weak self] in
            guard let self else { return }
            stopTimer()
            globalStep = 0
            heldSectionID = heldSection
            // Start ON the held section: pressing play with a section held should sound
            // that section, not restart the arrangement from the top.
            sectionIndex = heldSection.flatMap { id in sections.firstIndex { $0.id == id } } ?? 0
            songLoops = loop
            _songSections = sections
            _songTempo = tempo
            _songTimeSignature = timeSignature
            initialRandomSeed = randomSeed
            random = SeededRandomGenerator(seed: randomSeed)
            cancelAllPendingNoteOffs()
            audioEngine?.allNotesOff()
            states = Dictionary(uniqueKeysWithValues: trackIDs.map { ($0, TrackState()) })
            onSectionChange?(sectionIndex)
            startTimer(tempo: tempo, immediate: true)
        }
    }

    /// Hold playback on one section (by ID) so it repeats for editing, or pass nil to
    /// release and resume moving through the arrangement. Takes effect at the next
    /// section boundary, so engaging it never chops the bar that is playing.
    func holdSection(_ sectionID: UUID?) {
        sequencerQueue.async { [weak self] in self?.heldSectionID = sectionID }
    }

    /// Atomically push the complete live song configuration. Current section identity
    /// survives reordering, new tracks gain state immediately, and removed tracks are
    /// silenced before their state is discarded.
    func updateSong(sections: [SequencerSection], tempo: Double,
                    timeSignature: TimeSignature, trackIDs: [UUID], loop: Bool) {
        sequencerQueue.async { [weak self] in
            guard let self else { return }

            let currentID = _songSections.indices.contains(sectionIndex)
                ? _songSections[sectionIndex].id : nil
            let oldTempo = _songTempo

            _songSections = sections
            _songTempo = tempo
            _songTimeSignature = timeSignature
            songLoops = loop

            if let currentID, let newIndex = sections.firstIndex(where: { $0.id == currentID }) {
                sectionIndex = newIndex
            } else {
                sectionIndex = min(sectionIndex, max(0, sections.count - 1))
            }

            reconcileTrackStates(trackIDs: trackIDs)
            silenceInaudibleTracks()

            if timer != nil, oldTempo != tempo {
                stopTimer()
                startTimer(tempo: tempo, immediate: false)
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        sequencerQueue.async { [weak self] in
            self?.stopInternal(resetPosition: true)
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    private func stopInternal(resetPosition: Bool) {
        stopTimer()
        if resetPosition {
            globalStep = 0
            sectionIndex = 0
            random = SeededRandomGenerator(seed: initialRandomSeed)
        }
        for key in Array(states.keys) { states[key] = TrackState() }
        cancelAllPendingNoteOffs()
        audioEngine?.allNotesOff()
        if resetPosition { onBarChange?(0) }
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    /// Pause at a queue boundary. Delayed ratchets share `pendingNoteOffs` with
    /// note releases, so merely cancelling the repeating timer is insufficient:
    /// already-enqueued ratchets can otherwise sound after the UI says Paused.
    /// Track traversal state is retained so resume continues from the same place.
    func pause(completion: (() -> Void)? = nil) {
        sequencerQueue.async { [weak self] in
            guard let self else { return }
            stopTimer()
            cancelAllPendingNoteOffs()
            audioEngine?.allNotesOff()
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }

    func resume(tempo: Double) {
        sequencerQueue.async { [weak self] in
            guard let self, timer == nil else { return }
            _songTempo = tempo
            startTimer(tempo: tempo, immediate: false)
        }
    }

    func rewind() {
        sequencerQueue.async { [weak self] in
            guard let self else { return }
            globalStep = 0
            // Rewind to the HELD section when one is held — rewinding to the top would
            // jump away from the section being edited.
            sectionIndex = heldSectionID.flatMap { id in self._songSections.firstIndex { $0.id == id } } ?? 0
            random = SeededRandomGenerator(seed: initialRandomSeed)
            for key in Array(states.keys) { states[key] = TrackState() }
            cancelAllPendingNoteOffs()
            audioEngine?.allNotesOff()
            onBarChange?(0)
            onSectionChange?(sectionIndex)
        }
    }

    // MARK: - Tick scheduling
    //
    // The handler used to be `tick()` directly, which quietly made the sequencer run
    // SLOW. A DispatchSourceTimer keeps its own absolute schedule, so it does not
    // accumulate error from handler execution time — but when the system is busy it
    // COALESCES firings that fall due together, delivering one callback where several
    // were owed. Counting one step per callback therefore lost the difference: the
    // sequence fell progressively behind wall-clock time, and with MIDI clock enabled
    // it dragged everything slaved to it along too.
    //
    // Ticks are now counted against the timeline instead of against callbacks: each
    // firing works out how many are due and issues the backlog.

    /// Ticks issued back-to-back to make up a shortfall. A coalesced firing is normally
    /// one or two ticks behind, and catching those up is inaudible. A larger gap means
    /// a real stall (an instrument loading, the app suspended), and replaying it as a
    /// burst would dump a bar of notes at once — so past this the timeline is rebased
    /// instead, keeping the sequence continuous at the cost of the lost time.
    private var maxCatchUpTicks: Int64 { Int64(stepsPerBeat / 2) }

    private var tickIntervalNanos: Int64 = 0
    /// Monotonic uptime at which tick 0 of the current timer was due.
    private var firstTickNanos: Int64 = 0
    private var ticksIssued: Int64 = 0

    private func startTimer(tempo: Double, immediate: Bool) {
        let safeTempo = min(max(tempo, 20), 400)
        let interval = 60.0 / safeTempo / Double(stepsPerBeat)
        let deadline = DispatchTime.now() + (immediate ? 0 : interval)
        tickIntervalNanos = Int64((interval * 1_000_000_000).rounded())
        firstTickNanos = Int64(bitPattern: deadline.uptimeNanoseconds)
        ticksIssued = 0
        let t = DispatchSource.makeTimerSource(queue: sequencerQueue)
        t.schedule(deadline: deadline, repeating: interval, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.fireDueTicks() }
        t.resume()
        timer = t
    }

    /// Issue every tick the timeline says is owed, not just one per callback.
    private func fireDueTicks() {
        guard tickIntervalNanos > 0 else { tick(); return }
        let now = Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
        let elapsed = max(0, now - firstTickNanos)
        let due = elapsed / tickIntervalNanos + 1
        var backlog = due - ticksIssued

        if backlog < 1 {
            backlog = 1          // fired a touch early (leeway) — still run this one
        } else if backlog > maxCatchUpTicks {
            // Rebase so the CURRENT position becomes "on time" and carry on, rather
            // than firing the whole backlog at once.
            firstTickNanos = now - ticksIssued * tickIntervalNanos
            backlog = 1
        }

        for _ in 0..<backlog {
            ticksIssued += 1
            tick()
            // finishSong() stops the timer mid-catch-up; anything further would start
            // replaying the song from the top.
            if timer == nil { break }
        }
    }

    private func reconcileTrackStates(trackIDs: [UUID]) {
        let desired = Set(trackIDs)
        for removed in Array(states.keys) where !desired.contains(removed) {
            cancelPendingNoteOffs(for: removed)
            for note in states[removed]?.lastMidiNotes ?? [] {
                audioEngine?.stopNote(trackID: removed, midiNote: UInt8(note))
            }
            states.removeValue(forKey: removed)
        }
        for added in desired where states[added] == nil {
            states[added] = TrackState()
        }
    }

    private func silenceInaudibleTracks() {
        let frame = currentFrame()
        let anySoloed = frame.tracks.contains(where: { $0.isSoloed })
        let audible = Set(frame.tracks.compactMap { track in
            (!track.isMuted && (!anySoloed || track.isSoloed)) ? track.id : nil
        })
        for id in Array(states.keys) where !audible.contains(id) {
            cancelPendingNoteOffs(for: id)
            for note in states[id]?.lastMidiNotes ?? [] {
                audioEngine?.stopNote(trackID: id, midiNote: UInt8(note))
            }
            states[id]?.lastMidiNotes.removeAll()
            onNotePlayed?(id, [])
        }
    }

    private static func seed(from id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { bytes in
            bytes.enumerated().reduce(UInt64(0x465744)) { partial, pair in
                (partial &* 1099511628211) ^ UInt64(pair.element)
            }
        }
    }

    // MARK: - Tick

    private func tick() {
        var frame = currentFrame()
        let interval = 60.0 / frame.tempo / Double(stepsPerBeat)

        // How many ticks make one bar, at the 32nd-note tick resolution above.
        // Formula: numerator beats × (32 ticks per whole note / denominator).
        var stepsPerBar = max(1, frame.timeSignature.numerator * ticksPerWholeNote / frame.timeSignature.denominator)
        var totalSteps  = stepsPerBar * max(1, frame.numberOfBars)

        // Loop point: end of the current pattern/section.
        if globalStep >= totalSteps {
            // A Hold/Pause still dwelling at the boundary carries into the next
            // section: a two-beat Hold on the last beat keeps holding through beat 1
            // of the next section. Detect those tracks (from the OLD section's steps,
            // frame is still the old section here) and preserve their dwell.
            var carries: [UUID: TrackState] = [:]
            for track in frame.tracks {
                guard let st = states[track.id], st.dwellRemaining > 0 else { continue }
                let carryType: StepType?
                if let existing = st.carry {
                    carryType = existing                       // already carrying — keep going
                } else if !track.steps.isEmpty {
                    let type = track.steps[st.stepIndex % track.steps.count].type
                    carryType = (type == .hold || type == .pause) ? type : nil
                } else {
                    carryType = nil
                }
                guard let ct = carryType else { continue }
                var carried = TrackState()
                carried.carry = ct
                carried.dwellRemaining = st.dwellRemaining
                carried.notePtr = st.notePtr
                carried.lastMidiNotes = ct == .hold ? st.lastMidiNotes : []  // Hold keeps ringing
                carries[track.id] = carried
            }

            // Every other track hard-restarts: release its ringing notes and drop
            // pending note-offs so nothing bleeds into the next section (the "extra"/
            // muddy artifact). A carrying Hold is left untouched so it keeps sounding.
            for key in Array(states.keys) {
                if carries[key]?.carry == .hold { continue }
                cancelPendingNoteOffs(for: key)
                for note in states[key]?.lastMidiNotes ?? [] {
                    audioEngine?.stopNote(trackID: key, midiNote: UInt8(note))
                }
            }
            for key in Array(states.keys) { states[key] = carries[key] ?? TrackState() }
            globalStep = 0
            let count = songSectionCount()
            if count > 0 {
                // Held: repeat this section rather than advancing. A hold engaged while
                // a different section was playing lands here, so playback moves to the
                // held one at the boundary. The end-of-arrangement check is skipped
                // deliberately — hold outranks "don't loop", or turning it on near the
                // end of a non-looping song would stop playback instead of repeating.
                let held = heldSectionID.flatMap { id in _songSections.firstIndex { $0.id == id } }
                if let held {
                    if held != sectionIndex {
                        sectionIndex = held
                        onSectionChange?(sectionIndex)
                        frame = currentFrame()
                        stepsPerBar = max(1, frame.timeSignature.numerator * ticksPerWholeNote / frame.timeSignature.denominator)
                        totalSteps  = stepsPerBar * max(1, frame.numberOfBars)
                    }
                } else {
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
                    stepsPerBar = max(1, frame.timeSignature.numerator * ticksPerWholeNote / frame.timeSignature.denominator)
                    totalSteps  = stepsPerBar * max(1, frame.numberOfBars)
                }
            }
        }

        // Fire after resolving a section boundary so the UI never briefly receives
        // an out-of-range value such as "bar 5 of 4" from the previous section.
        if globalStep % stepsPerBar == 0 {
            onBarChange?(globalStep / stepsPerBar)
        }

        // Beat indicator — fires every beat; true = downbeat (beat 1 of bar)
        let stepsPerBeatTS = max(1, ticksPerWholeNote / frame.timeSignature.denominator)
        if globalStep % stepsPerBeatTS == 0 {
            let isDownbeat = (globalStep % stepsPerBar) == 0
            onBeat?(isDownbeat)
        }

        let anySoloed = frame.tracks.contains(where: { $0.isSoloed })

        for track in frame.tracks {
            guard !track.notePool.isEmpty else { continue }

            // Single source of truth for the grid, shared with the model layer.
            let triggerEvery = max(1, track.tempoDivision.sequencerTicks)

            guard globalStep % triggerEvery == 0 else { continue }
            guard var state = states[track.id] else { continue }

            if !track.steps.isEmpty {
                onStepChange?(track.id, state.stepIndex % track.steps.count)
            }

            let shouldSound = !track.isMuted && (!anySoloed || track.isSoloed)
            let isCarrying = state.carry != nil
            let activeStep = track.steps.isEmpty ? nil : track.steps[state.stepIndex % track.steps.count]
            var (poolIndices, stopPrev, stepGate) = executeStep(track: track, state: &state)
            let probability = isCarrying ? 1 : min(1, max(0, activeStep?.probability ?? 1))
            let ratchets = min(8, max(1, activeStep?.ratchets ?? 1))
            let passesProbability = probability >= 1 || random.nextUnitInterval() < probability
            if !passesProbability {
                poolIndices.removeAll()
                stopPrev = true
            }

            let stepDuration = interval * Double(triggerEvery)

            if stopPrev {
                // Cancel pending releases and stop all ringing notes immediately.
                cancelPendingNoteOffs(for: track.id)
                for last in state.lastMidiNotes {
                    audioEngine?.stopNote(trackID: track.id, midiNote: UInt8(last))
                }
                state.lastMidiNotes = []
            } else if pendingNoteOffs[track.id] != nil {
                // Skip — notes still ringing: hold them through the skip by extending
                // every pending release by one step. (Same serial queue, so a non-empty
                // map reliably means the notes haven't been released yet.)
                cancelPendingNoteOffs(for: track.id)
                for note in state.lastMidiNotes {
                    scheduleNoteOff(trackID: track.id, midiNote: UInt8(note), delay: stepDuration)
                }
            }
            // else: Skip but releases already fired — notes are off, nothing to extend

            if shouldSound, !poolIndices.isEmpty {
                // Play every note in the (possibly chord) step. Each note releases on
                // its own schedule: its gate × the step's gate. So per-note gates shape
                // the chord internally, while the step gate scales the whole thing.
                var notes: [Int] = []
                for idx in poolIndices {
                    // Belt and braces: every producer of poolIndices bounds-checks, but
                    // this is the one place a stale index would trap on the audio path.
                    guard idx >= 0, idx < track.notePool.count else { continue }
                    let entry = track.notePool[idx]
                    let midiNote = UInt8(entry.midiNote)
                    audioEngine?.playNote(trackID: track.id, midiNote: midiNote, velocity: UInt8(entry.velocity))
                    notes.append(entry.midiNote)
                    let noteGate = max(0.01, entry.gateLength * stepGate)
                    let subdivision = stepDuration / Double(ratchets)
                    scheduleNoteOff(trackID: track.id, midiNote: midiNote, delay: noteGate * subdivision)
                    if ratchets > 1 {
                        for ratchet in 1..<ratchets {
                            scheduleRatchet(
                                trackID: track.id,
                                midiNote: midiNote,
                                velocity: UInt8(entry.velocity),
                                delay: Double(ratchet) * subdivision,
                                gateDuration: noteGate * subdivision
                            )
                        }
                    }
                }
                state.lastMidiNotes = notes
                onNotePlayed?(track.id, notes)   // highlight every note in the chord
            } else if poolIndices.isEmpty && stopPrev {
                onNotePlayed?(track.id, [])
            }

            states[track.id] = state
        }

        globalStep += 1
    }

    // Non-looping song reached its end: stop the timer and signal completion.
    private func finishSong() {
        stopTimer()
        globalStep = 0
        sectionIndex = 0
        for key in Array(states.keys) { states[key] = TrackState() }
        cancelAllPendingNoteOffs()
        audioEngine?.allNotesOff()
        onSongFinished?()
    }

    // Schedule a single note's release on the sequencer queue so it serialises with
    // ticks. Each work item self-removes from the per-track map when it fires, so the
    // non-empty check in the skip-extend path reliably means notes still ring.
    private func scheduleNoteOff(trackID: UUID, midiNote: UInt8, delay: Double) {
        noteOffSeq += 1
        let offID = noteOffSeq
        let noteInt = Int(midiNote)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            audioEngine?.stopNote(trackID: trackID, midiNote: midiNote)
            // Repeated ratchets of the same pitch overlap. Remove only the note-on
            // paired with this release; removing every occurrence loses ownership of
            // a later ratchet and can leave it sounding when the next step cancels
            // its queued note-off.
            if let index = states[trackID]?.lastMidiNotes.firstIndex(of: noteInt) {
                states[trackID]?.lastMidiNotes.remove(at: index)
            }
            pendingNoteOffs[trackID]?.removeValue(forKey: offID)
            if pendingNoteOffs[trackID]?.isEmpty == true { pendingNoteOffs.removeValue(forKey: trackID) }
        }
        pendingNoteOffs[trackID, default: [:]][offID] = item
        sequencerQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Queue a later note-on as a cancellable sequencer event. Reusing the pending
    /// event map means stop, rewind, section changes, and track deletion cannot leave
    /// a delayed ratchet firing after playback has moved on.
    private func scheduleRatchet(trackID: UUID, midiNote: UInt8, velocity: UInt8,
                                 delay: Double, gateDuration: Double) {
        noteOffSeq += 1
        let eventID = noteOffSeq
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            pendingNoteOffs[trackID]?.removeValue(forKey: eventID)
            if pendingNoteOffs[trackID]?.isEmpty == true {
                pendingNoteOffs.removeValue(forKey: trackID)
            }
            audioEngine?.playNote(trackID: trackID, midiNote: midiNote, velocity: velocity)
            states[trackID]?.lastMidiNotes.append(Int(midiNote))
            scheduleNoteOff(trackID: trackID, midiNote: midiNote, delay: gateDuration)
        }
        pendingNoteOffs[trackID, default: [:]][eventID] = item
        sequencerQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Step Execution
    // Returns (notePoolIndex, stopPreviousNote).
    // notePoolIndex nil = don't play. stopPreviousNote false = let current note ring (Skip).

    private func advanceStepIndex(_ si: Int, stepCount: Int, state: inout TrackState) {
        state.stepIndex = (si + 1) % stepCount
        // notePtr intentionally NOT reset on wrap — generative patterns rely on the
        // pointer continuing to evolve across step-list loops.
    }

    // Stay on the current step for `count` triggers, then advance. Shared by Rep (which
    // replays), Hold (holds the note) and Pause (rests) — a track dwells on one step at
    // a time, so a single counter suffices.
    private func dwell(_ count: Int, si: Int, stepCount: Int, state: inout TrackState) {
        if count <= 1 {
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            state.dwellRemaining = 0
        } else if state.dwellRemaining == 0 {
            state.dwellRemaining = count - 1   // first trigger: start the dwell
        } else {
            state.dwellRemaining -= 1
            if state.dwellRemaining == 0 { advanceStepIndex(si, stepCount: stepCount, state: &state) }
        }
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
            // Out-of-range chord positions are dropped; if every one is gone the result
            // is empty → the hit is skipped (matches single-note Play below).
            return result
        }
        // Single-note Play: if the position no longer exists in the pool (e.g. a note was
        // removed on a key change), skip the hit rather than clamping to a different note.
        let idx = step.n - 1
        return (idx >= 0 && idx < noteCount) ? [idx] : []
    }

    // Returns (poolIndices, stopPreviousNote, stepGate). stepGate scales note lengths.
    private func executeStep(track: PlayTrack, state: inout TrackState) -> ([Int], Bool, Double) {
        let noteCount = track.notePool.count
        let stepCount = track.steps.count
        guard noteCount > 0 else { return ([], true, 1.0) }

        guard stepCount > 0 else {
            let index = state.notePtr % noteCount
            state.notePtr = (index + 1) % noteCount
            state.hasPlayed = true
            return ([index], true, 1.0)
        }

        state.notePtr = state.notePtr % noteCount

        // Re-validate a carried-over chord voicing against the CURRENT pool.
        //
        // `voicing` holds absolute pool positions captured when a Play step ran. The
        // pool can shrink underneath it while the sequencer is running — dropping
        // out-of-key notes on a key change does exactly that — and `.rep` returned the
        // voicing verbatim, so `notePool[idx]` indexed past the end and trapped. (Fwd
        // and Back happened to survive because they map through `% noteCount`.)
        //
        // Survivors are kept and dropped positions discarded, matching how a Play
        // chord is pruned on a key change. Down to one note, the track returns to
        // single-note mode; down to none, the voicing is abandoned.
        if let v = state.voicing {
            let valid = v.filter { $0 >= 0 && $0 < noteCount }
            if valid.count > 1 {
                state.voicing = valid
            } else {
                state.voicing = nil
                if let only = valid.first { state.notePtr = only }
            }
        }

        // Finish a Hold/Pause carried over from the previous section before running
        // any of this section's steps. Each trigger consumes one of the remaining
        // dwell counts; when it runs out, hand off to step 0 on the next trigger.
        if let carryType = state.carry {
            state.dwellRemaining -= 1
            if state.dwellRemaining <= 0 {
                state.carry = nil
                state.stepIndex = 0
            }
            return carryType == .hold ? ([], false, 1.0) : ([], true, 1.0)
        }

        let si = state.stepIndex % stepCount
        let step = track.steps[si]

        switch step.type {

        case .fwd:
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            let n = max(1, step.n)
            if let v = state.voicing {
                // Chord mode: slide the whole voicing forward, then play it.
                let moved = v.map { ($0 + n) % noteCount }
                state.voicing = moved
                state.notePtr = moved.first ?? 0
                state.hasPlayed = true
                return (moved, true, step.gate)
            }
            // First step plays the starting note in place; afterwards move forward THEN
            // play — so a plain Fwd run walks 0,1,2… while Play→Rep→Fwd doesn't replay.
            if state.hasPlayed { state.notePtr = (state.notePtr + n) % noteCount }
            state.hasPlayed = true
            return ([state.notePtr], true, step.gate)

        case .back:
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            let n = max(1, step.n)
            if let v = state.voicing {
                let moved = v.map { (($0 - n) % noteCount + noteCount) % noteCount }
                state.voicing = moved
                state.notePtr = moved.first ?? 0
                state.hasPlayed = true
                return (moved, true, step.gate)
            }
            if state.hasPlayed { state.notePtr = ((state.notePtr - n) % noteCount + noteCount) % noteCount }
            state.hasPlayed = true
            return ([state.notePtr], true, step.gate)

        case .rep:
            // Replay the current note/chord for n triggers.
            dwell(max(1, step.n), si: si, stepCount: stepCount, state: &state)
            state.hasPlayed = true
            return (state.voicing ?? [state.notePtr], true, step.gate)

        case .play:
            // Absolute pool positions. A chord (>1 note) becomes the moving voicing that
            // following Fwd/Back/Rep transform; a single note returns to single-note mode.
            let indices = playIndices(for: step, noteCount: noteCount)
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            // No valid position (e.g. Play 4 after the pool shrank to 3) → skip the hit:
            // advance the step but play nothing, leaving the pointer where it was.
            guard !indices.isEmpty else {
                state.voicing = nil
                return ([], true, step.gate)
            }
            state.voicing = indices.count > 1 ? indices : nil
            state.notePtr = indices[0]
            state.hasPlayed = true
            return (indices, true, step.gate)

        case .hold:
            // Keep the previous note ringing (no new note, don't stop it) for n triggers.
            dwell(max(1, step.n), si: si, stepCount: stepCount, state: &state)
            return ([], false, 1.0)

        case .pause:
            // Rest: note-off the previous note and stay silent for n triggers.
            dwell(max(1, step.n), si: si, stepCount: stepCount, state: &state)
            return ([], true, 1.0)

        case .random:
            // Play a random note; leave the pointer ON it so subsequent steps
            // (Fwd/Back/Hold…) calculate from the random note itself. Returns to
            // single-note mode (a random chord isn't meaningful here).
            state.voicing = nil
            let idx = random.nextIndex(upperBound: noteCount)
            state.notePtr = idx
            state.hasPlayed = true
            advanceStepIndex(si, stepCount: stepCount, state: &state)
            return ([idx], true, step.gate)
        }
    }
}
