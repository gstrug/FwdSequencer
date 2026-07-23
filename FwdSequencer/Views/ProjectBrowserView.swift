import SwiftUI

struct ProjectBrowserView: View {
    @EnvironmentObject var songStore: SongStore
    @State private var songs: [Song] = []
    @State private var showingSong = false
    @State private var songDeleteTarget: Song? = nil

    var body: some View {
        NavigationStack {
            songList
                .navigationTitle("FWD Sequencer")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { createSongAndOpen() } label: {
                            Label("New Song", systemImage: "plus")
                        }
                    }
                }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            songStore.saveNow()
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
                if let s = songDeleteTarget { SongStorage.delete(s) }
                songDeleteTarget = nil
                reload()
            }
            Button("Cancel", role: .cancel) { songDeleteTarget = nil }
        } message: {
            Text("\"\(songDeleteTarget?.name ?? "")\" will be permanently deleted.")
        }
    }

    // MARK: - List

    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty {
            emptyState(icon: "music.note.list", title: "No Songs Yet",
                       subtitle: "Tap New Song to arrange sections")
        } else {
            List {
                ForEach(songs) { song in
                    SongRow(song: song)
                        .contentShape(Rectangle())
                        .onTapGesture { openSong(song) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { songDeleteTarget = song } label: {
                                Label("Delete", systemImage: "trash")
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
        songs = SongStorage.all()
    }

    private func openSong(_ song: Song) {
        songStore.open(song)
        showingSong = true
    }

    private func createSongAndOpen() {
        var s = Song()
        s.addEmptySection(named: "Section 1")
        songStore.open(s)
        songStore.saveNow()
        showingSong = true
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
                HStack(spacing: 12) {
                    Label("\(project.tracks.count) track\(project.tracks.count == 1 ? "" : "s")",
                          systemImage: "slider.horizontal.3")
                    Label("\(Int(project.tempo)) BPM", systemImage: "metronome")
                    Label("\(project.timeSignature.numerator)/\(project.timeSignature.denominator)",
                          systemImage: "music.note")
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
                HStack(spacing: 12) {
                    Label("\(song.tracks.count) track\(song.tracks.count == 1 ? "" : "s")",
                          systemImage: "slider.horizontal.3")
                    Label("\(song.sections.count) section\(song.sections.count == 1 ? "" : "s")",
                          systemImage: "square.stack")
                    Label("\(Int(song.tempo)) BPM", systemImage: "metronome")
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
}
