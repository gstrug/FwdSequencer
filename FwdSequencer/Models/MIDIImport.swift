import Foundation

// MARK: - MIDI import
//
// Reads a Standard MIDI File and turns each of its parts into a FWD Part for one
// section: the pitches used become the note pool, and the timing becomes steps —
// Play (a note or chord), Hold (keep it sounding) and Rest (silence) — snapped to the
// chosen step size. The Happy Birthday example is music written the same way.
//
// Portable and unit-tested; the screen is Views/MIDIImportSheet.swift.
//
// What a transcription cannot keep: timing finer than the step size, and notes that
// overlap on one track — a new note or chord ends the one before, as every FWD step
// does. A part with sustained notes under a moving line is best split across two
// FWD tracks (one per MIDI track or channel).

/// One note read from a file, in the file's own ticks.
nonisolated struct ImportedNote: Equatable {
    var start: Int
    var end: Int
    var pitch: Int
    var velocity: Int
}

/// One part of a file that can go to a FWD track: a MIDI track, or one channel of it
/// when a track carries several (as Type 0 files do).
nonisolated struct ImportedPart: Equatable, Identifiable {
    var id: Int
    var name: String
    var channel: Int        // 1–16
    var notes: [ImportedNote]

    var isDrums: Bool { channel == 10 }
    var lowestPitch: Int { notes.map(\.pitch).min() ?? 0 }
    var highestPitch: Int { notes.map(\.pitch).max() ?? 0 }
}

nonisolated struct ImportedMIDIFile: Equatable {
    var ticksPerQuarter: Int
    var parts: [ImportedPart]
    var tempo: Double?                  // BPM, the file's first tempo
    var timeSignature: TimeSignature?   // the file's first
}

nonisolated enum MIDIImportError: LocalizedError, Equatable {
    case notAMIDIFile
    case unsupportedTiming
    case damaged
    case noNotes
    case tooLong(String)

    var errorDescription: String? {
        switch self {
        case .notAMIDIFile: return "That file is not a MIDI file."
        case .unsupportedTiming: return "That MIDI file uses SMPTE timing, which can't be imported."
        case .damaged: return "That MIDI file is damaged or incomplete."
        case .noNotes: return "That MIDI file has no notes."
        case .tooLong(let detail): return detail
        }
    }
}

// MARK: Reading

