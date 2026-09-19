import Foundation

/// The feel of a generated sequence.
///
/// The reason this is not just "random": a uniform draw over the step types produces
/// mush. Too many Randoms and the line has no shape; too many Pauses and it stops
/// breathing. What makes a generated sequence worth listening to is a weighting toward
/// movement, with rests as punctuation — so the choice offered is a character, and the
/// distribution behind it is the actual design work.
nonisolated enum StepCharacter: String, CaseIterable, Identifiable, Equatable {
    case flowing = "Flowing"
    case sparse  = "Sparse"
    case jumpy   = "Jumpy"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .flowing: return "Mostly stepwise movement, few rests"
        case .sparse:  return "Long notes and rests, room to breathe"
        case .jumpy:   return "Leaps, repeats and surprises"
        }
    }

    var systemImage: String {
        switch self {
        case .flowing: return "wave.3.right"
        case .sparse:  return "moon.zzz"
        case .jumpy:   return "bolt"
        }
    }

    /// Relative likelihood of each step type. Not probabilities — they are normalised.
    fileprivate var weights: [(StepType, Int)] {
        switch self {
        case .flowing:
            return [(.fwd, 45), (.back, 20), (.rep, 8), (.play, 10),
                    (.random, 2), (.hold, 10), (.pause, 5)]
        case .sparse:
            return [(.fwd, 24), (.back, 12), (.rep, 4), (.play, 8),
                    (.random, 2), (.hold, 30), (.pause, 20)]
        case .jumpy:
            return [(.fwd, 18), (.back, 14), (.rep, 6), (.play, 28),
                    (.random, 20), (.hold, 7), (.pause, 7)]
        }
    }

    /// How far Fwd and Back tend to move. Small intervals read as a line; large ones as
    /// leaps, which is the whole difference between Flowing and Jumpy.
    fileprivate var strideWeights: [(Int, Int)] {
        switch self {
        case .flowing: return [(1, 70), (2, 25), (3, 5)]
        case .sparse:  return [(1, 60), (2, 30), (3, 10)]
        case .jumpy:   return [(1, 30), (2, 25), (3, 25), (4, 20)]
        }
    }

    /// How long a Rep, Hold or Pause dwells.
    fileprivate var dwellWeights: [(Int, Int)] {
        switch self {
        case .flowing: return [(1, 60), (2, 30), (3, 10)]
        case .sparse:  return [(1, 30), (2, 35), (3, 25), (4, 10)]
        case .jumpy:   return [(1, 75), (2, 20), (3, 5)]
        }
    }

    /// Chance in 100 that a step is less than certain to sound. Probability is what
    /// makes a fixed sequence feel alive, so it is part of the character rather than an
    /// afterthought — but Sparse is already airy and does not need holes punched in it.
    fileprivate var probabilityChance: Int {
        switch self {
        case .flowing: return 10
        case .sparse:  return 0
        case .jumpy:   return 18
        }
    }

    /// Chance in 100 of a Divide (ratchet) on a sounding step.
    fileprivate var divideChance: Int {
        switch self {
        case .flowing: return 4
        case .sparse:  return 0
        case .jumpy:   return 14
        }
    }
}

