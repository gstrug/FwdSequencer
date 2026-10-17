import XCTest
@testable import FwdSequencerCore

/// The portable half of MIDI Learn: decoding, matching, scaling, pickup, templates.
final class MIDIControlTests: XCTestCase {

    // MARK: Decoding

    func testDecodesControlChangeOnChannelOne() {
        let m = MIDIControlMessage(status: 0xB0, data1: 7, data2: 100)
        XCTAssertEqual(m, MIDIControlMessage(kind: .controlChange, channel: 1, number: 7, value: 100))
    }

    func testDecodesNotesAndTreatsVelocityZeroAsRelease() {
        let on = MIDIControlMessage(status: 0x99, data1: 36, data2: 90)!
        XCTAssertEqual(on.kind, .note)
        XCTAssertEqual(on.channel, 10)
        XCTAssertTrue(on.isPress)

        XCTAssertFalse(MIDIControlMessage(status: 0x99, data1: 36, data2: 0)!.isPress)
        let off = MIDIControlMessage(status: 0x89, data1: 36, data2: 64)!
        XCTAssertEqual(off.value, 0, "a note off is a release whatever its velocity byte")
        XCTAssertFalse(off.isPress)
    }

    func testIgnoresMessagesThatCannotBeLinked() {
        XCTAssertNil(MIDIControlMessage(status: 0xE0, data1: 0, data2: 64))  // pitch bend
        XCTAssertNil(MIDIControlMessage(status: 0xC0, data1: 5, data2: 0))   // program change
        XCTAssertNil(MIDIControlMessage(status: 0xF8, data1: 0, data2: 0))   // clock
    }

    func testButtonPressThreshold() {
        XCTAssertTrue(MIDIControlMessage(kind: .controlChange, channel: 1, number: 41, value: 127).isPress)
        XCTAssertTrue(MIDIControlMessage(kind: .controlChange, channel: 1, number: 41, value: 64).isPress)
        XCTAssertFalse(MIDIControlMessage(kind: .controlChange, channel: 1, number: 41, value: 63).isPress)
    }

    // MARK: Sources

    func testSourceMatchesKindChannelAndNumber() {
        let source = MIDIControlSource(kind: .controlChange, channel: 1, number: 7)
        XCTAssertTrue(source.matches(.init(kind: .controlChange, channel: 1, number: 7, value: 3)))
        XCTAssertFalse(source.matches(.init(kind: .controlChange, channel: 2, number: 7, value: 3)))
        XCTAssertFalse(source.matches(.init(kind: .controlChange, channel: 1, number: 8, value: 3)))
        XCTAssertFalse(source.matches(.init(kind: .note, channel: 1, number: 7, value: 3)))
    }

    func testSourceDisplayNames() {
        XCTAssertEqual(MIDIControlSource(kind: .controlChange, channel: 1, number: 7).displayName, "CC 7 · Ch 1")
        XCTAssertEqual(MIDIControlSource(kind: .note, channel: 10, number: 60).displayName, "Note C4 · Ch 10")
    }

    // MARK: Templates and Learn

    func testLearnReplacesBothTheOldSourceAndTheOldTarget() {
        var t = MIDIControllerTemplate(name: "Test")
        let cc7 = MIDIControlSource(kind: .controlChange, channel: 1, number: 7)
        let cc8 = MIDIControlSource(kind: .controlChange, channel: 1, number: 8)

        t.learn(cc7, for: .masterVolume)
        t.learn(cc8, for: .masterVolume)      // same control, new knob
        XCTAssertEqual(t.mappings.count, 1)
        XCTAssertEqual(t.mapping(for: .masterVolume)?.source, cc8)

        t.learn(cc8, for: .tempo)              // same knob, new control
        XCTAssertEqual(t.mappings.count, 1)
        XCTAssertNil(t.mapping(for: .masterVolume))
        XCTAssertEqual(t.mapping(for: .tempo)?.source, cc8)

        t.forget(.tempo)
        XCTAssertTrue(t.mappings.isEmpty)
    }

