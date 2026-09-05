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
