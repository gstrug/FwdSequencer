import XCTest
@testable import FwdSequencerCore

final class FwdSequencerCoreTests: XCTestCase {
    private enum TestError: Error { case corruptMIDI }

    private struct MIDIChannelEvent {
        let tick: Int
        let status: UInt8
        let note: UInt8
        let velocity: UInt8
    }

    /// Records when notes start and stop, for asserting how long they actually sound.
    private final class TimingAudioOutput: SequencerAudioOutput {
        private let lock = NSLock()
        private var started: [UInt8: CFAbsoluteTime] = [:]
        private var _durations: [Double] = []
        var durations: [Double] { lock.lock(); defer { lock.unlock() }; return _durations }

        func playNote(trackID: UUID, midiNote: UInt8, velocity: UInt8) {
            lock.lock(); started[midiNote] = CFAbsoluteTimeGetCurrent(); lock.unlock()
        }
        func stopNote(trackID: UUID, midiNote: UInt8) {
            lock.lock()
            if let start = started.removeValue(forKey: midiNote) {
                _durations.append(CFAbsoluteTimeGetCurrent() - start)
            }
            lock.unlock()
        }
        func allNotesOff() {}
    }

    /// Records the OFFSET each event was stamped with, which is what phase 3 changes.
    private final class StampingAudioOutput: SequencerAudioOutput {
        private let lock = NSLock()
        private var _onOffsets: [Double] = []
        private var _flushOffsets: [Double] = []
        var placesScheduledEvents: Bool { true }

        var noteOnOffsets: [Double] { lock.lock(); defer { lock.unlock() }; return _onOffsets }
        var flushOffsets: [Double] { lock.lock(); defer { lock.unlock() }; return _flushOffsets }

        func playNote(trackID: UUID, midiNote: UInt8, velocity: UInt8) {
            lock.lock(); _onOffsets.append(0); lock.unlock()
        }
        func playNote(trackID: UUID, midiNote: UInt8, velocity: UInt8, afterSeconds: Double) {
            lock.lock(); _onOffsets.append(afterSeconds); lock.unlock()
        }
        func stopNote(trackID: UUID, midiNote: UInt8) {}
        func stopNote(trackID: UUID, midiNote: UInt8, afterSeconds: Double) {}
        func allNotesOff() {}
        func allNotesOff(afterSeconds: Double) {
            lock.lock(); _flushOffsets.append(afterSeconds); lock.unlock()
        }

        private var _clockOffsets: [Double] = []
        private var _transport: [UInt8] = []
        var clockOffsets: [Double] { lock.lock(); defer { lock.unlock() }; return _clockOffsets }
        var transport: [UInt8] { lock.lock(); defer { lock.unlock() }; return _transport }
        func sendMIDIClockPulse(afterSeconds: Double) {
            lock.lock(); _clockOffsets.append(afterSeconds); lock.unlock()
        }
        func sendMIDITransport(_ status: UInt8) {
            lock.lock(); _transport.append(status); lock.unlock()
        }
    }

    private final class RecordingAudioOutput: SequencerAudioOutput {
        private let lock = NSLock()
        private var _playedNotes = 0
        private var _stoppedNotes = 0
        var onFirstNote: (() -> Void)?
        var onSecondStop: (() -> Void)?

        var playedNotes: Int {
            lock.lock(); defer { lock.unlock() }
            return _playedNotes
        }

        var stoppedNotes: Int {
            lock.lock(); defer { lock.unlock() }
            return _stoppedNotes
        }

        func playNote(trackID: UUID, midiNote: UInt8, velocity: UInt8) {
            let callback: (() -> Void)?
            lock.lock()
            _playedNotes += 1
            callback = _playedNotes == 1 ? onFirstNote : nil
            lock.unlock()
            callback?()
        }

        func stopNote(trackID: UUID, midiNote: UInt8) {
            let callback: (() -> Void)?
            lock.lock()
            _stoppedNotes += 1
            callback = _stoppedNotes == 2 ? onSecondStop : nil
            lock.unlock()
            callback?()
        }
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
                        result.append(MIDIChannelEvent(
                            tick: tick, status: status, note: bytes[offset],
                            velocity: offset + 1 < end ? bytes[offset + 1] : 0
                        ))
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

    func testMidnightCurrentIsACompleteDeterministicShowcase() throws {
        let song = SongTemplate.midnightCurrent.makeSong()
        let validated = try SongValidator.validateAndNormalize(song)
        let steps = song.sections.flatMap { $0.parts }.flatMap { $0.steps }
        let operations = Set(steps.map { $0.type.rawValue })

        XCTAssertEqual(song.name, "Midnight Current — Demo")
        XCTAssertEqual(song.tempo, 104)
        XCTAssertEqual(song.tracks.count, 3)
        XCTAssertEqual(song.sections.map(\.name),
                       ["Nightfall", "Open Water", "Still Point", "Home Lights"])
        XCTAssertEqual(song.sections.reduce(0) { $0 + $1.numberOfBars }, 24)
        XCTAssertEqual(operations, Set(StepType.allCases.map(\.rawValue)))
        XCTAssertTrue(steps.contains { $0.isChord })
        XCTAssertTrue(steps.contains { $0.probability < 1 })
        XCTAssertTrue(steps.contains { $0.ratchets > 1 })
        XCTAssertNotNil(song.performance)
        XCTAssertEqual(validated, song)
        XCTAssertGreaterThan(try SongMIDIExporter.data(for: song).count, 1_000)

        // Creating another copy for the New Song menu must never identify as the
        // preinstalled document or overwrite a user's edited demo.
        XCTAssertNotEqual(song.id, SongTemplate.midnightCurrent.makeSong().id)
    }

    func testMidnightCurrentRoundTripsThroughSongLibrary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FwdSequencer-MidnightCurrent-\(UUID().uuidString)", isDirectory: true)
        SongStorage.directoryOverrideForTesting = root
        defer {
            SongStorage.directoryOverrideForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }

        let song = SongTemplate.midnightCurrent.makeSong()
        try SongStorage.saveResult(song).get()

        let snapshot = try SongStorage.loadLibrary().get()
        XCTAssertEqual(snapshot.songs, [song])
        XCTAssertTrue(snapshot.failedFiles.isEmpty)
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

