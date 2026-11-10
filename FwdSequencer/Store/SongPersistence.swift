import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    // `nonisolated` because the target defaults to MainActor isolation, and these are
    // read from background work that writes files.
    nonisolated static let fwdSong = UTType(exportedAs: "com.grahamstruwig.FwdSequencer.song",
                                                    conformingTo: .json)
    nonisolated static let standardMIDI = UTType(filenameExtension: "mid") ?? .data
    nonisolated static let coreAudioRecording = UTType(filenameExtension: "caf") ?? .audio
}

struct MIDIFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.standardMIDI] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw SongStorageError.unreadableFile("The selected file has no MIDI data.")
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct AudioRecordingDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.coreAudioRecording] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw SongStorageError.unreadableFile("The selected file has no audio data.")
        }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// What a song can be exported as, offered the same way the recording chooser is.
nonisolated enum SongExportFormat: String, CaseIterable, Identifiable {
    case fwdSong
    case midi
    case midiOnGrid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fwdSong: return "FWD Song"
        case .midi:    return "MIDI"
        case .midiOnGrid: return "MIDI (on the Grid)"
        }
    }

    var detail: String {
        switch self {
        case .fwdSong: return "The whole song, to reopen here or share."
        case .midi:    return "Notes as they play, Feel included, for a DAW. Muted tracks are omitted."
        case .midiOnGrid: return "Notes exactly on their steps, without Feel: tidiest in GarageBand, Logic or a notation app."
        }
    }

    var fileExtension: String {
        switch self {
        case .fwdSong: return "fwdsong"
        case .midi, .midiOnGrid: return "mid"
        }
    }
}

struct SongDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.fwdSong, .json] }
    var song: Song

    init(song: Song) {
        self.song = song
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw SongStorageError.unreadableFile("The selected file has no song data.")
        }
        song = try SongValidator.decodeAndValidate(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let safeSong = try SongValidator.validateAndNormalize(song)
        return FileWrapper(regularFileWithContents: try JSONEncoder().encode(safeSong))
    }
}

/// Byte-preserving wrapper used to let a user export an unreadable song before
/// removing it from the visible library. It intentionally performs no decoding.
struct RawSongDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.fwdSong, .json, .data] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw SongStorageError.unreadableFile("The selected file has no song data.")
        }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum SongStorageError: LocalizedError {
    case directoryUnavailable(String)
    case unreadableFile(String)
    case corruptFile(String)
    case writeFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let detail): return "The song library is unavailable. \(detail)"
        case .unreadableFile(let detail): return detail
        case .corruptFile(let detail): return "A song could not be opened. \(detail)"
        case .writeFailed(let detail): return "The song could not be saved. \(detail)"
        case .deleteFailed(let detail): return "The song could not be removed. \(detail)"
        }
    }
}

struct FailedSongFile: Identifiable {
    var id: String { fileURL.path }
    let filename: String
    let message: String
    let fileURL: URL
    let backupFileURL: URL?

    var canRestoreBackup: Bool { backupFileURL != nil }
}

struct SongLibrarySnapshot {
    var songs: [Song]
    var failedFiles: [FailedSongFile]
}

struct TrashedSong: Identifiable {
    let id: UUID
    let song: Song
    let fileURL: URL
}

// MARK: - Song file storage

enum SongStorage {
    private static let fileManager = FileManager.default
    /// Portable tests redirect storage to a unique temporary directory. Production
    /// never sets this value.
    static var directoryOverrideForTesting: URL?

    private static var documentsRoot: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Where the song library lives: Application Support, not Documents.
    ///
    /// `UIFileSharingEnabled` shows the whole Documents folder in the Files app, so the
    /// library used to sit there in the open — songs named by UUID, beside the app's own
    /// Backups and Quarantine folders. Nothing there is meant to be handled by hand
    /// (Graham, 2026-11-10: "we don't want users messing with the song structure"), and
    /// a song moved, renamed or half-deleted in Files comes back as a song that will not
    /// open. Application Support is the iOS place for data the app owns and the user
    /// does not: still backed up, no longer on show. Documents now holds only what the
    /// user is meant to see — Exports and MIDI Loops. Songs leave and arrive through
    /// Import and Export, which name their files properly.
    private static var supportRoot: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var directory: URL {
        if let directoryOverrideForTesting { return directoryOverrideForTesting }
        return supportRoot.appendingPathComponent("Songs", isDirectory: true)
    }

