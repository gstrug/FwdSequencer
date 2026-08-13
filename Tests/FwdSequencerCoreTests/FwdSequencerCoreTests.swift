import XCTest
@testable import FwdSequencerCore

final class FwdSequencerCoreTests: XCTestCase {
    private enum TestError: Error { case corruptMIDI }

    private struct MIDIChannelEvent {
        let tick: Int
        let status: UInt8
        let note: UInt8
    }

    private final class RecordingAudioOutput: SequencerAudioOutput {
        private let lock = NSLock()
        private var _playedNotes = 0
        var onFirstNote: (() -> Void)?

        var playedNotes: Int {
            lock.lock(); defer { lock.unlock() }
            return _playedNotes
        }

        func playNote(trackID: UUID, midiNote: UInt8, velocity: UInt8) {
            let callback: (() -> Void)?
            lock.lock()
            _playedNotes += 1
            callback = _playedNotes == 1 ? onFirstNote : nil
            lock.unlock()
            callback?()
        }

        func stopNote(trackID: UUID, midiNote: UInt8) {}
        func allNotesOff() {}
    }

    private func channelEvents(in data: Data, track targetTrack: Int) throws -> [MIDIChannelEvent] {
        let bytes = [UInt8](data)
        func uint32(at offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        func variableLength(_ offset: inout Int, limit: Int) throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard offset < limit else { throw TestError.corruptMIDI }
                let byte = bytes[offset]
                offset += 1
                value = (value << 7) | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw TestError.corruptMIDI
        }

        var chunkOffset = 14
        for trackIndex in 0...targetTrack {
            guard chunkOffset + 8 <= bytes.count,
                  Array(bytes[chunkOffset..<(chunkOffset + 4)]) == [0x4D, 0x54, 0x72, 0x6B]
            else { throw TestError.corruptMIDI }
            let length = uint32(at: chunkOffset + 4)
            let start = chunkOffset + 8
            let end = start + length
            guard end <= bytes.count else { throw TestError.corruptMIDI }
            if trackIndex != targetTrack {
                chunkOffset = end
                continue
            }

            var offset = start
            var tick = 0
            var result: [MIDIChannelEvent] = []
            while offset < end {
                tick += try variableLength(&offset, limit: end)
                guard offset < end else { throw TestError.corruptMIDI }
                let status = bytes[offset]
                offset += 1
                if status == 0xFF {
                    guard offset < end else { throw TestError.corruptMIDI }
                    offset += 1 // meta-event type
                    let payloadLength = try variableLength(&offset, limit: end)
                    guard offset + payloadLength <= end else { throw TestError.corruptMIDI }
                    offset += payloadLength
                } else {
                    let dataLength = ((status & 0xE0) == 0xC0) ? 1 : 2
                    guard offset + dataLength <= end else { throw TestError.corruptMIDI }
                    if (status & 0xF0) == 0x80 || (status & 0xF0) == 0x90 {
                        result.append(MIDIChannelEvent(tick: tick, status: status, note: bytes[offset]))
                    }
                    offset += dataLength
                }
            }
            return result
        }
        throw TestError.corruptMIDI
    }

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

    func testMIDIExportCarriesHoldAcrossASectionBoundary() throws {
        let track = SongTrack(name: "Held")
        let heldNote = NoteEntry(midiNote: 60, velocity: 100, gateLength: 8)
        let firstPart = Part(
            trackID: track.id,
            notePool: [heldNote],
            steps: [Step(type: .play), Step(type: .hold, n: 4)],
            tempoDivision: .quarter
        )
        let secondPart = Part(
            trackID: track.id,
            notePool: [heldNote],
            steps: [Step(type: .pause)],
            tempoDivision: .quarter
        )
        let song = Song(
            name: "Held Export",
            tracks: [track],
            sections: [
                SongSection(name: "One", numberOfBars: 1, parts: [firstPart]),
                SongSection(name: "Two", numberOfBars: 1, parts: [secondPart])
            ],
            randomSeed: 1
        )

        let events = try channelEvents(in: SongMIDIExporter.data(for: song), track: 1)
        let noteOns = events.filter { ($0.status & 0xF0) == 0x90 && $0.note == 60 }
        let noteOffs = events.filter { ($0.status & 0xF0) == 0x80 && $0.note == 60 }

        XCTAssertEqual(noteOns.map(\.tick), [0])
        // Four beats in section one, then the carried Hold consumes beat one of
        // section two; its Pause releases the note on beat two.
        XCTAssertEqual(noteOffs.map(\.tick), [2_400])
    }

