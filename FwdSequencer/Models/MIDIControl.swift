import Foundation

// MARK: - MIDI control: links from a controller's knobs, faders and buttons to the app
//
// The portable half of MIDI Learn: what a link is, what it can control, how an incoming
// message is matched and scaled, and the built-in templates. No CoreMIDI and no UI, so
// it is tested with the rest of the core. The app half (CoreMIDI input, applying actions
// to the song, the Learn mode UI) lives in MIDIInputManager and MIDIControlCenter.
//
// Links are APP-WIDE and address tracks BY POSITION ("track 1's volume"), not a
// particular track in a particular song — so a controller set up once works the same in
// every song. A song with fewer tracks simply ignores the links past its last track.

/// One incoming MIDI 1.0 channel message, reduced to what mapping needs.
nonisolated struct MIDIControlMessage: Equatable {
    enum Kind: String, Codable, Equatable {
        /// Control change: number = controller, value = 0...127.
        case controlChange
        /// Note on/off: number = note, value = velocity (0 for a note off).
        case note
    }
    var kind: Kind
    /// 1...16, as shown to people.
    var channel: Int
    var number: Int
    var value: Int

    /// Decode three MIDI 1.0 bytes. Anything that is not a CC, note on or note off is
    /// not something a link can be made to, and returns nil.
    init?(status: UInt8, data1: UInt8, data2: UInt8) {
        let type = status & 0xF0
        channel = Int(status & 0x0F) + 1
        number = Int(data1 & 0x7F)
        switch type {
        case 0xB0: kind = .controlChange; value = Int(data2 & 0x7F)
        case 0x90: kind = .note; value = Int(data2 & 0x7F)   // velocity 0 is a note off
        case 0x80: kind = .note; value = 0
        default: return nil
        }
    }

    init(kind: Kind, channel: Int, number: Int, value: Int) {
        self.kind = kind; self.channel = channel; self.number = number; self.value = value
    }

    /// A button counts as pressed above half way. Notes are pressed while sounding.
    var isPress: Bool { value >= 64 || (kind == .note && value > 0) }

    /// The value as 0...1.
    var fraction: Double { Double(value) / 127 }
}

/// What a link controls.
nonisolated enum MIDIControlTarget: Codable, Hashable {
    // Transport
    case playPause, stop, rewind, record, loop, panic, tapTempo, hold
    case tempo
    case masterVolume
    // Tracks, by position (0-based; shown as 1-based).
    case trackVolume(Int), trackPan(Int), trackMute(Int), trackSolo(Int), trackEffects(Int)
    // Sections, by position.
    case section(Int)
    case previousSection, nextSection

    /// Continuous targets take the knob or fader's position; the rest act on a press.
    var isContinuous: Bool {
        switch self {
        case .tempo, .masterVolume, .trackVolume, .trackPan: return true
        default: return false
        }
    }

    var displayName: String {
        switch self {
        case .playPause:            return "Play / Pause"
        case .stop:                 return "Stop"
        case .rewind:               return "Rewind"
        case .record:               return "Record"
        case .loop:                 return "Loop"
        case .panic:                return "Panic"
        case .tapTempo:             return "Tap Tempo"
        case .hold:                 return "Hold Section"
        case .tempo:                return "Tempo"
        case .masterVolume:         return "Master Volume"
        case .trackVolume(let i):   return "Track \(i + 1) Volume"
        case .trackPan(let i):      return "Track \(i + 1) Pan"
        case .trackMute(let i):     return "Track \(i + 1) Mute"
        case .trackSolo(let i):     return "Track \(i + 1) Solo"
        case .trackEffects(let i):  return "Track \(i + 1) FX On/Off"
        case .section(let i):       return "Section \(i + 1)"
        case .previousSection:      return "Previous Section"
        case .nextSection:          return "Next Section"
        }
    }
}

/// The message a link listens for: kind, number and channel.
nonisolated struct MIDIControlSource: Codable, Hashable {
    var kind: MIDIControlMessage.Kind
    /// 1...16.
    var channel: Int
    var number: Int

    init(kind: MIDIControlMessage.Kind, channel: Int, number: Int) {
        self.kind = kind; self.channel = channel; self.number = number
    }

    init(_ message: MIDIControlMessage) {
        self.init(kind: message.kind, channel: message.channel, number: message.number)
    }

    func matches(_ message: MIDIControlMessage) -> Bool {
        kind == message.kind && channel == message.channel && number == message.number
    }

    /// "CC 7 · Ch 1", "Note C3 · Ch 10".
    var displayName: String {
        switch kind {
        case .controlChange: return "CC \(number) · Ch \(channel)"
        case .note:
            let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
            return "Note \(names[number % 12])\(number / 12 - 1) · Ch \(channel)"
        }
    }
}

