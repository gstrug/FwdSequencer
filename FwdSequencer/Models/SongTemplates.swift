import Foundation

/// New Song: a starting point for each way of using the app.
///
/// Apart from Blank, these are song documents in Resources (Template-*.json and
/// Example-NightMarket.json), written by Tools/make_examples.py — edit the music
/// there and regenerate, rather than editing the JSON.
enum SongTemplate: String, CaseIterable, Identifiable {
    case starter
    case instrumentHost
    case sequencer
    case fromMIDIFile
    case patternPads

    var id: String { rawValue }

    var name: String {
        switch self {
        case .starter: return "Blank"
        case .instrumentHost: return "Instrument Host"
        case .sequencer: return "Sequencer"
        case .fromMIDIFile: return "From a MIDI File…"
        case .patternPads: return "Pattern Pads"
        }
    }

    var summary: String {
        switch self {
        case .starter: return "One empty track, ready for anything"
        case .instrumentHost: return "Four instruments to play from a MIDI keyboard"
        case .sequencer: return "Drums, bass, chords and lead with starting patterns"
        case .fromMIDIFile: return "A new song from the parts of a MIDI file"
        case .patternPads: return "Eight sections to fire live as pads"
        }
    }

    var systemImage: String {
        switch self {
        case .starter: return "plus.square"
        case .instrumentHost: return "pianokeys"
        case .sequencer: return "square.grid.3x3"
        case .fromMIDIFile: return "doc.badge.plus"
        case .patternPads: return "square.grid.2x2"
        }
    }

    /// The name a new song suggests.
    var songName: String {
        switch self {
        case .starter: return "New FWD Song"
        case .fromMIDIFile: return "MIDI Song"
        default: return name
        }
    }

    /// Whether a new song from this template goes straight to Import MIDI.
    var startsWithMIDIImport: Bool { self == .fromMIDIFile }

    func makeSong() -> Song {
        var song: Song
        switch self {
        case .starter, .fromMIDIFile:
            song = Self.starterSong()
        case .instrumentHost:
            song = Self.bundledSong("Template-InstrumentHost") ?? Self.starterSong()
        case .sequencer:
            song = Self.bundledSong("Template-Sequencer") ?? Self.starterSong()
        case .patternPads:
            song = Self.bundledSong("Example-NightMarket") ?? Self.starterSong()
        }
        song.name = songName
        return song
    }

    static func starterSong() -> Song {
        let track = SongTrack(name: "First Track")
        // Truly blank, like a new track (Graham, 2026-10-29): no notes and no steps, so
        // it is an instrument for a MIDI keyboard until a step is added — which suits
        // using the app purely as an AUv3 host. The step display says so.
        let part = Part(trackID: track.id)
        return Song(name: "New FWD Song", tracks: [track],
                    sections: [SongSection(name: "Section 1", numberOfBars: 4, parts: [part])],
                    randomSeed: 0x46574401)
    }

    /// A song document carried in the app. The stored id is a placeholder: a fresh one
    /// keeps each copy separate, so it can be added again without overwriting edits.
    /// If the resource is ever missing the app must still work, so callers fall back.
    static func bundledSong(_ resource: String) -> Song? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var song = try? SongStorage.decodeDocument(data)
        else { return nil }
        song.id = UUID()
        return song
    }
}

/// The example songs: each a different style, and each showing a way of using the app.
/// Added to the song list once; New Song ▸ Examples adds a fresh copy any time.
/// The raw values are kept in the installed list, so they must not change.
enum ExampleSong: String, CaseIterable, Identifiable {
    case nightMarket
    case bluesInA
    case lighthouse
    case sundayStrut
    case happyBirthday

    var id: String { rawValue }

    var resource: String {
        switch self {
        case .nightMarket: return "Example-NightMarket"
        case .bluesInA: return "Example-BluesInA"
        case .lighthouse: return "Example-Lighthouse"
        case .sundayStrut: return "Example-SundayStrut"
        case .happyBirthday: return "Example-HappyBirthdayJazz"
        }
    }

    var name: String {
        switch self {
        case .nightMarket: return "Night Market"
        case .bluesInA: return "12-Bar Blues in A"
        case .lighthouse: return "Lighthouse"
        case .sundayStrut: return "Sunday Strut"
        case .happyBirthday: return "Happy Birthday in C (Jazz)"
        }
    }

    var summary: String {
        switch self {
        case .nightMarket: return "Deep house on eight pads. Opens in Trigger Mode"
        case .bluesInA: return "A shuffle backing track to solo over on the Play keyboard"
        case .lighthouse: return "A ballad arranged in Song Parts, quiet to full and back"
        case .sundayStrut: return "Funk with swing, accent and chord roll in its Feel"
        case .happyBirthday: return "A jazz arrangement transcribed bar by bar, in 3/4"
        }
    }

    var systemImage: String {
        switch self {
        case .nightMarket: return "square.grid.2x2"
        case .bluesInA: return "guitars"
        case .lighthouse: return "light.beacon.max"
        case .sundayStrut: return "figure.dance"
        case .happyBirthday: return "birthday.cake"
        }
    }

    func makeSong() -> Song? {
        SongTemplate.bundledSong(resource)
    }
}
