import XCTest
@testable import FwdSequencerCore

final class MIDIImportTests: XCTestCase {

    private func describe(_ steps: [Step]) -> [String] {
        steps.map { step in
            step.chordPositions.count > 1
                ? "\(step.type.rawValue) \(step.chordPositions)"
                : "\(step.type.rawValue) \(step.n)"
        }
    }

    private func smf(division: UInt16 = 96, _ track: [UInt8]) -> Data {
        var bytes: [UInt8] = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1,
                              UInt8(division >> 8), UInt8(division & 0xFF)]
        let body = track + [0x00, 0xFF, 0x2F, 0x00]
        bytes += [0x4D, 0x54, 0x72, 0x6B]
        bytes += withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init)
        bytes += body
        return Data(bytes)
    }

    func testReadsNotesWithRunningStatusAndZeroVelocityReleases() throws {
        let file = try MIDIFileReader.read(smf([
            0x00, 0x90, 60, 100,     // C on
            0x60, 60, 0,             // 96 ticks later, running status, velocity 0 = off
            0x00, 64, 90,            // E on
            0x30, 0x80, 64, 0,       // 48 ticks later, E off
        ]))
        XCTAssertEqual(file.ticksPerQuarter, 96)
        XCTAssertEqual(file.parts.count, 1)
        XCTAssertEqual(file.parts[0].notes, [
            ImportedNote(start: 0, end: 96, pitch: 60, velocity: 100),
            ImportedNote(start: 96, end: 144, pitch: 64, velocity: 90),
        ])
    }

    func testATrackWithSeveralChannelsBecomesSeveralParts() throws {
        let file = try MIDIFileReader.read(smf([
            0x00, 0xFF, 0x03, 0x04, 0x53, 0x6F, 0x6E, 0x67,   // name "Song"
            0x00, 0x90, 60, 100, 0x00, 0x91, 40, 100,
            0x60, 0x80, 60, 0, 0x00, 0x81, 40, 0,
        ]))
        XCTAssertEqual(file.parts.map(\.name), ["Song (ch 1)", "Song (ch 2)"])
        XCTAssertEqual(file.parts.map { $0.notes.map(\.pitch) }, [[60], [40]])
    }

    func testNotMIDIIsRefused() {
        XCTAssertThrowsError(try MIDIFileReader.read(Data("hello".utf8)))
    }

    private let fourFour = TimeSignature(numerator: 4, denominator: 4)

    func testAMelodyBecomesPlayHoldAndRest() throws {
        let notes = [ImportedNote(start: 0, end: 192, pitch: 60, velocity: 100),    // half note
                     ImportedNote(start: 288, end: 384, pitch: 64, velocity: 100)]  // after a rest
        let result = try MIDIImportConverter.convert(notes, from: 0, bars: 1, ticksPerQuarter: 96,
                                                     timeSignature: fourFour, division: .quarter)
        XCTAssertEqual(result.notePool.map(\.midiNote), [60, 64])
        XCTAssertEqual(describe(result.steps), ["Play 1", "Hold 1", "Pause 1", "Play 2"])
    }

    func testNotesStruckTogetherBecomeAChord() throws {
        let notes = [60, 64, 67].map { ImportedNote(start: 0, end: 96, pitch: $0, velocity: 100) }
        let result = try MIDIImportConverter.convert(notes, from: 0, bars: 1, ticksPerQuarter: 96,
                                                     timeSignature: fourFour, division: .quarter)
        XCTAssertEqual(describe(result.steps), ["Play [1, 2, 3]", "Pause 3"])
    }

    func testANewNoteEndsTheOneBefore() throws {
        let notes = [ImportedNote(start: 0, end: 288, pitch: 48, velocity: 100),
                     ImportedNote(start: 96, end: 192, pitch: 60, velocity: 100)]
        let result = try MIDIImportConverter.convert(notes, from: 0, bars: 1, ticksPerQuarter: 96,
                                                     timeSignature: fourFour, division: .quarter)
        XCTAssertEqual(describe(result.steps), ["Play 1", "Play 2", "Pause 2"])
    }

    func testNotesPastTheSectionAreCounted() throws {
        let notes = [ImportedNote(start: 0, end: 96, pitch: 60, velocity: 100),
                     ImportedNote(start: 400, end: 480, pitch: 62, velocity: 100)]
        let result = try MIDIImportConverter.convert(notes, from: 0, bars: 1, ticksPerQuarter: 96,
                                                     timeSignature: fourFour, division: .quarter)
        XCTAssertEqual(result.notesLeftOut, 1)
        XCTAssertEqual(describe(result.steps), ["Play 1", "Pause 3"])
    }

    func testTheSuggestedStepSizeFitsTheRhythm() {
        let triplets = (0..<6).map { ImportedNote(start: $0 * 32, end: $0 * 32 + 30, pitch: 60, velocity: 100) }
        XCTAssertEqual(MIDIImportConverter.suggestedDivision(for: triplets, ticksPerQuarter: 96), .eighthTriplet)
        let sixteenths = (0..<8).map { ImportedNote(start: $0 * 24, end: $0 * 24 + 20, pitch: 60, velocity: 100) }
        XCTAssertEqual(MIDIImportConverter.suggestedDivision(for: sixteenths, ticksPerQuarter: 96), .sixteenth)
        let quarters = (0..<4).map { ImportedNote(start: $0 * 96 + 2, end: $0 * 96 + 90, pitch: 60, velocity: 100) }
        XCTAssertEqual(MIDIImportConverter.suggestedDivision(for: quarters, ticksPerQuarter: 96), .quarter)
    }

    func testImportStartsAtTheBarOfTheFirstNoteAndCountsBars() {
        let notes = [ImportedNote(start: 400, end: 1_200, pitch: 60, velocity: 100)]
        let origin = MIDIImportConverter.firstBarStart(of: notes, ticksPerQuarter: 96, timeSignature: fourFour)
        XCTAssertEqual(origin, 384)
        XCTAssertEqual(MIDIImportConverter.barsNeeded(for: notes, from: origin, ticksPerQuarter: 96,
                                                      timeSignature: fourFour, division: .quarter), 3)
    }

    func testStepsFillTheSectionExactlyInAnOddMeter() throws {
        let fiveEight = TimeSignature(numerator: 5, denominator: 8)
        let notes = [ImportedNote(start: 0, end: 10, pitch: 60, velocity: 100)]
        let result = try MIDIImportConverter.convert(notes, from: 0, bars: 2, ticksPerQuarter: 96,
                                                     timeSignature: fiveEight, division: .eighthTriplet)
        let triggers = result.steps.reduce(0) { $0 + (($1.type == .hold || $1.type == .pause) ? $1.n : 1) }
        // Two bars of 5/8 are 120 sequencer ticks; at 1/8T (8 ticks) that is 15 triggers.
        XCTAssertEqual(triggers, 15)
    }

    /// What FWD exports, FWD imports back to the same steps.
    func testAPartExportedToMIDIImportsBackToTheSameSteps() throws {
        let track = SongTrack(name: "Lead")
        let steps = [Step(type: .play, n: 1), Step(type: .play, n: 2), Step(type: .hold, n: 1),
                     Step(type: .pause, n: 2), Step(type: .play, n: 1, chordPositions: [1, 3]),
                     Step(type: .hold, n: 1), Step(type: .pause, n: 1)]
        var song = Song()
        song.tracks = [track]
        song.sections = [SongSection(name: "A", numberOfBars: 1, parts: [
            Part(trackID: track.id, notePool: [60, 62, 64].map { NoteEntry(midiNote: $0) },
                 steps: steps, tempoDivision: .eighth)
        ])]
        song.randomSeed = 7
        let file = try MIDIFileReader.read(try SongMIDIExporter.data(for: song))
        let part = try XCTUnwrap(file.parts.first { !$0.notes.isEmpty })
        let result = try MIDIImportConverter.convert(part.notes, from: 0, bars: 1,
                                                     ticksPerQuarter: file.ticksPerQuarter,
                                                     timeSignature: fourFour, division: .eighth)
        XCTAssertEqual(result.notePool.map(\.midiNote), [60, 62, 64])
        XCTAssertEqual(describe(result.steps), describe(steps))
    }
}
