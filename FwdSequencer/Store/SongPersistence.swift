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

// MARK: - Seeding a song from an existing pattern
//
// The on-ramp described in the plan: a pattern's tracks become the song's
// instruments, and its note data becomes section 1. This is the only place a
// standalone pattern feeds a song.

extension Song {
    /// Build a new song seeded from a standalone pattern.
    static func seeded(from project: Project) -> Song {
        var song = Song()
        song.name = project.name
        song.tempo = project.tempo
        song.timeSignature = project.timeSignature
        song.masterVolume = project.masterVolume

        // Each pattern track → a SongTrack (the instrument) plus a Part (the notes).
        // Key/scale are section-wide, so seed them from the pattern's first track.
        var firstSection = SongSection()
        firstSection.name = "Section 1"
        firstSection.numberOfBars = project.numberOfBars
        firstSection.key = project.tracks.first?.key ?? 0
        firstSection.scale = project.tracks.first?.scale ?? .chromatic

        for track in project.tracks {
            let songTrack = SongTrack(
                name: track.name,
                pluginInfo: track.pluginInfo,
                pluginStateData: track.pluginStateData,
                mixer: track.mixer
            )
            song.tracks.append(songTrack)

            let part = Part(
                trackID: songTrack.id,
                notePool: track.notePool,
                steps: track.steps,
                tempoDivision: track.tempoDivision
            )
            firstSection.parts.append(part)
        }

        song.sections = [firstSection]
        return song
    }

    /// Append an empty section with one (empty) Part per existing track.
    mutating func addEmptySection(named name: String) {
        var section = SongSection(name: name, numberOfBars: sections.last?.numberOfBars ?? 4)
        section.parts = tracks.map { Part(trackID: $0.id) }
        sections.append(section)
    }
}
