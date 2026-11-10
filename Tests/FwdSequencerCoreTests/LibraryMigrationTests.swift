import XCTest
@testable import FwdSequencerCore

/// Carrying a library written by an earlier version out of Documents and into
/// Application Support, where the Files app does not show it.
///
/// The hard rule for this is the oldest one in the project: a saved song must keep
/// opening. So every case here is about not losing a file.
final class LibraryMigrationTests: XCTestCase {
    private var root: URL!
    private var documents: URL!
    private var support: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwd-migration-\(UUID().uuidString)")
        documents = root.appendingPathComponent("Documents")
        support = root.appendingPathComponent("Application Support/Songs")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let url = documents.appendingPathComponent("Songs/" + relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ relativePath: String) -> String? {
        try? String(contentsOf: support.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The whole tree moves, each file keeping its place in it.
    func testTheWholeLibraryMoves() throws {
        try write("song", to: "A.fwdsong")
        try write("deleted", to: "Recently Deleted/B.fwdsong")
        try write("backup", to: "Backups/A.fwdsong")
        try write("broken", to: "Quarantine/C-1.fwdsong")

        XCTAssertTrue(SongStorage.migrateLibrary(fromDocuments: documents, toSupport: support))

        XCTAssertEqual(read("A.fwdsong"), "song")
        XCTAssertEqual(read("Recently Deleted/B.fwdsong"), "deleted")
        XCTAssertEqual(read("Backups/A.fwdsong"), "backup")
        XCTAssertEqual(read("Quarantine/C-1.fwdsong"), "broken")
        // Nothing left behind in the user's Documents.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: documents.appendingPathComponent("Songs").path))
    }

    /// Nothing to carry: a fresh install must not be disturbed by this.
    func testNothingToMoveIsNotAFailure() {
        XCTAssertFalse(SongStorage.migrateLibrary(fromDocuments: documents, toSupport: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    /// Run again, nothing happens — and nothing is moved twice.
    func testMigratingTwiceIsHarmless() throws {
        try write("song", to: "A.fwdsong")
        XCTAssertTrue(SongStorage.migrateLibrary(fromDocuments: documents, toSupport: support))
        XCTAssertFalse(SongStorage.migrateLibrary(fromDocuments: documents, toSupport: support))
        XCTAssertEqual(read("A.fwdsong"), "song")
    }

    /// A file already in the new place is the one that has been used since; the old copy
    /// must never overwrite it.
    func testTheNewerCopyWins() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try "new".write(to: support.appendingPathComponent("A.fwdsong"), atomically: true, encoding: .utf8)
        try write("old", to: "A.fwdsong")
        try write("only in the old place", to: "B.fwdsong")

        SongStorage.migrateLibrary(fromDocuments: documents, toSupport: support)

        XCTAssertEqual(read("A.fwdsong"), "new")
        XCTAssertEqual(read("B.fwdsong"), "only in the old place")
    }

    /// Something that is not a song is carried across too, rather than being left in a
    /// folder that is then deleted.
    func testAnUnexpectedFileIsCarriedAcrossAsWell() throws {
        try write("{}", to: "notes.json")
        SongStorage.migrateLibrary(fromDocuments: documents, toSupport: support)
        XCTAssertEqual(read("notes.json"), "{}")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: documents.appendingPathComponent("Songs").path))
    }
}
