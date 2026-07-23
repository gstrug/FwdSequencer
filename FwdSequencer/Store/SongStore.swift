import Foundation
import Combine
import SwiftUI

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
            // Live edits take effect on the next loop while playing.
            if isPlaying { sequencer.updateSongSections(flattenedSections()) }
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
    /// When off (default), the song plays once to the end and stops; on, it loops.
    @Published var loopEnabled: Bool = false

    let levels = LevelMonitor()
    let playback = PlaybackMonitor()
    let audioEngine = AudioEngineManager.shared
    let sequencer = SequencerEngine()
    let pluginManager = PluginManager.shared

    let savedSignal = PassthroughSubject<Void, Never>()
    let beatSignal  = PassthroughSubject<Bool, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var saveWorkItem: DispatchWorkItem?

    init() {
        sequencer.audioEngine = audioEngine

        sequencer.onNotePlayed = { [weak self] trackID, midiNote in
            DispatchQueue.main.async {
                if let note = midiNote {
                    self?.playback.playingNotes[trackID] = note
                } else {
                    self?.playback.playingNotes.removeValue(forKey: trackID)
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
                self?.selectedSection = index
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

        // Live tempo change while playing.
        $song
            .map(\.tempo)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newTempo in
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.sequencer.updateTempo(newTempo)
            }
            .store(in: &cancellables)

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
            return SequencerSection(numberOfBars: section.numberOfBars, tracks: tracks)
        }
    }

    // MARK: - Open / persistence

    /// Open a song: tear down any previously loaded instruments and load this
    /// song's instruments once (concurrently — open time ≈ one plugin's load).
    func open(_ song: Song) {
        stop()
        for t in self.song.tracks { audioEngine.removeTrack(id: t.id) }

        self.song = song
        selectedSection = 0
        currentSection = 0
        activate()

        for track in song.tracks {
            audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
            if let plugin = track.pluginInfo {
                audioEngine.loadPlugin(plugin, for: track.id, stateData: track.pluginStateData)
            }
        }

        // Instruments instantiate asynchronously and restore state ~1 s later.
        // No per-plugin ready callback yet (Phase 6), so approximate with a short
        // loading window sized to one plugin's load+restore.
        if song.tracks.contains(where: { $0.pluginInfo != nil }) {
            isLoading = true
            // Must outlast the 1.0 s state-restore in loadPlugin so a save during the
            // window can't capture a plugin before it has restored.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.isLoading = false
            }
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    func saveNow() {
        // Snapshot copy with current AUv3 states — never mutate self.song here or
        // didSet → scheduleSave would loop (see ProjectStore.saveNow).
        var snapshot = song
        // Do NOT re-capture plugin state while instruments are still loading/restoring:
        // getPluginState could read a half-initialised plugin (e.g. GeoShred mid-restore)
        // and clobber the good state we just loaded. Keep the model's existing state
        // during that window; normal capture resumes once loading finishes.
        if !isLoading {
            for idx in snapshot.tracks.indices {
                if let state = audioEngine.getPluginState(for: snapshot.tracks[idx].id) {
                    snapshot.tracks[idx].pluginStateData = state
                }
            }
        }
        guard SongStorage.save(snapshot) else { return }
        DispatchQueue.main.async { self.savedSignal.send() }
    }

    // MARK: - Playback

    func play() {
        activate()
        for track in song.tracks where !audioEngine.hasInstrument(for: track.id) {
            audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
            if let plugin = track.pluginInfo {
                audioEngine.loadPlugin(plugin, for: track.id, stateData: track.pluginStateData)
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
            loop: loopEnabled
        )
    }

    func pause() {
        sequencer.pause()
        isPlaying = false
        isPaused = true
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func resume() {
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

    /// Release this song's instruments (call when leaving the song view).
    func close() {
        stop()
        for t in song.tracks { audioEngine.removeTrack(id: t.id) }
    }

    // MARK: - Track editing

    func addTrack() {
        let track = SongTrack(name: "Track \(song.tracks.count + 1)")
        song.tracks.append(track)
        // Every section gains an (empty) part for the new track.
        for i in song.sections.indices {
            song.sections[i].parts.append(Part(trackID: track.id))
        }
        audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
    }

    func deleteTrack(_ trackID: UUID) {
        audioEngine.removeTrack(id: trackID)
        song.tracks.removeAll { $0.id == trackID }
        for i in song.sections.indices {
            song.sections[i].parts.removeAll { $0.trackID == trackID }
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
        }

        audioEngine.addTrack(id: copy.id, volume: copy.mixer.volume, pan: copy.mixer.pan)
        if let plugin = copy.pluginInfo {
            audioEngine.loadPlugin(plugin, for: copy.id, stateData: copy.pluginStateData)
        }
    }

    func setPlugin(_ info: PluginInfo?, for trackID: UUID) {
        audioEngine.loadPlugin(info, for: trackID)
        if let idx = song.tracks.firstIndex(where: { $0.id == trackID }) {
            song.tracks[idx].pluginInfo = info
            song.tracks[idx].pluginStateData = nil
        }
    }

    func capturePluginState(for trackID: UUID) {
        guard let idx = song.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if let state = audioEngine.getPluginState(for: trackID) {
            song.tracks[idx].pluginStateData = state
        }
    }

    // MARK: - Section editing (independent clones — no cross-section reuse)

    func addSection() {
        song.addEmptySection(named: "Section \(song.sections.count + 1)")
        selectedSection = song.sections.count - 1
    }

    /// Deep value-copy → a fully independent clone (new ids), inserted after the source.
    func duplicateSection(at index: Int) {
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
}
