import SwiftUI
import UniformTypeIdentifiers

struct ProjectBrowserView: View {
    @EnvironmentObject var songStore: SongStore
    /// Which example songs have been added to the list, by `ExampleSong` raw value, so
    /// each is added once — including any added to the app later. New Song ▸ Examples
    /// adds another copy any time.
    @AppStorage("installedExamples") private var installedExamplesRaw = ""
    /// Earlier records of the same thing, read once to carry them over.
    @AppStorage("didInstallExamplesV3") private var didInstallExamplesV3 = false
    @AppStorage("didInstallHappyBirthdayDemoV2") private var didInstallHappyBirthdayDemo = false
    @State private var songs: [Song] = []
    @State private var showingSong = false
    @State private var songDeleteTarget: Song? = nil
    @State private var songRenameTarget: Song? = nil
    @State private var renameText = ""
    /// A template chosen from New Song, waiting for its name. Nothing is created until
    /// the name is confirmed, so cancelling leaves no stray "New FWD Song" behind.
    @State private var newSongTemplate: SongTemplate? = nil
    @State private var newSongName = ""
    @State private var failedFiles: [FailedSongFile] = []
    @State private var trashedSongs: [TrashedSong] = []
    @State private var trashPurgeTarget: TrashedSong? = nil
    @State private var notice: String? = nil
    @State private var importingSong = false
    @State private var exportingSong = false
    @State private var exportDocument: SongDocument? = nil
    @State private var exportFilename = "FWD Song"
    @State private var exportingMIDI = false
    /// Two-step export, mirroring the recording flow: choose a format, then name it.
    @State private var exportFormatTarget: Song?
    @State private var exportNameTarget: (song: Song, format: SongExportFormat)?
    @State private var exportNameText = ""
    /// Shown after an export so the file can actually be found.
    @State private var exportedLocation: String?

    @State private var midiDocument: MIDIFileDocument? = nil
    @State private var midiFilename = "FWD Song"
    @State private var failedRemovalTarget: FailedSongFile? = nil
    @State private var exportingFailedFile = false
    @State private var failedFileDocument: RawSongDocument? = nil
    @State private var failedExportFilename = "Unreadable FWD Song"

