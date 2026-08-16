import Foundation

enum SongTemplate: String, CaseIterable, Identifiable {
    case starter
    case midnightCurrent
    case ambientCanon
    case bassPulse
    case chordDrift

    var id: String { rawValue }

    var name: String {
        switch self {
        case .starter: return "Blank Starter"
        case .midnightCurrent: return "Midnight Current"
        case .ambientCanon: return "Ambient Canon"
        case .bassPulse: return "Bass Pulse"
        case .chordDrift: return "Chord Drift"
        }
    }

    var summary: String {
        switch self {
        case .starter: return "One ready-to-edit GM track"
        case .midnightCurrent: return "A complete four-section performance showcasing FWD"
        case .ambientCanon: return "Two evolving lines moving at different rates"
        case .bassPulse: return "A direct rhythmic example of Fwd, Repeat, and Rest"
        case .chordDrift: return "Moving triads with Hold and Back steps"
        }
    }

    var systemImage: String {
        switch self {
        case .starter: return "plus.square"
        case .midnightCurrent: return "sparkles"
        case .ambientCanon: return "waveform.path"
        case .bassPulse: return "metronome"
        case .chordDrift: return "music.quarternote.3"
        }
    }

    func makeSong() -> Song {
        switch self {
        case .starter:
            return Self.starterSong()
        case .midnightCurrent:
            return Self.midnightCurrentSong()
        case .ambientCanon:
            return Self.ambientCanonSong()
        case .bassPulse:
            return Self.bassPulseSong()
        case .chordDrift:
            return Self.chordDriftSong()
        }
    }

    private static func starterSong() -> Song {
        let track = SongTrack(name: "First Track")
        let part = Part(trackID: track.id, notePool: notes([60, 64, 67]),
                        steps: [Step(type: .fwd), Step(type: .fwd), Step(type: .back)])
        return Song(name: "New FWD Song", tracks: [track],
                    sections: [SongSection(name: "Section 1", numberOfBars: 4, parts: [part])],
                    randomSeed: 0x46574401)
    }