/// Builds a step sequence from a character and a seed.
///
/// Pure and seeded: the same inputs always give the same sequence, so a generated part
/// reproduces on reload and in export like everything else here. Re-rolling is a matter
/// of passing a different seed, which is what makes "press until something catches" work
/// without the result being unrepeatable.
nonisolated enum StepGenerator {
    /// Any length from one step to a full bar of 32nds. A short sequence is a valid
    /// musical choice — one step that repeats is an ostinato — so the range is not
    /// restricted to a handful of presets.
    static let lengthRange = 1...32
    /// The same range as Doubles, for a slider.
    static var lengthSliderRange: ClosedRange<Double> {
        Double(lengthRange.lowerBound)...Double(lengthRange.upperBound)
    }

    static func steps(count: Int, character: StepCharacter,
                      poolSize: Int, seed: UInt64) -> [Step] {
        let length = min(max(count, 1), 64)
        var generator = SeededRandomGenerator(seed: seed)
        var steps: [Step] = []
        var consecutiveRests = 0

        for position in 0..<length {
            var type = pick(character.weights, using: &generator)

            // The first step must SOUND. A sequence that opens on a Hold has nothing to
            // hold and one that opens on a Pause starts with silence, which reads as a
            // broken generator rather than a musical choice.
            if position == 0, type == .hold || type == .pause {
                type = .fwd
            }
            // Cap runs of silence. Two rests in a row is phrasing; four is a gap, and at
            // Sparse's weighting those happen often enough to matter.
            if type == .hold || type == .pause {
                if consecutiveRests >= 2 { type = .fwd }
                else { consecutiveRests += 1 }
            } else {
                consecutiveRests = 0
            }

            steps.append(step(of: type, character: character,
                              poolSize: poolSize, using: &generator))
        }

        // Guarantee the sequence is audible.
        //
        // Every step can carry a probability below 1, and at short lengths a draw can
        // leave a sequence whose only sounding steps are all uncertain — which plays as
        // silence often enough to look broken. The first step is always certain, so
        // something sounds on every pass whatever else was rolled.
        if !steps.isEmpty { steps[0].probability = 1.0 }
        return steps
    }

    private static func step(of type: StepType, character: StepCharacter,
                             poolSize: Int, using generator: inout SeededRandomGenerator) -> Step {
        var n = 1
        var chordPositions: [Int] = []

        switch type {
        case .fwd, .back:
            n = pick(character.strideWeights, using: &generator)
        case .rep, .hold, .pause:
            n = pick(character.dwellWeights, using: &generator)
        case .play:
            let size = max(1, poolSize)
            n = generator.nextIndex(upperBound: size) + 1
            // An occasional chord, but only where there are notes to spare — a two-note
            // pool cannot voice one.
            if character == .jumpy, size >= 3, roll(30, using: &generator) {
                var chosen = Set<Int>()
                let wanted = 2 + generator.nextIndex(upperBound: min(2, size - 1))
                while chosen.count < wanted {
                    chosen.insert(generator.nextIndex(upperBound: size) + 1)
                }
                chordPositions = chosen.sorted()
            }
        case .random:
            break
        }

        let sounds = type != .hold && type != .pause
        let probability = sounds && roll(character.probabilityChance, using: &generator)
            ? [0.5, 0.65, 0.8].randomElement(using: &generator) ?? 0.8
            : 1.0
        let ratchets = sounds && roll(character.divideChance, using: &generator)
            ? 2 + generator.nextIndex(upperBound: 2)
            : 1

        return Step(type: type, n: n, chordPositions: chordPositions,
                    gate: 1.0, probability: probability, ratchets: ratchets)
    }

    /// Weighted pick. Weights are relative, so a character's table can be edited without
    /// having to keep it summing to anything.
    private static func pick<T>(_ weighted: [(T, Int)],
                                using generator: inout SeededRandomGenerator) -> T {
        let total = weighted.reduce(0) { $0 + max(0, $1.1) }
        guard total > 0 else { return weighted[0].0 }
        var remaining = generator.nextIndex(upperBound: total)
        for (value, weight) in weighted {
            remaining -= max(0, weight)
            if remaining < 0 { return value }
        }
        return weighted[weighted.count - 1].0
    }

    private static func roll(_ chanceInHundred: Int,
                             using generator: inout SeededRandomGenerator) -> Bool {
        chanceInHundred > 0 && generator.nextIndex(upperBound: 100) < chanceInHundred
    }
}

/// `randomElement(using:)` needs a RandomNumberGenerator; SeededRandomGenerator is
/// deliberately not one, so that nothing can draw from it by accident.
private extension Array {
    func randomElement(using generator: inout SeededRandomGenerator) -> Element? {
        isEmpty ? nil : self[generator.nextIndex(upperBound: count)]
    }
}