    func testValidatorRejectsOversizedTrackAndPluginLabels() {
        var song = SongTemplate.bassPulse.makeSong()
        song.tracks[0].name = String(repeating: "T", count: SongValidator.maximumNameLength + 1)
        XCTAssertThrowsError(try SongValidator.validateAndNormalize(song))

        song.tracks[0].name = "Track"
        song.tracks[0].pluginInfo = PluginInfo(
            name: String(repeating: "P", count: SongValidator.maximumPluginLabelLength + 1),
            manufacturerName: "Maker",
            componentType: 1,
            componentSubType: 2,
            componentManufacturer: 3
        )
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

    func testMIDIExportSplitsVeryLongEmptyTrackDeltas() throws {
        let track = SongTrack(name: "Silent")
        let part = Part(trackID: track.id)
        let sections = (0..<18).map {
            SongSection(name: "Long \($0)", numberOfBars: 256, parts: [part])
        }
        let song = Song(
            name: "Long Export",
            tempo: 120,
            timeSignature: TimeSignature(numerator: 32, denominator: 1),
            tracks: [track],
            sections: sections,
            randomSeed: 1
        )

        let events = try channelEvents(in: SongMIDIExporter.data(for: song), track: 1)
        XCTAssertTrue(events.isEmpty)
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

    func testNextStepStopsAnOverlappingRatchet() {
        let output = RecordingAudioOutput()
        let bothNotesStopped = expectation(description: "Initial note and ratchet stopped")
        output.onSecondStop = { bothNotesStopped.fulfill() }

        let trackID = UUID()
        let track = PlayTrack(
            id: trackID,
            tempoDivision: .quarter,
            notePool: [NoteEntry(midiNote: 60)],
            steps: [
                Step(type: .play, gate: 1.8, ratchets: 2),
                Step(type: .pause)
            ],
            isMuted: false,
            isSoloed: false
        )
        let engine = SequencerEngine()
        engine.audioEngine = output
        engine.startSong(
            sections: [SequencerSection(id: UUID(), numberOfBars: 1, tracks: [track])],
            tempo: 240,
            timeSignature: TimeSignature(),
            trackIDs: [trackID],
            loop: true
        )

        wait(for: [bothNotesStopped], timeout: 1)
        XCTAssertEqual(output.playedNotes, 2)
        XCTAssertEqual(output.stoppedNotes, 2)
        engine.stop()
    }

    /// A chord voicing holds ABSOLUTE pool positions. Shrinking the pool underneath it
    /// — which is exactly what dropping out-of-key notes on a key change does while the
    /// sequencer is running — left `.rep` returning positions past the end of the new
    /// pool, and the tick loop trapped indexing it. Survivors must be kept and dropped
    /// positions discarded, with playback continuing.
    func testChordVoicingSurvivesThePoolShrinkingUnderneathIt() {
        let output = RecordingAudioOutput()
        let firstNote = expectation(description: "Chord played")
        output.onFirstNote = { firstNote.fulfill() }

        let trackID = UUID()
        let sectionID = UUID()
        let fullPool = [NoteEntry(midiNote: 60), NoteEntry(midiNote: 62),
                        NoteEntry(midiNote: 64), NoteEntry(midiNote: 67)]
        let steps = [Step(type: .play, chordPositions: [1, 3, 4]), Step(type: .rep)]

        let engine = SequencerEngine()
        engine.audioEngine = output
        engine.startSong(
            sections: [SequencerSection(id: sectionID, numberOfBars: 1, tracks: [
                PlayTrack(id: trackID, tempoDivision: .quarter, notePool: fullPool,
                          steps: steps, isMuted: false, isSoloed: false)
            ])],
            tempo: 240,
            timeSignature: TimeSignature(),
            trackIDs: [trackID],
            loop: true
        )
        wait(for: [firstNote], timeout: 1)

        // Positions 3 and 4 no longer exist. The voicing must not be replayed verbatim.
        let shrunkPool = Array(fullPool.prefix(2))
        engine.updateSong(
            sections: [SequencerSection(id: sectionID, numberOfBars: 1, tracks: [
                PlayTrack(id: trackID, tempoDivision: .quarter, notePool: shrunkPool,
                          steps: steps, isMuted: false, isSoloed: false)
            ])],
            tempo: 240,
            timeSignature: TimeSignature(),
            trackIDs: [trackID],
            loop: true
        )

        let countAtShrink = output.playedNotes
        Thread.sleep(forTimeInterval: 0.75)   // several steps at 240 BPM
        XCTAssertGreaterThan(output.playedNotes, countAtShrink,
                             "Playback should continue against the smaller pool")
        engine.stop()
    }

    /// Hold repeats one section for editing. It has to outrank "don't loop": turning it
    /// on near the end of a non-looping song must keep repeating, not stop playback.
    /// It also must not advance to the next section at the boundary.
    func testHeldSectionRepeatsAndDoesNotEndANonLoopingSong() {
        let output = RecordingAudioOutput()
        let trackID = UUID()
        let first = UUID()
        let second = UUID()

        func section(_ id: UUID, note: Int) -> SequencerSection {
            SequencerSection(id: id, numberOfBars: 1, tracks: [
                PlayTrack(id: trackID, tempoDivision: .quarter,
                          notePool: [NoteEntry(midiNote: note)],
                          steps: [Step(type: .play)], isMuted: false, isSoloed: false)
            ])
        }

        let engine = SequencerEngine()
        engine.audioEngine = output
        let finishedLock = NSLock()
        var finished = false
        var sectionsSeen: [Int] = []
        engine.onSongFinished = { finishedLock.lock(); finished = true; finishedLock.unlock() }
        engine.onSectionChange = { finishedLock.lock(); sectionsSeen.append($0); finishedLock.unlock() }

        // loop: false — without the hold this song would finish after two bars.
        engine.startSong(
            sections: [section(first, note: 60), section(second, note: 67)],
            tempo: 400,
            timeSignature: TimeSignature(),
            trackIDs: [trackID],
            loop: false,
            heldSection: first
        )

        // At 400 BPM a 4/4 bar is 0.6s, so an unheld song would have finished by now.
        Thread.sleep(forTimeInterval: 1.6)
        engine.stop()

        finishedLock.lock()
        let didFinish = finished
        let seen = sectionsSeen
        finishedLock.unlock()

        XCTAssertFalse(didFinish, "A held section must keep repeating, not end the song")
        XCTAssertEqual(Set(seen), [0], "Playback must not leave the held section")
        XCTAssertGreaterThan(output.playedNotes, 2, "The held section should still be playing")
    }

    /// Restore applies a snapshot and CONSUMES it: the entry leaves the list, so a
    /// restore cannot be repeated and the list only ever holds versions not yet used.
    func testRestoringASnapshotAppliesItAndRemovesItFromTheList() throws {
        let track = SongTrack(name: "T")
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60), NoteEntry(midiNote: 64)]
        var section = SongSection(name: "A", parts: [part])

        section.saveSnapshot(named: "Clean")
        let clean = try XCTUnwrap(section.variations.first)
        section.parts[0].notePool = [NoteEntry(midiNote: 72)]
        section.saveSnapshot(named: "Busy")

        XCTAssertTrue(section.restoreSnapshot(clean.id))
        XCTAssertEqual(section.parts[0].notePool.map(\.midiNote), [60, 64])
        XCTAssertFalse(section.variations.contains { $0.id == clean.id },
                       "A restored snapshot is consumed")
        XCTAssertEqual(section.variations.map(\.name), ["Busy"],
                       "Other snapshots are untouched, and no 'Before' entry is bred")
        XCTAssertFalse(section.restoreSnapshot(clean.id), "It cannot be restored twice")
    }

