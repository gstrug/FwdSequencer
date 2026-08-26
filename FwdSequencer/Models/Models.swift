import Foundation

// MARK: - Project

nonisolated struct Project: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Untitled Pattern"
    var tempo: Double = 120.0
    var timeSignature: TimeSignature = TimeSignature()
    var numberOfBars: Int = 4
    var scale: MusicalScale = .chromatic
    var masterVolume: Float = 1.0
    var tracks: [Track] = []
}

nonisolated struct TimeSignature: Codable, Equatable {
    var numerator: Int = 4
    var denominator: Int = 4
}

// MARK: - Plugin

nonisolated struct PluginInfo: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var manufacturerName: String
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32

    /// Audio-component identity is stable across scans and launches. `id` remains in
    /// the saved format for backward compatibility, but must not decide whether two
    /// records refer to the same installed plugin.
    var componentIdentifier: String {
        "\(componentType)-\(componentSubType)-\(componentManufacturer)"
    }

    static func == (lhs: PluginInfo, rhs: PluginInfo) -> Bool {
        lhs.componentType == rhs.componentType
            && lhs.componentSubType == rhs.componentSubType
            && lhs.componentManufacturer == rhs.componentManufacturer
    }
}

// MARK: - Song
//
// A Song arranges ordered Sections over a shared, load-once instrument set.
// Instruments live on SongTracks (the "sound"); note data lives in per-section
// Parts (the "notes"). The two are independent — swap a track's instrument and
// every section's part for that track stays put. See SONG_MODE_PLAN.md.

nonisolated struct Song: Codable, Identifiable, Equatable {
    /// Optional keeps build 1–16 documents decodable. New saves use format 2.
    var formatVersion: Int? = 2
    var id: UUID = UUID()
    var name: String = "Untitled Song"
    var tempo: Double = 120.0
    var timeSignature: TimeSignature = TimeSignature()
    var masterVolume: Float = 1.0
    var tracks: [SongTrack] = []      // instruments — loaded once when the song opens
    var sections: [SongSection] = []  // arrangement, in play order
    /// Optional preserves decoding of builds 1–16. SongStore materialises a stable
    /// value when an older song opens, making Random steps reproducible thereafter.
    var randomSeed: UInt64? = nil
    /// Whether the song loops. Optional so builds before this key still decode; nil
    /// means "not saved yet" and the store treats it as off.
    var loops: Bool? = nil
    // A dedicated instrument for the manual Play dock, independent of the sequencer
    // tracks. Optional, so older saved songs still decode (missing key → nil).
    var performance: SongTrack? = nil
}

nonisolated struct SongTrack: Codable, Identifiable, Equatable {
    var id: UUID = UUID()             // stable instrument key in AudioEngineManager
    var name: String = "Track"
    var pluginInfo: PluginInfo? = nil
    var pluginStateData: Data? = nil  // song-level sound (see AudioEngineManager.getPluginState)
    var mixer: MixerState = MixerState()
    var collapsed: Bool? = nil        // persisted minimized state (Optional → old songs decode)
}

/// A named, non-destructive snapshot of a section's note data. Variations do not
/// create extra arrangement entries; applying one replaces the section's current
/// parts, so save a variation first if the present arrangement matters.
nonisolated struct SectionVariation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var parts: [Part]
}

