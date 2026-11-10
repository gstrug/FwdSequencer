import XCTest
@testable import FwdSequencerCore

/// Section menu ▸ Export MIDI…: one section as a file of its own.
final class SectionExportTests: XCTestCase {

    /// A section's file is exactly the file of a song holding only that section, so the
    /// section export can never place a note differently from the song export.
    func testASectionExportsAsASongOfThatSectionAlone() throws {
        for song in TestSongs.all where song.sections.count > 1 {
            for section in song.sections {
                var alone = song
                alone.sections = [section]
                alone.arrangement = nil
                alone.songParts = nil
                alone.playsArrangement = nil
                for feel in [true, false] {
                    XCTAssertEqual(
                        try SongMIDIExporter.data(for: song, section: section.id, includingFeel: feel),
                        try SongMIDIExporter.data(for: alone, includingFeel: feel),
                        "\(song.name) ▸ \(section.name)")
                }
            }
        }
    }

    /// The arrangement does not reach into a section's own file: placed three times in
    /// the song's order, a section still exports once.
    func testTheArrangementIsSetAside() throws {
        var song = try XCTUnwrap(TestSongs.all.first { $0.sections.count > 1 })
        let section = song.sections[0]
        let plain = try SongMIDIExporter.data(for: song, section: section.id)
        song.arrangement = Array(repeating: ArrangementSlot(sectionID: section.id), count: 3)
            .map { ArrangementSlot(sectionID: $0.sectionID) }
        song.playsArrangement = true
        XCTAssertEqual(try SongMIDIExporter.data(for: song, section: section.id), plain)
        XCTAssertLessThan(plain.count, try SongMIDIExporter.data(for: song).count)
    }

    func testASectionThatHasGoneIsRefused() {
        let song = TestSongs.all[0]
        XCTAssertThrowsError(try SongMIDIExporter.data(for: song, section: UUID())) { error in
            XCTAssertEqual(error as? SongMIDIExporter.ExportError, .sectionMissing)
        }
    }

    /// What is exported comes back in: the file reads as MIDI with a part to import.
    func testASectionsFileImports() throws {
        let song = try XCTUnwrap(TestSongs.all.first { $0.sections.count > 1 })
        let data = try SongMIDIExporter.data(for: song, section: song.sections[0].id, includingFeel: false)
        let file = try MIDIFileReader.read(data)
        XCTAssertFalse(file.parts.isEmpty)
        XCTAssertEqual(file.usableTempo ?? 0, song.tempo, accuracy: 0.01)
    }
}