    func testPauseCancelsAlreadyScheduledRatchets() {
        let output = RecordingAudioOutput()
        let firstNote = expectation(description: "Initial note played")
        output.onFirstNote = { firstNote.fulfill() }

        let trackID = UUID()
        let track = PlayTrack(
            id: trackID,
            tempoDivision: .quarter,
            notePool: [NoteEntry(midiNote: 60)],
            steps: [Step(type: .play, ratchets: 8)],
            isMuted: false,
            isSoloed: false
        )
        let engine = SequencerEngine()
        engine.audioEngine = output
        engine.startSong(
            sections: [SequencerSection(id: UUID(), numberOfBars: 1, tracks: [track])],
            tempo: 20,
            timeSignature: TimeSignature(),
            trackIDs: [trackID],
            loop: true
        )

        wait(for: [firstNote], timeout: 1)
        let paused = expectation(description: "Pause queue barrier completed")
        engine.pause { paused.fulfill() }
        wait(for: [paused], timeout: 1)
        let countAtPause = output.playedNotes

        // At 20 BPM the first delayed ratchet is due 0.375 seconds after the
        // initial note. It must not fire once the pause barrier has completed.
        Thread.sleep(forTimeInterval: 0.45)
        XCTAssertEqual(output.playedNotes, countAtPause)
        engine.stop()
    }

    func testStorageSurfacesCorruptionAndRestoresLastKnownGoodBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FWD-StorageTests-\(UUID().uuidString)", isDirectory: true)
        SongStorage.directoryOverrideForTesting = root
        defer {
            SongStorage.directoryOverrideForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }

        var original = SongTemplate.bassPulse.makeSong()
        original.name = "Known Good"
        guard case .success = SongStorage.saveResult(original) else {
            return XCTFail("Initial save failed")
        }
        original.name = "Newer Good"
        guard case .success = SongStorage.saveResult(original) else {
            return XCTFail("Second save failed")
        }

        try Data("not-json".utf8).write(to: SongStorage.url(for: original.id), options: .atomic)
        let snapshot = try SongStorage.loadLibrary().get()
        let failure = try XCTUnwrap(snapshot.failedFiles.first)
        XCTAssertTrue(failure.canRestoreBackup)
        XCTAssertTrue(snapshot.songs.isEmpty)

        let restored = try SongStorage.restoreBackup(failure).get()
        XCTAssertEqual(restored.name, "Known Good")
        let reloaded = try SongStorage.loadLibrary().get()
        XCTAssertEqual(reloaded.songs.map(\.name), ["Known Good"])
        XCTAssertTrue(reloaded.failedFiles.isEmpty)

        let unreadableURL = root.appendingPathComponent("\(UUID().uuidString).fwdsong")
        try Data("still-not-json".utf8).write(to: unreadableURL, options: .atomic)
        let withUnreadable = try SongStorage.loadLibrary().get()
        let unreadable = try XCTUnwrap(withUnreadable.failedFiles.first)
        XCTAssertFalse(unreadable.canRestoreBackup)
        guard case .success = SongStorage.quarantine(unreadable) else {
            return XCTFail("Quarantine failed")
        }
        let afterQuarantine = try SongStorage.loadLibrary().get()
        XCTAssertTrue(afterQuarantine.failedFiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadableURL.path))
        let quarantine = root.appendingPathComponent("Quarantine", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: quarantine.path).count, 2)
    }
}
