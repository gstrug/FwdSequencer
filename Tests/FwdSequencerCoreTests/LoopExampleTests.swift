import XCTest
@testable import FwdSequencerCore

/// The MIDI loops the app carries (FwdSequencer/Resources/Loop-*.mid, written by
/// Tools/make_midi_loops.py) and the example song made from them.
///
/// "Malecón" is not written out by hand or by a script: it is what the app's own
/// importer gives for the six Malecon loops, one file to a section, exactly as Section
/// menu ▸ Import MIDI… would at a step size of 1/16. `buildSong` does that here, and
/// the test holds the song in the app to it — so if the loops or the importer change,
/// the example has to be made again:
///
///     FWD_WRITE_EXAMPLES=1 swift test --filter LoopExampleTests
final class LoopExampleTests: XCTestCase {

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("FwdSequencer/Resources")

    /// Fixed ids, so making the song again changes nothing that has not changed.
    private static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "4D414C45-434F-4E00-8000-%012X", number)) ?? UUID()
    }

    /// The song's tracks: which part of each file they take (the name the file gives
    /// the track), their built-in sound, and where they sit in the mix.
    private static let tracks: [(name: String, part: String, sound: Int, volume: Float, pan: Float)] = [
        ("Timbales & Bell", "Drums", GeneralMIDI.drumKit, 0.78, 0.15),
        ("Congas", "Congas", GeneralMIDI.drumKit, 0.8, -0.2),
        ("Bass", "Bass", 32, 0.85, 0),
        ("Piano", "Piano", 0, 0.72, -0.1),
        ("Brass", "Brass", 61, 0.62, 0.2),
    ]

    /// The sections, in the order they sit on the chips, each from one loop.
    private static let sections: [(name: String, file: String, bars: Int)] = [
        ("Intro", "Loop-Malecon 1 Intro", 4),
        ("Verse", "Loop-Malecon 2 Verse", 4),
        ("Fill", "Loop-Malecon 5 Fill", 1),
        ("Chorus", "Loop-Malecon 3 Chorus", 4),
        ("Breakdown", "Loop-Malecon 4 Breakdown", 4),
        ("Ending", "Loop-Malecon 6 Ending", 2),
    ]

    /// How the sections are put together into the song.
    private static let order = ["Intro", "Verse", "Verse", "Fill", "Chorus", "Chorus",
                                "Breakdown", "Fill", "Chorus", "Ending"]

    /// The file's own name for a track: the importer puts the General MIDI instrument
    /// in front of it ("Acoustic Bass · Bass").
    private static func trackName(of part: ImportedPart) -> String {
        part.name.components(separatedBy: " · ").last ?? part.name
    }

    static func buildSong() throws -> Song {
        var nextID = 1_000
        func fresh() -> UUID { nextID += 1; return id(nextID) }

        var song = Song()
        song.id = id(1)
        song.name = "Malecón"
        song.tempo = 100
        song.loops = false
        song.randomSeed = 0x4D41_4C45
        song.tracks = tracks.enumerated().map { index, track in
            var made = SongTrack(name: track.name)
            made.id = id(10 + index)
            made.builtInSound = track.sound
            made.mixer.volume = track.volume
            made.mixer.pan = track.pan
            return made
        }

        for (index, section) in sections.enumerated() {
            let url = resources.appendingPathComponent(section.file + ".mid")
            let file = try MIDIFileReader.read(Data(contentsOf: url))
            let plan = MIDIImportPlan(file: file, parts: file.parts, timeSignature: song.timeSignature,
                                      division: .sixteenth, startAtFirstNote: false,
                                      fitLength: false, currentBars: section.bars)
            var parts: [Part] = []
            for (trackIndex, track) in tracks.enumerated() {
                let trackID = song.tracks[trackIndex].id
                guard let imported = file.parts.first(where: { trackName(of: $0) == track.part }) else {
                    // Not in this loop: the track rests for the section.
                    parts.append(Part(trackID: trackID))
                    continue
                }
                var result = try plan.convert(imported)
                guard result.notesLeftOut == 0 else {
                    throw MIDIImportError.tooLong("\(section.file) does not fit \(section.bars) bars.")
                }
                for i in result.notePool.indices { result.notePool[i].id = fresh() }
                for i in result.steps.indices { result.steps[i].id = fresh() }
                parts.append(Part(trackID: trackID, notePool: result.notePool, steps: result.steps,
                                  tempoDivision: .sixteenth, key: 0, scale: .chromatic))
            }
            song.sections.append(SongSection(id: id(100 + index), name: section.name,
                                             numberOfBars: section.bars, parts: parts))
        }

        song.arrangement = order.enumerated().compactMap { index, name in
            song.sections.first { $0.name == name }.map {
                ArrangementSlot(id: id(200 + index), sectionID: $0.id)
            }
        }
        song.playsArrangement = true
        return try SongValidator.validateAndNormalize(song)
    }

    func testTheExampleIsWhatImportingItsLoopsGives() throws {
        let built = try Self.buildSong()
        let url = Self.resources.appendingPathComponent("Example-Malecon.json")
        if ProcessInfo.processInfo.environment["FWD_WRITE_EXAMPLES"] != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(built).write(to: url)
            return
        }
        let inTheApp = try SongStorage.decodeDocument(Data(contentsOf: url))
        XCTAssertEqual(inTheApp, built, "Example-Malecon.json no longer matches its loops; make it again")
    }

    func testTheExampleUsesEveryPartOfItsLoops() throws {
        let song = try Self.buildSong()
        XCTAssertEqual(song.sections.map(\.numberOfBars), [4, 4, 1, 4, 4, 2])
        XCTAssertEqual(song.arrangement?.count, Self.order.count)
        XCTAssertTrue(song.arrangementIsActive)
        // Every part of every loop went to a track: none was left without one.
        for section in Self.sections {
            let file = try MIDIFileReader.read(
                Data(contentsOf: Self.resources.appendingPathComponent(section.file + ".mid")))
            let known = Set(Self.tracks.map(\.part))
            XCTAssertTrue(file.parts.allSatisfy { known.contains(Self.trackName(of: $0)) }, section.file)
        }
        // The velocities came through as played: ghosted conga strokes beside slaps.
        let congas = try XCTUnwrap(song.sections[1].parts.first { $0.trackID == song.tracks[1].id })
        let strokes = congas.notePool.filter { $0.midiNote == 62 }.map(\.velocity)
        XCTAssertLessThan(try XCTUnwrap(strokes.min()), 40)
        XCTAssertGreaterThan(try XCTUnwrap(strokes.max()), 100)
    }

    /// Every loop the app carries reads as MIDI, sits exactly on sixteenths (so Import
    /// suggests 1/16 and moves nothing), and fills whole bars.
    func testEveryLoopImportsCleanly() throws {
        let loops = try FileManager.default.contentsOfDirectory(at: Self.resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mid" && $0.lastPathComponent.hasPrefix("Loop-") }
        XCTAssertEqual(loops.count, 10)
        for url in loops {
            let name = url.lastPathComponent
            let file = try MIDIFileReader.read(Data(contentsOf: url))
            XCTAssertEqual(file.usableTempo ?? 0, 100, accuracy: 0.01, name)
            XCTAssertEqual(file.usableTimeSignature, TimeSignature(numerator: 4, denominator: 4), name)
            let notes = file.parts.flatMap(\.notes)
            XCTAssertEqual(MIDIImportConverter.suggestedDivision(for: notes, ticksPerQuarter: file.ticksPerQuarter),
                           .sixteenth, name)
            let grid = file.ticksPerQuarter / 4
            XCTAssertTrue(notes.allSatisfy { $0.start % grid == 0 && $0.end % grid == 0 }, name)
            let plan = MIDIImportPlan(file: file, parts: file.parts, timeSignature: TimeSignature(),
                                      division: .sixteenth, startAtFirstNote: true,
                                      fitLength: true, currentBars: 4)
            for part in file.parts {
                XCTAssertEqual(try plan.convert(part).notesLeftOut, 0, name)
            }
        }
    }
}