    func testTemplateRoundTripsAndOldSavesStillLoad() throws {
        var t = MIDIControllerTemplate(name: "Mine", deviceNameHint: "X-Station")
        t.learn(MIDIControlSource(kind: .note, channel: 2, number: 40), for: .section(3))
        t.learn(MIDIControlSource(kind: .controlChange, channel: 1, number: 10), for: .trackPan(5))
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(MIDIControllerTemplate.self, from: data), t)

        // A template saved before `pickup`, `isBuiltIn` and `deviceNameHint` existed.
        let old = """
        {"name":"Old","mappings":[{"source":{"kind":"controlChange","channel":1,"number":1},
          "target":{"tempo":{}}}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MIDIControllerTemplate.self, from: old)
        XCTAssertEqual(decoded.name, "Old")
        XCTAssertEqual(decoded.mappings.first?.target, .tempo)
        XCTAssertEqual(decoded.mappings.first?.pickup, false)
        XCTAssertFalse(decoded.isBuiltIn)
    }

    func testDeviceNameHintIsCaseInsensitiveAndNeedsAHint() {
        let t = MIDIControllerTemplate(name: "n", deviceNameHint: "nanoKONTROL2")
        XCTAssertTrue(t.suits(deviceNamed: "NANOKONTROL2 SLIDER/KNOB"))
        XCTAssertFalse(t.suits(deviceNamed: "X-Station"))
        XCTAssertFalse(MIDIControllerTemplate(name: "none").suits(deviceNamed: "anything"))
    }

    // MARK: Built-in nanoKONTROL2

    func testNanoKONTROL2FactoryLayout() {
        let t = MIDIBuiltInTemplates.nanoKONTROL2
        XCTAssertTrue(t.isBuiltIn)
        XCTAssertEqual(t.mappings.count, 8 * 5 + 8)
        XCTAssertEqual(Set(t.mappings.map(\.id)).count, t.mappings.count, "ids must be unique")
        XCTAssertEqual(Set(t.mappings.map(\.source)).count, t.mappings.count, "one link per message")

        func target(cc: Int) -> MIDIControlTarget? {
            t.mappings(matching: .init(kind: .controlChange, channel: 1, number: cc, value: 0)).first?.target
        }
        XCTAssertEqual(target(cc: 0), .trackVolume(0))
        XCTAssertEqual(target(cc: 7), .trackVolume(7))
        XCTAssertEqual(target(cc: 16), .trackPan(0))
        XCTAssertEqual(target(cc: 39), .trackSolo(7))
        XCTAssertEqual(target(cc: 48), .trackMute(0))
        XCTAssertEqual(target(cc: 71), .trackEffects(7))
        XCTAssertEqual(target(cc: 41), .playPause)
        XCTAssertEqual(target(cc: 42), .stop)
        XCTAssertEqual(target(cc: 59), .nextSection)
        XCTAssertTrue(t.suits(deviceNamed: "nanoKONTROL2"))
    }

    // MARK: Scaling

    func testVolumeScalingMatchesTheFaders() {
        XCTAssertEqual(MIDIControlScaling.gain(forFraction: 0), 0, "bottom of the fader is silence")
        let top = MIDIControlScaling.gain(forFraction: 1)
        XCTAssertEqual(Double(top), pow(10, 6.0 / 20), accuracy: 1e-4, "top is +6 dB")
        // Unity gain (0 dB) is 60/66 of the way up, and round-trips.
        let unity = MIDIControlScaling.fraction(forGain: 1)
        XCTAssertEqual(unity, 60.0 / 66.0, accuracy: 1e-9)
        XCTAssertEqual(Double(MIDIControlScaling.gain(forFraction: unity)), 1, accuracy: 1e-5)
        XCTAssertEqual(MIDIControlScaling.fraction(forGain: 0), 0)
    }

    func testPanAndTempoScaling() {
        XCTAssertEqual(MIDIControlScaling.pan(forFraction: 0), -1)
        XCTAssertEqual(MIDIControlScaling.pan(forFraction: 1), 1)
        XCTAssertEqual(MIDIControlScaling.fraction(forPan: 0), 0.5)
        XCTAssertEqual(MIDIControlScaling.tempo(forFraction: 0), 40)
        XCTAssertEqual(MIDIControlScaling.tempo(forFraction: 1), 240)
        XCTAssertEqual(MIDIControlScaling.tempo(forFraction: 2), 240, "clamped")
        XCTAssertEqual(MIDIControlScaling.fraction(forTempo: 140), 0.5, accuracy: 1e-9)
    }

    // MARK: Pickup

    func testWithoutPickupEveryPositionApplies() {
        var pickup = MIDIPickup()
        let m = MIDIControlMapping(source: .init(kind: .controlChange, channel: 1, number: 1),
                                   target: .masterVolume, pickup: false)
        XCTAssertTrue(pickup.shouldApply(m, incoming: 0.0, current: 0.9))
    }

    func testPickupWaitsUntilTheKnobCrossesTheValueThenFollows() {
        var pickup = MIDIPickup()
        let m = MIDIControlMapping(source: .init(kind: .controlChange, channel: 1, number: 1),
                                   target: .masterVolume, pickup: true)
        // App at 0.5; the knob starts low and is turned up.
        XCTAssertFalse(pickup.shouldApply(m, incoming: 0.10, current: 0.5))
        XCTAssertFalse(pickup.shouldApply(m, incoming: 0.30, current: 0.5))
        XCTAssertTrue(pickup.shouldApply(m, incoming: 0.55, current: 0.5), "crossed the value")
        // Caught: follows from here, the app's value now being what the knob set.
        XCTAssertTrue(pickup.shouldApply(m, incoming: 0.60, current: 0.55))
        XCTAssertTrue(pickup.shouldApply(m, incoming: 0.40, current: 0.60))
    }

    func testPickupLetsGoWhenTheValueIsChangedElsewhere() {
        var pickup = MIDIPickup()
        let m = MIDIControlMapping(source: .init(kind: .controlChange, channel: 1, number: 1),
                                   target: .masterVolume, pickup: true)
        XCTAssertTrue(pickup.shouldApply(m, incoming: 0.5, current: 0.5))
        // The fader on screen was dragged to 0.9; the knob, still at 0.5, must not jump it.
        XCTAssertFalse(pickup.shouldApply(m, incoming: 0.52, current: 0.9))
    }

    // MARK: Keys

    private func note(_ n: Int, _ velocity: Int, channel: Int = 1) -> MIDIControlMessage {
        MIDIControlMessage(kind: .note, channel: channel, number: n, value: velocity)
    }

    private func routing(_ device: String, plays id: UUID) -> MIDIKeyRouting {
        var r = MIDIKeyRouting()
        _ = r.reconfigure { $0.instruments = [device: id]; $0.paused = false }
        return r
    }

    func testKeysPlayTheirInstrumentAndReleaseIt() {
        let synth = UUID()
        var r = routing("Keys", plays: synth)
        let on = r.route(device: "Keys", note(60, 90))
        XCTAssertEqual(on.actions, [.play(synth, note: 60, velocity: 90)])
        XCTAssertFalse(on.passOn, "nothing for the main thread to do")
        XCTAssertEqual(r.route(device: "Keys", note(60, 0)).actions, [.stop(synth, note: 60)])
        XCTAssertEqual(r.heldCount, 0)
    }

    func testOtherDevicesAndControlChangesAreLeftAlone() {
        var r = routing("Keys", plays: UUID())
        XCTAssertEqual(r.route(device: "nanoKONTROL2", note(60, 90)), .init(passOn: true))
        XCTAssertEqual(r.route(device: "Keys", .init(kind: .controlChange, channel: 1, number: 7, value: 3)),
                       .init(passOn: true))
    }

    func testLinkedNotesBelongToTheirLink() {
        let synth = UUID()
        var r = routing("Keys", plays: synth)
        _ = r.reconfigure { $0.linkedNotes = ["Keys": [MIDIControlSource(kind: .note, channel: 1, number: 36)]] }
        XCTAssertEqual(r.route(device: "Keys", note(36, 100)), .init(passOn: true))
        XCTAssertEqual(r.route(device: "Keys", note(37, 100)).actions, [.play(synth, note: 37, velocity: 100)])
    }

    func testNothingPlaysWhilePausedLearningOrDisabled() {
        var r = routing("Keys", plays: UUID())
        _ = r.reconfigure { $0.paused = true }
        XCTAssertTrue(r.route(device: "Keys", note(60, 90)).actions.isEmpty)
        _ = r.reconfigure { $0.paused = false; $0.learning = true }
        XCTAssertEqual(r.route(device: "Keys", note(60, 90)), .init(passOn: true), "Learn gets it")
        _ = r.reconfigure { $0.learning = false; $0.disabledDevices = ["Keys"] }
        XCTAssertTrue(r.route(device: "Keys", note(60, 90)).actions.isEmpty)
    }

    func testArmedTrackTakesEveryDevicesKeysAndPassesThemOnToBeWritten() {
        let own = UUID(), armed = UUID()
        var r = routing("Keys", plays: own)
        _ = r.reconfigure { $0.writingNotes = true; $0.armedInstrument = armed }
        let on = r.route(device: "Keys", note(64, 80))
        XCTAssertEqual(on.actions, [.play(armed, note: 64, velocity: 80)], "plays the armed track, not Keys play's")
        XCTAssertTrue(on.passOn, "and goes on to be written")
        // A device whose keys play nothing (Keys play Off) still plays and writes it.
        XCTAssertEqual(r.route(device: "Other", note(65, 70)).actions, [.play(armed, note: 65, velocity: 70)])
    }

    func testAnArmedTrackThatCannotBeHeardIsStillWritten() {
        var r = routing("Keys", plays: UUID())
        _ = r.reconfigure { $0.writingNotes = true; $0.armedInstrument = nil }   // muted
        XCTAssertEqual(r.route(device: "Keys", note(64, 80)), .init(passOn: true))
    }

    func testArmingReleasesHeldNotesAndLinkedKeysStayWithTheirLink() {
        let own = UUID(), armed = UUID()
        var r = routing("Keys", plays: own)
        _ = r.route(device: "Keys", note(60, 90))
        XCTAssertEqual(r.reconfigure { $0.writingNotes = true; $0.armedInstrument = armed },
                       [.stop(own, note: 60)])
        _ = r.reconfigure { $0.linkedNotes = ["Keys": [MIDIControlSource(kind: .note, channel: 1, number: 36)]] }
        XCTAssertEqual(r.route(device: "Keys", note(36, 100)), .init(passOn: true), "a pad, not a note")
    }

    func testReleaseGoesWhereThePressWentAndRoutingChangesReleaseHeldNotes() {
        let first = UUID(), second = UUID()
        var r = routing("Keys", plays: first)
        _ = r.route(device: "Keys", note(60, 90))
        _ = r.route(device: "Keys", note(62, 90))
        // Switching the keys to another track releases what was sounding on the first…
        let released = r.reconfigure { $0.instruments = ["Keys": second] }
        XCTAssertEqual(Set(released.map { "\($0)" }),
                       Set([MIDIKeyRouting.Action.stop(first, note: 60), .stop(first, note: 62)].map { "\($0)" }))
        // …so a later release has nothing left to stop and does not reach the new one.
        XCTAssertTrue(r.route(device: "Keys", note(60, 0)).actions.isEmpty)
        // A setting that doesn't move the keys leaves held notes alone.
        _ = r.route(device: "Keys", note(65, 90))
        XCTAssertTrue(r.reconfigure { $0.learning = false }.isEmpty)
        XCTAssertEqual(r.route(device: "Keys", note(65, 0)).actions, [.stop(second, note: 65)])
    }

    func testRepeatedNoteOnEndsTheFirstSoNothingHangs() {
        let synth = UUID()
        var r = routing("Keys", plays: synth)
        _ = r.route(device: "Keys", note(60, 90))
        XCTAssertEqual(r.route(device: "Keys", note(60, 70)).actions,
                       [.stop(synth, note: 60), .play(synth, note: 60, velocity: 70)])
        XCTAssertEqual(r.heldCount, 1)
    }

    func testKeysDestinationRoundTrips() throws {
        let all: [MIDIKeysDestination] = [.off, .playKeyboard, .track(4)]
        let data = try JSONEncoder().encode(["a": all[0], "b": all[1], "c": all[2]])
        let back = try JSONDecoder().decode([String: MIDIKeysDestination].self, from: data)
        XCTAssertEqual(back, ["a": .off, "b": .playKeyboard, "c": .track(4)])
        XCTAssertEqual(MIDIKeysDestination.track(4).displayName, "Track 5")
    }

    // MARK: Play keyboard as a channel

    private func songWithTwoTracksAndPlay() -> Song {
        var song = Song()
        song.tracks = [SongTrack(name: "A"), SongTrack(name: "B")]
        song.performance = SongTrack(name: "Play Keyboard")
        return song
    }

    func testEverythingAudibleWithNoMuteOrSolo() {
        let song = songWithTwoTracksAndPlay()
        XCTAssertTrue(song.tracks.allSatisfy { song.isAudible($0) })
        XCTAssertTrue(song.isPlayKeyboardAudible)
    }

    func testSoloingPlaySilencesTracksThatAreNotSoloed() {
        var song = songWithTwoTracksAndPlay()
        song.performance?.mixer.isSoloed = true
        XCTAssertFalse(song.isAudible(song.tracks[0]))
        XCTAssertTrue(song.isPlayKeyboardAudible)
        song.tracks[1].mixer.isSoloed = true
        XCTAssertTrue(song.isAudible(song.tracks[1]), "soloed with it, it plays")
        XCTAssertFalse(song.isAudible(song.tracks[0]))
    }

    func testSoloingATrackSilencesPlayUnlessPlayIsSoloedToo() {
        var song = songWithTwoTracksAndPlay()
        song.tracks[0].mixer.isSoloed = true
        XCTAssertFalse(song.isPlayKeyboardAudible)
        song.performance?.mixer.isSoloed = true
        XCTAssertTrue(song.isPlayKeyboardAudible)
    }

    func testMutingPlaySilencesIt() {
        var song = songWithTwoTracksAndPlay()
        song.performance?.mixer.isMuted = true
        XCTAssertFalse(song.isPlayKeyboardAudible)
        XCTAssertTrue(song.isAudible(song.tracks[0]), "tracks are unaffected")
    }

    func testPlaySoloRestartsWhatTheSequencerPlays() {
        let song = songWithTwoTracksAndPlay()
        var soloed = song
        soloed.performance?.mixer.isSoloed = true
        XCTAssertTrue(soloed.playbackDiffers(from: song))
        var louder = song
        louder.performance?.mixer.volume = 0.2
        XCTAssertFalse(louder.playbackDiffers(from: song), "volume is the mixer's, not the sequencer's")
    }

    func testNewTargetsRoundTrip() throws {
        let targets: [MIDIControlTarget] = [.playVolume, .playPan, .playMute, .playSolo,
                                            .playEffects, .togglePlayDock, .triggerMode,
                                            .writeNotes, .trackWriteNotes(2)]
        let back = try JSONDecoder().decode([MIDIControlTarget].self, from: JSONEncoder().encode(targets))
        XCTAssertEqual(back, targets)
        XCTAssertTrue(MIDIControlTarget.playVolume.isContinuous)
        XCTAssertFalse(MIDIControlTarget.playMute.isContinuous)
    }
}
