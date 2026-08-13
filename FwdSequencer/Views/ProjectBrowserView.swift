import SwiftUI
import UniformTypeIdentifiers

struct ProjectBrowserView: View {
    @EnvironmentObject var songStore: SongStore
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @State private var songs: [Song] = []
    @State private var showingSong = false
    @State private var songDeleteTarget: Song? = nil
    @State private var songRenameTarget: Song? = nil
    @State private var renameText = ""
    @State private var failedFiles: [FailedSongFile] = []
    @State private var trashedSongs: [TrashedSong] = []
    @State private var trashPurgeTarget: TrashedSong? = nil
    @State private var notice: String? = nil
    @State private var importingSong = false
    @State private var exportingSong = false
    @State private var exportDocument: SongDocument? = nil
    @State private var exportFilename = "FWD Song"
    @State private var exportingMIDI = false
    @State private var midiDocument: MIDIFileDocument? = nil
    @State private var midiFilename = "FWD Song"
    @State private var showingOnboarding = false
    @State private var failedRemovalTarget: FailedSongFile? = nil
    @State private var exportingFailedFile = false
    @State private var failedFileDocument: RawSongDocument? = nil
    @State private var failedExportFilename = "Unreadable FWD Song"

    var body: some View {
        NavigationStack {
            songList
                .navigationTitle("FWD Sequencer")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(SongTemplate.allCases) { template in
                                Button { createSongAndOpen(template) } label: {
                                    Label {
                                        VStack(alignment: .leading) {
                                            Text(template.name)
                                            Text(template.summary)
                                        }
                                    } icon: {
                                        Image(systemName: template.systemImage)
                                    }
                                }
                            }
                        } label: {
                            Label("New Song", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button { importingSong = true } label: {
                            Label("Import Song", systemImage: "square.and.arrow.down")
                        }
                    }
                }
        }
        .onAppear {
            reload()
            if !didCompleteOnboarding { showingOnboarding = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Backgrounding is a safe point to snapshot live plugin sounds and persist.
            songStore.captureAndSave()
        }
        .onOpenURL { url in importSong(at: url) }
        .fullScreenCover(isPresented: $showingSong, onDismiss: {
            songStore.saveNow()
            reload()
        }) {
            SongView()
                .environmentObject(songStore)
        }
        .alert("Delete Song?", isPresented: Binding(
            get: { songDeleteTarget != nil },
            set: { if !$0 { songDeleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let s = songDeleteTarget {
                    if case .failure(let error) = SongStorage.moveToTrash(s) {
                        notice = error.localizedDescription
                    }
                }
                songDeleteTarget = nil
                reload()
            }
            Button("Cancel", role: .cancel) { songDeleteTarget = nil }
        } message: {
            Text("\"\(songDeleteTarget?.name ?? "")\" will move to Recently Deleted.")
        }
        .alert("Rename Song", isPresented: Binding(
            get: { songRenameTarget != nil },
            set: { if !$0 { songRenameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if var s = songRenameTarget {
                    s.name = String(renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                        .prefix(SongValidator.maximumNameLength))
                    if !s.name.isEmpty,
                       case .failure(let error) = SongStorage.saveResult(s) {
                        notice = error.localizedDescription
                    }
                }
                songRenameTarget = nil
                reload()
            }
            Button("Cancel", role: .cancel) { songRenameTarget = nil }
        }
        .alert("FWD Sequencer", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .alert("Delete Permanently?", isPresented: Binding(
            get: { trashPurgeTarget != nil },
            set: { if !$0 { trashPurgeTarget = nil } }
        )) {
            Button("Delete Permanently", role: .destructive) {
                if let item = trashPurgeTarget { permanentlyDelete(item) }
                trashPurgeTarget = nil
            }
            Button("Cancel", role: .cancel) { trashPurgeTarget = nil }
        } message: {
            Text("\"\(trashPurgeTarget?.song.name ?? "")\" will be permanently deleted. This can't be undone.")
        }
        .alert("Remove Unreadable Song?", isPresented: Binding(
            get: { failedRemovalTarget != nil },
            set: { if !$0 { failedRemovalTarget = nil } }
        )) {
            Button("Remove from Library", role: .destructive) {
                if let failure = failedRemovalTarget { quarantine(failure) }
                failedRemovalTarget = nil
            }
            Button("Cancel", role: .cancel) { failedRemovalTarget = nil }
        } message: {
            Text("The unreadable file will leave the song list but remain quarantined inside FWD Sequencer for support or recovery. Export the original first if you want your own copy.")
        }
        .fileImporter(isPresented: $importingSong, allowedContentTypes: [.fwdSong, .json]) { result in
            importSong(result)
        }
        .fileExporter(isPresented: $exportingSong,
                      document: exportDocument,
                      contentType: .fwdSong,
                      defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
            exportDocument = nil
        }
        .fileExporter(isPresented: $exportingMIDI,
                      document: midiDocument,
                      contentType: .standardMIDI,
                      defaultFilename: midiFilename) { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
            midiDocument = nil
        }
        .fileExporter(isPresented: $exportingFailedFile,
                      document: failedFileDocument,
                      contentType: .fwdSong,
                      defaultFilename: failedExportFilename) { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
            failedFileDocument = nil
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView(completed: $didCompleteOnboarding)
        }
    }

    private func duplicateSong(_ song: Song) {
        var copy = song
        copy.id = UUID()
        copy.formatVersion = 2
        copy.name += " copy"
        if case .failure(let error) = SongStorage.saveResult(copy) {
            notice = error.localizedDescription
        }
        reload()
    }

    private func exportSong(_ song: Song) {
        exportDocument = SongDocument(song: song)
        exportFilename = sanitizedFilename(song.name)
        exportingSong = true
    }

    private func exportMIDI(_ song: Song) {
        do {
            midiDocument = MIDIFileDocument(data: try SongMIDIExporter.data(for: song))
            midiFilename = sanitizedFilename(song.name)
            exportingMIDI = true
        } catch {
            notice = "MIDI export failed. \(error.localizedDescription)"
        }
    }

    private func beginRename(_ song: Song) {
        renameText = song.name
        songRenameTarget = song
    }

    // MARK: - List

    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty && failedFiles.isEmpty && trashedSongs.isEmpty {
            VStack(spacing: 18) {
                emptyState(icon: "music.note.list", title: "Make something move",
                           subtitle: "Start from a playable example, then change its notes and steps.")
                Button { createSongAndOpen(.ambientCanon) } label: {
                    Label("Play Ambient Canon", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button { createSongAndOpen(.starter) } label: {
                    Label("Start Blank", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 30)
            }
        } else {
            List {
                if !failedFiles.isEmpty {
                    Section("Needs Attention") {
                        ForEach(failedFiles) { failure in
                            VStack(alignment: .leading, spacing: 8) {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text("Unreadable song: \(failure.filename)").lineLimit(2)
                                        Text(failure.message).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                                HStack {
                                    Spacer(minLength: 0)
                                    if failure.canRestoreBackup {
                                        Button("Restore Backup") { restoreBackup(failure) }
                                            .buttonStyle(.borderedProminent)
                                    }
                                    Menu {
                                        Button { exportOriginal(failure) } label: {
                                            Label("Export Original", systemImage: "square.and.arrow.up")
                                        }
                                        Button(role: .destructive) {
                                            failedRemovalTarget = failure
                                        } label: {
                                            Label("Remove from Library", systemImage: "archivebox")
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .frame(width: 44, height: 44)
                                    }
                                    .accessibilityLabel("Actions for unreadable song \(failure.filename)")
                                }
                            }
                        }
                    }
                }

                ForEach(songs) { song in
                    SongRow(song: song)
                        .contentShape(Rectangle())
                        .onTapGesture { openSong(song) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { songDeleteTarget = song } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { exportSong(song) } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                        // Long-press menu mirrors the swipe action for people who
                        // don't discover the swipe, and adds rename/duplicate.
                        .contextMenu {
                            Button { openSong(song) } label: { Label("Open", systemImage: "play.fill") }
                            Button { beginRename(song) } label: { Label("Rename", systemImage: "pencil") }
                            Button { duplicateSong(song) } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                            Button { exportSong(song) } label: {
                                Label("Export FWD Song", systemImage: "square.and.arrow.up")
                            }
                            Button { exportMIDI(song) } label: {
                                Label("Export MIDI", systemImage: "music.note.list")
                            }
                            Divider()
                            Button(role: .destructive) { songDeleteTarget = song } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }

                if !trashedSongs.isEmpty {
                    Section("Recently Deleted") {
                        ForEach(trashedSongs) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(item.song.name, systemImage: "trash").lineLimit(2)
                                HStack {
                                    Spacer(minLength: 0)
                                    Button("Restore") { restore(item) }
                                        .buttonStyle(.bordered)
                                    Button(role: .destructive) { trashPurgeTarget = item } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .accessibilityLabel("Delete \(item.song.name) permanently")
                                }
                            }
                            .contextMenu {
                                Button("Restore") { restore(item) }
                                Button("Delete Permanently", role: .destructive) {
                                    trashPurgeTarget = item
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 56)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func reload() {
        switch SongStorage.loadLibrary() {
        case .success(let snapshot):
            songs = snapshot.songs
            failedFiles = snapshot.failedFiles
        case .failure(let error):
            songs = []
            failedFiles = []
            notice = error.localizedDescription
        }
        trashedSongs = SongStorage.trashedSongs()
    }

    private func openSong(_ song: Song) {
        songStore.open(song)
        showingSong = true
    }

    private func createSongAndOpen(_ template: SongTemplate = .starter) {
        let s = template.makeSong()
        songStore.open(s)
        songStore.saveNow()
        showingSong = true
    }

    private func importSong(_ result: Result<URL, Error>) {
        do {
            importSong(at: try result.get())
        } catch {
            notice = "That file is not a valid FWD song. \(error.localizedDescription)"
        }
    }

    private func importSong(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try SongStorage.decodeDocument(Data(contentsOf: url))
            switch SongStorage.importSong(imported) {
            case .success: reload()
            case .failure(let error): notice = error.localizedDescription
            }
        } catch {
            notice = "That file is not a valid FWD song. \(error.localizedDescription)"
        }
    }

    private func restore(_ item: TrashedSong) {
        if case .failure(let error) = SongStorage.restore(item) {
            notice = error.localizedDescription
        }
        reload()
    }

    private func permanentlyDelete(_ item: TrashedSong) {
        if case .failure(let error) = SongStorage.permanentlyDelete(item) {
            notice = error.localizedDescription
        }
        reload()
    }

    private func restoreBackup(_ failure: FailedSongFile) {
        if case .failure(let error) = SongStorage.restoreBackup(failure) {
            notice = error.localizedDescription
        }
        reload()
    }

    private func exportOriginal(_ failure: FailedSongFile) {
        do {
            failedFileDocument = RawSongDocument(data: try Data(contentsOf: failure.fileURL))
            failedExportFilename = sanitizedFilename(failure.filename)
            exportingFailedFile = true
        } catch {
            notice = "The unreadable file could not be exported. \(error.localizedDescription)"
        }
    }

    private func quarantine(_ failure: FailedSongFile) {
        if case .failure(let error) = SongStorage.quarantine(failure) {
            notice = error.localizedDescription
        }
        reload()
    }

    private func sanitizedFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "FWD Song" : cleaned
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        projectMetadata
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        projectMetadata
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var projectMetadata: some View {
        Label("\(project.tracks.count) track\(project.tracks.count == 1 ? "" : "s")",
              systemImage: "slider.horizontal.3")
        Label("\(Int(project.tempo)) BPM", systemImage: "metronome")
        Label("\(project.timeSignature.numerator)/\(project.timeSignature.denominator)",
              systemImage: "music.note")
    }
}

// MARK: - Song Row

struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .font(.headline)
                    .lineLimit(2)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        songMetadata
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        songMetadata
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var songMetadata: some View {
        Label("\(song.tracks.count) track\(song.tracks.count == 1 ? "" : "s")",
              systemImage: "slider.horizontal.3")
        Label("\(song.sections.count) section\(song.sections.count == 1 ? "" : "s")",
              systemImage: "square.stack")
        Label("\(Int(song.tempo)) BPM", systemImage: "metronome")
    }
}
