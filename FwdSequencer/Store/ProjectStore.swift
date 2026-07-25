import Foundation
import Combine
import SwiftUI

// MARK: - File helpers

private let projectsDirectory: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let dir = docs.appendingPathComponent("Projects", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

private func projectURL(for id: UUID) -> URL {
    projectsDirectory.appendingPathComponent("\(id.uuidString).fwdproj")
}

// MARK: - ProjectStore

class ProjectStore: ObservableObject {
    @Published var project: Project = Project() {
        didSet {
            sequencer.updateProject(project)
            scheduleSave()
        }
    }
    @Published var isPlaying: Bool = false
    @Published var isPaused: Bool = false

    /// High-frequency VU-meter telemetry, isolated from this store so meter
    /// updates don't invalidate the whole view tree during playback.
    let levels = LevelMonitor()
    /// Note/step/bar telemetry, isolated for the same reason.
    let playback = PlaybackMonitor()

    let audioEngine = AudioEngineManager.shared
    let sequencer = SequencerEngine()
    let pluginManager = PluginManager.shared

    /// Fires once after each successful auto-save so the UI can show a confirmation.
    let savedSignal = PassthroughSubject<Void, Never>()
    /// Fires on every beat. true = downbeat (beat 1), false = all other beats.
    let beatSignal = PassthroughSubject<Bool, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var saveWorkItem: DispatchWorkItem?

    init() {
        sequencer.audioEngine = audioEngine

        sequencer.onNotePlayed = { [weak self] trackID, notes in
            DispatchQueue.main.async {
                if notes.isEmpty {
                    self?.playback.playingNotes.removeValue(forKey: trackID)
                } else {
                    self?.playback.playingNotes[trackID] = notes
                }
            }
        }

        audioEngine.onLevelUpdate = { [weak self] id, level in
            DispatchQueue.main.async { self?.levels.trackLevels[id] = level }
        }

        audioEngine.onMasterLevelUpdate = { [weak self] level in
            DispatchQueue.main.async { self?.levels.masterLevel = level }
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

        $project
            .map(\.tempo)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] newTempo in
                guard let self, self.isPlaying, !self.isPaused else { return }
                self.sequencer.updateTempo(newTempo)
            }
            .store(in: &cancellables)

        $project
            .map(\.masterVolume)
            .removeDuplicates()
            .sink { [weak self] vol in self?.audioEngine.setMasterVolume(vol) }
            .store(in: &cancellables)

        // Apply volume/pan to mixer nodes whenever track mixer state changes.
        // Running on the main thread avoids data races with node graph modifications.
        // Only touch the audio node graph when a volume/pan value actually changed
        // (removeDuplicates) — not on every unrelated project edit (rename, note
        // toggle, tempo, step change all mutate `project` and would otherwise
        // re-push volume+pan to every mixer node).
        $project
            .map { project -> [TrackMix] in
                project.tracks.map { TrackMix(id: $0.id, volume: $0.mixer.volume, pan: $0.mixer.pan) }
            }
            .removeDuplicates()
            .sink { [weak self] states in
                guard let self else { return }
                for mix in states {
                    audioEngine.setVolume(mix.volume, for: mix.id)
                    audioEngine.setPan(mix.pan, for: mix.id)
                }
            }
            .store(in: &cancellables)
    }

    /// Lightweight snapshot of a track's mixer routing, used to drive the
    /// volume/pan Combine pipeline with cheap `removeDuplicates` comparison.
    private struct TrackMix: Equatable {
        let id: UUID
        let volume: Float
        let pan: Float
    }

    /// Claim the shared engine's level callbacks for this store. The engine is a
    /// singleton shared with SongStore, so whichever document is on screen must
    /// (re)claim these when it appears. Call from ProjectView.onAppear.
    func activate() {
        audioEngine.onLevelUpdate = { [weak self] id, level in
            DispatchQueue.main.async { self?.levels.trackLevels[id] = level }
        }
        audioEngine.onMasterLevelUpdate = { [weak self] level in
            DispatchQueue.main.async { self?.levels.masterLevel = level }
        }
        audioEngine.setMasterVolume(project.masterVolume)
    }

    // MARK: - File save / load

    /// Debounced auto-save — coalesces rapid edits into one write ~1 second later
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    /// True during the load/restore window. While set, saveNow keeps the state we
    /// just loaded rather than re-capturing a plugin that may still be restoring.
    private var isLoadingInstruments = false

    func saveNow() {
        // Build a snapshot copy with current AUv3 states — never mutate self.project
        // here or it would re-trigger didSet → scheduleSave → infinite loop.
        var snapshot = project
        // Skip re-capturing plugin state mid-load (see SongStore.saveNow): reading a
        // half-restored plugin would clobber the good state we just loaded.
        if !isLoadingInstruments {
            for idx in snapshot.tracks.indices {
                if let state = audioEngine.getPluginState(for: snapshot.tracks[idx].id) {
                    snapshot.tracks[idx].pluginStateData = state
                }
            }
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: projectURL(for: snapshot.id), options: .atomic)
        DispatchQueue.main.async { self.savedSignal.send() }
    }

    func load(project: Project) {
        stop()
        for track in self.project.tracks {
            audioEngine.removeTrack(id: track.id)
        }
        self.project = project
        let hasPlugins = project.tracks.contains { $0.pluginInfo != nil }
        if hasPlugins {
            isLoadingInstruments = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.isLoadingInstruments = false
            }
        }
        for track in project.tracks {
            audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
            if let plugin = track.pluginInfo {
                audioEngine.loadPlugin(plugin, for: track.id, stateData: track.pluginStateData)
            }
        }
    }

    /// Reads the plugin's current state and saves it into the track model.
    func capturePluginState(for trackID: UUID) {
        guard let idx = project.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if let state = audioEngine.getPluginState(for: trackID) {
            project.tracks[idx].pluginStateData = state
        }
    }

    static func allSavedProjects() -> [Project] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "fwdproj" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Project.self, from: data)
            }
    }

    static func delete(project: Project) {
        try? FileManager.default.removeItem(at: projectURL(for: project.id))
    }

    // MARK: - Playback

    func play() {
        for track in project.tracks {
            audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
            if let plugin = track.pluginInfo, !audioEngine.hasInstrument(for: track.id) {
                audioEngine.loadPlugin(plugin, for: track.id, stateData: track.pluginStateData)
            }
        }
        isPlaying = true
        playback.currentBar = 0
        sequencer.start(project: project)
    }

    func pause() {
        sequencer.pause()
        isPlaying = false
        isPaused = true
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func resume() {
        sequencer.resume(tempo: project.tempo)
        isPlaying = true
        isPaused = false
    }

    func stop() {
        sequencer.stop()
        isPlaying = false
        isPaused = false
        playback.currentBar = 0
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func rewind() {
        sequencer.rewind()
        playback.currentBar = 0
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    // MARK: - Track management

    func addTrack() {
        let track = Track(name: "Track \(project.tracks.count + 1)")
        project.tracks.append(track)
        audioEngine.addTrack(id: track.id, volume: track.mixer.volume, pan: track.mixer.pan)
    }

    func deleteTrack(at offsets: IndexSet) {
        for idx in offsets {
            audioEngine.removeTrack(id: project.tracks[idx].id)
        }
        project.tracks.remove(atOffsets: offsets)
    }

    func moveTrackUp(at index: Int) {
        guard index > 0 else { return }
        project.tracks.swapAt(index, index - 1)
    }

    func moveTrackDown(at index: Int) {
        guard index < project.tracks.count - 1 else { return }
        project.tracks.swapAt(index, index + 1)
    }

    func midiPanic() {
        sequencer.stop()
        audioEngine.allNotesOff()
        isPlaying = false
        isPaused = false
        playback.playingNotes.removeAll()
        playback.activeSteps.removeAll()
    }

    func setPlugin(_ pluginInfo: PluginInfo?, for trackID: UUID) {
        audioEngine.loadPlugin(pluginInfo, for: trackID)
    }

    func copyTrack(at index: Int) {
        var copy = project.tracks[index]
        copy.id = UUID()
        copy.name = copy.name + " Copy"
        project.tracks.insert(copy, at: index + 1)
        audioEngine.addTrack(id: copy.id, volume: copy.mixer.volume, pan: copy.mixer.pan)
    }
}