    var body: some View {
        NavigationStack {
            songList
                .helpHost()
                .navigationTitle("FWD Sequencer")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HelpToolbarItem(topic: .newSong) {
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
                                Divider()
                                Menu {
                                    ForEach(ExampleSong.allCases) { example in
                                        Button { addExample(example) } label: {
                                            Label {
                                                VStack(alignment: .leading) {
                                                    Text(example.name)
                                                    Text(example.summary)
                                                }
                                            } icon: {
                                                Image(systemName: example.systemImage)
                                            }
                                        }
                                    }
                                } label: {
                                    Label("Examples", systemImage: "music.note.list")
                                }
                            } label: {
                                Label("New Song", systemImage: "plus")
                            }
                        }
                    }
                    // Our own ⋯ menu rather than the system's overflow, so help mode can
                    // explain it like everything else.
                    ToolbarItem(placement: .primaryAction) {
                        HelpToolbarItem(topic: .importSong) {
                            Menu {
                                Button { importingSong = true } label: {
                                    Label("Import Song", systemImage: "square.and.arrow.down")
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        HelpButton()
                    }
                    // No tutorial: removed 2026-10-22. Help mode (the ?) explains every
                    // control where it is.
                }
        }
        .onAppear {
            SongStorage.prepareExportsFolder()
            reload()
            installBundledDemoIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Backgrounding is a safe point to snapshot live plugin sounds and persist.
            songStore.captureAndSave()
        }
        .onOpenURL { url in importSong(at: url) }
        // MIDI controllers act on the song only while it is open: from the song list, a
        // Play press must not start a song nobody can see. Tied to this flag rather than
        // the song screen appearing, because a plugin editor opened full screen over the
        // song makes it "disappear" — and a controller should keep working while you
        // tweak a synth.
        .onChange(of: showingSong) { open in
            MIDIControlCenter.shared.songStore = open ? songStore : nil
            if !open { MIDIControlCenter.shared.learn.isOn = false }
        }
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
        .alert("New Song", isPresented: Binding(
            get: { newSongTemplate != nil },
            set: { if !$0 { newSongTemplate = nil } }
        )) {
            TextField("Song Name", text: $newSongName)
            Button("Create") {
                if let template = newSongTemplate { createSongAndOpen(template, named: newSongName) }
                newSongTemplate = nil
            }
            Button("Cancel", role: .cancel) { newSongTemplate = nil }
        } message: {
            Text("A name already in use gets a number added.")
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
        .confirmationDialog("Export song as",
                            isPresented: Binding(get: { exportFormatTarget != nil },
                                                 set: { if !$0 { exportFormatTarget = nil } }),
                            titleVisibility: .visible) {
            ForEach(SongExportFormat.allCases) { format in
                Button(format.displayName) { beginExport(format) }
            }
        } message: {
            Text(SongExportFormat.allCases.map { "\($0.displayName) — \($0.detail)" }
                    .joined(separator: "\n"))
        }
        .alert("File name", isPresented: Binding(get: { exportNameTarget != nil },
                                                 set: { if !$0 { exportNameTarget = nil } })) {
            TextField("Name", text: $exportNameText)
            Button("Export") { performExport() }
            Button("Cancel", role: .cancel) { exportNameTarget = nil }
        } message: {
            if let target = exportNameTarget {
                Text("Saved as a \(target.format.displayName) file. Choose FWD Sequencer in the "
                     + "location picker to keep exports with the app.")
            }
        }
        .alert("Export complete", isPresented: Binding(
            get: { exportedLocation != nil },
            set: { if !$0 { exportedLocation = nil } }
        )) {
            Button("OK") { exportedLocation = nil }
        } message: {
            Text(exportedLocation ?? "")
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
    }

    private func duplicateSong(_ song: Song) {
        var copy = song
        copy.id = UUID()
        copy.formatVersion = 2
        copy.name = SongNaming.copyName(of: song.name, among: songs.map(\.name))
        if case .failure(let error) = SongStorage.saveResult(copy) {
            notice = error.localizedDescription
        }
        reload()
    }

    /// Step 1 → 2: format chosen, now ask for a name.
    private func beginExport(_ format: SongExportFormat) {
        guard let song = exportFormatTarget else { return }
        exportFormatTarget = nil
        exportNameText = sanitizedFilename(song.name)
        exportNameTarget = (song, format)
    }

    /// Step 2 → done: build the document and hand it to the system exporter.
    private func performExport() {
        guard let target = exportNameTarget else { return }
        exportNameTarget = nil
        let name = sanitizedFilename(exportNameText)
        do {
            // Always keep a copy in the app's Exports folder, then offer the system
            // picker for anywhere else. Without this, dismissing the picker left no
            // file at all and nowhere obvious to look.
            let data: Data
            switch target.format {
            case .fwdSong:
                data = try JSONEncoder().encode(SongValidator.validateAndNormalize(target.song))
                exportDocument = SongDocument(song: target.song)
                exportFilename = name
                exportingSong = true
            case .midi, .midiOnGrid:
                data = try SongMIDIExporter.data(for: target.song,
                                                 includingFeel: target.format == .midi)
                midiDocument = MIDIFileDocument(data: data)
                midiFilename = name
                exportingMIDI = true
            }
            if let url = SongStorage.saveToExports(data, name: name,
                                                   fileExtension: target.format.fileExtension) {
                exportedLocation = SongStorage.exportLocationDescription(for: url)
            }
        } catch {
            notice = "Export failed. \(error.localizedDescription)"
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
                Button { addExample(.lighthouse) } label: {
                    Label("Play Lighthouse", systemImage: "play.fill")
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
                                            .helpTag(.needsAttention, instance: failure.id)
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
                        // Rows sized to their content rather than the default row height.
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .contentShape(Rectangle())
                        .onTapGesture { openSong(song) }
                        .helpTag(.songRow, instance: song.id.uuidString)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { songDeleteTarget = song } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { exportFormatTarget = song } label: {
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
                            Button { exportFormatTarget = song } label: {
                                Label("Export…", systemImage: "square.and.arrow.up")
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
                                        .helpTag(.recentlyDeleted, instance: item.id.uuidString)
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
            // A List enforces a ~44pt minimum row height whatever the content is,
            // which left song rows taller than the two lines they show.
            .environment(\.defaultMinListRowHeight, 34)
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

    /// Install the bundled example exactly once through the same validated,
    /// atomic save path as a user-created song. A fresh UUID keeps it separate
    /// from every existing document; after installation it is an ordinary song
    /// that can be edited, duplicated, exported, or deleted without returning.
    private func installBundledDemoIfNeeded() {
        var installed = Set(installedExamplesRaw.split(separator: ",").map(String.init))
        // Carried over from before the list: the 2026-10-30 set, and Happy Birthday.
        if didInstallExamplesV3 { installed.formUnion(["nightMarket", "lighthouse", "sundayStrut"]) }
        if didInstallHappyBirthdayDemo { installed.insert(ExampleSong.happyBirthday.rawValue) }
        var added = false
        for example in ExampleSong.allCases where !installed.contains(example.rawValue) {
            // Recorded only once saved, so a failure is retried next launch.
            guard let song = example.makeSong() else { continue }
            switch SongStorage.saveResult(song) {
            case .success:
                installed.insert(example.rawValue)
                added = true
            case .failure(let error):
                notice = "\(example.name) could not be installed. \(error.localizedDescription)"
            }
        }
        installedExamplesRaw = installed.sorted().joined(separator: ",")
        if added { reload() }
    }

    /// New Song ▸ Examples: a fresh copy, opened straight away.
    private func addExample(_ example: ExampleSong) {
        guard var song = example.makeSong() else {
            notice = "\(example.name) could not be found in the app."
            return
        }
        song.name = SongNaming.uniqueName(song.name, among: songs.map(\.name))
        songStore.open(song)
        songStore.saveNow()
        showingSong = true
    }

    private func openSong(_ song: Song) {
        songStore.open(song)
        showingSong = true
    }

    /// New Song: ask for the name first. The suggestion is the template's own name, with
    /// a number if a song already has it.
    private func createSongAndOpen(_ template: SongTemplate = .starter) {
        newSongName = SongNaming.uniqueName(template.songName, among: songs.map(\.name))
        newSongTemplate = template
    }

    private func createSongAndOpen(_ template: SongTemplate, named name: String) {
        var s = template.makeSong()
        // Kept distinct even if the suggestion was edited back to a name in use.
        s.name = SongNaming.uniqueName(name, among: songs.map(\.name))
        songStore.open(s)
        songStore.saveNow()
        // From a MIDI File…: the song opens on the import, file timing on.
        songStore.startsWithMIDIImport = template.startsWithMIDIImport
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
            switch SongStorage.importSong(imported, existingNames: songs.map(\.name)) {
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

// MARK: - Song Row

struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.footnote)
                .foregroundStyle(.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(song.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if hasArrangement { arrangementBadge }
                }
                // Spelled out rather than icon-only: a metronome or slider glyph on its
                // own tells you nothing about what the number means.
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The song has been arranged in the Arranger (Section menu). Shown whether or not
    /// Play Arrangement is on, so arranged songs can be found; dimmed when it is off.
    private var hasArrangement: Bool { !(song.arrangement ?? []).isEmpty }
    private var arrangementIsOn: Bool { song.playsArrangement == true }

    private var arrangementBadge: some View {
        Label(arrangementIsOn ? "Arranged" : "Arranged · off", systemImage: "list.number")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(arrangementIsOn ? Color.accentColor : Color.secondary)
            .background((arrangementIsOn ? Color.accentColor : Color.secondary).opacity(0.15),
                        in: Capsule())
            .accessibilityLabel(arrangementIsOn ? "Has an arrangement" : "Has an arrangement, switched off")
    }

    private var summary: String {
        let tracks = "\(song.tracks.count) track\(song.tracks.count == 1 ? "" : "s")"
        let sections = "\(song.sections.count) section\(song.sections.count == 1 ? "" : "s")"
        let tempo = "\(Int(song.tempo)) BPM"
        let meter = "\(song.timeSignature.numerator)/\(song.timeSignature.denominator)"
        return [tracks, sections, tempo, meter].joined(separator: " · ")
    }
}