    private static var trashDirectory: URL {
        directory.appendingPathComponent("Recently Deleted", isDirectory: true)
    }

    private static var backupDirectory: URL {
        directory.appendingPathComponent("Backups", isDirectory: true)
    }

    private static var quarantineDirectory: URL {
        directory.appendingPathComponent("Quarantine", isDirectory: true)
    }

    /// Carry a library written by an earlier version out of Documents, once.
    ///
    /// Every file is moved, whole tree and all — songs, Recently Deleted, Backups,
    /// Quarantine — and a file already at the destination is left alone rather than
    /// overwritten, so running this again can never lose the newer copy. Anything that
    /// cannot be moved stays where it is and is tried again next launch; the loader
    /// reads the old place too (see `songFileURLs`) so a song is never invisible
    /// because a move failed.
    @discardableResult
    static func migrateLibrary(fromDocuments documents: URL, toSupport support: URL) -> Bool {
        let old = documents.appendingPathComponent("Songs", isDirectory: true)
        guard fileManager.fileExists(atPath: old.path) else { return false }
        var moved = false
        // Enumerated BY PATH, which hands back each file's path relative to the folder.
        // Taking the relative part off the absolute URLs instead looks simpler and is
        // wrong: the two can disagree about their prefix (/var against /private/var),
        // and the relative path then comes out mangled. Caught by the tests.
        for relative in filesIn(old) {
            let source = old.appendingPathComponent(relative)
            // Keep each file's place in the tree: Backups/x.fwdsong stays in Backups.
            let destination = support.appendingPathComponent(relative)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: source)   // the newer copy is already there
                } else {
                    try fileManager.moveItem(at: source, to: destination)
                }
                moved = true
            } catch {
                continue    // left behind; tried again at the next launch
            }
        }
        // Only when nothing is left: an empty tree goes, a tree with a file still in it
        // stays, so nothing is ever thrown away here.
        if filesIn(old).isEmpty { try? fileManager.removeItem(at: old) }
        return moved
    }

    /// Every regular file under `folder`, as paths relative to it.
    private static func filesIn(_ folder: URL) -> [String] {
        guard let walk = fileManager.enumerator(atPath: folder.path) else { return [] }
        var found: [String] = []
        for case let relative as String in walk {
            let url = folder.appendingPathComponent(relative)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            found.append(relative)
        }
        return found
    }

    /// Runs once per launch, before anything is read or written.
    private static var didMigrate = false
    private static func migrateLibraryIfNeeded() {
        guard directoryOverrideForTesting == nil, !didMigrate else { return }
        didMigrate = true
        migrateLibrary(fromDocuments: documentsRoot, toSupport: directory)
    }

    private static func prepareDirectories() throws {
        migrateLibraryIfNeeded()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: quarantineDirectory, withIntermediateDirectories: true)
        } catch {
            throw SongStorageError.directoryUnavailable(error.localizedDescription)
        }
    }

    /// A folder for exported files, created so it is visible in the Files app under
    /// "FWD Sequencer" (see UIFileSharingEnabled in Info.plist). Exports still go
    /// wherever the system picker is pointed; this just gives them a home.
    static var exportsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Exports", isDirectory: true)
    }

    static func prepareExportsFolder() {
        try? fileManager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
    }

    /// MIDI loops to try Import MIDI with, in Files under "FWD Sequencer". Without them
    /// an iPad with no MIDI files of its own has nothing to import.
    static var midiLoopsDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("MIDI Loops", isDirectory: true)
    }

    /// Copy the loops the app carries (Loop-*.mid) into the MIDI Loops folder, each one
    /// once: a loop the user has deleted or changed is theirs and is left alone, and a
    /// loop added in a later version of the app arrives with it. Never overwrites.
    static func installMIDILoops(from bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let key = "installedMIDILoops"
        let prefix = "Loop-"
        let carried = (bundle.urls(forResourcesWithExtension: "mid", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
        var installed = Set(defaults.stringArray(forKey: key) ?? [])
        let waiting = carried.filter { !installed.contains($0.lastPathComponent) }
        guard !waiting.isEmpty else { return }
        do {
            try fileManager.createDirectory(at: midiLoopsDirectory, withIntermediateDirectories: true)
        } catch {
            return      // tried again at the next launch
        }
        for source in waiting {
            let name = String(source.lastPathComponent.dropFirst(prefix.count))
            let destination = midiLoopsDirectory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: destination.path) {
                guard (try? fileManager.copyItem(at: source, to: destination)) != nil else { continue }
            }
            installed.insert(source.lastPathComponent)
        }
        defaults.set(installed.sorted(), forKey: key)
    }

    /// Write an export into the app's Exports folder, so a file always exists somewhere
    /// findable even if the system location picker is dismissed. Returns the URL, or nil
    /// if it could not be written. Never overwrites: a duplicate name gains a suffix.
    @discardableResult
    static func saveToExports(_ data: Data, name: String, fileExtension: String) -> URL? {
        prepareExportsFolder()
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "FWD Export" : name
        var candidate = exportsDirectory.appendingPathComponent("\(base).\(fileExtension)")
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = exportsDirectory
                .appendingPathComponent("\(base) \(attempt).\(fileExtension)")
            attempt += 1
        }
        do {
            try data.write(to: candidate, options: .atomic)
            return candidate
        } catch {
            return nil
        }
    }

    /// Where an export landed, phrased the way the user sees it in the Files app.
    static func exportLocationDescription(for url: URL) -> String {
        "Saved to Files › On My iPad › FWD Sequencer › Exports › \(url.lastPathComponent)"
    }

    static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).fwdsong")
    }

    private static func backupURL(for id: UUID) -> URL {
        backupDirectory.appendingPathComponent("\(id.uuidString).fwdsong")
    }

    private static func backupURL(forSongFile fileURL: URL) -> URL {
        backupDirectory.appendingPathComponent(fileURL.lastPathComponent)
    }

    static func decodeDocument(_ data: Data) throws -> Song {
        try SongValidator.decodeAndValidate(data)
    }

    /// Write atomically and retain one last-known-good backup for recovery.
    static func saveResult(_ song: Song) -> Result<Void, SongStorageError> {
        do {
            try prepareDirectories()
            let safeSong = try SongValidator.validateAndNormalize(song)
            let destination = url(for: safeSong.id)
            if fileManager.fileExists(atPath: destination.path) {
                // Only promote a readable primary to "last known good". An externally
                // corrupted file must not overwrite the valid recovery copy before a
                // replacement save has completed.
                let existingData = try Data(contentsOf: destination)
                if (try? decodeDocument(existingData)) != nil {
                    let backup = backupURL(for: safeSong.id)
                    if fileManager.fileExists(atPath: backup.path) {
                        try fileManager.removeItem(at: backup)
                    }
                    try fileManager.copyItem(at: destination, to: backup)
                }
            }
            let data = try JSONEncoder().encode(safeSong)
            try data.write(to: destination, options: .atomic)
            return .success(())
        } catch let error as SongStorageError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    static func loadLibrary() -> Result<SongLibrarySnapshot, SongStorageError> {
        do {
            try prepareDirectories()
            let songFiles = songFileURLs()

            var songs: [Song] = []
            var failures: [FailedSongFile] = []
            for fileURL in songFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    songs.append(try decodeDocument(data))
                } catch {
                    let candidateBackup = backupURL(forSongFile: fileURL)
                    let validBackup: URL?
                    if let backupData = try? Data(contentsOf: candidateBackup),
                       (try? decodeDocument(backupData)) != nil {
                        validBackup = candidateBackup
                    } else {
                        validBackup = nil
                    }
                    failures.append(FailedSongFile(
                        filename: fileURL.deletingPathExtension().lastPathComponent,
                        message: error.localizedDescription,
                        fileURL: fileURL,
                        backupFileURL: validBackup
                    ))
                }
            }
            return .success(SongLibrarySnapshot(songs: songs, failedFiles: failures))
        } catch let error as SongStorageError {
            return .failure(error)
        } catch {
            return .failure(.directoryUnavailable(error.localizedDescription))
        }
    }

    static func moveToTrash(_ song: Song) -> Result<Void, SongStorageError> {
        do {
            try prepareDirectories()
            let source = url(for: song.id)
            guard fileManager.fileExists(atPath: source.path) else { return .success(()) }
            let destination = trashDirectory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
            return .success(())
        } catch {
            return .failure(.deleteFailed(error.localizedDescription))
        }
    }

    static func trashedSongs() -> [TrashedSong] {
        do {
            try prepareDirectories()
            let files = try fileManager.contentsOfDirectory(
                at: trashDirectory, includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)
            return files.compactMap { fileURL in
                guard fileURL.pathExtension == "fwdsong",
                      let data = try? Data(contentsOf: fileURL),
                      let song = try? decodeDocument(data) else { return nil }
                return TrashedSong(id: song.id, song: song, fileURL: fileURL)
            }
        } catch {
            return []
        }
    }

    static func restore(_ item: TrashedSong) -> Result<Void, SongStorageError> {
        do {
            try prepareDirectories()
            let destination = url(for: item.song.id)
            if fileManager.fileExists(atPath: destination.path) {
                throw SongStorageError.writeFailed("A song with this identifier already exists.")
            }
            try fileManager.moveItem(at: item.fileURL, to: destination)
            return .success(())
        } catch let error as SongStorageError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    static func permanentlyDelete(_ item: TrashedSong) -> Result<Void, SongStorageError> {
        do {
            try fileManager.removeItem(at: item.fileURL)
            let backup = backupURL(for: item.song.id)
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            return .success(())
        } catch {
            return .failure(.deleteFailed(error.localizedDescription))
        }
    }

    /// `existingNames`: the songs already in the library, so an import whose name is
    /// taken gets a number rather than a second song of the same name.
    static func importSong(_ imported: Song, existingNames: [String] = []) -> Result<Song, SongStorageError> {
        do {
            var copy = try SongValidator.validateAndNormalize(imported)
            copy.id = UUID()
            copy.formatVersion = SongValidator.currentFormatVersion
            copy.name = SongNaming.uniqueName(imported.name, among: existingNames)
            switch saveResult(copy) {
            case .success: return .success(copy)
            case .failure(let error): return .failure(error)
            }
        } catch {
            return .failure(.corruptFile(error.localizedDescription))
        }
    }

    /// Replace an unreadable primary file with its validated last-known-good backup.
    /// The unreadable bytes are retained in Quarantine for manual support/recovery.
    static func restoreBackup(_ failure: FailedSongFile) -> Result<Song, SongStorageError> {
        do {
            try prepareDirectories()
            guard let backup = failure.backupFileURL else {
                throw SongStorageError.unreadableFile("No valid backup is available for this song.")
            }
            let data = try Data(contentsOf: backup)
            let song = try decodeDocument(data)

            if fileManager.fileExists(atPath: failure.fileURL.path) {
                let quarantined = quarantineDirectory.appendingPathComponent(
                    "\(failure.fileURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).corrupt"
                )
                try fileManager.copyItem(at: failure.fileURL, to: quarantined)
            }
            try data.write(to: failure.fileURL, options: .atomic)
            return .success(song)
        } catch let error as SongStorageError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    /// Remove an unreadable primary from the visible library without destroying
    /// its bytes. The browser offers export first; this internal quarantine also
    /// leaves a support/recovery copy if the user chooses Remove from Library.
    static func quarantine(_ failure: FailedSongFile) -> Result<Void, SongStorageError> {
        do {
            try prepareDirectories()
            guard fileManager.fileExists(atPath: failure.fileURL.path) else {
                return .success(())
            }
            let base = failure.fileURL.deletingPathExtension().lastPathComponent
            let destination = quarantineDirectory.appendingPathComponent(
                "\(base)-\(UUID().uuidString).fwdsong"
            )
            try fileManager.moveItem(at: failure.fileURL, to: destination)
            return .success(())
        } catch {
            return .failure(.deleteFailed(error.localizedDescription))
        }
    }

    /// Every song file to show, newest first. The library's own folder, plus — only if
    /// a move out of Documents was left unfinished — whatever is still in the old one,
    /// so a song cannot vanish from the list because a file could not be moved.
    private static func songFileURLs() -> [URL] {
        var urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles)) ?? []
        if directoryOverrideForTesting == nil {
            let old = documentsRoot.appendingPathComponent("Songs", isDirectory: true)
            if fileManager.fileExists(atPath: old.path) {
                urls += (try? fileManager.contentsOfDirectory(
                    at: old, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: .skipsHiddenFiles)) ?? []
            }
        }
        var seen = Set<String>()
        return urls.filter { $0.pathExtension == "fwdsong" && seen.insert($0.lastPathComponent).inserted }
            .sorted { modificationDate($0) > modificationDate($1) }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}

extension Song {
    /// Append an empty section with one (empty) Part per existing track.
    mutating func addEmptySection(named name: String) {
        var section = SongSection(name: name, numberOfBars: sections.last?.numberOfBars ?? 4)
        section.parts = tracks.map { Part(trackID: $0.id) }
        sections.append(section)
    }
}
