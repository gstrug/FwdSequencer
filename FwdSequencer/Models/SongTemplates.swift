import Foundation

enum SongTemplate: String, CaseIterable, Identifiable {
    case starter
    case ambientCanon
    case bassPulse
    case chordDrift

    var id: String { rawValue }

    var name: String {
        switch self {
        case .starter: return "Blank Starter"
        case .ambientCanon: return "Ambient Canon"
        case .bassPulse: return "Bass Pulse"
        case .chordDrift: return "Chord Drift"
        }
    }

    var summary: String {
        switch self {
        case .starter: return "One ready-to-edit GM track"
        case .ambientCanon: return "Two evolving lines moving at different rates"
        case .bassPulse: return "A direct rhythmic example of Fwd, Repeat, and Rest"
        case .chordDrift: return "Moving triads with Hold and Back steps"
        }
    }

    var systemImage: String {
        switch self {
        case .starter: return "plus.square"
        case .ambientCanon: return "waveform.path"
        case .bassPulse: return "metronome"
        case .chordDrift: return "music.quarternote.3"
        }
    }

    func makeSong() -> Song {
        switch self {
        case .starter:
            return Self.starterSong()
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

    private static func notes(_ midi: [Int]) -> [NoteEntry] {
        midi.map { NoteEntry(midiNote: $0, velocity: 96, gateLength: 0.8) }
    }
}
