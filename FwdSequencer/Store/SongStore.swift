import Foundation
import Combine
import SwiftUI

enum TrackPluginStatus: Equatable {
    case loading(String)
    case ready
    case failed(String)
}

enum SectionTransform: String, CaseIterable, Identifiable {
    case rotateNotes = "Rotate Notes"
    case reverseNotes = "Reverse Notes"
    case flipDirection = "Flip Direction"
    case evolve = "Evolve One Step"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .rotateNotes: return "arrow.triangle.2.circlepath"
        case .reverseNotes: return "arrow.left.arrow.right"
        case .flipDirection: return "arrow.uturn.left"
        case .evolve: return "wand.and.stars"
        }
    }
}

// MARK: - SongStore
//
// Playback + persistence coordinator for a Song, mirroring ProjectStore. Shares
// the singleton AudioEngineManager (one audio session for the app) but owns its
// own SequencerEngine and telemetry monitors. Only one document (a pattern OR a
// song) is ever on screen / playing at a time; `activate()` claims the shared
// engine's level callbacks for whichever store is in front. See SONG_MODE_PLAN.md.

class SongStore: ObservableObject {
    @Published var song: Song = Song() {
        didSet {
            // Send one coherent snapshot so section order, track state, tempo, meter,
            // mute/solo, and notes cannot drift into different scheduler revisions.
            if isPlaying || isPaused { updateLiveSong() }
            scheduleSave()
        }
    }
    @Published var isPlaying: Bool = false
    @Published var isPaused: Bool = false
    /// Which section playback is currently in (drives the arrangement playhead).
    @Published var currentSection: Int = 0
    /// Which section the editors are bound to (the one the user is editing).
    @Published var selectedSection: Int = 0
    /// True while instruments are still spinning up after opening a song.
    @Published var isLoading: Bool = false
    @Published var pluginStatuses: [UUID: TrackPluginStatus] = [:]
    @Published var audioStatus: AudioEngineStatus = .recovering
    @Published var notice: String? = nil
    @Published private(set) var isRecording = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// When off (default), the song plays once to the end and stops; on, it loops.
    @Published var loopEnabled: Bool = false {
        didSet {
            if isPlaying || isPaused { updateLiveSong() }
        }
    }
    /// Keep the editor on the sounding section. This is a local workflow preference,
    /// not song data, so collaborators opening the document keep their own setting.
    @Published var followsPlayhead: Bool = UserDefaults.standard.object(
        forKey: "FollowsSongPlayhead"
    ) as? Bool ?? true {
        didSet { UserDefaults.standard.set(followsPlayhead, forKey: "FollowsSongPlayhead") }
    }

    let levels = LevelMonitor()
    let playback = PlaybackMonitor()
    let audioEngine = AudioEngineManager.shared
    let sequencer = SequencerEngine()
    let pluginManager = PluginManager.shared

    let savedSignal = PassthroughSubject<Void, Never>()
    let beatSignal  = PassthroughSubject<Bool, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var saveWorkItem: DispatchWorkItem?
    private var pendingPluginLoads = PluginLoadTracker()
    private var recordingURL: URL?
    /// True only once a song has actually been opened/created. The store's default
    /// `song` is an empty Song() with a fresh UUID at launch; without this guard a
    /// background save (captureAndSave) would persist that empty default as a new
    /// .fwdsong on every launch.
    private var hasActiveSong = false
    private var undoStack: [Song] = []
    private var redoStack: [Song] = []

