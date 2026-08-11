import Foundation

/// Small deterministic generator used by Random steps. A song supplies the seed, so
/// reopening, rewinding, and exporting the same song produces the same sequence.
struct SeededRandomGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextIndex(upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Int(value % UInt64(upperBound))
    }
}
