import XCTest
@testable import FwdSequencerCore

/// The templates and example songs the app carries (FwdSequencer/Resources, written by
/// Tools/make_examples.py), read from the source tree since the test bundle has no
/// access to the app's resources.
final class BundledSongTests: XCTestCase {

    private func bundled() throws -> [String: Song] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FwdSequencer/Resources")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .filter { $0.lastPathComponent.hasPrefix("Example-") || $0.lastPathComponent.hasPrefix("Template-") }
        var songs: [String: Song] = [:]
        for file in files {
            songs[file.deletingPathExtension().lastPathComponent] = try SongStorage.decodeDocument(Data(contentsOf: file))
        }
        return songs
    }

    func testEveryTemplateAndExampleIsInTheApp() throws {
        let names = Set(try bundled().keys)
        XCTAssertEqual(names, Set(ExampleSong.allCases.map(\.resource) + ["Template-InstrumentHost", "Template-Sequencer"]))
    }

    /// Loads, needs no correcting, has a part for every track in every section, gives
    /// steps to every part with notes, and exports.
    func testEveryBundledSongIsWellFormed() throws {
        for (name, song) in try bundled() {
            XCTAssertEqual(try SongValidator.validateAndNormalize(song), song, "\(name) was changed by validation")
            let trackIDs = song.tracks.map(\.id)
            let barTicks = song.timeSignature.numerator * 96 / song.timeSignature.denominator
            for section in song.sections {
                XCTAssertEqual(section.parts.map(\.trackID), trackIDs, "\(name) ▸ \(section.name)")
                for part in section.parts where !part.notePool.isEmpty {
                    let track = song.tracks.first { $0.id == part.trackID }?.name ?? "?"
                    XCTAssertFalse(part.steps.isEmpty, "\(name) ▸ \(section.name) ▸ \(track) has notes but no steps")
                    // Written-out parts (only Play, Hold and Rest) fill whole repeats of
                    // the section, so they never stop part-way through a phrase.
                    if part.steps.allSatisfy({ [.play, .hold, .pause].contains($0.type) }) {
                        let length = part.steps.reduce(0) { $0 + ($1.type == .play ? 1 : max(1, $1.n)) }
                        let section = section.numberOfBars * barTicks / part.tempoDivision.sequencerTicks
                        XCTAssertEqual(section % length, 0, "\(name) ▸ \(track): \(length) steps in a section of \(section)")
                    }
                }
            }
            XCTAssertGreaterThan(try SongMIDIExporter.data(for: song).count, 100, name)
        }
    }

    func testEachExampleOpensTheWayItIsMeantToBePlayed() throws {
        let songs = try bundled()
        let pads = try XCTUnwrap(songs["Example-NightMarket"])
        XCTAssertEqual(pads.opensInTriggerMode, true)
        XCTAssertEqual(pads.loops, true)
        XCTAssertEqual(pads.sections.count, 8)

        let blues = try XCTUnwrap(songs["Example-BluesInA"])
        XCTAssertEqual(blues.showsPlayKeyboard, true)
        XCTAssertEqual(blues.performance?.builtInSound, 29)
        XCTAssertTrue(blues.arrangementIsActive)
        XCTAssertEqual(blues.sections.map(\.numberOfBars), [4, 12, 12, 4])

        XCTAssertEqual(songs["Example-HappyBirthdayJazz"]?.timeSignature, TimeSignature(numerator: 3, denominator: 4))

        let ballad = try XCTUnwrap(songs["Example-Lighthouse"])
        XCTAssertTrue(ballad.arrangementIsActive)
        XCTAssertEqual(ballad.songParts?.count, 3)

        let funk = try XCTUnwrap(songs["Example-SundayStrut"])
        XCTAssertTrue(funk.tracks.contains { $0.effectiveSwing > 0 })
        XCTAssertTrue(funk.tracks.contains { $0.effectiveChordSpread > 0 })

        let host = try XCTUnwrap(songs["Template-InstrumentHost"])
        XCTAssertEqual(host.showsPlayKeyboard, true)
        XCTAssertTrue(host.sections.flatMap(\.parts).allSatisfy { $0.steps.isEmpty && $0.notePool.isEmpty })
        XCTAssertEqual(host.tracks.compactMap(\.builtInSound), [4, 48, 33])
    }
}
