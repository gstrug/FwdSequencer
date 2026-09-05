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
    /// The v1 audio verification matrix is defined up to 12 simultaneous tracks.
    /// Existing/imported documents remain readable up to the validator's safety
    /// limits; these caps only prevent the editor creating an unverified workload.
    static let maximumEditableTrackCount = 12
    static let maximumEditableSectionCount = 128

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
    @Published var selectedSection: Int = 0 {
        didSet {
            guard selectedSection != oldValue else { return }
            // The audition belongs to the section it was started from.
            stopAudition()
            guard holdsSection else { return }
            // Held: the selection IS what plays, so following it here lets the user
            // audition another section without releasing the hold.
            pushHeldSection()
        }
    }
    /// True while instruments are still spinning up after opening a song.
    @Published var isLoading: Bool = false
    @Published var pluginStatuses: [UUID: TrackPluginStatus] = [:]
    @Published var audioStatus: AudioEngineStatus = .recovering
    @Published var notice: String? = nil
    @Published private(set) var isRecording = false
    /// When off (default), the song plays once to the end and stops; on, it loops.
    @Published var loopEnabled: Bool = false {
        didSet {
            guard loopEnabled != oldValue else { return }
            // Persist with the song so the loop setting survives reopening.
            if song.loops != loopEnabled { song.loops = loopEnabled }
            if isPlaying || isPaused { updateLiveSong() }
        }
    }
    /// Repeat the SELECTED section instead of playing through the arrangement, so it
    /// can be edited against a continuous loop. Changing the selection while this is on
    /// moves playback to the newly selected section at the next boundary.
    ///
    /// Deliberately NOT persisted, unlike the loop setting: it is a transient editing
    /// mode, and silently restoring it on launch would present as "my song only plays
    /// one section". It also resets when a song is opened or closed.
    @Published var holdsSection: Bool = false {
        didSet {
            guard holdsSection != oldValue else { return }
            // Auditioning is only reachable while held; releasing the hold must not
            // leave the sequencer playing a snapshot that is not in the document.
            if !holdsSection { stopAudition() }
            pushHeldSection()
        }
    }

    /// Tell the sequencer which section to hold, or to release the hold.
    private func pushHeldSection() {
        guard holdsSection, song.sections.indices.contains(selectedSection) else {
            sequencer.holdSection(nil)
            return
        }
        sequencer.holdSection(song.sections[selectedSection].id)
    }
    @Published var midiClockEnabled: Bool = UserDefaults.standard.bool(forKey: "MIDIClockOutputEnabled") {
        didSet {
            UserDefaults.standard.set(midiClockEnabled, forKey: "MIDIClockOutputEnabled")
            if !midiClockEnabled { audioEngine.stopMIDIClock() }
            else if isPlaying { audioEngine.startMIDIClock(tempo: song.tempo) }
        }
    }

    let levels = LevelMonitor()
    let playback = PlaybackMonitor()
    let audioEngine = AudioEngineManager.shared
    let sequencer = SequencerEngine()

    let savedSignal = PassthroughSubject<Void, Never>()
    let beatSignal  = PassthroughSubject<Bool, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var saveWorkItem: DispatchWorkItem?
    /// Serial queue for document writes. A save reads the previous file back, decodes it,
    /// copies it to the backup, then encodes and writes — far too much to run on the main
    /// thread, which it did 1s after EVERY model change. Choosing an instrument is a model
    /// change, so that stall landed while the plugin's hosted view was being established.
    private let saveQueue = DispatchQueue(label: "com.fwd.song-save", qos: .utility)
    private var pendingPluginLoads = PluginLoadTracker()
    private var recordingURL: URL?
    /// True only once a song has actually been opened/created. The store's default
    /// `song` is an empty Song() with a fresh UUID at launch; without this guard a
    /// background save (captureAndSave) would persist that empty default as a new
    /// .fwdsong on every launch.
    private var hasActiveSong = false

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

        // Playback telemetry drives SwiftUI from the sequencer thread on every note,
        // step and beat. It is suppressed while a plugin builds its UI (see
        // AudioEngineManager.telemetryPaused) so that main-thread/CoreAnimation work
        // does not compete with establishing an out-of-process plugin view.
        sequencer.onNotePlayed = { [weak self] trackID, notes in
            guard self?.audioEngine.telemetryPaused == false else { return }
            DispatchQueue.main.async {
                if notes.isEmpty {
                    self?.playback.playingNotes.removeValue(forKey: trackID)
                } else {
                    self?.playback.playingNotes[trackID] = notes
                }
            }
        }
        sequencer.onBarChange = { [weak self] bar in
            guard self?.audioEngine.telemetryPaused == false else { return }
            DispatchQueue.main.async { self?.playback.currentBar = bar }
        }
        sequencer.onStepChange = { [weak self] trackID, stepIdx in
            guard self?.audioEngine.telemetryPaused == false else { return }
            DispatchQueue.main.async { self?.playback.activeSteps[trackID] = stepIdx }
        }
        sequencer.onBeat = { [weak self] isDownbeat in
            guard self?.audioEngine.telemetryPaused == false else { return }
            DispatchQueue.main.async { self?.beatSignal.send(isDownbeat) }
        }
        sequencer.onSectionChange = { [weak self] index in
            DispatchQueue.main.async {
                self?.currentSection = index
            }
        }
        sequencer.onSongFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.midiClockEnabled { self.audioEngine.stopMIDIClock() }
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

        $song
            .map(\.tempo)
            .removeDuplicates()
            .sink { [weak self] tempo in
                guard let self, midiClockEnabled, isPlaying else { return }
                audioEngine.updateMIDIClockTempo(tempo)
            }
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
        // While auditioning, the SELECTED section plays the snapshot's notes instead of
        // its own. Only what the sequencer is handed changes — `song` is untouched, so
        // an audition can be abandoned with nothing to undo.
        let auditioned: [Part]? = auditioningSnapshot.flatMap { id in
            song.sections.indices.contains(selectedSection)
                ? song.sections[selectedSection].snapshotParts(id) : nil
        }
        let auditionedSectionID: UUID? = auditioned == nil ? nil
            : (song.sections.indices.contains(selectedSection) ? song.sections[selectedSection].id : nil)

        return song.sections.map { section in
            let sourceParts = section.id == auditionedSectionID ? (auditioned ?? section.parts) : section.parts
            let tracks: [PlayTrack] = song.tracks.map { st in
                let part = sourceParts.first { $0.trackID == st.id }
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
    func open(_ song: Song) {
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

        self.song = song
        hasActiveSong = true
        loopEnabled = song.loops ?? false
        // Hold is a transient editing mode; a freshly opened song plays its arrangement.
        holdsSection = false
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
        let item = DispatchWorkItem { [weak self] in self?.saveInBackground() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// Debounced autosave. Snapshots on the main thread, then does all file I/O off it.
    /// Use `saveNow()` where the write must complete before proceeding (leaving the song,
    /// backgrounding); this variant is for the routine 1s-after-an-edit save.
    private func saveInBackground() {
        guard hasActiveSong else { return }
        let snapshot = song
        saveQueue.async { [weak self] in
            let result = SongStorage.saveResult(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.savedSignal.send()
                case .failure(let error): self.notice = error.localizedDescription
                }
            }
        }
    }

    /// Persist the model only — notes, arrangement, and whatever plugin-state blobs are
    /// already in the model. It deliberately does NOT read live plugin state: doing that
    /// on every debounced save pokes every plugin's state machinery ~1×/sec, which can
    /// destabilise a fragile AUv3 the user is actively editing. Live state is captured
    /// separately, only at safe moments (see captureAllPluginStates).
    @discardableResult
    func saveNow() -> Bool {
        // Don't persist the empty default song that exists before any song is opened.
        guard hasActiveSong else { return true }
        // Snapshot copy — never mutate self.song here or didSet → scheduleSave would loop.
        let snapshot = song
        switch SongStorage.saveResult(snapshot) {
        case .success:
            DispatchQueue.main.async { self.savedSignal.send() }
            return true
        case .failure(let error):
            notice = error.localizedDescription
            return false
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
            randomSeed: song.randomSeed ?? Self.seed(from: song.id),
            heldSection: holdsSection && song.sections.indices.contains(selectedSection)
                ? song.sections[selectedSection].id : nil
        )
        if midiClockEnabled { audioEngine.startMIDIClock(tempo: song.tempo) }
    }

    func pause() {
        if midiClockEnabled { audioEngine.stopMIDIClock() }
        isPlaying = false
        isPaused = true
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
        // Capture only after the sequencer queue has cancelled delayed ratchets and
        // silenced its outputs. If playback resumed while that barrier was pending,
        // skip capture rather than interrupt the newly-resumed performance.
        sequencer.pause { [weak self] in
            guard let self, isPaused, !isPlaying else { return }
            captureAllPluginStates()
        }
    }

    func resume() {
        updateLiveSong()
        sequencer.resume(tempo: song.tempo)
        if midiClockEnabled { audioEngine.startMIDIClock(tempo: song.tempo, continuing: true) }
        isPlaying = true
        isPaused = false
    }

    func stop() {
        sequencer.stop()
        if midiClockEnabled { audioEngine.stopMIDIClock() }
        isPlaying = false
        isPaused = false
        currentSection = 0
        playback.currentBar = 0
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func rewind() {
        sequencer.rewind()
        if midiClockEnabled && isPlaying { audioEngine.startMIDIClock(tempo: song.tempo) }
        currentSection = 0
        playback.currentBar = 0
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func midiPanic() {
        sequencer.stop()                       // cancels pending note-offs and ratchets
        if midiClockEnabled { audioEngine.stopMIDIClock() }
        audioEngine.panic()                    // aggressive: clears notes we may not be tracking
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

    /// Stop recording and hand back the captured file. The caller chooses an export
    /// format (see RecordingExporter) and must call `discardRecording` when done —
    /// the file is NOT deleted here, because converting to WAV needs to read it.
    func finishRecording() throws -> URL {
        guard isRecording, let url = recordingURL else {
            throw AudioRecordingError.unavailable
        }
        audioEngine.stopRecording()
        isRecording = false
        recordingURL = nil
        return url
    }

    /// Remove a finished recording's temporary file.
    func discardRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Release this song's instruments (call when leaving the song view). Captures live
    /// plugin state and persists BEFORE tearing the instruments down (they must still be
    /// loaded to read their state), so the sounds you were editing are saved.
    func close(completion: ((Bool) -> Void)? = nil) {
        guard !isRecording else {
            notice = "Stop and export the current recording before leaving this song."
            completion?(false)
            return
        }
        if midiClockEnabled { audioEngine.stopMIDIClock() }
        isPlaying = false
        isPaused = false
        currentSection = 0
        playback.currentBar = 0
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()

        // Do not capture AU state until the queue has cancelled its timer, ratchets,
        // and note releases. The completion returns to main for model/UI work.
        sequencer.stop { [weak self] in
            guard let self else { completion?(false); return }
            captureAllPluginStates()
            // Keep the document and its instruments alive when the final save fails.
            // SongView remains visible, so `notice` can explain the failure and the
            // user can retry instead of silently losing the latest edits.
            guard saveNow() else {
                completion?(false)
                return
            }
            pendingPluginLoads.cancelAll()
            pluginStatuses.removeAll()
            isLoading = false
            for track in song.tracks { audioEngine.removeTrack(id: track.id) }
            if let performance = song.performance { audioEngine.removeTrack(id: performance.id) }
            // No song is open anymore — a later background save must not re-persist this.
            hasActiveSong = false
            completion?(true)
        }
    }

    // MARK: - Manual Play-dock instrument

    /// Materialise the manual keyboard's built-in GM voice on first use. The Play
    /// dock must remain useful on a clean iPad with no third-party AUv3 installed.
    func ensurePerformanceInstrument() {
        if let performance = song.performance {
            if !audioEngine.hasInstrument(for: performance.id) {
                audioEngine.addTrack(
                    id: performance.id,
                    volume: performance.mixer.volume,
                    pan: performance.mixer.pan
                )
            }
            return
        }

        let performance = SongTrack(name: "Manual Keys")
        song.performance = performance
        audioEngine.addTrack(
            id: performance.id,
            volume: performance.mixer.volume,
            pan: performance.mixer.pan
        )
    }

    /// Choose (or change) the instrument the manual keyboard drives. Independent of
    /// the sequencer tracks — it gets its own engine voice.
    func setPerformancePlugin(_ info: PluginInfo?) {
        ensurePerformanceInstrument()
        guard var perf = song.performance else { return }
        if perf.pluginInfo == info { return }
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
        guard song.tracks.count < Self.maximumEditableTrackCount else {
            notice = "FWD Sequencer currently supports creating up to \(Self.maximumEditableTrackCount) tracks per song."
            return
        }
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
        song.tracks.swapAt(i, i - 1)
    }

    func moveTrackDown(_ trackID: UUID) {
        guard let i = song.tracks.firstIndex(where: { $0.id == trackID }), i < song.tracks.count - 1 else { return }
        song.tracks.swapAt(i, i + 1)
    }

    /// Duplicate a track (new instrument instance + independent note data in every section).
    func duplicateTrack(_ trackID: UUID) {
        guard song.tracks.count < Self.maximumEditableTrackCount else {
            notice = "FWD Sequencer currently supports creating up to \(Self.maximumEditableTrackCount) tracks per song."
            return
        }
        guard let i = song.tracks.firstIndex(where: { $0.id == trackID }) else { return }
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
        song.tracks[idx].pluginInfo = info
        song.tracks[idx].pluginStateData = nil
        if let info {
            loadPlugin(info, for: trackID)
        } else {
            loadPlugin(nil, for: trackID)
        }
    }

    /// Re-instantiate a track's existing instrument. Recovery for a plugin whose
    /// out-of-process view or extension has died (blank editor): the AU is rebuilt from
    /// scratch and its saved sound restored, without the user having to reassign it.
    func reloadPlugin(for trackID: UUID) {
        guard let idx = song.tracks.firstIndex(where: { $0.id == trackID }),
              let info = song.tracks[idx].pluginInfo else { return }
        // Does NOT stop playback: the theory that a plugin only loads cleanly with the
        // sequencer stopped was disproven — Stop & Load produced an equally blank UI.
        loadPlugin(info, for: trackID, stateData: song.tracks[idx].pluginStateData)
    }

    func capturePluginState(for trackID: UUID) {
        guard let idx = song.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if let state = audioEngine.captureState(for: trackID) {
            song.tracks[idx].pluginStateData = state
        }
    }

    // MARK: - Section editing (independent clones — no cross-section reuse)

    func addSection() {
        guard song.sections.count < Self.maximumEditableSectionCount else {
            notice = "A song can contain up to \(Self.maximumEditableSectionCount) editable sections."
            return
        }
        song.addEmptySection(named: "Section \(song.sections.count + 1)")
        selectedSection = song.sections.count - 1
    }

    /// Deep value-copy → a fully independent clone (new ids), inserted after the source.
    func duplicateSection(at index: Int) {
        guard song.sections.count < Self.maximumEditableSectionCount else {
            notice = "A song can contain up to \(Self.maximumEditableSectionCount) editable sections."
            return
        }
        guard song.sections.indices.contains(index) else { return }
        var copy = song.sections[index]
        copy.id = UUID()
        copy.name = copy.name + " copy"
        song.sections.insert(copy, at: index + 1)
        selectedSection = index + 1
    }

    func moveSection(from: Int, to: Int) {
        guard song.sections.indices.contains(from),
              to >= 0, to < song.sections.count, from != to else { return }
        let sec = song.sections.remove(at: from)
        song.sections.insert(sec, at: to)
        selectedSection = to
    }

    func deleteSection(at index: Int) {
        guard song.sections.count > 1, song.sections.indices.contains(index) else { return }
        song.sections.remove(at: index)
        selectedSection = min(selectedSection, song.sections.count - 1)
    }

    func transformSelectedSection(_ transform: SectionTransform) {
        guard canAlterSelectedSection else { return }
        // Transform reshapes the section in place and there is no undo, so it always
        // leaves a way back before touching anything.
        reportDroppedSnapshot(
            song.sections[selectedSection].saveSnapshot(named: "Before \(transform.rawValue)")
        )

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

    /// Altering a section requires it to be held.
    ///
    /// Transform and Restore are only worth judging by ear, and without Hold the
    /// sequencer walks on to the next section mid-audition. Holding repeats the
    /// selected section so each version can actually be heard. Enforced here as well as
    /// in the UI so the rule lives with the operations rather than with the buttons.
    var canAlterSelectedSection: Bool {
        holdsSection && song.sections.indices.contains(selectedSection)
    }

    /// Snapshot semantics live on SongSection; these wrap them for the selected section
    /// and surface anything the snapshot cap forced out.

    /// The name offered in the save prompt: describes nothing on its own, so it is only
    /// a starting point the user is expected to replace.
    func suggestedSnapshotName() -> String {
        guard song.sections.indices.contains(selectedSection) else { return "Snapshot" }
        return song.sections[selectedSection]
            .snapshotName(from: "Snapshot \(song.sections[selectedSection].variations.count + 1)")
    }

    func captureVariation(named name: String) {
        guard canAlterSelectedSection else { return }
        reportDroppedSnapshot(song.sections[selectedSection].saveSnapshot(named: name))
    }

    /// Restore CONSUMES the snapshot — see SongSection.restoreSnapshot.
    func applyVariation(_ variationID: UUID) {
        guard canAlterSelectedSection else { return }
        stopAudition()
        song.sections[selectedSection].restoreSnapshot(variationID)
    }

    func renameVariation(_ variationID: UUID, to newName: String) {
        guard song.sections.indices.contains(selectedSection) else { return }
        song.sections[selectedSection].renameSnapshot(variationID, to: newName)
    }

    // MARK: - Auditioning a snapshot
    //
    // Hearing a snapshot before committing to it. The document is NOT touched: the
    // snapshot's parts are substituted into the sections handed to the sequencer, so
    // the audition is purely a playback state and abandoning it costs nothing.

    @Published private(set) var auditioningSnapshot: UUID?

    func auditionSnapshot(_ variationID: UUID) {
        guard canAlterSelectedSection,
              song.sections[selectedSection].snapshotParts(variationID) != nil else { return }
        auditioningSnapshot = variationID
        updateLiveSong()
    }

    func stopAudition() {
        guard auditioningSnapshot != nil else { return }
        auditioningSnapshot = nil
        updateLiveSong()
    }

    private func reportDroppedSnapshot(_ droppedName: String?) {
        guard let droppedName else { return }
        notice = """
            This section already had \(SongSection.maximumSnapshots) snapshots, \
            so the oldest ("\(droppedName)") was removed to make room.
            """
    }

    func deleteVariation(_ variationID: UUID) {
        guard song.sections.indices.contains(selectedSection),
              song.sections[selectedSection].variations.contains(where: { $0.id == variationID })
        else { return }
        // Never leave playback pointed at notes that no longer exist.
        if auditioningSnapshot == variationID { stopAudition() }
        song.sections[selectedSection].variations.removeAll { $0.id == variationID }
    }

    private static func seed(from id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(UInt64(0x465744)) { partial, byte in
                (partial &* 1099511628211) ^ UInt64(byte)
            }
        }
    }


    private func pauseForAudioInterruption(_ message: String) {
        guard isPlaying else {
            notice = message
            return
        }
        if midiClockEnabled { audioEngine.stopMIDIClock() }
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