/// One link: this message controls that target.
nonisolated struct MIDIControlMapping: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var source: MIDIControlSource
    var target: MIDIControlTarget
    /// For a continuous target: don't move the app's control until the hardware passes
    /// its current value, so a knob that is somewhere else does not make it jump.
    var pickup: Bool = false

    init(id: UUID = UUID(), source: MIDIControlSource, target: MIDIControlTarget,
         pickup: Bool = false) {
        self.id = id; self.source = source; self.target = target; self.pickup = pickup
    }

    // Tolerant decoder so templates saved before a field existed still load.
    private enum CodingKeys: String, CodingKey { case id, source, target, pickup }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try c.decode(MIDIControlSource.self, forKey: .source)
        target = try c.decode(MIDIControlTarget.self, forKey: .target)
        pickup = try c.decodeIfPresent(Bool.self, forKey: .pickup) ?? false
    }
}

/// A named set of links for one controller.
nonisolated struct MIDIControllerTemplate: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var mappings: [MIDIControlMapping] = []
    /// Shipped with the app. Built-ins are not edited in place: learning on one makes a
    /// copy, so the factory layout is always there to go back to.
    var isBuiltIn: Bool = false
    /// Part of a device name this template is for, so it can be chosen automatically
    /// the first time that controller is plugged in. Case-insensitive.
    var deviceNameHint: String? = nil

    init(id: UUID = UUID(), name: String, mappings: [MIDIControlMapping] = [],
         isBuiltIn: Bool = false, deviceNameHint: String? = nil) {
        self.id = id; self.name = name; self.mappings = mappings
        self.isBuiltIn = isBuiltIn; self.deviceNameHint = deviceNameHint
    }

    private enum CodingKeys: String, CodingKey { case id, name, mappings, isBuiltIn, deviceNameHint }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Controller"
        mappings = try c.decodeIfPresent([MIDIControlMapping].self, forKey: .mappings) ?? []
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        deviceNameHint = try c.decodeIfPresent(String.self, forKey: .deviceNameHint)
    }

    func mappings(matching message: MIDIControlMessage) -> [MIDIControlMapping] {
        mappings.filter { $0.source.matches(message) }
    }

    func mapping(for target: MIDIControlTarget) -> MIDIControlMapping? {
        mappings.first { $0.target == target }
    }

    /// Link `source` to `target`, replacing whatever either was linked to before: one
    /// control per message and one message per control keeps Learn predictable.
    mutating func learn(_ source: MIDIControlSource, for target: MIDIControlTarget) {
        mappings.removeAll { $0.source == source || $0.target == target }
        mappings.append(MIDIControlMapping(source: source, target: target))
    }

    mutating func forget(_ target: MIDIControlTarget) {
        mappings.removeAll { $0.target == target }
    }

    /// Whether this template is the one for a device of this name.
    func suits(deviceNamed deviceName: String) -> Bool {
        guard let hint = deviceNameHint, !hint.isEmpty else { return false }
        return deviceName.range(of: hint, options: .caseInsensitive) != nil
    }
}

// MARK: - Scaling

nonisolated enum MIDIControlScaling {
    /// Fader range in dB, the same as the on-screen faders. FaderScale is in the app
    /// target, outside this portable core, so its limits are repeated here: change both.
    static let volumeMinDB: Double = -60
    static let volumeMaxDB: Double = 6
    /// Tempo range a knob covers. Narrower than the app's 20–400 so one step of a
    /// 0–127 knob is a sensible change; the tempo display still reaches the extremes.
    static let tempoRange: ClosedRange<Double> = 40...240

    /// Linear gain for a 0...1 control position, laid out in dB like the faders.
    static func gain(forFraction f: Double) -> Float {
        let db = volumeMinDB + (volumeMaxDB - volumeMinDB) * min(max(f, 0), 1)
        return db <= volumeMinDB ? 0 : Float(pow(10, db / 20))
    }

    /// The 0...1 control position that corresponds to a linear gain (for pickup).
    static func fraction(forGain gain: Float) -> Double {
        guard gain > 0 else { return 0 }
        let db = max(volumeMinDB, 20 * log10(Double(gain)))
        return (db - volumeMinDB) / (volumeMaxDB - volumeMinDB)
    }

    static func pan(forFraction f: Double) -> Float { Float(min(max(f, 0), 1) * 2 - 1) }
    static func fraction(forPan p: Float) -> Double { (Double(p) + 1) / 2 }

    static func tempo(forFraction f: Double) -> Double {
        (tempoRange.lowerBound + (tempoRange.upperBound - tempoRange.lowerBound) * min(max(f, 0), 1)).rounded()
    }
    static func fraction(forTempo t: Double) -> Double {
        (t - tempoRange.lowerBound) / (tempoRange.upperBound - tempoRange.lowerBound)
    }
}