nonisolated struct SongSection: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String = "Section"      // "Verse", "Chorus", …
    var numberOfBars: Int = 4         // per-section length
    var parts: [Part] = []            // one per SongTrack, keyed by trackID (key/scale live here now)
    var variations: [SectionVariation] = []

    init(id: UUID = UUID(), name: String = "Section", numberOfBars: Int = 4,
         parts: [Part] = [], variations: [SectionVariation] = []) {
        self.id = id; self.name = name; self.numberOfBars = numberOfBars
        self.parts = parts; self.variations = variations
    }

    // key/scale used to live on the section; they're now per-Part. `key`/`scale` remain
    // as decode-only keys so older songs migrate: any legacy section-level value is
    // back-filled onto that section's parts that don't already carry their own.
    private enum CodingKeys: String, CodingKey {
        case id, name, numberOfBars, key, scale, parts, variations
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Section"
        numberOfBars = try c.decodeIfPresent(Int.self, forKey: .numberOfBars) ?? 4
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        variations = try c.decodeIfPresent([SectionVariation].self, forKey: .variations) ?? []
        // Legacy migration: sections written before this change stored key/scale.
        // If present, stamp them onto the parts (old parts had no key/scale of their own).
        if let legacyKey = try c.decodeIfPresent(Int.self, forKey: .key) {
            for i in parts.indices { parts[i].key = legacyKey }
        }
        if let legacyScale = try c.decodeIfPresent(MusicalScale.self, forKey: .scale) {
            for i in parts.indices { parts[i].scale = legacyScale }
        }
    }

    // Custom encoder: never writes key/scale (they moved to Part).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(numberOfBars, forKey: .numberOfBars)
        try c.encode(parts, forKey: .parts)
        try c.encode(variations, forKey: .variations)
    }
}

// Per-track note data for one section. `trackID` == SongTrack.id, which is also
// the routing key in AudioEngineManager, so notes reach the already-loaded
// instrument with no audio-graph change at section boundaries. Key/scale, rhythm,
// and notes are all per-track within the section.
nonisolated struct Part: Codable, Equatable {
    var trackID: UUID
    var notePool: [NoteEntry] = []
    var steps: [Step] = []
    var tempoDivision: TempoDivision = .quarter
    var key: Int = 0                        // 0 = C … 11 = B — per-track harmonic context
    var scale: MusicalScale = .chromatic    // note-selection constraint for this track

    init(trackID: UUID, notePool: [NoteEntry] = [], steps: [Step] = [],
         tempoDivision: TempoDivision = .quarter, key: Int = 0,
         scale: MusicalScale = .chromatic) {
        self.trackID = trackID; self.notePool = notePool; self.steps = steps
        self.tempoDivision = tempoDivision; self.key = key; self.scale = scale
    }

    // Tolerant decoder so parts saved before key/scale existed still load. Where key/
    // scale are missing, SongSection.init back-fills them from the old section-level
    // values (see below), so pre-existing songs keep the key/scale they had.
    private enum CodingKeys: String, CodingKey { case trackID, notePool, steps, tempoDivision, key, scale }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try c.decode(UUID.self, forKey: .trackID)
        notePool = try c.decodeIfPresent([NoteEntry].self, forKey: .notePool) ?? []
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        tempoDivision = try c.decodeIfPresent(TempoDivision.self, forKey: .tempoDivision) ?? .quarter
        key = try c.decodeIfPresent(Int.self, forKey: .key) ?? 0
        scale = try c.decodeIfPresent(MusicalScale.self, forKey: .scale) ?? .chromatic
    }
}

// MARK: - Track

nonisolated struct Track: Codable, Identifiable, Equatable {
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

nonisolated struct NoteEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var midiNote: Int
    var velocity: Int = 100
    /// How long this note sounds, as a fraction of its step, 0.05–1.0.
    var gateLength: Double = 0.5

    init(id: UUID = UUID(), midiNote: Int, velocity: Int = 100, gateLength: Double = 0.5) {
        self.id = id; self.midiNote = midiNote
        self.velocity = velocity; self.gateLength = gateLength
    }

    // Tolerant decoder (the synthesised one throws on a missing key even where a
    // default exists). Also clamps to the editable range: a wider 0.01–8.0 slider
    // briefly allowed note gates up to 800%, sustaining a note across eight steps.
    private enum CodingKeys: String, CodingKey { case id, midiNote, velocity, gateLength }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        midiNote = try c.decode(Int.self, forKey: .midiNote)
        velocity = min(max(try c.decodeIfPresent(Int.self, forKey: .velocity) ?? 100, 0), 127)
        gateLength = min(max(try c.decodeIfPresent(Double.self, forKey: .gateLength) ?? 0.5, 0.05), 1.0)
    }
}