    /// Auditioning must not touch the document — it only changes what is handed to the
    /// sequencer, so abandoning an audition costs nothing.
    func testAuditioningReadsSnapshotPartsWithoutApplyingThem() throws {
        let track = SongTrack(name: "T")
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60)]
        var section = SongSection(name: "A", parts: [part])
        section.saveSnapshot(named: "Alt")
        let alt = try XCTUnwrap(section.variations.first)
        section.parts[0].notePool = [NoteEntry(midiNote: 72)]

        let auditioned = try XCTUnwrap(section.snapshotParts(alt.id))
        XCTAssertEqual(auditioned[0].notePool.map(\.midiNote), [60])
        XCTAssertEqual(section.parts[0].notePool.map(\.midiNote), [72], "Unchanged")
        XCTAssertEqual(section.variations.count, 1, "Unchanged")
    }

    /// The Original is the one guaranteed way back, so the mechanisms that normally
    /// remove snapshots — restore consuming them, the cap evicting the oldest, and
    /// delete — must all leave it alone.
    func testTheOriginalSnapshotSurvivesRestoreEvictionAndDeletion() throws {
        let track = SongTrack(name: "T")
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60)]
        var section = SongSection(name: "A", parts: [part])

        XCTAssertTrue(section.saveOriginalSnapshot())
        XCTAssertFalse(section.saveOriginalSnapshot(), "Only ever captured once")
        let original = try XCTUnwrap(section.variations.first)
        XCTAssertTrue(original.isProtected)

        // Edit, then restore the Original: it applies but is NOT consumed.
        section.parts[0].notePool = [NoteEntry(midiNote: 72)]
        XCTAssertTrue(section.restoreSnapshot(original.id))
        XCTAssertEqual(section.parts[0].notePool.map(\.midiNote), [60])
        XCTAssertTrue(section.variations.contains { $0.id == original.id },
                      "Restoring the Original must not use it up")

        // Delete is refused.
        XCTAssertFalse(section.deleteSnapshot(original.id))
        XCTAssertTrue(section.variations.contains { $0.id == original.id })

        // Fill to the cap: the Original must never be the one evicted.
        while section.variations.count < SongSection.maximumSnapshots {
            section.saveSnapshot(named: "S\(section.variations.count)")
        }
        let dropped = section.saveSnapshot(named: "One more")
        XCTAssertNotEqual(dropped, original.name)
        XCTAssertTrue(section.variations.contains { $0.id == original.id },
                      "The cap must evict an ordinary snapshot, never the Original")
    }

    /// Restore & Keep leaves the entry in place so it can be returned to repeatedly.
    func testRestoreAndKeepLeavesTheSnapshotInTheList() throws {
        let track = SongTrack(name: "T")
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60)]
        var section = SongSection(name: "A", parts: [part])
        section.saveSnapshot(named: "Clean")
        let clean = try XCTUnwrap(section.variations.first)

        section.parts[0].notePool = [NoteEntry(midiNote: 72)]
        XCTAssertTrue(section.restoreSnapshot(clean.id, keeping: true))
        XCTAssertEqual(section.parts[0].notePool.map(\.midiNote), [60])
        XCTAssertTrue(section.variations.contains { $0.id == clean.id })

        // And again, which a consuming restore could not do.
        section.parts[0].notePool = [NoteEntry(midiNote: 80)]
        XCTAssertTrue(section.restoreSnapshot(clean.id, keeping: true))
        XCTAssertEqual(section.parts[0].notePool.map(\.midiNote), [60])
    }

    /// At the cap the oldest snapshot makes way, rather than the save being refused —
    /// a full list must never silently remove the safety net from Transform.
    func testSnapshotCapDropsTheOldestRatherThanRefusingToSave() {
        let track = SongTrack(name: "T")
        var section = SongSection(name: "A", parts: [Part(trackID: track.id)])

        for i in 0..<SongSection.maximumSnapshots {
            section.parts[0].notePool = [NoteEntry(midiNote: 60 + i)]
            XCTAssertNil(section.saveSnapshot(named: "S\(i)"), "Below the cap nothing is dropped")
        }
        XCTAssertEqual(section.variations.count, SongSection.maximumSnapshots)

        let dropped = section.saveSnapshot(named: "One more")
        XCTAssertEqual(dropped, "S0", "The OLDEST snapshot makes way")
        XCTAssertEqual(section.variations.count, SongSection.maximumSnapshots)
        XCTAssertEqual(section.variations.last?.name, "One more")
    }

    /// Names are user-supplied now, so they must be made safe: the validator rejects an
    /// empty or over-long one, and duplicates make the list unreadable.
    func testSnapshotNamesAreTrimmedCappedAndDeduplicated() {
        let track = SongTrack(name: "T")
        var section = SongSection(name: "A", parts: [Part(trackID: track.id)])

        section.saveSnapshot(named: "  Chorus idea  ")
        XCTAssertEqual(section.variations[0].name, "Chorus idea", "Trimmed")

        section.saveSnapshot(named: "Chorus idea")
        XCTAssertEqual(section.variations[1].name, "Chorus idea 2", "Duplicates get a suffix")
        section.saveSnapshot(named: "Chorus idea")
        XCTAssertEqual(section.variations[2].name, "Chorus idea 3")

        section.saveSnapshot(named: "   ")
        XCTAssertFalse(section.variations[3].name.isEmpty, "An empty name is never stored")

        section.saveSnapshot(named: String(repeating: "x", count: 5_000))
        XCTAssertLessThanOrEqual(section.variations[4].name.count, SongValidator.maximumNameLength)

        // Renaming is held to the same rules, but must not collide with itself.
        let id = section.variations[0].id
        section.renameSnapshot(id, to: "Chorus idea")
        XCTAssertEqual(section.variations[0].name, "Chorus idea",
                       "Renaming to its own name must not add a suffix")
        section.renameSnapshot(id, to: "Chorus idea 2")
        XCTAssertEqual(section.variations[0].name, "Chorus idea 2 2", "Collides with another")
    }

    /// The tick grid exists to make triplets — and therefore swing — expressible. It was
    /// 8 per quarter, which divides only by two, so a triplet could not land on a tick.
    func testTheTickGridExpressesBothBinaryAndTripletDivisions() {
        let ticksPerQuarter = TempoDivision.quarter.sequencerTicks
        XCTAssertEqual(ticksPerQuarter, 24)

        // Binary divisions halve cleanly all the way to a 32nd.
        XCTAssertEqual(TempoDivision.eighth.sequencerTicks, 12)
        XCTAssertEqual(TempoDivision.sixteenth.sequencerTicks, 6)
        XCTAssertEqual(TempoDivision.thirtysecond.sequencerTicks, 3)

        // A triplet is three in the time of two, and must land on whole ticks.
        for (triplet, parent) in [(TempoDivision.quarterTriplet, TempoDivision.quarter),
                                  (.eighthTriplet, .eighth),
                                  (.sixteenthTriplet, .sixteenth)] {
            XCTAssertEqual(triplet.sequencerTicks * 3, parent.sequencerTicks * 2,
                           "\(triplet) must be three in the time of two \(parent)")
        }

        // Every division is a whole number of ticks — nothing rounds.
        for division in TempoDivision.allCases {
            XCTAssertGreaterThan(division.sequencerTicks, 0, "\(division)")
        }

        // Swing is now representable: a swung eighth pair is a triplet-eighth held for
        // two units followed by one, i.e. 2:1 within a quarter.
        let swungLong = TempoDivision.eighthTriplet.sequencerTicks * 2
        let swungShort = TempoDivision.eighthTriplet.sequencerTicks
        XCTAssertEqual(swungLong + swungShort, ticksPerQuarter)
        XCTAssertEqual(swungLong, swungShort * 2)

        // Common bars divide evenly by the common divisions, so patterns line up with
        // the bar rather than drifting at the loop point.
        let ticksPerWholeNote = ticksPerQuarter * 4
        for (numerator, denominator) in [(4, 4), (3, 4), (6, 8)] {
            let bar = numerator * ticksPerWholeNote / denominator
            for division in [TempoDivision.quarter, .eighth, .sixteenth, .eighthTriplet] {
                XCTAssertEqual(bar % division.sequencerTicks, 0,
                               "\(numerator)/\(denominator) bar must divide by \(division)")
            }
        }
    }

    /// A note followed by Hold steps must sound across them.
    ///
    /// Sustain used to be applied by extending whatever release was still pending when
    /// the Hold ran — which silently required the note to outlive its own step. At any
    /// gate below 1.0 the release had already fired, so nothing was extended and the
    /// note stayed one step long however many Holds followed: everything came out
    /// staccato. The note is now scheduled to span the Holds up front.
    func testANoteSoundsAcrossTheHoldStepsThatFollowIt() {
        let out = TimingAudioOutput()
        let id = UUID()
        // Quarter = 60, triplet-eighths -> one step is 1/3 s. Play + Hold x2 is a
        // quarter note, so the note must sound for ~gate x 1.0 s, not ~1/3 s.
        let track = PlayTrack(id: id, tempoDivision: .eighthTriplet,
                              notePool: [NoteEntry(midiNote: 60, velocity: 100, gateLength: 0.9)],
                              steps: [Step(type: .play), Step(type: .hold, n: 2)],
                              isMuted: false, isSoloed: false)
        let engine = SequencerEngine()
        engine.audioEngine = out
        engine.startSong(sections: [SequencerSection(id: UUID(), numberOfBars: 1, tracks: [track])],
                         tempo: 60, timeSignature: TimeSignature(numerator: 3, denominator: 4),
                         trackIDs: [id], loop: true)
        Thread.sleep(forTimeInterval: 2.2)
        engine.stop()

        let durations = out.durations
        XCTAssertFalse(durations.isEmpty, "no notes were played")
        let first = durations[0]
        // Bounded rather than pinned to a target: this is a wall-clock measurement, and
        // asyncAfter has no upper bound on a loaded machine, so an exact expectation is
        // not something CI can honour. The two behaviours are 0.33s apart from 0.9s, so
        // a generous window still tells them apart.
        XCTAssertGreaterThan(first, 0.6,
                             "regression: the note lasted only its own step (~0.33s)")
        XCTAssertLessThan(first, 2.0,
                          "the note should stop within the bar, not ring on indefinitely")
    }

    /// Feel must be DERIVED, never random: probability already relies on a seeded
    /// generator so a song reproduces exactly, and export is asserted byte-identical.
    func testFeelIsDeterministicAcrossRepeatedExports() throws {
        var song = Song()
        var track = SongTrack(name: "Piano")
        track.chordSpread = 12
        track.accent = 16
        song.tracks = [track]
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60), NoteEntry(midiNote: 64), NoteEntry(midiNote: 67)]
        part.steps = [Step(type: .play, chordPositions: [1, 2, 3]), Step(type: .play, n: 1)]
        song.sections = [SongSection(name: "A", numberOfBars: 1, parts: [part])]

        let first = try SongMIDIExporter.data(for: song)
        let second = try SongMIDIExporter.data(for: song)
        XCTAssertEqual(first, second, "feel must not introduce run-to-run variation")
    }

    /// Accent is metric stress, not noise — and it SUBTRACTS: the downbeat keeps the
    /// written velocity, other beats give up half, and what falls between gives up all
    /// of it. Adding to the downbeat instead left no headroom on parts written near 100.
    func testAccentFollowsTheBarRatherThanBeingRandom() throws {
        var song = Song()
        var track = SongTrack(name: "T")
        track.accent = 16
        song.tracks = [track]
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60, velocity: 80)]
        part.steps = [Step(type: .play, n: 1)]
        part.tempoDivision = .eighth      // two triggers a beat: on it, then between
        song.sections = [SongSection(name: "A", numberOfBars: 1, parts: [part])]

        let velocities = try channelEvents(in: SongMIDIExporter.data(for: song), track: 1)
            .filter { $0.status & 0xF0 == 0x90 }
            .map { Int($0.velocity) }

        XCTAssertGreaterThanOrEqual(velocities.count, 4)
        XCTAssertEqual(velocities[0], 80, "the downbeat keeps the written velocity")
        XCTAssertEqual(velocities[1], 80 - 16, "between beats gives up the full amount")
        XCTAssertEqual(velocities[2], 80 - 8, "beat two gives up half")
        XCTAssertEqual(velocities[3], 80 - 16)
        XCTAssertLessThanOrEqual(velocities.max() ?? 0, 80, "nothing exceeds what was written")
    }

    /// A chord is rolled from the lowest note up rather than struck as a block, and each
    /// note keeps its length instead of being clipped by the delay.
    func testChordSpreadRollsUpwardFromTheLowestNote() throws {
        var song = Song()
        var track = SongTrack(name: "T")
        track.chordSpread = 12
        song.tracks = [track]
        var part = Part(trackID: track.id)
        // Deliberately out of pitch order: the roll must follow PITCH, not pool order.
        part.notePool = [NoteEntry(midiNote: 67), NoteEntry(midiNote: 60), NoteEntry(midiNote: 64)]
        part.steps = [Step(type: .play, chordPositions: [1, 2, 3])]
        song.sections = [SongSection(name: "A", numberOfBars: 1, parts: [part])]

        let ons = try channelEvents(in: SongMIDIExporter.data(for: song), track: 1)
            .filter { $0.status & 0xF0 == 0x90 }
            .prefix(3)
        let byNote = Dictionary(uniqueKeysWithValues: ons.map { (Int($0.note), $0.tick) })

        XCTAssertEqual(byNote.count, 3)
        let low = try XCTUnwrap(byNote[60]), mid = try XCTUnwrap(byNote[64]), high = try XCTUnwrap(byNote[67])
        XCTAssertLessThan(low, mid, "the lowest note leads the roll")
        XCTAssertLessThan(mid, high, "and the highest arrives last")

        // Without spread they would all land together.
        song.tracks[0].chordSpread = 0
        let blockTicks = Set(try channelEvents(in: SongMIDIExporter.data(for: song), track: 1)
            .filter { $0.status & 0xF0 == 0x90 }.prefix(3).map(\.tick))
        XCTAssertEqual(blockTicks.count, 1, "off means a block chord")
    }

    /// Variation must be a function of POSITION, not a stream: playback and the exporter
    /// walk the song in different orders, so a stream would hand them different numbers
    /// and the exported file would stop matching what was heard.
    func testVariationIsAddressedByPositionNotDrawnFromAStream() {
        let a = FeelNoise.unitValue(seed: 99, section: 1, trigger: 4, midiNote: 60, salt: 0x11)
        let b = FeelNoise.unitValue(seed: 99, section: 1, trigger: 4, midiNote: 60, salt: 0x11)
        XCTAssertEqual(a, b, "the same note must always get the same value")

        // Every input must actually change the result, or notes would move together.
        XCTAssertNotEqual(a, FeelNoise.unitValue(seed: 98, section: 1, trigger: 4, midiNote: 60, salt: 0x11))
        XCTAssertNotEqual(a, FeelNoise.unitValue(seed: 99, section: 2, trigger: 4, midiNote: 60, salt: 0x11))
        XCTAssertNotEqual(a, FeelNoise.unitValue(seed: 99, section: 1, trigger: 5, midiNote: 60, salt: 0x11))
        XCTAssertNotEqual(a, FeelNoise.unitValue(seed: 99, section: 1, trigger: 4, midiNote: 61, salt: 0x11))
        // Velocity and gate must not move in lockstep at the same position.
        XCTAssertNotEqual(a, FeelNoise.unitValue(seed: 99, section: 1, trigger: 4, midiNote: 60, salt: 0x22))

        for trigger in 0..<200 {
            let v = FeelNoise.unitValue(seed: 7, section: 0, trigger: trigger, midiNote: 64, salt: 0x11)
            XCTAssertGreaterThanOrEqual(v, 0)
            XCTAssertLessThan(v, 1)
        }
    }

    /// Variation changes what is played, and repeated exports still match byte for byte.
    func testVariationAltersVelocitiesWithoutBreakingReproducibility() throws {
        var song = Song()
        var track = SongTrack(name: "T")
        song.tracks = [track]
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60, velocity: 80)]
        part.steps = [Step(type: .play, n: 1)]
        part.tempoDivision = .sixteenth
        song.sections = [SongSection(name: "A", numberOfBars: 2, parts: [part])]
        song.randomSeed = 12_345

        func velocities(_ s: Song) throws -> [Int] {
            try channelEvents(in: SongMIDIExporter.data(for: s), track: 1)
                .filter { $0.status & 0xF0 == 0x90 }.map { Int($0.velocity) }
        }

        let flat = try velocities(song)
        XCTAssertEqual(Set(flat).count, 1, "with variation off every note is identical")

        track.variation = 32
        song.tracks = [track]
        let varied = try velocities(song)
        XCTAssertGreaterThan(Set(varied).count, 3, "variation must actually vary velocity")
        XCTAssertEqual(varied, try velocities(song), "and still be reproducible")
    }

    /// Songs saved before feel existed must still decode — SongTrack has the synthesised
    /// decoder, which throws on a missing key even where a default exists.
    func testSongsWithoutFeelStillDecodeAndAreUnaffected() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","tempo":120,
         "timeSignature":{"numerator":4,"denominator":4},"masterVolume":1,
         "tracks":[{"id":"\(UUID().uuidString)","name":"T",
                    "mixer":{"volume":0.8,"pan":0,"isMuted":false,"isSoloed":false}}],
         "sections":[]}
        """
        let song = try JSONDecoder().decode(Song.self, from: Data(json.utf8))
        XCTAssertNil(song.tracks[0].chordSpread)
        XCTAssertNil(song.tracks[0].accent)
        XCTAssertEqual(song.tracks[0].effectiveChordSpread, 0, "off by default")
        XCTAssertEqual(song.tracks[0].effectiveAccent, 0)
    }

    // MARK: - Look-ahead scheduler, phase 1: the musical timeline

    /// The timeline is musical, so a tick means the same thing whatever the tempo, and
    /// real time is derived from it rather than the other way round (TIMING.md §6).
    func testTimelineConvertsBetweenTicksAndSeconds() {
        let line = MusicalTimeline(ticksPerBeat: 24, tempo: 120)
        XCTAssertEqual(line.secondsPerBeat, 0.5, accuracy: 1e-12)
        XCTAssertEqual(line.secondsPerTick, 0.5 / 24, accuracy: 1e-12)

        XCTAssertEqual(line.seconds(atTick: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(line.seconds(atTick: 24), 0.5, accuracy: 1e-12, "a beat later")
        XCTAssertEqual(line.seconds(atTick: 96), 2.0, accuracy: 1e-12, "a 4/4 bar later")

        // Round trip: the tick containing a moment is the one that began at or before it.
        for tick in Int64(0)...200 {
            XCTAssertEqual(line.tick(atSeconds: line.seconds(atTick: tick) + 1e-9), tick)
        }
    }

    /// Ticks before the origin are earlier, not clamped. Today an event can only be
    /// pushed later; a signed timeline is what lets the horizon nudge one EARLIER.
    func testTimelineIsSignedSoEventsCanBePulledEarlier() {
        let line = MusicalTimeline(ticksPerBeat: 24, tempo: 60, originTick: 100, originSeconds: 10)
        XCTAssertEqual(line.seconds(atTick: 100), 10, accuracy: 1e-12)
        XCTAssertLessThan(line.seconds(atTick: 76), 10, "a beat before the origin")
        XCTAssertEqual(line.offset(ofTick: 76, from: 10), -1.0, accuracy: 1e-12)
        XCTAssertEqual(line.offset(ofTick: 124, from: 10), 1.0, accuracy: 1e-12)
    }

    /// A tempo change must not retime what has already been played. Assigning tempo
    /// directly would reinterpret every past tick and shift the whole timeline under the
    /// sequencer; rebasing pins the present and stretches only the future.
    func testTempoChangeRebasesInsteadOfRetimingThePast() {
        let slow = MusicalTimeline(ticksPerBeat: 24, tempo: 60)
        let changeAt: Int64 = 48                       // two beats in, at 2.0 s
        XCTAssertEqual(slow.seconds(atTick: changeAt), 2.0, accuracy: 1e-12)

        let fast = slow.rebased(toTempo: 120, atTick: changeAt)
        XCTAssertEqual(fast.seconds(atTick: changeAt), 2.0, accuracy: 1e-12,
                       "the moment of the change must not move")
        XCTAssertEqual(fast.seconds(atTick: changeAt + 24), 2.5, accuracy: 1e-12,
                       "the next beat arrives at the new tempo")
        XCTAssertEqual(fast.tempo, 120)
    }

    /// Tempo is clamped to the range the tick loop will actually run at, so the timeline
    /// cannot describe playback the sequencer would refuse.
    func testTimelineClampsTempoToThePlayableRange() {
        XCTAssertEqual(MusicalTimeline(ticksPerBeat: 24, tempo: 5).tempo, 20)
        XCTAssertEqual(MusicalTimeline(ticksPerBeat: 24, tempo: 10_000).tempo, 400)
        XCTAssertGreaterThan(MusicalTimeline(ticksPerBeat: 0, tempo: 120).secondsPerTick, 0,
                             "a zero resolution must not divide by zero")
    }

    /// The window a horizon-based scheduler — or an AUv3 render block — asks for.
    func testTimelineReportsTheTicksDueInAWindow() throws {
        let line = MusicalTimeline(ticksPerBeat: 24, tempo: 120)   // 1/48 s per tick
        let window = try XCTUnwrap(line.ticks(from: 0, horizon: 0.5))
        XCTAssertEqual(window.lowerBound, 0)
        XCTAssertEqual(window.upperBound, 24, "half a second is a beat at 120")

        // Consecutive windows must not drop or repeat a tick.
        let first = try XCTUnwrap(line.ticks(from: 0, horizon: 0.1))
        let second = try XCTUnwrap(line.ticks(from: 0.1, horizon: 0.1))
        XCTAssertEqual(second.lowerBound, first.upperBound + 1)

        XCTAssertNil(line.ticks(from: 0, horizon: 0), "an empty window has no ticks")
    }

    // MARK: - Phase 2: the stamped output boundary

    /// An output that has not opted in must SAY it cannot place events, rather than
    /// quietly firing them at the wrong time and leaving the caller none the wiser.
    func testUnstampedOutputsDeclareThemselvesAndFallBackToImmediate() {
        let out = RecordingAudioOutput()
        XCTAssertFalse(out.placesScheduledEvents,
                       "the default must be honest about not scheduling")

        out.playNote(trackID: UUID(), midiNote: 60, velocity: 100, afterSeconds: 5)
        XCTAssertEqual(out.playedNotes, 1, "the fallback fires immediately, not in 5s")
    }

    // MARK: - Phase 3: the look-ahead horizon

    private func makeStampingEngine(lead: Double) -> (SequencerEngine, StampingAudioOutput, UUID) {
        let out = StampingAudioOutput()
        let id = UUID()
        let engine = SequencerEngine()
        engine.audioEngine = out
        engine.scheduleLead = lead
        let track = PlayTrack(id: id, tempoDivision: .quarter,
                              notePool: [NoteEntry(midiNote: 60)],
                              steps: [Step(type: .play)], isMuted: false, isSoloed: false)
        engine.startSong(sections: [SequencerSection(id: UUID(), numberOfBars: 1, tracks: [track])],
                         tempo: 240, timeSignature: TimeSignature(), trackIDs: [id], loop: true)
        return (engine, out, id)
    }

    /// Notes are STAMPED for their tick's moment rather than fired whenever the handler
    /// runs, so dispatch jitter stops being audible. The offset should sit near the lead.
    func testNotesAreStampedAheadRatherThanFiredOnArrival() {
        let (engine, out, _) = makeStampingEngine(lead: 0.020)
        Thread.sleep(forTimeInterval: 0.9)
        engine.stop()

        let offsets = out.noteOnOffsets
        XCTAssertFalse(offsets.isEmpty, "nothing played")
        XCTAssertTrue(offsets.allSatisfy { $0 >= 0 }, "an event can never be stamped into the past")
        XCTAssertTrue(offsets.allSatisfy { $0 <= 0.030 }, "never stamped beyond the lead")
        // Only that stamping HAPPENS, not how often. A late timer firing legitimately
        // consumes the lead and stamps 0, and on a loaded runner several in a row can —
        // asserting a majority made this flaky over a handful of samples. That every
        // offset is 0 when the lead is 0 is the other half of the proof, and is
        // deterministic; see testZeroLeadRestoresImmediateDelivery.
        XCTAssertTrue(offsets.contains { $0 > 0.005 },
                      "notes should be placed ahead of their tick, not fired on arrival")
    }

    /// Lead 0 must reproduce the old behaviour exactly — every event "now". This is the
    /// escape hatch if a fragile plugin dislikes being given future timestamps.
    func testZeroLeadRestoresImmediateDelivery() {
        let (engine, out, _) = makeStampingEngine(lead: 0)
        Thread.sleep(forTimeInterval: 0.6)
        engine.stop()

        let offsets = out.noteOnOffsets
        XCTAssertFalse(offsets.isEmpty)
        XCTAssertTrue(offsets.allSatisfy { $0 == 0 }, "lead 0 means every event is immediate")
        XCTAssertTrue(out.flushOffsets.isEmpty, "and there is nothing in flight to flush")
    }

    /// STARTING must not schedule a delayed sweep. The notes that start with playback
    /// are stamped a lead ahead and the sweep would land a lead plus a margin ahead —
    /// i.e. just after them — cutting them a few milliseconds in. On device that
    /// silenced tracks from the moment play was pressed.
    func testStartingPlaybackSchedulesNoDelayedFlush() {
        let (engine, out, _) = makeStampingEngine(lead: 0.020)
        Thread.sleep(forTimeInterval: 0.4)

        XCTAssertTrue(out.flushOffsets.isEmpty,
                      "a delayed all-notes-off scheduled at startup would cut the notes "
                      + "playback has just scheduled")
        XCTAssertFalse(out.noteOnOffsets.isEmpty, "and notes should be sounding")
        engine.stop()
    }

    /// Rewinding keeps playing, so it begins rather than ends: the same delayed sweep
    /// would cut the notes the new position is about to play.
    func testRewindingWhilePlayingSchedulesNoDelayedFlush() {
        let (engine, out, _) = makeStampingEngine(lead: 0.020)
        Thread.sleep(forTimeInterval: 0.3)
        engine.rewind()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertTrue(out.flushOffsets.isEmpty, "rewind must not sweep behind itself")
        engine.stop()
    }

    /// Stopping must flush PAST the horizon as well as immediately. Cancelling work
    /// items cannot recall an event already stamped into a plugin, so an immediate
    /// all-notes-off alone would land before it and leave the note hanging.
    func testStoppingFlushesPastTheHorizonSoNothingCanHang() {
        let (engine, out, _) = makeStampingEngine(lead: 0.020)
        Thread.sleep(forTimeInterval: 0.5)
        engine.stop()
        Thread.sleep(forTimeInterval: 0.1)

        let flushes = out.flushOffsets
        XCTAssertFalse(flushes.isEmpty, "a stop must sweep past the look-ahead window")
        XCTAssertTrue(flushes.allSatisfy { $0 > 0.020 },
                      "the sweep must land after anything already stamped, not with it")
    }

    // MARK: - Phase 4: one timeline for notes and clock

    /// Clock used to run on its OWN timer, started separately from playback, so notes
    /// and clock began at different instants and drifted apart. Riding the same ticks
    /// and the same stamps makes drift impossible rather than merely small.
    func testClockRidesTheSameTicksAndStampsAsTheNotes() {
        let (engine, out, _) = makeStampingEngine(lead: 0.020)
        Thread.sleep(forTimeInterval: 1.0)
        engine.stop()

        let clock = out.clockOffsets
        let notes = out.noteOnOffsets
        XCTAssertFalse(clock.isEmpty, "no clock was emitted")

        // 24 PPQN at 240 BPM is 96 pulses a second; a quarter-note track gives 4 notes.
        XCTAssertGreaterThan(clock.count, notes.count * 10,
                             "a pulse per tick, not per note")
        XCTAssertTrue(clock.allSatisfy { $0 >= 0 && $0 <= 0.030 },
                      "pulses are stamped on the same basis as notes, never fired blind")
    }

    /// Transport is driven by the sequencer's own transport, so slaves start, continue
    /// and stop with us rather than with a separate timer that could disagree.
    func testTransportBytesFollowTheSequencersOwnTransport() {
        let (engine, out, _) = makeStampingEngine(lead: 0.020)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(out.transport.first, 0xFA, "starting playback sends Start")

        let paused = expectation(description: "paused")
        engine.pause { paused.fulfill() }
        wait(for: [paused], timeout: 1)
        XCTAssertEqual(out.transport.last, 0xFC, "pausing sends Stop")

        engine.resume(tempo: 240)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(out.transport.last, 0xFB, "resuming sends Continue, not Start")

        engine.stop()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(out.transport.last, 0xFC, "stopping sends Stop")
    }

    // MARK: - Phase 5: swing and timing

    /// Swing delays the OFFBEAT eighth only, by a sixth of a beat at full — moving it
    /// from halfway through the beat to two thirds of the way, which is a triplet feel.
    func testSwingDelaysOnlyTheOffbeatAndByTheRightAmount() throws {
        func onTicks(swing: Double) throws -> [Int] {
            var song = Song()
            var track = SongTrack(name: "T")
            track.swing = swing
            song.tracks = [track]
            var part = Part(trackID: track.id)
            part.notePool = [NoteEntry(midiNote: 60)]
            part.steps = [Step(type: .play, n: 1)]
            part.tempoDivision = .eighth      // on the beat, then between
            song.sections = [SongSection(name: "A", numberOfBars: 1, parts: [part])]
            return try channelEvents(in: SongMIDIExporter.data(for: song), track: 1)
                .filter { $0.status & 0xF0 == 0x90 }.map(\.tick)
        }

        let straight = try onTicks(swing: 0)
        let swung = try onTicks(swing: 100)
        XCTAssertGreaterThanOrEqual(straight.count, 4)

        // Downbeats do not move; offbeats do.
        XCTAssertEqual(swung[0], straight[0], "the beat itself stays put")
        XCTAssertEqual(swung[2], straight[2], "and so does the next beat")

        // A quarter is 480 ticks, so a sixth of a beat is 80.
        XCTAssertEqual(swung[1] - straight[1], 80, "full swing is a sixth of a beat late")
        XCTAssertEqual(swung[3] - straight[3], 80)

        // Half the swing, half the shift.
        let half = try onTicks(swing: 50)
        XCTAssertEqual(half[1] - straight[1], 40)
    }

    /// Timing jitter pushes AND pulls. Being able to pull is the whole reason the
    /// look-ahead scheduler exists — notes used to be sent the instant their tick fired,
    /// so they could only ever be late.
    func testTimingJitterMovesNotesBothEarlyAndLate() throws {
        var song = Song()
        var track = SongTrack(name: "T")
        song.tracks = [track]
        var part = Part(trackID: track.id)
        part.notePool = [NoteEntry(midiNote: 60)]
        part.steps = [Step(type: .play, n: 1)]
        part.tempoDivision = .sixteenth
        song.sections = [SongSection(name: "A", numberOfBars: 4, parts: [part])]
        song.randomSeed = 2_468

        func onTicks(_ s: Song) throws -> [Int] {
            try channelEvents(in: SongMIDIExporter.data(for: s), track: 1)
                .filter { $0.status & 0xF0 == 0x90 }.map(\.tick)
        }

        let exact = try onTicks(song)
        track.timingJitter = 15
        song.tracks = [track]
        let loose = try onTicks(song)

        XCTAssertEqual(exact.count, loose.count, "jitter must not add or drop notes")
        let deltas = zip(loose, exact).map(-)
        XCTAssertTrue(deltas.contains { $0 > 0 }, "some notes must be late")
        XCTAssertTrue(deltas.contains { $0 < 0 }, "and some EARLY — the point of phase 5")
        XCTAssertEqual(loose, try onTicks(song), "still reproducible")

        // 15 ms at 120 BPM is 0.03 of a quarter, so ~14 ticks at 480 PPQ.
        XCTAssertTrue(deltas.allSatisfy { abs($0) <= 16 }, "kept within the stated amount")
    }

    /// Swing is a groove, jitter is looseness: the first must be identical every bar,
    /// the second must not be.
    func testSwingIsSystematicWhileJitterIsNot() throws {
        func deltas(swing: Double, jitter: Double) throws -> [Int] {
            var song = Song()
            var track = SongTrack(name: "T")
            track.swing = swing
            track.timingJitter = jitter
            song.tracks = [track]
            var part = Part(trackID: track.id)
            part.notePool = [NoteEntry(midiNote: 60)]
            part.steps = [Step(type: .play, n: 1)]
            part.tempoDivision = .eighth
            song.sections = [SongSection(name: "A", numberOfBars: 4, parts: [part])]
            song.randomSeed = 99
            let ticks = try channelEvents(in: SongMIDIExporter.data(for: song), track: 1)
                .filter { $0.status & 0xF0 == 0x90 }.map(\.tick)
            // Offset of each note from its exact grid position.
            return ticks.enumerated().map { $0.element - $0.offset * 240 }
        }

        let swung = try deltas(swing: 100, jitter: 0)
        let offbeats = stride(from: 1, to: swung.count, by: 2).map { swung[$0] }
        XCTAssertEqual(Set(offbeats).count, 1, "every offbeat is swung identically")

        let loose = try deltas(swing: 0, jitter: 15)
        XCTAssertGreaterThan(Set(loose).count, 3, "jitter differs note to note")
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

    func testSavingOverCorruptPrimaryPreservesLastKnownGoodBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FWD-StorageTests-\(UUID().uuidString)", isDirectory: true)
        SongStorage.directoryOverrideForTesting = root
        defer {
            SongStorage.directoryOverrideForTesting = nil
            try? FileManager.default.removeItem(at: root)
        }

        var song = SongTemplate.bassPulse.makeSong()
        song.name = "First"
        guard case .success = SongStorage.saveResult(song) else { return XCTFail("Initial save failed") }
        song.name = "Last Known Good"
        guard case .success = SongStorage.saveResult(song) else { return XCTFail("Backup save failed") }

        try Data("corrupt-primary".utf8).write(to: SongStorage.url(for: song.id), options: .atomic)
        song.name = "Replacement"
        guard case .success = SongStorage.saveResult(song) else { return XCTFail("Replacement save failed") }

        try Data("corrupt-again".utf8).write(to: SongStorage.url(for: song.id), options: .atomic)
        let snapshot = try SongStorage.loadLibrary().get()
        let failure = try XCTUnwrap(snapshot.failedFiles.first)
        let restored = try SongStorage.restoreBackup(failure).get()
        XCTAssertEqual(restored.name, "First")
    }
}
