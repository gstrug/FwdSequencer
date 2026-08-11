import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let fwdSong = UTType(exportedAs: "com.grahamstruwig.FwdSequencer.song",
                                conformingTo: .json)
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
        song = try JSONDecoder().decode(Song.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try JSONEncoder().encode(song))
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
        case .deleteFailed(let detail): return "The song could not be moved to Recently Deleted. \(detail)"
        }
    }
}

struct FailedSongFile: Identifiable {
    let id = UUID()
    let filename: String
    let message: String
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

    static let directory: URL = {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Songs", isDirectory: true)
    }()

    private static var trashDirectory: URL {
        directory.appendingPathComponent("Recently Deleted", isDirectory: true)
    }

    private static var backupDirectory: URL {
        directory.appendingPathComponent("Backups", isDirectory: true)
    }

    private static func prepareDirectories() throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        } catch {
            throw SongStorageError.directoryUnavailable(error.localizedDescription)
        }
    }

    static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).fwdsong")
    }

    /// Write atomically and retain one last-known-good backup for recovery.
    static func saveResult(_ song: Song) -> Result<Void, SongStorageError> {
        do {
            try prepareDirectories()
            let destination = url(for: song.id)
            if fileManager.fileExists(atPath: destination.path) {
                let backup = backupDirectory.appendingPathComponent(destination.lastPathComponent)
                if fileManager.fileExists(atPath: backup.path) {
                    try fileManager.removeItem(at: backup)
                }
                try fileManager.copyItem(at: destination, to: backup)
            }
            let data = try JSONEncoder().encode(song)
            try data.write(to: destination, options: .atomic)
            return .success(())
        } catch let error as SongStorageError {
            return .failure(error)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    @discardableResult
    static func save(_ song: Song) -> Bool {
        if case .success = saveResult(song) { return true }
        return false
    }

    static func loadLibrary() -> Result<SongLibrarySnapshot, SongStorageError> {
        do {
            try prepareDirectories()
            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            )
            let songFiles = files.filter { $0.pathExtension == "fwdsong" }
                .sorted { modificationDate($0) > modificationDate($1) }

            var songs: [Song] = []
            var failures: [FailedSongFile] = []
            for fileURL in songFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    songs.append(try JSONDecoder().decode(Song.self, from: data))
                } catch {
                    failures.append(FailedSongFile(
                        filename: fileURL.deletingPathExtension().lastPathComponent,
                        message: error.localizedDescription
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

    static func all() -> [Song] {
        guard case .success(let snapshot) = loadLibrary() else { return [] }
        return snapshot.songs
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

    /// Compatibility wrapper. New UI uses moveToTrash and reports its result.
    static func delete(_ song: Song) {
        _ = moveToTrash(song)
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
                      let song = try? JSONDecoder().decode(Song.self, from: data) else { return nil }
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
            return .success(())
        } catch {
            return .failure(.deleteFailed(error.localizedDescription))
        }
    }

    static func importSong(_ imported: Song) -> Result<Song, SongStorageError> {
        var copy = imported
        copy.id = UUID()
        copy.formatVersion = 2
        copy.name = imported.name + " (Imported)"
        switch saveResult(copy) {
        case .success: return .success(copy)
        case .failure(let error): return .failure(error)
        }
    }

    @discardableResult
    static func duplicate(_ song: Song) -> Song {
        var copy = song
        copy.id = UUID()
        copy.formatVersion = 2
        copy.name = song.name + " copy"
        _ = saveResult(copy)
        return copy
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
