import XCTest
@testable import FwdSequencerCore

/// New, duplicated and imported songs never share a name with one already in the list.
final class SongNamingTests: XCTestCase {

    func testAFreeNameIsKept() {
        XCTAssertEqual(SongNaming.uniqueName("Bass Pulse", among: ["Chord Drift"]), "Bass Pulse")
    }

    func testATakenNameGetsTheLowestFreeNumber() {
        XCTAssertEqual(SongNaming.uniqueName("New FWD Song", among: ["New FWD Song"]), "New FWD Song 2")
        XCTAssertEqual(SongNaming.uniqueName("New FWD Song",
                                             among: ["New FWD Song", "New FWD Song 2", "New FWD Song 4"]),
                       "New FWD Song 3")
    }

    func testCaseAndSpacesDoNotMakeANameDifferent() {
        XCTAssertEqual(SongNaming.uniqueName("  bass pulse ", among: ["Bass Pulse"]), "bass pulse 2")
    }

    func testANumberedNameCountsOnRatherThanDoublingUp() {
        XCTAssertEqual(SongNaming.uniqueName("Take 2", among: ["Take 2"]), "Take 3")
        XCTAssertEqual(SongNaming.uniqueName("Take 2", among: ["Take 2", "Take 3"]), "Take 4")
    }

    func testAnEmptyNameBecomesUntitled() {
        XCTAssertEqual(SongNaming.uniqueName("   ", among: []), "Untitled Song")
        XCTAssertEqual(SongNaming.uniqueName("", among: ["Untitled Song"]), "Untitled Song 2")
    }

    func testTheResultStaysWithinTheLengthLimit() {
        let long = String(repeating: "x", count: SongValidator.maximumNameLength)
        let name = SongNaming.uniqueName(long, among: [long])
        XCTAssertEqual(name.count, SongValidator.maximumNameLength)
        XCTAssertTrue(name.hasSuffix(" 2"))
        XCTAssertEqual(SongNaming.uniqueName(long + "yyy", among: []).count, SongValidator.maximumNameLength)
    }

    func testDuplicatesAreNumberedCopies() {
        XCTAssertEqual(SongNaming.copyName(of: "Groove", among: ["Groove"]), "Groove copy")
        XCTAssertEqual(SongNaming.copyName(of: "Groove", among: ["Groove", "Groove copy"]), "Groove copy 2")
        // Duplicating a copy makes the next copy, not "Groove copy copy".
        XCTAssertEqual(SongNaming.copyName(of: "Groove copy", among: ["Groove", "Groove copy"]),
                       "Groove copy 2")
        XCTAssertEqual(SongNaming.copyName(of: "Groove copy 2",
                                           among: ["Groove", "Groove copy", "Groove copy 2"]),
                       "Groove copy 3")
    }
}
