import XCTest
@testable import FwdSequencerCore

/// A track with no steps does not sequence: it is an instrument for a MIDI keyboard.
/// So an example song that is meant to play must give steps to every track that has
/// notes, or that track will be silent. Add any new example song here.
final class ExampleSongTests: XCTestCase {

    private func assertEveryPartWithNotesHasSteps(_ song: Song, _ name: String,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        for section in song.sections {
            for part in section.parts where !part.notePool.isEmpty {
                let track = song.tracks.first { $0.id == part.trackID }?.name ?? "?"
                XCTAssertFalse(part.steps.isEmpty,
                               "\(name): track \"\(track)\" has notes but no steps in \"\(section.name)\", so it would be silent",
                               file: file, line: line)
            }
        }
    }

    func testEveryBuiltInExampleSequencesItsNotes() {
        for template in SongTemplate.allCases {
            assertEveryPartWithNotesHasSteps(template.makeSong(), template.rawValue)
        }
    }

    /// The Happy Birthday example is an app resource, which the test bundle cannot load
    /// through Bundle.main, so it is read from the source tree.
    func testTheHappyBirthdayExampleSequencesItsNotes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FwdSequencer/Resources/HappyBirthdayJazz.json")
        let song = try SongStorage.decodeDocument(Data(contentsOf: url))
        assertEveryPartWithNotesHasSteps(song, "Happy Birthday")
    }
}

/// A track with notes but no steps is an instrument only: nothing is sequenced, so
/// MIDI export writes no notes for it, exactly as playback plays none.
final class InstrumentOnlyTrackTests: XCTestCase {
    private func song(notes: [Int], steps: [Step]) -> Song {
        let track = SongTrack(name: "Keys")
        var song = Song()
        song.tracks = [track]
        song.sections = [SongSection(name: "A", numberOfBars: 2, parts: [
            Part(trackID: track.id, notePool: notes.map { NoteEntry(midiNote: $0) }, steps: steps)
        ])]
        song.randomSeed = 1
        return song
    }

    func testNoStepsExportsNoNotes() throws {
        var silent = song(notes: [60, 64], steps: [])
        var empty = silent
        empty.sections[0].parts[0].notePool = []
        silent.id = empty.id
        XCTAssertEqual(try SongMIDIExporter.data(for: silent), try SongMIDIExporter.data(for: empty))
    }

    func testAddingAStepStartsSequencing() throws {
        let withStep = song(notes: [60, 64], steps: [Step(type: .fwd)])
        var none = withStep
        none.sections[0].parts[0].steps = []
        XCTAssertGreaterThan(try SongMIDIExporter.data(for: withStep).count,
                             try SongMIDIExporter.data(for: none).count)
    }
}