nonisolated enum MIDIFileReader {
    static let maximumFileBytes = 16 * 1_024 * 1_024

    static func read(_ data: Data) throws -> ImportedMIDIFile {
        let bytes = [UInt8](data)
        guard bytes.count >= 14, bytes.count <= maximumFileBytes,
              Array(bytes[0..<4]) == [0x4D, 0x54, 0x68, 0x64] else { throw MIDIImportError.notAMIDIFile }
        let headerLength = Int(be32(bytes, 4))
        guard headerLength >= 6, bytes.count >= 8 + headerLength else { throw MIDIImportError.damaged }
        let trackCount = Int(be16(bytes, 10))
        let division = Int(be16(bytes, 12))
        guard division & 0x8000 == 0 else { throw MIDIImportError.unsupportedTiming }
        guard division > 0 else { throw MIDIImportError.damaged }

        var file = ImportedMIDIFile(ticksPerQuarter: division, parts: [])
        var offset = 8 + headerLength
        var nextID = 0
        for trackIndex in 0..<trackCount {
            // Skip anything that is not a track chunk.
            while offset + 8 <= bytes.count, Array(bytes[offset..<offset + 4]) != [0x4D, 0x54, 0x72, 0x6B] {
                offset += 8 + Int(be32(bytes, offset + 4))
            }
            guard offset + 8 <= bytes.count else { break }
            let length = Int(be32(bytes, offset + 4))
            let start = offset + 8
            let end = min(bytes.count, start + length)
            offset = start + length
            let track = try readTrack(bytes, from: start, to: end, file: &file)
            let name = track.name ?? "Track \(trackIndex + 1)"
            let channels = Set(track.notes.map { $0.channel }).sorted()
            for channel in channels {
                let notes = track.notes.filter { $0.channel == channel }.map { $0.note }
                    .sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
                let label = channels.count > 1 ? "\(name) (ch \(channel))" : name
                file.parts.append(ImportedPart(id: nextID, name: label, channel: channel, notes: notes))
                nextID += 1
            }
        }
        guard file.parts.contains(where: { !$0.notes.isEmpty }) else { throw MIDIImportError.noNotes }
        return file
    }

    private struct Track {
        var name: String?
        var notes: [(channel: Int, note: ImportedNote)] = []
    }

    private static func readTrack(_ b: [UInt8], from start: Int, to end: Int,
                                  file: inout ImportedMIDIFile) throws -> Track {
        var track = Track()
        var i = start
        var tick = 0
        var status: UInt8 = 0
        // Notes sounding, per channel and pitch, oldest first (a pitch can be
        // struck again before it is released).
        var open: [Int: [(start: Int, velocity: Int)]] = [:]

        func varLen() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard i < end else { throw MIDIImportError.damaged }
                let byte = b[i]; i += 1
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw MIDIImportError.damaged
        }

        func close(channel: Int, pitch: Int, at tick: Int) {
            let key = channel * 128 + pitch
            guard var waiting = open[key], !waiting.isEmpty else { return }
            let first = waiting.removeFirst()
            open[key] = waiting
            track.notes.append((channel, ImportedNote(start: first.start, end: max(tick, first.start),
                                                      pitch: pitch, velocity: first.velocity)))
        }

        while i < end {
            tick += try varLen()
            guard i < end else { break }
            var byte = b[i]
            if byte & 0x80 != 0 {
                i += 1
                if byte < 0xF0 { status = byte }
            } else {
                // Running status: this byte is the first data byte.
                guard status != 0 else { throw MIDIImportError.damaged }
                byte = status
            }
            switch byte {
            case 0xFF:
                guard i < end else { throw MIDIImportError.damaged }
                let type = b[i]; i += 1
                let length = try varLen()
                guard i + length <= end else { throw MIDIImportError.damaged }
                let payload = Array(b[i..<i + length]); i += length
                switch type {
                case 0x03 where track.name == nil:
                    let name = String(decoding: payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { track.name = name }
                case 0x51 where file.tempo == nil && length == 3:
                    let micros = Int(payload[0]) << 16 | Int(payload[1]) << 8 | Int(payload[2])
                    if micros > 0 { file.tempo = 60_000_000 / Double(micros) }
                case 0x58 where file.timeSignature == nil && length >= 2:
                    file.timeSignature = TimeSignature(numerator: Int(payload[0]),
                                                       denominator: 1 << Int(min(payload[1], 5)))
                case 0x2F:
                    i = end
                default: break
                }
            case 0xF0, 0xF7:
                let length = try varLen()
                i += length
            default:
                let kind = byte & 0xF0
                let channel = Int(byte & 0x0F) + 1
                let dataCount = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                guard i + dataCount <= end else { throw MIDIImportError.damaged }
                let d1 = Int(b[i] & 0x7F)
                let d2 = dataCount == 2 ? Int(b[i + 1] & 0x7F) : 0
                i += dataCount
                if kind == 0x90 && d2 > 0 {
                    open[channel * 128 + d1, default: []].append((tick, d2))
                } else if kind == 0x80 || (kind == 0x90 && d2 == 0) {
                    close(channel: channel, pitch: d1, at: tick)
                }
            }
        }
        // Notes never released end where the track ends.
        for (key, waiting) in open {
            for note in waiting {
                track.notes.append((key / 128, ImportedNote(start: note.start, end: max(tick, note.start + 1),
                                                           pitch: key % 128, velocity: note.velocity)))
            }
        }
        return track
    }

    private static func be16(_ b: [UInt8], _ at: Int) -> UInt16 {
        UInt16(b[at]) << 8 | UInt16(b[at + 1])
    }

    private static func be32(_ b: [UInt8], _ at: Int) -> UInt32 {
        guard at + 3 < b.count else { return 0 }
        return UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }
}

// MARK: Converting

