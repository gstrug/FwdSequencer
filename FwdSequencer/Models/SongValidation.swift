import Foundation

nonisolated enum SongValidationError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This song uses format version \(version), but this version of FWD Sequencer supports up to version \(SongValidator.currentFormatVersion)."
        case .invalid(let detail):
            return "The song contains invalid data. \(detail)"
        }
    }
}

/// Validates every value that eventually reaches SwiftUI identity, integer division,
/// MIDI byte conversion, or the real-time scheduler. Imported files are untrusted input;
/// a successful JSON decode alone is not enough to make them safe to play.
nonisolated enum SongValidator {
    static let currentFormatVersion = 2
    static let maximumDocumentBytes = 64 * 1_024 * 1_024
    static let maximumPluginStateBytes = 32 * 1_024 * 1_024
    static let maximumNameLength = 200
    static let maximumPluginLabelLength = 1_000

    static func decodeAndValidate(_ data: Data) throws -> Song {
        guard data.count <= maximumDocumentBytes else {
            throw SongValidationError.invalid("The file is larger than 64 MB.")
        }
        return try validateAndNormalize(JSONDecoder().decode(Song.self, from: data))
    }

    /// Returns a safe, format-current value. The only normalization is backward-
    /// compatible structure that older documents legitimately lack: a first section,
    /// missing per-track parts, a random seed, and the current format marker.
    static func validateAndNormalize(_ input: Song) throws -> Song {
        var song = input

        if let version = song.formatVersion {
            guard version > 0 else {
                throw SongValidationError.invalid("Format version must be positive.")
            }
            guard version <= currentFormatVersion else {
                throw SongValidationError.unsupportedVersion(version)
            }
        }

        guard song.name.count <= maximumNameLength else {
            throw SongValidationError.invalid("The song name is too long.")
        }
        try requireFinite(song.tempo, name: "Tempo")
        guard (20...400).contains(song.tempo) else {
            throw SongValidationError.invalid("Tempo must be between 20 and 400 BPM.")
        }
        try validate(song.timeSignature)
        try validateGain(song.masterVolume, name: "Master volume")

        guard song.tracks.count <= 128 else {
            throw SongValidationError.invalid("A song cannot contain more than 128 tracks.")
        }
        try requireUnique(song.tracks.map(\.id), name: "track")

        if song.sections.isEmpty {
            song.sections = [SongSection(
                name: "Section 1",
                numberOfBars: 4,
                parts: song.tracks.map { Part(trackID: $0.id) }
            )]
        }
        guard song.sections.count <= 1_024 else {
            throw SongValidationError.invalid("A song cannot contain more than 1,024 sections.")
        }
        try requireUnique(song.sections.map(\.id), name: "section")

        let trackIDs = Set(song.tracks.map(\.id))
        for track in song.tracks {
            try validateDisplayName(track.name, context: "A track")
            try validate(track.pluginInfo, context: "Track \"\(track.name)\"")
            try validate(track.mixer, context: "Track \"\(track.name)\"")
            try validatePluginState(track.pluginStateData, context: "Track \"\(track.name)\"")
        }

        if let performance = song.performance {
            guard !trackIDs.contains(performance.id) else {
                throw SongValidationError.invalid("The manual instrument reuses a sequencer track identifier.")
            }
            try validateDisplayName(performance.name, context: "The manual instrument")
            try validate(performance.pluginInfo, context: "Manual instrument")
            try validate(performance.mixer, context: "Manual instrument")
            try validatePluginState(performance.pluginStateData, context: "Manual instrument")
        }

        for sectionIndex in song.sections.indices {
            var section = song.sections[sectionIndex]
            guard section.name.count <= maximumNameLength else {
                throw SongValidationError.invalid("Section \(sectionIndex + 1) has a name that is too long.")
            }
            guard (1...256).contains(section.numberOfBars) else {
                throw SongValidationError.invalid("Section \(sectionIndex + 1) must contain between 1 and 256 bars.")
            }

            let partIDs = section.parts.map(\.trackID)
            try requireUnique(partIDs, name: "part in section \(sectionIndex + 1)")
            guard Set(partIDs).isSubset(of: trackIDs) else {
                throw SongValidationError.invalid("Section \(sectionIndex + 1) contains a part for an unknown track.")
            }

            for trackID in song.tracks.map(\.id) where !partIDs.contains(trackID) {
                section.parts.append(Part(trackID: trackID))
            }
            for partIndex in section.parts.indices {
                try validate(section.parts[partIndex], section: sectionIndex + 1)
            }
            guard section.variations.count <= 32 else {
                throw SongValidationError.invalid("Section \(sectionIndex + 1) has more than 32 variations.")
            }
            try requireUnique(section.variations.map(\.id), name: "variation in section \(sectionIndex + 1)")
            for variation in section.variations {
                guard !variation.name.isEmpty, variation.name.count <= maximumNameLength else {
                    throw SongValidationError.invalid("A variation in section \(sectionIndex + 1) has an invalid name.")
                }
                let variationPartIDs = variation.parts.map(\.trackID)
                try requireUnique(variationPartIDs, name: "variation part in section \(sectionIndex + 1)")
                guard Set(variationPartIDs) == trackIDs else {
                    throw SongValidationError.invalid("A variation in section \(sectionIndex + 1) does not match the song tracks.")
                }
                for part in variation.parts { try validate(part, section: sectionIndex + 1) }
            }
            song.sections[sectionIndex] = section
        }

        if song.randomSeed == nil {
            song.randomSeed = seed(from: song.id)
        }
        song.formatVersion = currentFormatVersion
        return song
    }

    private static func validate(_ signature: TimeSignature) throws {
        guard (1...32).contains(signature.numerator) else {
            throw SongValidationError.invalid("Time-signature numerator must be between 1 and 32.")
        }
        guard [1, 2, 4, 8, 16, 32].contains(signature.denominator) else {
            throw SongValidationError.invalid("Time-signature denominator must be a power of two from 1 through 32.")
        }
    }

    private static func validate(_ mixer: MixerState, context: String) throws {
        try validateGain(mixer.volume, name: "\(context) volume")
        try requireFinite(mixer.pan, name: "\(context) pan")
        guard (-1...1).contains(mixer.pan) else {
            throw SongValidationError.invalid("\(context) pan must be between -1 and 1.")
        }
    }

    private static func validateDisplayName(_ value: String, context: String) throws {
        guard value.count <= maximumNameLength else {
            throw SongValidationError.invalid("\(context) has a name that is too long.")
        }
    }

    private static func validate(_ plugin: PluginInfo?, context: String) throws {
        guard let plugin else { return }
        guard plugin.name.count <= maximumPluginLabelLength,
              plugin.manufacturerName.count <= maximumPluginLabelLength else {
            throw SongValidationError.invalid("\(context) has plug-in labels that are too long.")
        }
    }

    private static func validate(_ part: Part, section: Int) throws {
        guard (0...11).contains(part.key) else {
            throw SongValidationError.invalid("A part in section \(section) has an invalid musical key.")
        }
        guard part.notePool.count <= 512 else {
            throw SongValidationError.invalid("A part in section \(section) has more than 512 notes.")
        }
        guard part.steps.count <= 4_096 else {
            throw SongValidationError.invalid("A part in section \(section) has more than 4,096 steps.")
        }
        try requireUnique(part.notePool.map(\.id), name: "note in section \(section)")
        try requireUnique(part.steps.map(\.id), name: "step in section \(section)")

        for note in part.notePool {
            guard (0...127).contains(note.midiNote) else {
                throw SongValidationError.invalid("A MIDI note in section \(section) is outside 0–127.")
            }
            guard (0...127).contains(note.velocity) else {
                throw SongValidationError.invalid("A note velocity in section \(section) is outside 0–127.")
            }
            try requireFinite(note.gateLength, name: "Note gate")
            guard (0.01...8).contains(note.gateLength) else {
                throw SongValidationError.invalid("A note gate in section \(section) is outside 0.01–8.")
            }
        }

        for step in part.steps {
            guard (1...4_096).contains(step.n) else {
                throw SongValidationError.invalid("A step value in section \(section) is outside 1–4,096.")
            }
            guard step.chordPositions.allSatisfy({ (1...4_096).contains($0) }) else {
                throw SongValidationError.invalid("A chord position in section \(section) is outside 1–4,096.")
            }
            try requireFinite(step.gate, name: "Step gate")
            guard (0.01...8).contains(step.gate) else {
                throw SongValidationError.invalid("A step gate in section \(section) is outside 0.01–8.")
            }
            try requireFinite(step.probability, name: "Step probability")
            guard (0...1).contains(step.probability) else {
                throw SongValidationError.invalid("A step probability in section \(section) is outside 0–1.")
            }
            guard (1...8).contains(step.ratchets) else {
                throw SongValidationError.invalid("A step ratchet count in section \(section) is outside 1–8.")
            }
        }
    }

    private static func validatePluginState(_ data: Data?, context: String) throws {
        guard (data?.count ?? 0) <= maximumPluginStateBytes else {
            throw SongValidationError.invalid("\(context) has more than 32 MB of plug-in state.")
        }
    }

    /// Mixer/master gain. Faders run to +6 dB so quiet instruments can be brought up,
    /// which is about 2.0 in linear terms — a plain 0...1 unit check would reject it.
    private static func validateGain(_ value: Float, name: String) throws {
        try requireFinite(value, name: name)
        guard (0...2).contains(value) else {
            throw SongValidationError.invalid("\(name) must be between 0 and 2.")
        }
    }

    private static func validateUnit(_ value: Float, name: String) throws {
        try requireFinite(value, name: name)
        guard (0...1).contains(value) else {
            throw SongValidationError.invalid("\(name) must be between 0 and 1.")
        }
    }

    private static func requireFinite<T: BinaryFloatingPoint>(_ value: T, name: String) throws {
        guard value.isFinite else {
            throw SongValidationError.invalid("\(name) must be a finite number.")
        }
    }

    private static func requireUnique(_ ids: [UUID], name: String) throws {
        guard Set(ids).count == ids.count else {
            throw SongValidationError.invalid("The document contains a duplicate \(name) identifier.")
        }
    }

    private static func seed(from id: UUID) -> UInt64 {
        withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(UInt64(0x465744)) { partial, byte in
                (partial &* 1_099_511_628_211) ^ UInt64(byte)
            }
        }
    }
}
