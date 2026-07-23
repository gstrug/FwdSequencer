import Foundation
import Combine

/// High-frequency audio-level telemetry (~20 Hz VU meters).
///
/// Kept on its own `ObservableObject`, separate from `ProjectStore`, so that a
/// meter tick only invalidates the small meter leaf views that observe it —
/// not the whole track list, transport, or any view that holds the store.
///
/// It is also kept separate from `PlaybackMonitor` so that note/step observers
/// (e.g. the 88-key keyboard highlight) do not re-render on every level update.
final class LevelMonitor: ObservableObject {
    @Published var trackLevels: [UUID: Float] = [:]
    @Published var masterLevel: Float = 0
}

/// Musical-event telemetry: which note each track is currently sounding, the
/// active step index, and the current bar. These change at note/step/bar rate
/// (much lower than the level meters) and are isolated so that displaying them
/// doesn't invalidate views that only care about the project data.
final class PlaybackMonitor: ObservableObject {
    @Published var playingNotes: [UUID: Int] = [:]
    @Published var activeSteps: [UUID: Int] = [:]
    @Published var currentBar: Int = 0
}
