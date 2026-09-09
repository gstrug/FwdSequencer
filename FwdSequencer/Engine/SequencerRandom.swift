import Foundation

/// Small deterministic generator used by Random steps. A song supplies the seed, so
/// reopening, rewinding, and exporting the same song produces the same sequence.
nonisolated struct SeededRandomGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextIndex(upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(nextUInt64() % UInt64(upperBound))
    }

    /// Deterministic value in 0..<1 for probability decisions.
    mutating func nextUnitInterval() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    private mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return value
    }
}

/// Position-addressable deterministic noise, for humanising feel.
///
/// `SeededRandomGenerator` is a STREAM — its output depends on how many values have
/// been drawn before, which is fine for Random steps (drawn in playback order) but
/// useless here: the MIDI exporter walks the song in a different order from playback,
/// so a stream would hand the two different numbers and the file would stop matching
/// what you heard. This is a pure function of position instead, so anything that can
/// name a note — playback, recording, export — computes the identical value for it.
///
/// The same reason feel is derived rather than random at all: a song must reproduce
/// exactly, and MIDI export is asserted byte-identical run to run.
nonisolated enum FeelNoise {
    /// A value in 0..<1 for one note, identified by where it falls in the song.
    /// `salt` separates independent uses (velocity vs gate) at the same position.
    static func unitValue(seed: UInt64, section: Int, trigger: Int,
                          midiNote: Int, salt: UInt64) -> Double {
        var value = seed
        value &+= UInt64(bitPattern: Int64(section)) &* 0x9E3779B97F4A7C15
        value &+= UInt64(bitPattern: Int64(trigger)) &* 0xC2B2AE3D27D4EB4F
        value &+= UInt64(bitPattern: Int64(midiNote)) &* 0x165667B19E3779F9
        value &+= salt &* 0x27D4EB2F165667C5
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// The same value centred on zero, in -1...1 — the usual form for an offset.
    static func signedValue(seed: UInt64, section: Int, trigger: Int,
                            midiNote: Int, salt: UInt64) -> Double {
        unitValue(seed: seed, section: section, trigger: trigger,
                  midiNote: midiNote, salt: salt) * 2 - 1
    }

    static let velocitySalt: UInt64 = 0x11
    static let gateSalt: UInt64 = 0x22
}