nonisolated struct MixerState: Codable, Equatable {
    var volume: Float = 0.8
    var pan: Float = 0.0
    var isMuted: Bool = false
    var isSoloed: Bool = false
}

// MARK: - Step Sequencer

nonisolated struct Step: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: StepType
    var n: Int = 1
    /// Play step only: 1-indexed pool positions played simultaneously (a chord).
    /// Empty = single-note behaviour driven by `n`.
    var chordPositions: [Int] = []
    /// Per-step articulation, 0.05–1.0. Scales how long this step's note(s) sustain
    /// (multiplies each note's own gate). 1.0 = full note gates (default).
    var gate: Double = 1.0
    /// Deterministic chance that this step sounds. Traversal still advances when a
    /// hit is skipped, so probability changes rhythm without changing the sequence.
    var probability: Double = 1.0
    /// Number of evenly-spaced re-triggers within this step's duration.
    var ratchets: Int = 1

    init(type: StepType, n: Int = 1, chordPositions: [Int] = [], gate: Double = 1.0,
         probability: Double = 1.0, ratchets: Int = 1) {
        self.type = type
        self.n = n
        self.chordPositions = chordPositions
        self.gate = gate
        self.probability = probability
        self.ratchets = ratchets
    }

    // Custom decoder so steps saved before `chordPositions`/`gate` existed still load.
    // (Swift's synthesised decoder throws on a missing key even with a default.)
    private enum CodingKeys: String, CodingKey {
        case id, type, n, chordPositions, gate, probability, ratchets
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(StepType.self, forKey: .type)
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 1
        chordPositions = try c.decodeIfPresent([Int].self, forKey: .chordPositions) ?? []
        // Clamped to the editable range. A wider 0.01–8.0 slider briefly allowed step
        // gates up to 800%, which sustains a note across eight steps — easy to set by
        // accident and not what the control is for. Values outside the range are
        // corrected on load.
        gate = min(max(try c.decodeIfPresent(Double.self, forKey: .gate) ?? 1.0, 0.05), 1.0)
        probability = try c.decodeIfPresent(Double.self, forKey: .probability) ?? 1.0
        ratchets = try c.decodeIfPresent(Int.self, forKey: .ratchets) ?? 1
    }

    /// True when this Play step names more than one note (a chord).
    var isChord: Bool { type == .play && chordPositions.count > 1 }

    var label: String {
        let suffix = (ratchets > 1 ? " ×\(ratchets)" : "")
            + (probability < 0.999 ? " \(Int((probability * 100).rounded()))%" : "")
        switch type {
        case .play:
            return (isChord ? "P" + chordPositions.map(String.init).joined(separator: ",") : "P\(n)") + suffix
        case .rep   where n > 1: return "R×\(n)" + suffix
        case .fwd   where n > 1: return "F\(n)" + suffix
        case .back  where n > 1: return "B\(n)" + suffix
        case .hold  where n > 1: return "H×\(n)"
        case .pause where n > 1: return "—×\(n)"
        case .hold:  return "Hold"
        case .pause: return "—"
        default: return type.abbreviation + suffix
        }
    }
}

nonisolated enum StepType: String, CaseIterable, Equatable {
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

// Custom Codable so songs saved with the old "Skip" name still decode as .hold.
// Unknown operations are rejected: silently turning a future operation into Fwd would
// change the composition while making the document appear to have loaded correctly.
extension StepType: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "Skip" { self = .hold }
        else if let value = StepType(rawValue: raw) { self = value }
        else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown step operation: \(raw)"
            )
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

// MARK: - Enumerations

nonisolated enum TempoDivision: String, Codable, CaseIterable, Equatable {
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

nonisolated enum MusicalScale: String, Codable, CaseIterable, Equatable {
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
