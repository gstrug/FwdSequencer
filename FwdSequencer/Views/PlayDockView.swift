import SwiftUI

// MARK: - Play Dock
//
// A performance panel that docks at the bottom of the song view. It targets one
// track at a time, exposes that track's instrument + mixer, and gives a wide,
// scrollable, free-play (chromatic) keyboard that sends live MIDI — independent of
// the sequencer, so you can play a melody over a running pattern. Fully additive:
// it touches nothing in the sequencer or the per-track editors.

struct PlayDockView: View {
    @EnvironmentObject var songStore: SongStore
    @Binding var trackID: UUID?
    var onClose: () -> Void

    @State private var showPluginEditor = false
    @State private var activeNotes = Set<UInt8>()

    // Resolve the target track's index (defaults to the first track).
    private var trackIndex: Int? {
        if let tid = trackID, let i = songStore.song.tracks.firstIndex(where: { $0.id == tid }) {
            return i
        }
        return songStore.song.tracks.isEmpty ? nil : 0
    }

    var body: some View {
        VStack(spacing: 8) {
            if let idx = trackIndex {
                header(idx)
                PlayableKeyboard(
                    onNoteOn: { note in
                        activeNotes.insert(note)
                        AudioEngineManager.shared.playNote(
                            trackID: songStore.song.tracks[idx].id, midiNote: note, velocity: 100)
                    },
                    onNoteOff: { note in
                        activeNotes.remove(note)
                        AudioEngineManager.shared.stopNote(
                            trackID: songStore.song.tracks[idx].id, midiNote: note)
                    }
                )
            } else {
                Text("Add a track to play")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                HStack { Spacer(); closeButton }
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .onDisappear { releaseAll() }        // backstop: kill any held notes if the dock goes away
        .fullScreenCover(isPresented: $showPluginEditor) {
            if let idx = trackIndex {
                let t = songStore.song.tracks[idx]
                PluginEditorView(trackID: t.id, trackName: t.name,
                                 onCommitState: { songStore.capturePluginState(for: t.id) })
            }
        }
    }

    // Track picker + instrument + mixer + close.
    @ViewBuilder
    private func header(_ idx: Int) -> some View {
        HStack(spacing: 12) {
            // Which track the keys drive.
            Menu {
                ForEach(songStore.song.tracks) { t in
                    Button(t.name) { switchTrack(to: t.id) }
                }
            } label: {
                Label(songStore.song.tracks[idx].name, systemImage: "pianokeys")
                    .font(.subheadline.bold())
            }

            if songStore.song.tracks[idx].pluginInfo != nil {
                Button { showPluginEditor = true } label: {
                    Label("Edit Sound", systemImage: "slider.horizontal.3").font(.caption)
                }
                .buttonStyle(.bordered).tint(.purple)
            }

            Divider().frame(height: 20)

            Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $songStore.song.tracks[idx].mixer.volume, in: 0...1).frame(width: 110)
            SongTrackMeter(trackID: songStore.song.tracks[idx].id)

            Text("Pan").font(.caption2).foregroundStyle(.secondary)
            Slider(value: $songStore.song.tracks[idx].mixer.pan, in: -1...1).frame(width: 80)

            Toggle("M", isOn: $songStore.song.tracks[idx].mixer.isMuted)
                .toggleStyle(.button).tint(.orange).font(.caption2.bold())
            Toggle("S", isOn: $songStore.song.tracks[idx].mixer.isSoloed)
                .toggleStyle(.button).tint(.yellow).font(.caption2.bold())

            Spacer()
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            releaseAll()
            onClose()
        } label: {
            Image(systemName: "chevron.down.circle.fill")
                .font(.title3).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func switchTrack(to id: UUID) {
        releaseAll()   // stop notes ringing on the previous track before switching
        trackID = id
    }

    private func releaseAll() {
        guard let idx = trackIndex else { activeNotes.removeAll(); return }
        let tid = songStore.song.tracks[idx].id
        for note in activeNotes {
            AudioEngineManager.shared.stopNote(trackID: tid, midiNote: note)
        }
        activeNotes.removeAll()
    }
}

// MARK: - Playable keyboard (scrollable, wide keys, press-and-hold, chromatic)

private struct PlayableKeyboard: View {
    let onNoteOn: (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void

    private static let lowMidi = 24    // C1
    private static let highMidi = 96   // C7
    private static func isWhite(_ m: Int) -> Bool { [0,2,4,5,7,9,11].contains(m % 12) }
    private static let whiteKeys: [Int] = (lowMidi...highMidi).filter { isWhite($0) }
    private static let blackKeys: [Int] = (lowMidi...highMidi).filter { !isWhite($0) }
    private static let whiteIndex: [Int: Int] =
        Dictionary(uniqueKeysWithValues: whiteKeys.enumerated().map { ($1, $0) })

    private let whiteW: CGFloat = 46
    private let keyH: CGFloat = 128
    private var blackW: CGFloat { whiteW * 0.6 }
    private var blackH: CGFloat { keyH * 0.62 }

    @State private var centerC = 60   // middle C — the octave button target (always a C = white)

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button { shift(-12) } label: {
                    Label("Octave", systemImage: "chevron.left").font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(centerC <= Self.lowMidi)

                Spacer()
                Text("C\(centerC / 12 - 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()

                Button { shift(12) } label: {
                    Label("Octave", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(centerC >= Self.highMidi - 12)
            }
            .padding(.horizontal, 8)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            ForEach(Self.whiteKeys, id: \.self) { m in
                                PlayKey(midi: m, isBlack: false, width: whiteW, height: keyH,
                                        onNoteOn: onNoteOn, onNoteOff: onNoteOff)
                                    .overlay(alignment: .bottom) { octaveLabel(m) }
                                    .id(m)
                            }
                        }
                        ForEach(Self.blackKeys, id: \.self) { m in
                            PlayKey(midi: m, isBlack: true, width: blackW, height: blackH,
                                    onNoteOn: onNoteOn, onNoteOff: onNoteOff)
                                .offset(x: blackX(m))
                        }
                    }
                    .frame(width: CGFloat(Self.whiteKeys.count) * whiteW, height: keyH, alignment: .topLeading)
                }
                .frame(height: keyH)
                .onAppear { proxy.scrollTo(centerC, anchor: .center) }
                .onChange(of: centerC) { c in withAnimation { proxy.scrollTo(c, anchor: .center) } }
            }
        }
    }

    @ViewBuilder
    private func octaveLabel(_ m: Int) -> some View {
        if m % 12 == 0 {   // label each C
            Text("C\(m / 12 - 1)")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .padding(.bottom, 4).allowsHitTesting(false)
        }
    }

    private func blackX(_ m: Int) -> CGFloat {
        var left = m - 1
        while left >= Self.lowMidi && !Self.isWhite(left) { left -= 1 }
        guard let idx = Self.whiteIndex[left] else { return 0 }
        return CGFloat(idx + 1) * whiteW - blackW / 2
    }

    private func shift(_ delta: Int) {
        centerC = min(Self.highMidi - 12, max(Self.lowMidi, centerC + delta))
    }
}

// A single key: press-and-hold to sound, release to stop. Multi-touch friendly, so
// chords work (each key owns its own gesture).
private struct PlayKey: View {
    let midi: Int
    let isBlack: Bool
    let width: CGFloat
    let height: CGFloat
    let onNoteOn: (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void
    @State private var pressed = false

    var body: some View {
        Rectangle()
            .fill(pressed ? Color.accentColor
                          : (isBlack ? Color.black : Color.white))
            .frame(width: width, height: height)
            .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; onNoteOn(UInt8(midi)) }
                    }
                    .onEnded { _ in
                        pressed = false; onNoteOff(UInt8(midi))
                    }
            )
    }
}
