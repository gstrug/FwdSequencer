import Foundation

// MARK: - Project

struct Project: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Untitled Pattern"
    var tempo: Double = 120.0
    var timeSignature: TimeSignature = TimeSignature()
    var numberOfBars: Int = 4
    var scale: MusicalScale = .chromatic
    var masterVolume: Float = 1.0
    var tracks: [Track] = []
}

struct TimeSignature: Codable {
    var numerator: Int = 4
    var denominator: Int = 4
}

// MARK: - Plugin

struct PluginInfo: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var manufacturerName: String
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
}

// MARK: - Song
//
// A Song arranges ordered Sections over a shared, load-once instrument set.
// Instruments live on SongTracks (the "sound"); note data lives in per-section
// Parts (the "notes"). The two are independent — swap a track's instrument and
// every section's part for that track stays put. See SONG_MODE_PLAN.md.

struct Song: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Untitled Song"
    var tempo: Double = 120.0
    var timeSignature: TimeSignature = TimeSignature()
    var masterVolume: Float = 1.0
    var tracks: [SongTrack] = []      // instruments — loaded once when the song opens
    var sections: [SongSection] = []  // arrangement, in play order
    // A dedicated instrument for the manual Play dock, independent of the sequencer
    // tracks. Optional, so older saved songs still decode (missing key → nil).
    var performance: SongTrack? = nil
}

struct SongTrack: Codable, Identifiable {
    var id: UUID = UUID()             // stable instrument key in AudioEngineManager
    var name: String = "Track"
    var pluginInfo: PluginInfo? = nil
    var pluginStateData: Data? = nil  // song-level sound (see AudioEngineManager.getPluginState)
    var mixer: MixerState = MixerState()
    var collapsed: Bool? = nil        // persisted minimized state (Optional → old songs decode)
}

struct SongSection: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Section"      // "Verse", "Chorus", …
    var numberOfBars: Int = 4         // per-section length
    var key: Int = 0                  // section-wide harmonic context (0 = C … 11 = B)
    var scale: MusicalScale = .chromatic
    var parts: [Part] = []            // one per SongTrack, keyed by trackID

    init(id: UUID = UUID(), name: String = "Section", numberOfBars: Int = 4,
         key: Int = 0, scale: MusicalScale = .chromatic, parts: [Part] = []) {
        self.id = id; self.name = name; self.numberOfBars = numberOfBars
        self.key = key; self.scale = scale; self.parts = parts
    }

    // Tolerant decoder so sections saved before key/scale existed still load.
    private enum CodingKeys: String, CodingKey { case id, name, numberOfBars, key, scale, parts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Section"
        numberOfBars = try c.decodeIfPresent(Int.self, forKey: .numberOfBars) ?? 4
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? 0
        scale = try c.decodeIfPresent(MusicalScale.self, forKey: .scale) ?? .chromatic
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
    }
}

// Per-track note data for one section. `trackID` == SongTrack.id, which is also
// the routing key in AudioEngineManager, so notes reach the already-loaded
// instrument with no audio-graph change at section boundaries. Key/scale live on
// the section (shared by all tracks); only rhythm + notes are per-track here.
struct Part: Codable {
    var trackID: UUID
    var notePool: [NoteEntry] = []
    var steps: [Step] = []
    var tempoDivision: TempoDivision = .quarter
}

// MARK: - Track

struct Track: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Track"
    var pluginInfo: PluginInfo? = nil
    var pluginStateData: Data? = nil   // PropertyList-serialised AUv3 state (see AudioEngineManager.getPluginState)
    var tempoDivision: TempoDivision = .quarter
    var scale: MusicalScale = .chromatic
    var key: Int = 0   // 0 = C, 1 = C#, 2 = D … 11 = B
    var notePool: [NoteEntry] = []
    var steps: [Step] = []
    var mixer: MixerState = MixerState()
}

struct NoteEntry: Codable, Identifiable {
    var id: UUID = UUID()
    var midiNote: Int
    var velocity: Int = 100
    var gateLength: Double = 0.5
}

struct MixerState: Codable {
    var volume: Float = 0.8
    var pan: Float = 0.0
    var isMuted: Bool = false
    var isSoloed: Bool = false
}

// MARK: - Step Sequencer

struct Step: Codable, Identifiable {
    var id: UUID = UUID()
    var type: StepType
    var n: Int = 1
    /// Play step only: 1-indexed pool positions played simultaneously (a chord).
    /// Empty = single-note behaviour driven by `n`.
    var chordPositions: [Int] = []
    /// Per-step articulation, 0.05–1.0. Scales how long this step's note(s) sustain
    /// (multiplies each note's own gate). 1.0 = full note gates (default).
    var gate: Double = 1.0

    init(type: StepType, n: Int = 1, chordPositions: [Int] = [], gate: Double = 1.0) {
        self.type = type
        self.n = n
        self.chordPositions = chordPositions
        self.gate = gate
    }

