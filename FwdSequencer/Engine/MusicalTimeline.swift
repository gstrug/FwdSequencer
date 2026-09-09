import Foundation

/// The mapping between MUSICAL position and real time.
///
/// Phase 1 of the look-ahead scheduler (see TIMING.md). The sequencer's timeline is
/// musical — ticks, at `ticksPerBeat` per quarter — and only the output converts to
/// seconds, sample time or host time. That direction matters: hosted as an AUv3 the
/// position would come from the host's musical context instead of our own clock, and a
/// timeline expressed in seconds would have to be torn out to allow it (TIMING.md §6).
///
/// Value type with no scheduling of its own, so it is pure and testable: it answers
/// "when does tick N happen" and "which tick is it now", nothing more.
nonisolated struct MusicalTimeline: Equatable {
    let ticksPerBeat: Int

    /// Beats per minute. Changing it must go through `rebased(toTempo:atTick:)`, never
    /// direct assignment, so that already-played ticks keep the times they had.
    private(set) var tempo: Double

    /// The tick the origin refers to, and the monotonic instant it occurred at. Ticks
    /// are counted from here, so a tempo change simply moves the origin to now.
    private(set) var originTick: Int64
    private(set) var originSeconds: Double

    init(ticksPerBeat: Int, tempo: Double, originTick: Int64 = 0, originSeconds: Double = 0) {
        self.ticksPerBeat = max(1, ticksPerBeat)
        self.tempo = Self.safeTempo(tempo)
        self.originTick = originTick
        self.originSeconds = originSeconds
    }

    /// Matches the sequencer's existing clamp, so the timeline cannot describe a tempo
    /// the tick loop would refuse to run at.
    static func safeTempo(_ raw: Double) -> Double { min(max(raw, 20), 400) }

    var secondsPerTick: Double { 60.0 / tempo / Double(ticksPerBeat) }
    var secondsPerBeat: Double { 60.0 / tempo }

    /// When `tick` falls, in the same monotonic reference as `originSeconds`.
    /// Ticks before the origin give earlier times — the timeline is signed, which is
    /// what lets an event be nudged EARLIER once there is a look-ahead horizon to do it
    /// in. Today's scheduler can only ever push later.
    func seconds(atTick tick: Int64) -> Double {
        originSeconds + Double(tick - originTick) * secondsPerTick
    }

    /// The tick containing `seconds` — floored, so it names the tick already begun.
    func tick(atSeconds seconds: Double) -> Int64 {
        originTick + Int64(floor((seconds - originSeconds) / secondsPerTick))
    }

    /// How far `tick` is from `seconds`; negative means it has already passed.
    func offset(ofTick tick: Int64, from seconds: Double) -> Double {
        self.seconds(atTick: tick) - seconds
    }

    /// Every tick due in `seconds ..< seconds + horizon` — the look-ahead window a
    /// render block or a horizon-based scheduler asks for.
    func ticks(from seconds: Double, horizon: Double) -> ClosedRange<Int64>? {
        guard horizon > 0 else { return nil }
        let first = originTick + Int64(ceil((seconds - originSeconds) / secondsPerTick))
        let last = tick(atSeconds: seconds + horizon)
        return first <= last ? first...last : nil
    }

    /// Change tempo without disturbing anything already played.
    ///
    /// The origin moves to `tick` and the instant it falls at under the CURRENT tempo,
    /// so history keeps its timing and only the future stretches. Assigning tempo
    /// directly would silently reinterpret every past tick and shift the whole timeline
    /// underneath the sequencer.
    func rebased(toTempo newTempo: Double, atTick tick: Int64) -> MusicalTimeline {
        MusicalTimeline(ticksPerBeat: ticksPerBeat,
                        tempo: newTempo,
                        originTick: tick,
                        originSeconds: seconds(atTick: tick))
    }

    /// Re-anchor to a known instant without changing tempo — for starting playback, or
    /// for taking position from a host rather than our own clock.
    func rebased(toTick tick: Int64, atSeconds seconds: Double) -> MusicalTimeline {
        MusicalTimeline(ticksPerBeat: ticksPerBeat, tempo: tempo,
                        originTick: tick, originSeconds: seconds)
    }
}
