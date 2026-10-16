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
}