nonisolated enum MIDIImportConverter {
    /// Step sizes offered, coarsest first.
    static let divisions: [TempoDivision] = [.quarter, .eighth, .eighthTriplet, .sixteenth,
                                             .sixteenthTriplet, .thirtysecond]

    /// The coarsest step size that places the notes' starts close to where they were
    /// played — fewer steps to read and edit — falling back to the finest.
    static func suggestedDivision(for notes: [ImportedNote], ticksPerQuarter: Int) -> TempoDivision {
        guard !notes.isEmpty else { return .sixteenth }
        for division in divisions {
            let grid = gridTicks(division, ticksPerQuarter: ticksPerQuarter)
            let error = notes.reduce(0.0) { total, note in
                let offset = Double(note.start).truncatingRemainder(dividingBy: grid)
                return total + min(offset, grid - offset)
            } / Double(notes.count)
            // Within 1/24 of a beat on average: a played note, not a different rhythm.
            if error <= Double(ticksPerQuarter) / 24 { return division }
        }
        return .thirtysecond
    }

    /// The first bar holding a note, in file ticks, measured in the song's bars.
    static func firstBarStart(of notes: [ImportedNote], ticksPerQuarter: Int,
                              timeSignature: TimeSignature) -> Int {
        let bar = barTicks(ticksPerQuarter: ticksPerQuarter, timeSignature: timeSignature)
        let first = notes.map(\.start).min() ?? 0
        return (first / bar) * bar
    }

    /// Bars needed to hold the notes from `origin`, at the chosen step size.
    static func barsNeeded(for notes: [ImportedNote], from origin: Int, ticksPerQuarter: Int,
                           timeSignature: TimeSignature, division: TempoDivision) -> Int {
        let grid = gridTicks(division, ticksPerQuarter: ticksPerQuarter)
        let lastSlot = notes.map { max(slot(of: $0.end - origin, grid: grid),
                                       slot(of: $0.start - origin, grid: grid) + 1) }.max() ?? 1
        let barLength = timeSignature.numerator * 96 / max(1, timeSignature.denominator)
        let needed = Double(lastSlot * division.sequencerTicks) / Double(max(1, barLength))
        return max(1, Int(needed.rounded(.up)))
    }

    struct Result: Equatable {
        var notePool: [NoteEntry]
        var steps: [Step]
        /// Notes that started past the end of the section and were left out.
        var notesLeftOut: Int
    }

    /// Transcribe notes into a pool and steps filling exactly `bars` bars from `origin`.
    static func convert(_ notes: [ImportedNote], from origin: Int, bars: Int,
                        ticksPerQuarter: Int, timeSignature: TimeSignature,
                        division: TempoDivision) throws -> Result {
        let grid = gridTicks(division, ticksPerQuarter: ticksPerQuarter)
        let total = slots(inBars: bars, timeSignature: timeSignature, division: division)

        // Onsets per slot. The same pitch struck twice in one slot is one note, at the
        // louder velocity and the longer length.
        var onsets: [Int: [Int: (velocity: Int, end: Int)]] = [:]
        var leftOut = 0
        for note in notes where note.start >= origin {
            let s = slot(of: note.start - origin, grid: grid)
            guard s < total else { leftOut += 1; continue }
            let e = min(total, max(s + 1, slot(of: note.end - origin, grid: grid)))
            let existing = onsets[s]?[note.pitch]
            onsets[s, default: [:]][note.pitch] = (max(existing?.velocity ?? 0, note.velocity),
                                                  max(existing?.end ?? 0, e))
        }

        // The pool: each pitch and velocity used, low to high. Velocities are rounded
        // to steps of 8 so a played part does not need a pool entry per touch; if the
        // pool would still be too big, one entry per pitch.
        func entryKey(_ pitch: Int, _ velocity: Int, perPitch: Bool) -> Int {
            perPitch ? pitch * 128 : pitch * 128 + min(127, max(1, (velocity + 4) / 8 * 8))
        }
        let all = onsets.values.flatMap { $0.map { ($0.key, $0.value.velocity) } }
        var perPitch = Set(all.map { entryKey($0.0, $0.1, perPitch: false) }).count > maxPool
        var keys = Set(all.map { entryKey($0.0, $0.1, perPitch: perPitch) }).sorted()
        if keys.count > maxPool { perPitch = true; keys = Set(all.map { entryKey($0.0, $0.1, perPitch: true) }).sorted() }
        guard keys.count <= maxPool else {
            throw MIDIImportError.tooLong("That part uses more than \(maxPool) different notes.")
        }
        var averageVelocity: [Int: Int] = [:]
        if perPitch {
            var sums: [Int: (Int, Int)] = [:]
            for (pitch, velocity) in all { sums[pitch, default: (0, 0)].0 += velocity; sums[pitch, default: (0, 0)].1 += 1 }
            for (pitch, sum) in sums { averageVelocity[pitch] = sum.0 / max(1, sum.1) }
        }
        let pool = keys.map { key -> NoteEntry in
            let pitch = key / 128
            let velocity = perPitch ? (averageVelocity[pitch] ?? 100) : key % 128
            return NoteEntry(midiNote: pitch, velocity: velocity, gateLength: 0.9)
        }
        var position: [Int: Int] = [:]
        for (index, key) in keys.enumerated() { position[key] = index + 1 }

        // Walk the section: a note or chord is Play, its length a Hold after it, and a
        // gap a Rest. A new onset ends whatever was sounding.
        var steps: [Step] = []
        let onsetSlots = onsets.keys.sorted()
        var nextOnset = 0
        var s = 0
        while s < total {
            while nextOnset < onsetSlots.count && onsetSlots[nextOnset] < s { nextOnset += 1 }
            let following = nextOnset < onsetSlots.count ? onsetSlots[nextOnset] : total
            if let chord = onsets[s] {
                let positions = chord.map { position[entryKey($0.key, $0.value.velocity, perPitch: perPitch)] ?? 1 }
                    .sorted()
                let after = nextOnset + 1 < onsetSlots.count ? onsetSlots[nextOnset + 1] : total
                let ends = chord.values.map(\.end).max() ?? (s + 1)
                let length = max(1, min(ends, after) - s)
                if positions.count > 1 {
                    steps.append(Step(type: .play, n: positions[0], chordPositions: positions, gate: 1.0))
                } else {
                    steps.append(Step(type: .play, n: positions[0], gate: 1.0))
                }
                if length > 1 { steps.append(Step(type: .hold, n: length - 1)) }
                s += length
            } else {
                steps.append(Step(type: .pause, n: following - s))
                s = following
            }
        }
        guard steps.count <= maxSteps else {
            throw MIDIImportError.tooLong("That part needs more than \(maxSteps) steps at this step size. Try a larger step size or a shorter part.")
        }
        return Result(notePool: pool, steps: steps, notesLeftOut: leftOut)
    }

    // MARK: Units

    static let maxPool = 512
    static let maxSteps = 4_096

    /// File ticks per step.
    static func gridTicks(_ division: TempoDivision, ticksPerQuarter: Int) -> Double {
        Double(division.sequencerTicks) * Double(ticksPerQuarter) / 24
    }

    static func barTicks(ticksPerQuarter: Int, timeSignature: TimeSignature) -> Int {
        max(1, ticksPerQuarter * 4 * timeSignature.numerator / max(1, timeSignature.denominator))
    }

    /// Steps in a section of `bars` bars, counted as the sequencer counts its triggers
    /// (one at every multiple of the step size from the section's start).
    static func slots(inBars bars: Int, timeSignature: TimeSignature, division: TempoDivision) -> Int {
        let sectionTicks = max(1, bars) * timeSignature.numerator * 96 / max(1, timeSignature.denominator)
        let trigger = division.sequencerTicks
        return max(1, (sectionTicks + trigger - 1) / trigger)
    }

    private static func slot(of ticks: Int, grid: Double) -> Int {
        max(0, Int((Double(ticks) / grid).rounded()))
    }
}

