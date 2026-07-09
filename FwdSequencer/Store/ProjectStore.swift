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
    @Published var currentBar: Int = 0
    @Published var playingNotes: [UUID: Int] = [:]
    @Published var activeSteps: [UUID: Int] = [:]
    @Published var trackLevels: [UUID: Float] = [:]
    @Published var masterLevel: Float = 0

    let audioEngine = AudioEngineManager()
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

        sequencer.onNotePlayed = { [weak self] trackID, midiNote in
            DispatchQueue.main.async {
                if let note = midiNote {
                    self?.playingNotes[trackID] = note
                } else {
                    self?.playingNotes.removeValue(forKey: trackID)
                }
            }
        }

        audioEngine.onLevelUpdate = { [weak self] id, level in
            DispatchQueue.main.async { self?.trackLevels[id] = level }
        }

        audioEngine.onMasterLevelUpdate = { [weak self] level in
            DispatchQueue.main.async { self?.masterLevel = level }
        }

        sequencer.onBarChange = { [weak self] bar in
            DispatchQueue.main.async { self?.currentBar = bar }
        }

        sequencer.onStepChange = { [weak self] trackID, stepIdx in
            DispatchQueue.main.async { self?.activeSteps[trackID] = stepIdx }
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

    func saveNow() {
        guard let data = try? JSONEncoder().encode(project) else { return }
        try? data.write(to: projectURL(for: project.id), options: .atomic)
        DispatchQueue.main.async { self.savedSignal.send() }
    }

    func load(project: Project) {
        stop()
        // Remove all existing audio tracks
        for track in self.project.tracks {
            audioEngine.removeTrack(id: track.id)
        }
        self.project = project
        // Re-add audio nodes for the loaded project
        for track in project.tracks {
            audioEngine.addTrack(id: track.id)
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
            audioEngine.addTrack(id: track.id)
        }
        isPlaying = true
        currentBar = 0
        sequencer.start(project: project)
    }

    func pause() {
        sequencer.pause()
        isPlaying = false
        isPaused = true
        playingNotes.removeAll()
        activeSteps.removeAll()
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
        currentBar = 0
        playingNotes.removeAll()
        activeSteps.removeAll()
    }

    func rewind() {
        sequencer.rewind()
        currentBar = 0
        playingNotes.removeAll()
        activeSteps.removeAll()
    }

    // MARK: - Track management

    func addTrack() {
        let track = Track(name: "Track \(project.tracks.count + 1)")
        project.tracks.append(track)
        audioEngine.addTrack(id: track.id)
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

    func copyTrack(at index: Int) {
        var copy = project.tracks[index]
        copy.id = UUID()
        copy.name = copy.name + " Copy"
        project.tracks.insert(copy, at: index + 1)
        audioEngine.addTrack(id: copy.id)
    }
}
