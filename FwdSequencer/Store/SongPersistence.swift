import Foundation

// MARK: - Song file storage
//
// Songs persist to their own directory / extension so they never collide with
// standalone patterns (Projects/*.fwdproj). Mirrors the Project persistence in
// ProjectStore.swift. Phase 0 of SONG_MODE_PLAN.md — additive, no behaviour change.

enum SongStorage {

    static let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).fwdsong")
    }

    /// Write a song to disk atomically. Returns false on encode/write failure.
    @discardableResult
    static func save(_ song: Song) -> Bool {
        guard let data = try? JSONEncoder().encode(song) else { return false }
        do {
            try data.write(to: url(for: song.id), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// All saved songs, most-recently-modified first.
    static func all() -> [Song] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "fwdsong" }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
            .compactMap { fileURL in
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? JSONDecoder().decode(Song.self, from: data)
            }
    }

    static func delete(_ song: Song) {
        try? FileManager.default.removeItem(at: url(for: song.id))
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