    // Custom decoder so steps saved before `chordPositions`/`gate` existed still load.
    // (Swift's synthesised decoder throws on a missing key even with a default.)
    private enum CodingKeys: String, CodingKey { case id, type, n, chordPositions, gate }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(StepType.self, forKey: .type)
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 1
        chordPositions = try c.decodeIfPresent([Int].self, forKey: .chordPositions) ?? []
        gate = try c.decodeIfPresent(Double.self, forKey: .gate) ?? 1.0
    }

    /// True when this Play step names more than one note (a chord).
    var isChord: Bool { type == .play && chordPositions.count > 1 }

    var label: String {
        switch type {
        case .play:
            return isChord ? "P" + chordPositions.map(String.init).joined(separator: ",") : "P\(n)"
        case .rep   where n > 1: return "R×\(n)"
        case .fwd   where n > 1: return "F\(n)"
        case .back  where n > 1: return "B\(n)"
        case .hold  where n > 1: return "H×\(n)"
        case .pause where n > 1: return "—×\(n)"
        case .hold:  return "Hold"
        case .pause: return "—"
        default: return type.abbreviation
        }
    }
}

enum StepType: String, CaseIterable {
    case fwd    = "Fwd"
    case back   = "Back"
    case rep    = "Repeat"
    case play   = "Play"
    case random = "Random"
    case hold   = "Hold"     // was "Skip": keep the previous note ringing, play nothing
    case pause  = "Pause"    // rest: note-off the previous note, play nothing

    var abbreviation: String {
        switch self {
        case .fwd:    return "Fwd"
        case .back:   return "Back"
        case .rep:    return "Rep"
        case .play:   return "Play"
        case .random: return "Rnd"
        case .hold:   return "Hold"
        case .pause:  return "Rest"
        }
    }
}

// Custom Codable so songs saved with the old "Skip" name still decode as .hold, and
// any unknown future value falls back safely rather than failing the whole song.
extension StepType: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "Skip" { self = .hold }
        else { self = StepType(rawValue: raw) ?? .fwd }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Enumerations

enum TempoDivision: String, Codable, CaseIterable {
    case breve          = "Breve"
    case whole          = "Whole"
    case half           = "Half"
    case quarter        = "Quarter"
    case eighth         = "Eighth"
    case sixteenth      = "Sixteenth"
    case thirtysecond   = "32nd"

    var abbreviation: String {
        switch self {
        case .breve:        return "2/1"
        case .whole:        return "1/1"
        case .half:         return "1/2"
        case .quarter:      return "1/4"
        case .eighth:       return "1/8"
        case .sixteenth:    return "1/16"
        case .thirtysecond: return "1/32"
        }
    }

    var stepsPerBar: Int {
        switch self {
        case .breve:        return 1
        case .whole:        return 1
        case .half:         return 2
        case .quarter:      return 4
        case .eighth:       return 8
        case .sixteenth:    return 16
        case .thirtysecond: return 32
        }
    }
}

enum MusicalScale: String, Codable, CaseIterable {
    // Diatonic / common
    case chromatic        = "Chromatic"
    case major            = "Major"
    case minor            = "Minor"
    case harmonicMinor    = "Harmonic Minor"
    case melodicMinor     = "Melodic Minor"
    // Pentatonic / blues
    case pentatonic       = "Pentatonic"        // major pentatonic (keep rawValue for saved projects)
    case minorPentatonic  = "Minor Pentatonic"
    case blues            = "Blues"
    // Church modes
    case dorian           = "Dorian"
    case phrygian         = "Phrygian"
    case lydian           = "Lydian"
    case mixolydian       = "Mixolydian"
    case locrian          = "Locrian"
    // Symmetric
    case wholeTone        = "Whole Tone"
    case diminished       = "Diminished"

    var intervals: [Int] {
        switch self {
        case .chromatic:       return [0,1,2,3,4,5,6,7,8,9,10,11]
        case .major:           return [0,2,4,5,7,9,11]
        case .minor:           return [0,2,3,5,7,8,10]
        case .harmonicMinor:   return [0,2,3,5,7,8,11]
        case .melodicMinor:    return [0,2,3,5,7,9,11]
        case .pentatonic:      return [0,2,4,7,9]
        case .minorPentatonic: return [0,3,5,7,10]
        case .blues:           return [0,3,5,6,7,10]
        case .dorian:          return [0,2,3,5,7,9,10]
        case .phrygian:        return [0,1,3,5,7,8,10]
        case .lydian:          return [0,2,4,6,7,9,11]
        case .mixolydian:      return [0,2,4,5,7,9,10]
        case .locrian:         return [0,1,3,5,6,8,10]
        case .wholeTone:       return [0,2,4,6,8,10]
        case .diminished:      return [0,1,3,4,6,7,9,10]
        }
    }
}
