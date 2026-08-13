import XCTest
@testable import FwdSequencerCore

final class FwdSequencerCoreTests: XCTestCase {
    func testRandomSequenceRepeatsForSameSeed() {
        var first = SeededRandomGenerator(seed: 42)
        var second = SeededRandomGenerator(seed: 42)

        let firstRun = (0..<32).map { _ in first.nextIndex(upperBound: 7) }
        let secondRun = (0..<32).map { _ in second.nextIndex(upperBound: 7) }

        XCTAssertEqual(firstRun, secondRun)
        XCTAssertTrue(firstRun.allSatisfy { 0..<7 ~= $0 })
    }

    func testPluginEqualityUsesAudioComponentIdentity() {
        let original = PluginInfo(
            id: UUID(), name: "Synth", manufacturerName: "Maker",
            componentType: 1, componentSubType: 2, componentManufacturer: 3
        )
        let rescanned = PluginInfo(
            id: UUID(), name: "Synth Renamed", manufacturerName: "Maker",
            componentType: 1, componentSubType: 2, componentManufacturer: 3
        )

        XCTAssertEqual(original, rescanned)
        XCTAssertEqual(original.componentIdentifier, rescanned.componentIdentifier)
    }

    func testLegacySkipStepMigratesToHold() throws {
        let data = Data(#"{"type":"Skip","n":2}"#.utf8)
        let step = try JSONDecoder().decode(Step.self, from: data)

        XCTAssertEqual(step.type, .hold)
        XCTAssertEqual(step.n, 2)
        XCTAssertEqual(step.gate, 1)
        XCTAssertEqual(step.probability, 1)
        XCTAssertEqual(step.ratchets, 1)
    }

    func testBuild16SongWithoutRandomSeedStillDecodes() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","name":"Legacy","tempo":120,
         "timeSignature":{"numerator":4,"denominator":4},
         "masterVolume":1,"tracks":[],"sections":[]}
        """.utf8)

        let song = try JSONDecoder().decode(Song.self, from: data)

        XCTAssertNil(song.randomSeed)
        XCTAssertEqual(song.name, "Legacy")
    }

    func testTemplatesHaveValidTrackPartReferences() {
        for template in SongTemplate.allCases {
            let song = template.makeSong()
            let trackIDs = Set(song.tracks.map(\.id))

            XCTAssertFalse(song.sections.isEmpty, template.name)
            XCTAssertNotNil(song.randomSeed, template.name)
            for section in song.sections {
                XCTAssertEqual(Set(section.parts.map(\.trackID)), trackIDs, template.name)
                XCTAssertGreaterThan(section.numberOfBars, 0, template.name)
            }
        }
    }

    func testValidatorRejectsZeroTimeSignatureDenominator() {
        var song = SongTemplate.ambientCanon.makeSong()
        song.timeSignature.denominator = 0

        XCTAssertThrowsError(try SongValidator.validateAndNormalize(song)) { error in
            XCTAssertTrue(error.localizedDescription.contains("denominator"))
        }
    }

    func testValidatorRejectsOutOfRangeMIDI() {
        var song = SongTemplate.ambientCanon.makeSong()
        song.sections[0].parts[0].notePool[0].midiNote = 256

        XCTAssertThrowsError(try SongValidator.validateAndNormalize(song)) { error in
            XCTAssertTrue(error.localizedDescription.contains("MIDI"))
        }
    }

    func testValidatorRejectsDuplicateTrackIdentity() {
        var song = SongTemplate.ambientCanon.makeSong()
        song.tracks.append(song.tracks[0])

        XCTAssertThrowsError(try SongValidator.validateAndNormalize(song)) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate track"))
        }
    }

    func testValidatorRepairsMissingLegacyPartAndMetadata() throws {
        var song = SongTemplate.ambientCanon.makeSong()
        let missingTrackID = song.tracks[0].id
        song.formatVersion = nil
        song.randomSeed = nil
        song.sections[0].parts.removeAll { $0.trackID == missingTrackID }

        let validated = try SongValidator.validateAndNormalize(song)

        XCTAssertEqual(validated.formatVersion, SongValidator.currentFormatVersion)
        XCTAssertNotNil(validated.randomSeed)
        XCTAssertNotNil(validated.sections[0].parts.first { $0.trackID == missingTrackID })
    }

    func testValidatorRejectsFutureFormat() {
        var song = SongTemplate.ambientCanon.makeSong()
        song.formatVersion = SongValidator.currentFormatVersion + 1

        XCTAssertThrowsError(try SongValidator.validateAndNormalize(song)) { error in
            XCTAssertEqual(error as? SongValidationError,
                           .unsupportedVersion(SongValidator.currentFormatVersion + 1))
        }
    }

    func testUnknownStepOperationDoesNotSilentlyBecomeForward() {
        let data = Data(#"{"type":"FutureOperation","n":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Step.self, from: data))
    }

    func testStalePluginLoadCannotFinishNewRequest() {
        var tracker = PluginLoadTracker()
        let trackID = UUID()
        let old = tracker.begin(for: trackID)
        let current = tracker.begin(for: trackID)

        XCTAssertFalse(tracker.finish(for: trackID, token: old))
        XCTAssertFalse(tracker.isEmpty)
        XCTAssertTrue(tracker.finish(for: trackID, token: current))
        XCTAssertTrue(tracker.isEmpty)
    }

    func testCancellingPluginLoadClearsTracker() {
        var tracker = PluginLoadTracker()
        let trackID = UUID()
        _ = tracker.begin(for: trackID)

        tracker.cancel(for: trackID)

        XCTAssertTrue(tracker.isEmpty)
    }

    func testProbabilitySequenceRepeatsForSameSeed() {
        var first = SeededRandomGenerator(seed: 7)
        var second = SeededRandomGenerator(seed: 7)
        let firstRun = (0..<32).map { _ in first.nextUnitInterval() < 0.4 }
        let secondRun = (0..<32).map { _ in second.nextUnitInterval() < 0.4 }

        XCTAssertEqual(firstRun, secondRun)
        XCTAssertTrue(firstRun.contains(true))
        XCTAssertTrue(firstRun.contains(false))
    }

    func testValidatorRejectsUnsafeStepPerformanceValues() {
        var song = SongTemplate.bassPulse.makeSong()
        song.sections[0].parts[0].steps[0].ratchets = 9
        XCTAssertThrowsError(try SongValidator.validateAndNormalize(song))

        song.sections[0].parts[0].steps[0].ratchets = 1
        song.sections[0].parts[0].steps[0].probability = -0.1
        XCTAssertThrowsError(try SongValidator.validateAndNormalize(song))
    }

    func testSectionVariationsRoundTrip() throws {
        var song = SongTemplate.ambientCanon.makeSong()
        song.sections[0].variations = [
            SectionVariation(name: "Sparse", parts: song.sections[0].parts)
        ]

        let data = try JSONEncoder().encode(song)
        let decoded = try SongValidator.decodeAndValidate(data)

        XCTAssertEqual(decoded.sections[0].variations.first?.name, "Sparse")
        XCTAssertEqual(decoded.sections[0].variations.first?.parts, song.sections[0].parts)
    }

    func testMIDIExportIsDeterministicAndWellFormed() throws {
        let song = SongTemplate.ambientCanon.makeSong()
        let first = try SongMIDIExporter.data(for: song)
        let second = try SongMIDIExporter.data(for: song)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.prefix(4)), [0x4D, 0x54, 0x68, 0x64])
        XCTAssertEqual(first[8], 0)
        XCTAssertEqual(first[9], 1)
        XCTAssertEqual(first[10], 0)
        XCTAssertEqual(first[11], UInt8(song.tracks.count + 1))
        XCTAssertTrue(first.count > 100)
    }
}
