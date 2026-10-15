import Foundation
import Combine
import os
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

// MARK: - Batching telemetry onto the main thread
//
// Telemetry arrives from other threads one item at a time — a level per track per
// meter tap, a note and a step per track per trigger — and used to be posted to the
// main thread one item at a time, each a separate @Published change. Every change to a
// monitor re-evaluates EVERY view observing it, not just the one track's: twelve meters
// each updating twenty times a second redrew all twelve meters 240 times a second, and
// one track's step moving redrew every track's step strip and keyboard.
//
// These collect items as they arrive and hand them to the main thread as one change.
// What is shown is the same; only how often the screen is told changes.


/// Track and master levels, published together at most every `interval` seconds.
nonisolated final class LevelBatcher: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var pendingTracks: [UUID: AudioLevel] = [:]
    private var pendingMaster: AudioLevel?
    private var scheduled = false
    private let interval: TimeInterval
    private let deliver: ([UUID: AudioLevel], AudioLevel?) -> Void

    /// `deliver` runs on the main thread.
    init(interval: TimeInterval = 0.05,
         deliver: @escaping ([UUID: AudioLevel], AudioLevel?) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func track(_ id: UUID, _ level: AudioLevel) {
        lock.lock(); pendingTracks[id] = level; let start = claimFlush(); lock.unlock()
        if start { scheduleFlush() }
    }

    func master(_ level: AudioLevel) {
        lock.lock(); pendingMaster = level; let start = claimFlush(); lock.unlock()
        if start { scheduleFlush() }
    }

    /// Caller holds the lock. True for the item that should schedule the flush.
    private func claimFlush() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    private func scheduleFlush() {
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            lock.lock()
            let tracks = pendingTracks, master = pendingMaster
            pendingTracks = [:]; pendingMaster = nil; scheduled = false
            lock.unlock()
            deliver(tracks, master)
        }
    }
}

/// Notes and steps from the sequencer, published together on the next main-thread turn.
/// A tick's worth of tracks arrives within microseconds, so it usually lands as one.
nonisolated final class PlaybackBatcher: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    /// An empty array means "nothing sounding" — the entry is removed.
    private var pendingNotes: [UUID: [Int]] = [:]
    private var pendingSteps: [UUID: Int] = [:]
    private var scheduled = false
    private let deliver: ([UUID: [Int]], [UUID: Int]) -> Void

    /// `deliver` runs on the main thread.
    init(deliver: @escaping ([UUID: [Int]], [UUID: Int]) -> Void) {
        self.deliver = deliver
    }

    func notes(_ id: UUID, _ notes: [Int]) {
        lock.lock(); pendingNotes[id] = notes; let start = claimFlush(); lock.unlock()
        if start { scheduleFlush() }
    }

    func step(_ id: UUID, _ step: Int) {
        lock.lock(); pendingSteps[id] = step; let start = claimFlush(); lock.unlock()
        if start { scheduleFlush() }
    }

    /// Drop anything not yet delivered — playback stopped and the display was cleared,
    /// so a late batch must not put notes back.
    func discard() {
        lock.lock(); pendingNotes = [:]; pendingSteps = [:]; lock.unlock()
    }

    private func claimFlush() -> Bool {
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    private func scheduleFlush() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lock.lock()
            let notes = pendingNotes, steps = pendingSteps
            pendingNotes = [:]; pendingSteps = [:]; scheduled = false
            lock.unlock()
            guard !notes.isEmpty || !steps.isEmpty else { return }
            deliver(notes, steps)
        }
    }
}
