import Foundation
import Combine
import CoreGraphics

/// One meter reading: both the true peak and the RMS of a buffer, in linear terms.
///
/// Peak is what decides clipping — RMS alone cannot show an over, which is why the
/// old single RMS value made it impossible to mix to 0 dBFS.
nonisolated struct AudioLevel: Equatable {
    var peak: Float = 0
    var rms: Float = 0

    static let silent = AudioLevel()

    /// Full scale is 0 dBFS; silence is -infinity.
    var peakDB: Float { peak > 0 ? 20 * log10(peak) : -.infinity }
    var rmsDB: Float { rms > 0 ? 20 * log10(rms) : -.infinity }

    /// A sample reached or passed full scale, so the signal is clipping.
    var isOver: Bool { peak >= 1.0 }

    /// Where a dB value sits on a meter scaled from `floorDB` to 0 dBFS.
    /// Mixing decisions live between about -30 and 0 dBFS; on the old linear scale
    /// that was squashed into the bottom few percent of the bar.
    static let floorDB: Float = -60
    static func fraction(ofDB db: Float) -> CGFloat {
        guard db.isFinite else { return 0 }
        return CGFloat(min(1, max(0, (db - floorDB) / -floorDB)))
    }
    var peakFraction: CGFloat { Self.fraction(ofDB: peakDB) }
    var rmsFraction: CGFloat { Self.fraction(ofDB: rmsDB) }
}

/// High-frequency audio-level telemetry (~20 Hz VU meters).
///
/// Kept on its own `ObservableObject`, separate from `ProjectStore`, so that a
/// meter tick only invalidates the small meter leaf views that observe it —
/// not the whole track list, transport, or any view that holds the store.
///
/// It is also kept separate from `PlaybackMonitor` so that note/step observers
/// (e.g. the 88-key keyboard highlight) do not re-render on every level update.
final class LevelMonitor: ObservableObject {
    @Published var trackLevels: [UUID: AudioLevel] = [:]
    @Published var masterLevel: AudioLevel = .silent
}

/// Musical-event telemetry: which note each track is currently sounding, the
/// active step index, and the current bar. These change at note/step/bar rate
/// (much lower than the level meters) and are isolated so that displaying them
/// doesn't invalidate views that only care about the project data.
final class PlaybackMonitor: ObservableObject {
    @Published var playingNotes: [UUID: [Int]] = [:]   // all notes currently sounding (chord = several)
    @Published var activeSteps: [UUID: Int] = [:]
    @Published var currentBar: Int = 0
}