// MARK: - Pickup

/// Soft takeover for continuous links. With pickup on, an incoming position is ignored
/// until it reaches or crosses the app's current value — so turning a knob that sits
/// somewhere else does not make the control jump. Once caught, it follows directly
/// until the app's value is changed from elsewhere (touch, another controller).
nonisolated struct MIDIPickup {
    private var lastHardware: [UUID: Double] = [:]
    private var caught: Set<UUID> = []

    /// Whether to apply `incoming` (0...1) to a control currently at `current` (0...1).
    mutating func shouldApply(_ mapping: MIDIControlMapping, incoming: Double,
                              current: Double) -> Bool {
        defer { lastHardware[mapping.id] = incoming }
        guard mapping.pickup else { return true }
        // Close enough counts as caught: one step of a 7-bit knob is ~0.008.
        let tolerance = 1.5 / 127
        if caught.contains(mapping.id) {
            // Still in step with the app? Then keep following.
            if let last = lastHardware[mapping.id], abs(last - current) <= tolerance * 2 { return true }
            caught.remove(mapping.id)
        }
        if abs(incoming - current) <= tolerance {
            caught.insert(mapping.id); return true
        }
        if let last = lastHardware[mapping.id],
           (last - current) * (incoming - current) <= 0 {   // crossed the value
            caught.insert(mapping.id); return true
        }
        return false
    }

    mutating func reset() { lastHardware.removeAll(); caught.removeAll() }
}

// MARK: - Built-in templates

nonisolated enum MIDIBuiltInTemplates {
    /// Stable ids, so a built-in keeps its identity across launches and app updates.
    static let nanoKONTROL2ID = UUID(uuidString: "6E4B2C1A-0F3D-4C6B-9A7E-2B5D8C1F0A01")!

    /// Korg nanoKONTROL2, factory CC mode, global channel 1.
    ///
    /// Eight strips: fader CC 0–7, knob CC 16–23, S 32–39, M 48–55, R 64–71. Transport:
    /// ◀◀ 43, ▶▶ 44, ■ 42, ▶ 41, ● 45, cycle 46, track ◀ 58 / ▶ 59. Buttons send 127 on
    /// press and 0 on release in the factory (momentary) setting.
    static let nanoKONTROL2: MIDIControllerTemplate = {
        var mappings: [MIDIControlMapping] = []
        func cc(_ number: Int, _ target: MIDIControlTarget, pickup: Bool = false) {
            mappings.append(MIDIControlMapping(
                id: UUID(uuidString: String(format: "6E4B2C1A-0F3D-4C6B-9A7E-%012lX", number))!,
                source: MIDIControlSource(kind: .controlChange, channel: 1, number: number),
                target: target, pickup: pickup))
        }
        for strip in 0..<8 {
            cc(0 + strip, .trackVolume(strip))
            cc(16 + strip, .trackPan(strip))
            cc(32 + strip, .trackSolo(strip))
            cc(48 + strip, .trackMute(strip))
            cc(64 + strip, .trackEffects(strip))
        }
        cc(41, .playPause)
        cc(42, .stop)
        cc(43, .rewind)
        cc(44, .tapTempo)
        cc(45, .record)
        cc(46, .loop)
        cc(58, .previousSection)
        cc(59, .nextSection)
        return MIDIControllerTemplate(id: nanoKONTROL2ID, name: "nanoKONTROL2 (factory)",
                                      mappings: mappings, isBuiltIn: true,
                                      deviceNameHint: "nanoKONTROL2")
    }()

    static let all: [MIDIControllerTemplate] = [nanoKONTROL2]
}
