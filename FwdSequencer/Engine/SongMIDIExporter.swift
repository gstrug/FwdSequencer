import Foundation

/// Deterministically renders a song's arrangement to a type-1 Standard MIDI File.
/// AUv3 sound state is intentionally not embedded: the file contains tempo, meter,
/// section markers, track names, and the generated note performance.
nonisolated enum SongMIDIExporter {
    static let ticksPerQuarter = 480
    private static let baseTick = ticksPerQuarter / 8 // live engine's 32nd-note clock
    private static let maximumNoteEvents = 1_000_000

    enum ExportError: LocalizedError {
        case tooLarge

        var errorDescription: String? {
            "This arrangement is too large to export safely as one MIDI file. Export a shorter copy."
        }
    }

    private struct Event {
        let tick: Int
        let priority: Int
        let serial: Int
        let bytes: [UInt8]
    }

    private struct RenderState {
        var stepIndex = 0
        var notePointer = 0
        var dwellRemaining = 0
        var voicing: [Int]? = nil
        var hasPlayed = false
    }

    static func data(for input: Song) throws -> Data {
        let song = try SongValidator.validateAndNormalize(input)
        guard estimatedNoteEvents(in: song) <= maximumNoteEvents else {
            throw ExportError.tooLarge
        }
        var generator = SeededRandomGenerator(seed: song.randomSeed ?? 0x465744)
        var trackEvents = Array(repeating: [Event](), count: song.tracks.count)
        var conductor: [Event] = []
        var serial = 0

        func event(_ tick: Int, _ priority: Int, _ bytes: [UInt8]) -> Event {
            serial += 1
            return Event(tick: tick, priority: priority, serial: serial, bytes: bytes)
        }

        let microseconds = Int((60_000_000 / max(20, min(400, song.tempo))).rounded())
        conductor.append(event(0, -10, [
            0xFF, 0x51, 0x03,
            UInt8((microseconds >> 16) & 0xFF),
            UInt8((microseconds >> 8) & 0xFF),
            UInt8(microseconds & 0xFF)
        ]))
        let denominatorPower = UInt8(song.timeSignature.denominator.trailingZeroBitCount)
        conductor.append(event(0, -9, [
            0xFF, 0x58, 0x04,
            UInt8(song.timeSignature.numerator), denominatorPower, 24, 8
        ]))

        let channels = (0..<16).filter { $0 != 9 }
        var absoluteTick = 0
        for section in song.sections {
            conductor.append(event(absoluteTick, -8, metaText(0x06, section.name)))
            var states = Dictionary(uniqueKeysWithValues: song.tracks.map { ($0.id, RenderState()) })
            let ticksPerBar = ticksPerQuarter * 4 * song.timeSignature.numerator
                / song.timeSignature.denominator
            let sectionTicks = ticksPerBar * section.numberOfBars
            let anySoloed = song.tracks.contains { $0.mixer.isSoloed }

            for localTick in stride(from: 0, to: sectionTicks, by: baseTick) {
                for (trackIndex, track) in song.tracks.enumerated() {
                    guard !track.mixer.isMuted, !anySoloed || track.mixer.isSoloed,
                          let part = section.parts.first(where: { $0.trackID == track.id }),
                          !part.notePool.isEmpty else { continue }
                    let trigger = triggerTicks(for: part.tempoDivision)
                    guard localTick % trigger == 0, var state = states[track.id] else { continue }

                    let activeStep = part.steps.isEmpty ? nil : part.steps[state.stepIndex % part.steps.count]
                    var resolved = execute(part: part, state: &state, random: &generator)
                    if let step = activeStep, step.probability < 1,
                       generator.nextUnitInterval() >= max(0, step.probability) {
                        resolved.indices.removeAll()
                    }
                    states[track.id] = state
                    guard !resolved.indices.isEmpty else { continue }

                    let ratchets = min(8, max(1, activeStep?.ratchets ?? 1))
                    let subdivision = trigger / ratchets
                    let channel = UInt8(channels[trackIndex % channels.count])
                    for poolIndex in resolved.indices {
                        let note = part.notePool[poolIndex]
                        let gate = max(0.01, note.gateLength * resolved.gate)
                        let duration = max(1, min(subdivision - 1, Int(Double(subdivision) * gate)))
                        for ratchet in 0..<ratchets {
                            let onTick = absoluteTick + localTick + ratchet * subdivision
                            let noteByte = UInt8(note.midiNote)
                            trackEvents[trackIndex].append(event(
                                onTick, 1, [0x90 | channel, noteByte, UInt8(note.velocity)]
                            ))
                            trackEvents[trackIndex].append(event(
                                onTick + duration, 0, [0x80 | channel, noteByte, 0]
                            ))
                        }
                    }
                }
            }
            absoluteTick += sectionTicks
        }

        var chunks: [Data] = [trackChunk(events: conductor, endTick: absoluteTick)]
        for (index, track) in song.tracks.enumerated() {
            var events = trackEvents[index]
            events.append(event(0, -7, metaText(0x03, track.name)))
            chunks.append(trackChunk(events: events, endTick: absoluteTick))
        }

        var output = Data([0x4D, 0x54, 0x68, 0x64]) // MThd
        appendUInt32(6, to: &output)
        appendUInt16(1, to: &output)
        appendUInt16(UInt16(chunks.count), to: &output)
        appendUInt16(UInt16(ticksPerQuarter), to: &output)
        for chunk in chunks { output.append(chunk) }
        return output
    }

    private static func execute(part: Part, state: inout RenderState,
                                random: inout SeededRandomGenerator)
        -> (indices: [Int], gate: Double) {
        let noteCount = part.notePool.count
        guard !part.steps.isEmpty else {
            let index = state.notePointer % noteCount
            state.notePointer = (index + 1) % noteCount
            return ([index], 1)
        }
        let stepIndex = state.stepIndex % part.steps.count
        let step = part.steps[stepIndex]
        func advance() { state.stepIndex = (stepIndex + 1) % part.steps.count }
        func dwell() {
            if step.n <= 1 { advance(); state.dwellRemaining = 0 }
            else if state.dwellRemaining == 0 { state.dwellRemaining = step.n - 1 }
            else {
                state.dwellRemaining -= 1
                if state.dwellRemaining == 0 { advance() }
            }
        }

        switch step.type {
        case .fwd, .back:
            advance()
            let movement = max(1, step.n) * (step.type == .fwd ? 1 : -1)
            if let voicing = state.voicing {
                let moved = voicing.map { (($0 + movement) % noteCount + noteCount) % noteCount }
                state.voicing = moved
                state.notePointer = moved.first ?? 0
                state.hasPlayed = true
                return (moved, step.gate)
            }
            if state.hasPlayed {
                state.notePointer = ((state.notePointer + movement) % noteCount + noteCount) % noteCount
            }
            state.hasPlayed = true
            return ([state.notePointer], step.gate)
        case .rep:
            dwell()
            state.hasPlayed = true
            return (state.voicing ?? [state.notePointer], step.gate)
        case .play:
            let positions = step.chordPositions.count > 1 ? step.chordPositions : [step.n]
            var seen = Set<Int>()
            let indices = positions.compactMap { position -> Int? in
                let index = position - 1
                return index >= 0 && index < noteCount && seen.insert(index).inserted ? index : nil
            }
            advance()
            guard let first = indices.first else { state.voicing = nil; return ([], step.gate) }
            state.voicing = indices.count > 1 ? indices : nil
            state.notePointer = first
            state.hasPlayed = true
            return (indices, step.gate)
        case .random:
            let index = random.nextIndex(upperBound: noteCount)
            state.voicing = nil
            state.notePointer = index
            state.hasPlayed = true
            advance()
            return ([index], step.gate)
        case .hold, .pause:
            dwell()
            return ([], 1)
        }
    }

    private static func triggerTicks(for division: TempoDivision) -> Int {
        switch division {
        case .breve: return ticksPerQuarter * 8
        case .whole: return ticksPerQuarter * 4
        case .half: return ticksPerQuarter * 2
        case .quarter: return ticksPerQuarter
        case .eighth: return ticksPerQuarter / 2
        case .sixteenth: return ticksPerQuarter / 4
        case .thirtysecond: return ticksPerQuarter / 8
        }
    }

    private static func estimatedNoteEvents(in song: Song) -> Int {
        var total: Int64 = 0
        for section in song.sections {
            let ticksPerBar = ticksPerQuarter * 4 * song.timeSignature.numerator
                / song.timeSignature.denominator
            let sectionTicks = ticksPerBar * section.numberOfBars
            for part in section.parts where !part.notePool.isEmpty {
                let triggers = (sectionTicks + triggerTicks(for: part.tempoDivision) - 1)
                    / triggerTicks(for: part.tempoDivision)
                let widestStep = part.steps.map { step in
                    step.type == .play && step.chordPositions.count > 1
                        ? min(part.notePool.count, Set(step.chordPositions).count) : 1
                }.max() ?? 1
                let mostRatchets = part.steps.map(\.ratchets).max() ?? 1
                total += Int64(triggers) * Int64(widestStep) * Int64(mostRatchets)
                if total > Int64(maximumNoteEvents) { return maximumNoteEvents + 1 }
            }
        }
        return Int(total)
    }

    private static func metaText(_ type: UInt8, _ text: String) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(255))
        return [0xFF, type] + variableLength(bytes.count) + bytes
    }

    private static func trackChunk(events: [Event], endTick: Int) -> Data {
        let sorted = events.sorted {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.serial < $1.serial
        }
        var body = Data()
        var previousTick = 0
        for event in sorted {
            body.append(contentsOf: variableLength(max(0, event.tick - previousTick)))
            body.append(contentsOf: event.bytes)
            previousTick = event.tick
        }
        body.append(contentsOf: variableLength(max(0, endTick - previousTick)))
        body.append(contentsOf: [0xFF, 0x2F, 0x00])

        var chunk = Data([0x4D, 0x54, 0x72, 0x6B]) // MTrk
        appendUInt32(UInt32(body.count), to: &chunk)
        chunk.append(body)
        return chunk
    }

    private static func variableLength(_ input: Int) -> [UInt8] {
        var value = max(0, input)
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return bytes
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}
