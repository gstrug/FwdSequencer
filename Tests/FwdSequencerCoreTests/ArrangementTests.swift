import XCTest
@testable import FwdSequencerCore

/// The arranger: the order sections play in, with any section used any number of times.
final class ArrangementTests: XCTestCase {

    private func song(_ names: [String]) -> Song {
        var song = Song()
        song.sections = names.map { SongSection(name: $0, numberOfBars: 2) }
        return song
    }

    private func arrange(_ song: inout Song, _ indices: [Int]) {
        song.arrangement = indices.map { ArrangementSlot(sectionID: song.sections[$0].id) }
    }

    func testWithoutAnArrangementSectionsPlayInOrder() {
        let s = song(["A", "B", "C"])
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 1, 2])
        XCTAssertEqual(s.playOrder().map(\.id), s.sections.map(\.id))
        XCTAssertFalse(s.arrangementIsActive)
    }

    func testSwitchedOnTheArrangementDecidesTheOrderRepeatsIncluded() {
        var s = song(["Verse", "Chorus", "Bridge", "Pre"])
        arrange(&s, [0, 1, 0, 2, 3, 1])
        s.playsArrangement = true
        XCTAssertTrue(s.arrangementIsActive)
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 1, 0, 2, 3, 1])
        // Each place has its own id, so the two Choruses can be told apart.
        XCTAssertEqual(Set(s.playOrder().map(\.id)).count, 6)
        XCTAssertEqual(s.playOrder().map(\.id), s.arrangement!.map(\.id))
        XCTAssertEqual(s.sectionsInPlayOrder().map(\.name),
                       ["Verse", "Chorus", "Verse", "Bridge", "Pre", "Chorus"])
    }

    func testSwitchedOffOrSetAsideTheSectionsPlayInOrder() {
        var s = song(["A", "B"])
        arrange(&s, [1, 1, 0])
        s.playsArrangement = false
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 1])
        s.playsArrangement = true
        // Hold and Pattern Trigger mode ask for the plain order.
        XCTAssertEqual(s.playOrder(followArrangement: false).map(\.sectionIndex), [0, 1])
    }

    func testAnEmptyArrangementPlaysTheSectionsInOrder() {
        var s = song(["A", "B"])
        s.arrangement = []
        s.playsArrangement = true
        XCTAssertFalse(s.arrangementIsActive)
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 1])
    }

    func testPlacesWhoseSectionHasGoneAreSkipped() {
        var s = song(["A", "B", "C"])
        arrange(&s, [0, 2, 1, 2])
        s.playsArrangement = true
        s.sections.remove(at: 2)
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 1])
    }

    func testOlderSongsWithoutTheArrangerStillLoad() throws {
        let old = song(["A"])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json.removeValue(forKey: "arrangement")
        json.removeValue(forKey: "playsArrangement")
        let decoded = try JSONDecoder().decode(Song.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.arrangement)
        XCTAssertNil(decoded.playsArrangement)
        XCTAssertEqual(decoded.playOrder().count, 1)
    }

    func testTheArrangementAndItsSwitchAreSavedWithTheSong() throws {
        var s = song(["A", "B"])
        arrange(&s, [1, 0, 1])
        s.playsArrangement = true
        let decoded = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded.arrangement, s.arrangement)
        XCTAssertEqual(decoded.playsArrangement, true)
        XCTAssertEqual(decoded.playOrder(), s.playOrder())
    }

    func testValidationTidiesADamagedArrangementInsteadOfRefusingTheSong() throws {
        var s = song(["A", "B"])
        let repeated = UUID()
        s.arrangement = [ArrangementSlot(id: repeated, sectionID: s.sections[0].id),
                         ArrangementSlot(sectionID: UUID()),
                         ArrangementSlot(id: repeated, sectionID: s.sections[1].id)]
        s.playsArrangement = true
        let tidy = try SongValidator.validateAndNormalize(s)
        XCTAssertEqual(tidy.arrangement?.map(\.sectionID), [s.sections[0].id, s.sections[1].id])
        XCTAssertEqual(Set(tidy.arrangement!.map(\.id)).count, 2)
    }

    func testAnArrangementChangesWhatPlaysForTheSequencer() {
        var s = song(["A"])
        let before = s
        arrange(&s, [0, 0])
        XCTAssertTrue(s.playbackDiffers(from: before))
        var on = s
        on.playsArrangement = true
        XCTAssertTrue(on.playbackDiffers(from: s))
    }

    func testMIDIExportFollowsTheArrangement() throws {
        var s = song(["Alpha", "Beta"])
        arrange(&s, [0, 1, 0, 0])
        s.playsArrangement = true
        let data = [UInt8](try SongMIDIExporter.data(for: s))
        XCTAssertEqual(occurrences(of: "Alpha", in: data), 3)
        XCTAssertEqual(occurrences(of: "Beta", in: data), 1)
        s.playsArrangement = false
        let plain = [UInt8](try SongMIDIExporter.data(for: s))
        XCTAssertEqual(occurrences(of: "Alpha", in: plain), 1)
    }

    // MARK: Song Parts

    private func part(_ song: inout Song, _ name: String, _ indices: [Int]) -> UUID {
        let p = SongPart(name: name, sectionIDs: indices.map { song.sections[$0].id })
        song.songParts = (song.songParts ?? []) + [p]
        return p.id
    }

    func testASongPartPlaysItsSectionsWhereverItIsPlaced() {
        var s = song(["S1", "S2", "S3", "S4", "Ch1", "Ch2"])
        let verse = part(&s, "Verse", [0, 1, 2, 3])
        let chorus = part(&s, "Chorus", [4, 5, 4])
        s.arrangement = [ArrangementSlot(partID: verse), ArrangementSlot(partID: chorus),
                         ArrangementSlot(partID: verse), ArrangementSlot(sectionID: s.sections[5].id)]
        s.playsArrangement = true
        let order = s.playOrder()
        XCTAssertEqual(order.map(\.sectionIndex), [0, 1, 2, 3, 4, 5, 4, 0, 1, 2, 3, 5])
        XCTAssertEqual(order.map { $0.slotIndex }, [0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 3])
        XCTAssertEqual(order.map(\.positionInSlot), [0, 1, 2, 3, 0, 1, 2, 0, 1, 2, 3, 0])
        XCTAssertEqual(order[4].slotLength, 3)
        // Every entry is told apart, even the same section twice in one part.
        XCTAssertEqual(Set(order.map(\.id)).count, order.count)
        // A single section keeps the place's own id.
        XCTAssertEqual(order.last?.id, s.arrangement?.last?.id)
    }

    func testIdsStayTheSameWhenTheSongChanges() {
        var s = song(["A", "B"])
        let p = part(&s, "P", [0, 1])
        s.arrangement = [ArrangementSlot(partID: p)]
        s.playsArrangement = true
        let before = s.playOrder().map(\.id)
        s.tempo = 90
        s.sections[0].numberOfBars = 8
        XCTAssertEqual(s.playOrder().map(\.id), before)
    }

    func testChangingASongPartChangesEveryPlaceItIsUsed() {
        var s = song(["A", "B", "C"])
        let p = part(&s, "P", [0])
        s.arrangement = [ArrangementSlot(partID: p), ArrangementSlot(partID: p)]
        s.playsArrangement = true
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 0])
        s.songParts?[0].sectionIDs.append(s.sections[2].id)
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 2, 0, 2])
    }

    func testAnEmptySongPartPlaysNothing() {
        var s = song(["A", "B"])
        let empty = part(&s, "Empty", [])
        s.arrangement = [ArrangementSlot(partID: empty), ArrangementSlot(sectionID: s.sections[1].id)]
        s.playsArrangement = true
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [1])
        s.arrangement = [ArrangementSlot(partID: empty)]
        // Nothing to play: the sections play in order instead.
        XCTAssertFalse(s.arrangementIsActive)
        XCTAssertEqual(s.playOrder().map(\.sectionIndex), [0, 1])
    }

    func testBuild88ArrangementsStillLoad() throws {
        let section = UUID(), slot = UUID()
        let json = """
        {"id":"\(slot.uuidString)","sectionID":"\(section.uuidString)"}
        """
        let decoded = try JSONDecoder().decode(ArrangementSlot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, ArrangementSlot(id: slot, sectionID: section, partID: nil))
    }

    func testValidationTidiesSongParts() throws {
        var s = song(["A", "B"])
        let p = part(&s, "P", [0, 1])
        s.songParts?[0].sectionIDs.append(UUID())
        let keptEmpty = part(&s, "New", [])
        s.arrangement = [ArrangementSlot(partID: p), ArrangementSlot(partID: UUID()),
                         ArrangementSlot(partID: keptEmpty)]
        let tidy = try SongValidator.validateAndNormalize(s)
        XCTAssertEqual(tidy.songParts?[0].sectionIDs, [s.sections[0].id, s.sections[1].id])
        // A just-made empty part survives saving.
        XCTAssertEqual(tidy.songParts?.count, 2)
        XCTAssertEqual(tidy.arrangement?.compactMap(\.partID), [p, keptEmpty])
    }

    func testMIDIExportFollowsSongParts() throws {
        var s = song(["Alpha", "Beta", "Gamma"])
        let p = part(&s, "Verse", [0, 1])
        s.arrangement = [ArrangementSlot(partID: p), ArrangementSlot(sectionID: s.sections[2].id),
                         ArrangementSlot(partID: p)]
        s.playsArrangement = true
        let data = [UInt8](try SongMIDIExporter.data(for: s))
        XCTAssertEqual(occurrences(of: "Alpha", in: data), 2)
        XCTAssertEqual(occurrences(of: "Beta", in: data), 2)
        XCTAssertEqual(occurrences(of: "Gamma", in: data), 1)
    }

    func testAPartsChangesReachTheSequencer() {
        var s = song(["A"])
        let before = s
        _ = part(&s, "P", [0])
        XCTAssertTrue(s.playbackDiffers(from: before))
    }

    private func occurrences(of text: String, in bytes: [UInt8]) -> Int {
        let needle = Array(text.utf8)
        guard bytes.count >= needle.count else { return 0 }
        return (0...(bytes.count - needle.count)).filter { Array(bytes[$0..<$0 + needle.count]) == needle }.count
    }
}
