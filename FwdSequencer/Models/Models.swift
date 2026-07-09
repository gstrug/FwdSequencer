import Foundation

// MARK: - Project

struct Project: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Untitled Project"
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

// MARK: - Track

struct Track: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Track"
    var pluginInfo: PluginInfo? = nil
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
}

enum StepType: String, Codable, CaseIterable {
    case fwd    = "Fwd"
    case back   = "Back"
    case skip   = "Skip"
    case rep    = "Repeat"
    case random = "Random"

    var abbreviation: String {
        switch self {
        case .fwd:    return "Fwd"
        case .back:   return "Back"
        case .skip:   return "Skip"
        case .rep:    return "Rep"
        case .random: return "Rnd"
        }
    }
}

// MARK: - Enumerations

enum TempoDivision: String, Codable, CaseIterable {
    case breve       = "Breve"
    case whole       = "Whole"
    case half        = "Half"
    case quarter     = "Quarter"
    case eighth      = "Eighth"
    case sixteenth   = "Sixteenth"

    var abbreviation: String {
        switch self {
        case .breve:     return "2/1"
        case .whole:     return "1/1"
        case .half:      return "1/2"
        case .quarter:   return "1/4"
        case .eighth:    return "1/8"
        case .sixteenth: return "1/16"
        }
    }

    var stepsPerBar: Int {
        switch self {
        case .breve:      return 1
        case .whole:      return 1
        case .half:       return 2
        case .quarter:    return 4
        case .eighth:     return 8
        case .sixteenth:  return 16
        }
    }
}

enum MusicalScale: String, Codable, CaseIterable {
    case chromatic   = "Chromatic"
    case major       = "Major"
    case minor       = "Minor"
    case pentatonic  = "Pentatonic"
    case blues       = "Blues"
    case dorian      = "Dorian"
    case phrygian    = "Phrygian"

    var intervals: [Int] {
        switch self {
        case .chromatic:   return [0,1,2,3,4,5,6,7,8,9,10,11]
        case .major:       return [0,2,4,5,7,9,11]
        case .minor:       return [0,2,3,5,7,8,10]
        case .pentatonic:  return [0,2,4,7,9]
        case .blues:       return [0,3,5,6,7,10]
        case .dorian:      return [0,2,3,5,7,9,10]
        case .phrygian:    return [0,1,3,5,7,8,10]
        }
    }
}