    /// A complete, deterministic piece that sounds coherent through the built-in
    /// GM fallback while exposing the app's core vocabulary. It is intentionally
    /// long enough to demonstrate section changes, but short enough to audition
    /// in one sitting without editing or installing an AUv3 instrument.
    private static func midnightCurrentSong() -> Song {
        let bass = SongTrack(
            name: "Low Current",
            mixer: MixerState(volume: 0.58, pan: -0.28)
        )
        let harmony = SongTrack(
            name: "Wide Chords",
            mixer: MixerState(volume: 0.46, pan: 0.24)
        )
        let lead = SongTrack(
            name: "Lantern",
            mixer: MixerState(volume: 0.68, pan: 0.08)
        )

        let bassNotes = notes([38, 41, 43, 45, 48], velocity: 82, gate: 0.62)
        let chordNotes = notes([50, 53, 57, 58, 60, 65, 67, 69, 72],
                               velocity: 72, gate: 1.0)
        let leadNotes = notes([62, 65, 67, 69, 72, 74], velocity: 91, gate: 0.72)

        let nightfall = SongSection(name: "Nightfall", numberOfBars: 4, parts: [
            Part(trackID: bass.id, notePool: bassNotes, steps: [
                .init(type: .play, n: 1, gate: 0.9),
                .init(type: .hold),
                .init(type: .fwd, gate: 0.82),
                .init(type: .pause)
            ], tempoDivision: .half, key: 2, scale: .minorPentatonic),
            Part(trackID: harmony.id, notePool: chordNotes, steps: [
                .init(type: .play, chordPositions: [1, 2, 3], gate: 0.92),
                .init(type: .hold),
                .init(type: .play, chordPositions: [4, 6, 8], gate: 0.9),
                .init(type: .hold)
            ], tempoDivision: .half, key: 2, scale: .minor),
            Part(trackID: lead.id, notePool: leadNotes, steps: [
                .init(type: .pause, n: 4),
                .init(type: .play, n: 1, gate: 0.72),
                .init(type: .fwd, n: 2, gate: 0.72),
                .init(type: .rep, n: 2, gate: 0.62),
                .init(type: .fwd, gate: 0.75),
                .init(type: .hold),
                .init(type: .back, n: 2, gate: 0.68),
                .init(type: .pause, n: 2)
            ], tempoDivision: .eighth, key: 2, scale: .minorPentatonic)
        ])

        let openWater = SongSection(name: "Open Water", numberOfBars: 8, parts: [
            Part(trackID: bass.id, notePool: bassNotes, steps: [
                .init(type: .play, n: 1, gate: 0.68),
                .init(type: .rep, n: 2, gate: 0.48),
                .init(type: .pause),
                .init(type: .fwd, n: 2, gate: 0.64),
                .init(type: .rep, gate: 0.48),
                .init(type: .back, gate: 0.62),
                .init(type: .pause)
            ], tempoDivision: .eighth, key: 2, scale: .minorPentatonic),
            Part(trackID: harmony.id, notePool: chordNotes, steps: [
                .init(type: .play, chordPositions: [1, 2, 3], gate: 0.9),
                .init(type: .hold),
                .init(type: .play, chordPositions: [4, 6, 8], gate: 0.88),
                .init(type: .hold),
                .init(type: .play, chordPositions: [5, 7, 8], gate: 0.88),
                .init(type: .hold),
                .init(type: .play, chordPositions: [2, 6, 9], gate: 0.92),
                .init(type: .hold)
            ], tempoDivision: .half, key: 2, scale: .minor),
            Part(trackID: lead.id, notePool: leadNotes, steps: [
                .init(type: .play, n: 1, gate: 0.7),
                .init(type: .fwd, gate: 0.62),
                .init(type: .fwd, n: 2, gate: 0.7),
                .init(type: .rep, gate: 0.54, ratchets: 2),
                .init(type: .back, gate: 0.68),
                .init(type: .random, gate: 0.58, probability: 0.68),
                .init(type: .fwd, gate: 0.7),
                .init(type: .rep, gate: 0.52, probability: 0.86),
                .init(type: .pause),
                .init(type: .back, n: 2, gate: 0.65),
                .init(type: .fwd, gate: 0.72),
                .init(type: .hold)
            ], tempoDivision: .eighth, key: 2, scale: .minorPentatonic)
        ])

        let stillPoint = SongSection(name: "Still Point", numberOfBars: 4, parts: [
            Part(trackID: bass.id, notePool: bassNotes, steps: [
                .init(type: .play, n: 1, gate: 0.85),
                .init(type: .hold, n: 2),
                .init(type: .pause),
                .init(type: .back, gate: 0.72)
            ], tempoDivision: .quarter, key: 2, scale: .minorPentatonic),
            Part(trackID: harmony.id, notePool: chordNotes, steps: [
                .init(type: .play, chordPositions: [1, 2, 3], gate: 0.96),
                .init(type: .hold),
                .init(type: .play, chordPositions: [4, 6, 8], gate: 0.94),
                .init(type: .hold)
            ], tempoDivision: .whole, key: 2, scale: .minor),
            Part(trackID: lead.id, notePool: leadNotes, steps: [
                .init(type: .pause, n: 2),
                .init(type: .play, n: 5, gate: 0.78),
                .init(type: .back, n: 2, gate: 0.72),
                .init(type: .hold),
                .init(type: .random, gate: 0.7, probability: 0.55),
                .init(type: .pause)
            ], tempoDivision: .quarter, key: 2, scale: .minorPentatonic)
        ])

        let homeLights = SongSection(name: "Home Lights", numberOfBars: 8, parts: [
            Part(trackID: bass.id, notePool: bassNotes, steps: [
                .init(type: .play, n: 1, gate: 0.68),
                .init(type: .rep, n: 2, gate: 0.48),
                .init(type: .fwd, n: 2, gate: 0.64),
                .init(type: .pause),
                .init(type: .back, gate: 0.62),
                .init(type: .rep, gate: 0.48),
                .init(type: .fwd, gate: 0.66),
                .init(type: .pause)
            ], tempoDivision: .eighth, key: 2, scale: .minorPentatonic),
            Part(trackID: harmony.id, notePool: chordNotes, steps: [
                .init(type: .play, chordPositions: [1, 2, 3], gate: 0.9),
                .init(type: .hold),
                .init(type: .play, chordPositions: [5, 7, 8], gate: 0.88),
                .init(type: .hold),
                .init(type: .play, chordPositions: [4, 6, 8], gate: 0.9),
                .init(type: .hold),
                .init(type: .play, chordPositions: [2, 6, 9], gate: 0.94),
                .init(type: .hold)
            ], tempoDivision: .half, key: 2, scale: .minor),
            Part(trackID: lead.id, notePool: leadNotes, steps: [
                .init(type: .play, n: 1, gate: 0.7),
                .init(type: .fwd, gate: 0.62),
                .init(type: .fwd, n: 2, gate: 0.7),
                .init(type: .rep, gate: 0.5, ratchets: 2),
                .init(type: .back, gate: 0.66),
                .init(type: .fwd, gate: 0.7),
                .init(type: .random, gate: 0.58, probability: 0.74),
                .init(type: .fwd, gate: 0.72),
                .init(type: .hold),
                .init(type: .back, n: 2, gate: 0.66),
                .init(type: .rep, gate: 0.56),
                .init(type: .pause)
            ], tempoDivision: .eighth, key: 2, scale: .minorPentatonic)
        ])

        return Song(
            name: "Midnight Current — Demo",
            tempo: 104,
            masterVolume: 0.82,
            tracks: [bass, harmony, lead],
            sections: [nightfall, openWater, stillPoint, homeLights],
            randomSeed: 0x46574405,
            performance: SongTrack(name: "Play Along", mixer: MixerState(volume: 0.64))
        )
    }

