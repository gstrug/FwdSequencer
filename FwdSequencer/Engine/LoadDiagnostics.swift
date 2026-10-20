import Foundation
import QuartzCore
import os

/// Timing messages for plugin loading, printed to the Xcode console as lines starting
/// `[FWD-LOAD]`. Added 2026-10-20 to find out why GeoShred now takes 12–28 s to make a
/// sound. It only records what happens; it changes nothing about how loading works.
///
/// For each track it times, from the moment its plugin load is requested: the plugin
/// being created, its saved sound being restored, the load finishing (or timing out),
/// the MIDI gate opening, the first note sent and the first sound coming out. Comparing
/// those says whether the wait is ours (notes held back) or the plugin's (notes sent,
/// silence returned).
///
/// Safe from any thread. The first-sound check runs on the audio thread, so it is a
/// single short lock and never prints there — printing is sent to the main queue.
nonisolated final class LoadDiagnostics: @unchecked Sendable {
    static let shared = LoadDiagnostics()

    private let lock = OSAllocatedUnfairLock()
    private var started: [UUID: CFTimeInterval] = [:]
    private var labels: [UUID: String] = [:]
    private var awaitingFirstNote: Set<UUID> = []
    private var awaitingFirstSound: Set<UUID> = []
    private var heldBack: [UUID: Int] = [:]
    private var songOpened: CFTimeInterval?

    private init() {}

    /// A song is being opened: times below are also given from this moment.
    func songOpening(_ name: String) {
        lock.lock(); songOpened = CACurrentMediaTime(); lock.unlock()
        print("song opening: \(name)", track: nil)
    }

    /// A plugin load was requested for a track.
    func loadStarted(_ id: UUID, label: String, hasSavedSound: Bool) {
        lock.lock()
        started[id] = CACurrentMediaTime()
        labels[id] = label
        awaitingFirstNote.insert(id)
        awaitingFirstSound.insert(id)
        heldBack[id] = 0
        lock.unlock()
        print("load requested (saved sound: \(hasSavedSound ? "yes" : "no"))", track: id)
    }

    func event(_ message: String, track id: UUID) { print(message, track: id) }

    /// A message not about one track.
    func note(_ message: String) { print(message, track: nil) }

    /// A note was not sent because the track's MIDI gate was closed.
    func noteHeldBack(_ id: UUID) {
        lock.lock()
        let first = heldBack[id] == 0 && started[id] != nil
        if heldBack[id] != nil { heldBack[id, default: 0] += 1 }
        lock.unlock()
        if first { print("first note held back: MIDI gate is closed", track: id) }
    }

    /// The track's MIDI gate has fully opened. Reported once per load: the gate also
    /// closes briefly for other reasons later (saving a sound, opening an editor).
    func gateOpened(_ id: UUID) {
        lock.lock()
        let count = heldBack.removeValue(forKey: id)
        lock.unlock()
        if let count { print("MIDI gate open (\(count) notes held back while closed)", track: id) }
    }

    /// A note-on actually went to the instrument.
    func noteSent(_ id: UUID) {
        lock.lock()
        let first = awaitingFirstNote.remove(id) != nil
        lock.unlock()
        if first { print("first note sent to the instrument", track: id) }
    }

    /// Audio thread: whether this track is still waiting for its first sound. Cheap.
    func wantsFirstSound(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return awaitingFirstSound.contains(id)
    }

    /// Audio thread: the track's output has a level. Printed once, from the main queue.
    func soundHeard(_ id: UUID, peak: Float) {
        lock.lock()
        let first = awaitingFirstSound.remove(id) != nil
        lock.unlock()
        guard first else { return }
        DispatchQueue.main.async {
            self.print(String(format: "first sound out of the track (peak %.3f)", peak), track: id)
        }
    }

    private func print(_ message: String, track id: UUID?) {
        let now = CACurrentMediaTime()
        lock.lock()
        let start = id.flatMap { started[$0] }
        let label = id.flatMap { labels[$0] } ?? ""
        let opened = songOpened
        lock.unlock()
        var line = "[FWD-LOAD]"
        if let start { line += String(format: " +%6.2fs", now - start) }
        if let opened { line += String(format: " (song +%6.2fs)", now - opened) }
        if !label.isEmpty { line += " \(label):" }
        NSLog("%@ %@", line, message)
    }
}