// MARK: - One import, worked out

/// The choices for one import, applied the same way to every part so they stay in
/// time with each other: one starting bar and one length, from all the chosen parts.
nonisolated struct MIDIImportPlan {
    let file: ImportedMIDIFile
    let timeSignature: TimeSignature
    let division: TempoDivision
    let origin: Int
    let bars: Int

    init(file: ImportedMIDIFile, parts: [ImportedPart], timeSignature: TimeSignature,
         division: TempoDivision, startAtFirstNote: Bool, fitLength: Bool, currentBars: Int) {
        self.file = file
        self.timeSignature = timeSignature
        self.division = division
        let notes = parts.flatMap(\.notes)
        origin = startAtFirstNote
            ? MIDIImportConverter.firstBarStart(of: notes, ticksPerQuarter: file.ticksPerQuarter,
                                                timeSignature: timeSignature)
            : 0
        bars = fitLength
            ? min(Self.maximumBars, MIDIImportConverter.barsNeeded(
                for: notes, from: origin, ticksPerQuarter: file.ticksPerQuarter,
                timeSignature: timeSignature, division: division))
            : max(1, currentBars)
    }

    /// The longest a section can be.
    static let maximumBars = 256

    func convert(_ part: ImportedPart) throws -> MIDIImportConverter.Result {
        try MIDIImportConverter.convert(part.notes, from: origin, bars: bars,
                                        ticksPerQuarter: file.ticksPerQuarter,
                                        timeSignature: timeSignature, division: division)
    }
}