    init() {
        sequencer.audioEngine = audioEngine
        audioStatus = audioEngine.currentStatus

        audioEngine.onStatusChange = { [weak self] status in
            self?.audioStatus = status
            if case .failed(let message) = status { self?.notice = message }
        }
        audioEngine.onPlaybackInterrupted = { [weak self] message in
            self?.pauseForAudioInterruption(message)
        }
        audioEngine.onRecoveryRequired = { [weak self] in
            self?.reloadAudioGraph()
        }
        audioEngine.onRecordingError = { [weak self] detail in
            if let url = self?.recordingURL { try? FileManager.default.removeItem(at: url) }
            self?.isRecording = false
            self?.recordingURL = nil
            self?.notice = AudioRecordingError.writeFailed(detail).localizedDescription
        }

        sequencer.onNotePlayed = { [weak self] trackID, notes in
            DispatchQueue.main.async {
                if notes.isEmpty {
                    self?.playback.playingNotes.removeValue(forKey: trackID)
                } else {
                    self?.playback.playingNotes[trackID] = notes
                }
            }
        }
        sequencer.onBarChange = { [weak self] bar in
            DispatchQueue.main.async { self?.playback.currentBar = bar }
        }
        sequencer.onStepChange = { [weak self] trackID, stepIdx in
            DispatchQueue.main.async { self?.playback.activeSteps[trackID] = stepIdx }
        }
        sequencer.onBeat = { [weak self] isDownbeat in
            DispatchQueue.main.async { self?.beatSignal.send(isDownbeat) }
        }
        sequencer.onSectionChange = { [weak self] index in
            DispatchQueue.main.async {
                self?.currentSection = index
                // Follow the playhead so the note editor (blue selected keys, steps,
                // section settings) reflects the section currently sounding. Fires
                // only during playback, so manual selection is untouched when stopped.
                if self?.followsPlayhead == true { self?.selectedSection = index }
            }
        }
        sequencer.onSongFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isPlaying = false
                self.isPaused = false
                self.currentSection = 0
                self.playback.currentBar = 0
                self.playback.playingNotes.removeAll()
                self.playback.activeSteps.removeAll()
            }
        }

        $song
            .map(\.masterVolume)
            .removeDuplicates()
            .sink { [weak self] vol in self?.audioEngine.setMasterVolume(vol) }
            .store(in: &cancellables)

        // Push volume/pan to mixer nodes only when a value actually changed.
        $song
            .map { song -> [TrackMix] in
                song.tracks.map { TrackMix(id: $0.id, volume: $0.mixer.volume, pan: $0.mixer.pan) }
            }
            .removeDuplicates()
            .sink { [weak self] mixes in
                guard let self else { return }
                for mix in mixes {
                    audioEngine.setVolume(mix.volume, for: mix.id)
                    audioEngine.setPan(mix.pan, for: mix.id)
                }
            }
            .store(in: &cancellables)
    }

    private struct TrackMix: Equatable {
        let id: UUID
        let volume: Float
        let pan: Float
    }

    /// Claim the shared engine's level callbacks for this store. Call when the
    /// song view comes to the front so meter telemetry routes to *these* monitors.
    func activate() {
        audioEngine.onLevelUpdate = { [weak self] id, level in
            DispatchQueue.main.async { self?.levels.trackLevels[id] = level }
        }
        audioEngine.onMasterLevelUpdate = { [weak self] level in
            DispatchQueue.main.async { self?.levels.masterLevel = level }
        }
        audioEngine.setMasterVolume(song.masterVolume)
    }

    // MARK: - Flatten for the sequencer

    /// Build the sequencer's per-section playable view. Mute/solo come from the
    /// track (constant across sections); note data comes from each section's Part.
    private func flattenedSections() -> [SequencerSection] {
        song.sections.map { section in
            let tracks: [PlayTrack] = song.tracks.map { st in
                let part = section.parts.first { $0.trackID == st.id }
                return PlayTrack(
                    id: st.id,
                    tempoDivision: part?.tempoDivision ?? .quarter,
                    notePool: part?.notePool ?? [],
                    steps: part?.steps ?? [],
                    isMuted: st.mixer.isMuted,
                    isSoloed: st.mixer.isSoloed
                )
            }
            return SequencerSection(id: section.id, numberOfBars: section.numberOfBars, tracks: tracks)
        }
    }

    private func updateLiveSong() {
        sequencer.updateSong(
            sections: flattenedSections(),
            tempo: song.tempo,
            timeSignature: song.timeSignature,
            trackIDs: song.tracks.map(\.id),
            loop: loopEnabled
        )
    }

    // MARK: - Open / persistence

    /// Open a song: tear down any previously loaded instruments and load this
    /// song's instruments once (concurrently — open time ≈ one plugin's load).
    func open(_ song: Song, preserveHistory: Bool = false) {
        let safeSong: Song
        do {
            safeSong = try SongValidator.validateAndNormalize(song)
        } catch {
            notice = error.localizedDescription
            return
        }
        stop()
        pendingPluginLoads.cancelAll()
        pluginStatuses.removeAll()
        isLoading = false
        for t in self.song.tracks { audioEngine.removeTrack(id: t.id) }
        if let performance = self.song.performance { audioEngine.removeTrack(id: performance.id) }

        // A song must always have at least one section — note data lives in a section's
        // Part, so with zero sections note edits have nowhere to go and silently fail.
        // (An older saved song can decode with an empty section list.)
        let song = safeSong

        if !preserveHistory {
            undoStack.removeAll()
            redoStack.removeAll()
            updateHistoryAvailability()
        }

        self.song = song
        hasActiveSong = true
        selectedSection = 0
        currentSection = 0
        activate()

        for track in song.tracks {
            audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
            if let plugin = track.pluginInfo {
                loadPlugin(plugin, for: track.id, stateData: track.pluginStateData)
            }
        }

        // The manual Play-dock instrument, if this song has one.
        if let perf = song.performance {
            audioEngine.addTrack(id: perf.id, volume: perf.mixer.volume, pan: perf.mixer.pan)
            if let plugin = perf.pluginInfo {
                loadPlugin(plugin, for: perf.id, stateData: perf.pluginStateData)
            }
        }
    }

    private func loadPlugin(_ info: PluginInfo?, for trackID: UUID, stateData: Data? = nil) {
        let token = pendingPluginLoads.begin(for: trackID)
        pluginStatuses[trackID] = .loading(info?.name ?? "Built-in Sound")
        isLoading = true
        audioEngine.loadPlugin(info, for: trackID, stateData: stateData) { [weak self] result in
            guard let self else { return }
            guard pendingPluginLoads.finish(for: trackID, token: token) else { return }
            isLoading = !pendingPluginLoads.isEmpty
            switch result {
            case .success:
                pluginStatuses[trackID] = .ready
            case .failure(.cancelled):
                pluginStatuses.removeValue(forKey: trackID)
            case .failure(let error):
                let message = error.localizedDescription
                pluginStatuses[trackID] = .failed(message)
                notice = message
            }
        }
    }


    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Persist the model only — notes, arrangement, and whatever plugin-state blobs are
    /// already in the model. It deliberately does NOT read live plugin state: doing that
    /// on every debounced save pokes every plugin's state machinery ~1×/sec, which can
    /// destabilise a fragile AUv3 the user is actively editing. Live state is captured
    /// separately, only at safe moments (see captureAllPluginStates).
    func saveNow() {
        // Don't persist the empty default song that exists before any song is opened.
        guard hasActiveSong else { return }
        // Snapshot copy — never mutate self.song here or didSet → scheduleSave would loop.
        let snapshot = song
        switch SongStorage.saveResult(snapshot) {
        case .success:
            DispatchQueue.main.async { self.savedSignal.send() }
        case .failure(let error):
            notice = error.localizedDescription
        }
    }

    /// Read every instrument's live AUv3 state into the model. Only call at safe points
    /// (editor close, pause, leaving the song, backgrounding) — never on a timer while a
    /// plugin UI is open. Skipped while instruments are still loading/restoring, so it
    /// can't read a half-initialised plugin and clobber good state.
    func captureAllPluginStates() {
        guard !isLoading else { return }
        for idx in song.tracks.indices {
            if let state = audioEngine.captureState(for: song.tracks[idx].id) {
                song.tracks[idx].pluginStateData = state
            }
        }
        if let perfID = song.performance?.id,
           let state = audioEngine.captureState(for: perfID) {
            song.performance?.pluginStateData = state
        }
    }

    /// Capture live plugin state and persist immediately. For safe-point saves
    /// (backgrounding, leaving the song) where the debounced timer isn't guaranteed to fire.
    func captureAndSave() {
        // Capturing state deliberately sends all-notes-off. Keep background playback
        // continuous; capture rich AU state later when playback is paused or closed.
        if !isPlaying { captureAllPluginStates() }
        saveNow()
    }

    // MARK: - Playback

    func play() {
        activate()
        for track in song.tracks where !audioEngine.hasInstrument(for: track.id) {
            audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
            if let plugin = track.pluginInfo {
                loadPlugin(plugin, for: track.id, stateData: track.pluginStateData)
            }
        }
        isPlaying = true
        isPaused = false
        playback.currentBar = 0
        sequencer.startSong(
            sections: flattenedSections(),
            tempo: song.tempo,
            timeSignature: song.timeSignature,
            trackIDs: song.tracks.map(\.id),
            loop: loopEnabled,
            randomSeed: song.randomSeed ?? Self.seed(from: song.id)
        )
    }

    func pause() {
        sequencer.pause()
        isPlaying = false
        isPaused = true
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
        // Paused = a safe moment (no MIDI flowing) to snapshot live plugin sounds.
        captureAllPluginStates()
    }

    func resume() {
        updateLiveSong()
        sequencer.resume(tempo: song.tempo)
        isPlaying = true
        isPaused = false
    }

    func stop() {
        sequencer.stop()
        isPlaying = false
        isPaused = false
        currentSection = 0
        playback.currentBar = 0
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func rewind() {
        sequencer.rewind()
        currentSection = 0
        playback.currentBar = 0
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func midiPanic() {
        sequencer.stop()
        audioEngine.allNotesOff()
        isPlaying = false
        isPaused = false
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func beginRecording() throws {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FWD-\(UUID().uuidString).caf")
        try audioEngine.startRecording(to: url)
        recordingURL = url
        isRecording = true
    }

    func finishRecording() throws -> Data {
        guard isRecording, let url = recordingURL else {
            throw AudioRecordingError.unavailable
        }
        audioEngine.stopRecording()
        isRecording = false
        recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }
        do { return try Data(contentsOf: url) }
        catch { throw AudioRecordingError.writeFailed(error.localizedDescription) }
    }

    /// Release this song's instruments (call when leaving the song view). Captures live
    /// plugin state and persists BEFORE tearing the instruments down (they must still be
    /// loaded to read their state), so the sounds you were editing are saved.
    func close() {
        if isRecording {
            audioEngine.stopRecording()
            if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
            recordingURL = nil
            isRecording = false
        }
        stop()
        captureAllPluginStates()
        saveNow()
        pendingPluginLoads.cancelAll()
        pluginStatuses.removeAll()
        isLoading = false
        for t in song.tracks { audioEngine.removeTrack(id: t.id) }
        if let perf = song.performance { audioEngine.removeTrack(id: perf.id) }
        // No song is open anymore — a later background save must not re-persist this.
        hasActiveSong = false
    }

    // MARK: - Manual Play-dock instrument

    /// Choose (or change) the instrument the manual keyboard drives. Independent of
    /// the sequencer tracks — it gets its own engine voice.
    func setPerformancePlugin(_ info: PluginInfo?) {
        var perf = song.performance ?? SongTrack(name: "Manual Keys")
        if perf.pluginInfo == info { return }
        checkpointForUndo()
        perf.pluginInfo = info
        perf.pluginStateData = nil
        song.performance = perf
        if !audioEngine.hasInstrument(for: perf.id) {
            audioEngine.addTrack(id: perf.id, volume: perf.mixer.volume, pan: perf.mixer.pan)
        }
        if let info {
            loadPlugin(info, for: perf.id)
        } else {
            loadPlugin(nil, for: perf.id)
        }
    }

    func setPerformanceVolume(_ v: Float) {
        song.performance?.mixer.volume = v
        if let id = song.performance?.id { audioEngine.setVolume(v, for: id) }
    }

    func capturePerformanceState() {
        guard let id = song.performance?.id,
              let state = audioEngine.captureState(for: id) else { return }
        song.performance?.pluginStateData = state
    }

    // MARK: - Track editing

    func addTrack() {
        checkpointForUndo()
        let track = SongTrack(name: "Track \(song.tracks.count + 1)")
        song.tracks.append(track)
        // Every section gains an (empty) part for the new track.
        for i in song.sections.indices {
            song.sections[i].parts.append(Part(trackID: track.id))
            for variationIndex in song.sections[i].variations.indices {
                song.sections[i].variations[variationIndex].parts.append(Part(trackID: track.id))
            }
        }
        audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
    }

    func deleteTrack(_ trackID: UUID) {
        checkpointForUndo()
        pendingPluginLoads.cancel(for: trackID)
        pluginStatuses.removeValue(forKey: trackID)
        isLoading = !pendingPluginLoads.isEmpty
        audioEngine.removeTrack(id: trackID)
        song.tracks.removeAll { $0.id == trackID }
        for i in song.sections.indices {
            song.sections[i].parts.removeAll { $0.trackID == trackID }
            for variationIndex in song.sections[i].variations.indices {
                song.sections[i].variations[variationIndex].parts.removeAll { $0.trackID == trackID }
            }
        }
    }

    func moveTrackUp(_ trackID: UUID) {
        guard let i = song.tracks.firstIndex(where: { $0.id == trackID }), i > 0 else { return }
        checkpointForUndo()
        song.tracks.swapAt(i, i - 1)
    }

    func moveTrackDown(_ trackID: UUID) {
        guard let i = song.tracks.firstIndex(where: { $0.id == trackID }), i < song.tracks.count - 1 else { return }
        checkpointForUndo()
        song.tracks.swapAt(i, i + 1)
    }

    /// Duplicate a track (new instrument instance + independent note data in every section).
    func duplicateTrack(_ trackID: UUID) {
        guard let i = song.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        checkpointForUndo()
        var copy = song.tracks[i]
        copy.id = UUID()
        copy.name = copy.name + " Copy"
        song.tracks.insert(copy, at: i + 1)

        // Clone this track's note data in every section onto the new track id.
        for s in song.sections.indices {
            var newPart = song.sections[s].parts.first(where: { $0.trackID == trackID }) ?? Part(trackID: copy.id)
            newPart.trackID = copy.id
            song.sections[s].parts.append(newPart)
            for variationIndex in song.sections[s].variations.indices {
                var variationPart = song.sections[s].variations[variationIndex].parts
                    .first(where: { $0.trackID == trackID }) ?? Part(trackID: copy.id)
                variationPart.trackID = copy.id
                song.sections[s].variations[variationIndex].parts.append(variationPart)
            }
        }

        audioEngine.addTrack(id: copy.id, volume: copy.mixer.volume, pan: copy.mixer.pan)
        if let plugin = copy.pluginInfo {
            loadPlugin(plugin, for: copy.id, stateData: copy.pluginStateData)
        }
    }

    func setPlugin(_ info: PluginInfo?, for trackID: UUID) {
        guard let idx = song.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        guard song.tracks[idx].pluginInfo != info else { return }
        checkpointForUndo()
        song.tracks[idx].pluginInfo = info
        song.tracks[idx].pluginStateData = nil
        if let info {
            loadPlugin(info, for: trackID)
        } else {
            loadPlugin(nil, for: trackID)
        }
    }

    func capturePluginState(for trackID: UUID) {
        guard let idx = song.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if let state = audioEngine.captureState(for: trackID) {
            song.tracks[idx].pluginStateData = state
        }
    }

    // MARK: - Section editing (independent clones — no cross-section reuse)

    func addSection() {
        checkpointForUndo()
        song.addEmptySection(named: "Section \(song.sections.count + 1)")
        selectedSection = song.sections.count - 1
    }

    /// Deep value-copy → a fully independent clone (new ids), inserted after the source.
    func duplicateSection(at index: Int) {
        guard song.sections.indices.contains(index) else { return }
        checkpointForUndo()
        var copy = song.sections[index]
        copy.id = UUID()
        copy.name = copy.name + " copy"
        song.sections.insert(copy, at: index + 1)
        selectedSection = index + 1
    }

    func moveSection(from: Int, to: Int) {
        guard song.sections.indices.contains(from),
              to >= 0, to < song.sections.count, from != to else { return }
        checkpointForUndo()
        let sec = song.sections.remove(at: from)
        song.sections.insert(sec, at: to)
        selectedSection = to
    }

    func deleteSection(at index: Int) {
        guard song.sections.count > 1, song.sections.indices.contains(index) else { return }
        checkpointForUndo()
        song.sections.remove(at: index)
        selectedSection = min(selectedSection, song.sections.count - 1)
    }

    func transformSelectedSection(_ transform: SectionTransform) {
        guard song.sections.indices.contains(selectedSection) else { return }
        checkpointForUndo()

        switch transform {
        case .rotateNotes:
            for index in song.sections[selectedSection].parts.indices
                where song.sections[selectedSection].parts[index].notePool.count > 1 {
                let first = song.sections[selectedSection].parts[index].notePool.removeFirst()
                song.sections[selectedSection].parts[index].notePool.append(first)
            }
        case .reverseNotes:
            for index in song.sections[selectedSection].parts.indices {
                song.sections[selectedSection].parts[index].notePool.reverse()
            }
        case .flipDirection:
            for partIndex in song.sections[selectedSection].parts.indices {
                for stepIndex in song.sections[selectedSection].parts[partIndex].steps.indices {
                    let type = song.sections[selectedSection].parts[partIndex].steps[stepIndex].type
                    if type == .fwd { song.sections[selectedSection].parts[partIndex].steps[stepIndex].type = .back }
                    else if type == .back { song.sections[selectedSection].parts[partIndex].steps[stepIndex].type = .fwd }
                }
            }
        case .evolve:
            var seed = song.randomSeed ?? Self.seed(from: song.id)
            seed &+= 0x9E3779B97F4A7C15
            var generator = SeededRandomGenerator(seed: seed)
            let candidates: [StepType] = [.fwd, .back, .rep, .random, .hold, .pause]
            for partIndex in song.sections[selectedSection].parts.indices {
                guard !song.sections[selectedSection].parts[partIndex].steps.isEmpty else { continue }
                let stepIndex = generator.nextIndex(
                    upperBound: song.sections[selectedSection].parts[partIndex].steps.count
                )
                let typeIndex = generator.nextIndex(upperBound: candidates.count)
                song.sections[selectedSection].parts[partIndex].steps[stepIndex].type = candidates[typeIndex]
            }
            song.randomSeed = seed
        }
    }

    func captureVariation() {
        guard song.sections.indices.contains(selectedSection),
              song.sections[selectedSection].variations.count < 32 else { return }
        checkpointForUndo()
        let number = song.sections[selectedSection].variations.count + 1
        let snapshot = SectionVariation(
            name: "Variation \(number)",
            parts: song.sections[selectedSection].parts
        )
        song.sections[selectedSection].variations.append(snapshot)
    }

    func applyVariation(_ variationID: UUID) {
        guard song.sections.indices.contains(selectedSection),
              let variation = song.sections[selectedSection].variations
                .first(where: { $0.id == variationID }),
              variation.parts != song.sections[selectedSection].parts else { return }
        checkpointForUndo()
        song.sections[selectedSection].parts = variation.parts
    }

    func deleteVariation(_ variationID: UUID) {
        guard song.sections.indices.contains(selectedSection),
              song.sections[selectedSection].variations.contains(where: { $0.id == variationID })
        else { return }
        checkpointForUndo()
        song.sections[selectedSection].variations.removeAll { $0.id == variationID }
    }

    private static func seed(from id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(UInt64(0x465744)) { partial, byte in
                (partial &* 1099511628211) ^ UInt64(byte)
            }
        }
    }

    func checkpointForUndo() {
        guard undoStack.last != song else { return }
        undoStack.append(song)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    /// Record an editor's pre-presentation value after the editor closes, but only if
    /// it actually changed the song. Binding-driven sheets become one meaningful undo
    /// transaction instead of creating an entry for every slider tick.
    func recordUndoSnapshot(_ snapshot: Song) {
        guard snapshot != song, undoStack.last != snapshot else { return }
        undoStack.append(snapshot)
        if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(song)
        open(previous, preserveHistory: true)
        updateHistoryAvailability()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(song)
        open(next, preserveHistory: true)
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func pauseForAudioInterruption(_ message: String) {
        guard isPlaying else {
            notice = message
            return
        }
        sequencer.pause()
        isPlaying = false
        isPaused = true
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
        notice = message
    }

    private func reloadAudioGraph() {
        pauseForAudioInterruption("The audio system restarted. Instruments are being reloaded.")
        pendingPluginLoads.cancelAll()
        pluginStatuses.removeAll()
        isLoading = false
        for track in song.tracks {
            audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
            if let plugin = track.pluginInfo {
                loadPlugin(plugin, for: track.id, stateData: track.pluginStateData)
            }
        }
        if let perf = song.performance {
            audioEngine.addTrack(id: perf.id, volume: perf.mixer.volume, pan: perf.mixer.pan)
            if let plugin = perf.pluginInfo {
                loadPlugin(plugin, for: perf.id, stateData: perf.pluginStateData)
            }
        }
    }
}