    private static func ambientCanonSong() -> Song {
        let high = SongTrack(name: "Glass Line")
        let low = SongTrack(name: "Slow Line", mixer: MixerState(volume: 0.65, pan: -0.2))
        let first = SongSection(name: "Opening", numberOfBars: 4, parts: [
            Part(trackID: high.id, notePool: notes([60, 62, 67, 69, 74]),
                 steps: [.init(type: .fwd), .init(type: .rep, n: 2), .init(type: .random), .init(type: .hold)],
                 tempoDivision: .eighth, scale: .pentatonic),
            Part(trackID: low.id, notePool: notes([48, 55, 57, 62]),
                 steps: [.init(type: .fwd), .init(type: .hold, n: 2), .init(type: .back)],
                 tempoDivision: .half, scale: .pentatonic)
        ])
        var second = first
        second.id = UUID()
        second.name = "Lift"
        second.parts[0].steps = [.init(type: .back), .init(type: .fwd, n: 2), .init(type: .random)]
        return Song(name: "Ambient Canon", tempo: 92, tracks: [high, low],
                    sections: [first, second], randomSeed: 0x46574402)
    }

    private static func bassPulseSong() -> Song {
        let bass = SongTrack(name: "Pulse")
        let part = Part(trackID: bass.id, notePool: notes([36, 39, 43, 46]),
                        steps: [.init(type: .fwd), .init(type: .rep, n: 2),
                                .init(type: .pause), .init(type: .back)],
                        tempoDivision: .eighth, key: 0, scale: .minorPentatonic)
        return Song(name: "Bass Pulse", tempo: 118, tracks: [bass],
                    sections: [SongSection(name: "Pulse", numberOfBars: 4, parts: [part])],
                    randomSeed: 0x46574403)
    }

    private static func chordDriftSong() -> Song {
        let chords = SongTrack(name: "Drifting Chords")
        let pool = notes([60, 64, 67, 69, 72, 76])
        let part = Part(trackID: chords.id, notePool: pool,
                        steps: [
                            .init(type: .play, chordPositions: [1, 2, 3], gate: 0.9),
                            .init(type: .hold, n: 2),
                            .init(type: .fwd, n: 1, gate: 0.8),
                            .init(type: .back, n: 2, gate: 0.8)
                        ], tempoDivision: .quarter, key: 0, scale: .major)
        return Song(name: "Chord Drift", tempo: 76, tracks: [chords],
                    sections: [SongSection(name: "Drift", numberOfBars: 8, parts: [part])],
                    randomSeed: 0x46574404)
    }

    private static func notes(_ midi: [Int], velocity: Int = 96,
                              gate: Double = 0.8) -> [NoteEntry] {
        midi.map { NoteEntry(midiNote: $0, velocity: velocity, gateLength: gate) }
    }
}
