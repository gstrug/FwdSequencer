import SwiftUI

// MARK: - Play Dock
//
// A performance panel that docks at the bottom of the song view. It drives its own
// dedicated instrument (the song's `performance` SongTrack) — independent of the
// sequencer tracks — so you pick a plugin just for playing and jam a melody over a
// running pattern. Fully additive: nothing in the sequencer or the per-track
// editors changes.

struct PlayDockView: View {
    @EnvironmentObject var songStore: SongStore
    var onClose: () -> Void

    @State private var showPluginEditor = false
    @State private var showPluginPicker = false
    @State private var pendingPlugin: PendingPluginChoice? = nil
    @State private var activeNotes = Set<UInt8>()

    private var perf: SongTrack? { songStore.song.performance }

    var body: some View {
        VStack(spacing: 8) {
            header
            if let p = perf {
                PlayableKeyboard(
                    onNoteOn: { note in
                        activeNotes.insert(note)
                        AudioEngineManager.shared.playNote(trackID: p.id, midiNote: note, velocity: 100)
                    },
                    onNoteOff: { note in
                        activeNotes.remove(note)
                        AudioEngineManager.shared.stopNote(trackID: p.id, midiNote: note)
                    }
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)          // span the screen, never wider
        .background(.regularMaterial)
        .clipped()                           // keep the wide keyboard from spilling past the edges
        .overlay(alignment: .top) { Divider() }
        .onAppear { songStore.ensurePerformanceInstrument() }
        .onDisappear { releaseAll() }
        .sheet(isPresented: $showPluginPicker) {
            PluginPickerView(selectedPlugin: pluginBinding)
        }
        .alert("Stop playback to load?",
               isPresented: Binding(get: { pendingPlugin != nil },
                                    set: { if !$0 { pendingPlugin = nil } }),
               presenting: pendingPlugin) { choice in
            Button("Stop & Load") {
                songStore.stop()
                songStore.setPerformancePlugin(choice.info)
                pendingPlugin = nil
            }
            Button("Load Anyway") {
                songStore.setPerformancePlugin(choice.info)
                pendingPlugin = nil
            }
            Button("Cancel", role: .cancel) { pendingPlugin = nil }
        } message: { choice in
            Text("\(choice.info?.name ?? "The built-in sound") loads most reliably with the sequencer stopped — some plugins show a blank interface otherwise. Load Anyway keeps playing.")
        }
        .fullScreenCover(isPresented: $showPluginEditor) {
            if let p = perf {
                PluginEditorView(trackID: p.id, trackName: p.name,
                                 onCommitState: { songStore.capturePerformanceState() })
            }
        }
    }

    // Instrument picker + Edit Sound + volume + close.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            wideHeader.fixedSize(horizontal: true, vertical: false)
            compactHeader
        }
    }

    private var wideHeader: some View {
        HStack(spacing: 12) {
            instrumentButton
            editSoundButton
            volumeControls
            closeButton
        }
    }

    private var compactHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                instrumentButton
                Spacer(minLength: 4)
                closeButton
            }
            HStack(spacing: 8) {
                editSoundButton
                volumeControls
            }
        }
    }

    private var instrumentButton: some View {
        Button { showPluginPicker = true } label: {
            Label(perf?.pluginInfo?.name ?? "Built-in GM Sound", systemImage: "pianokeys")
                .font(.subheadline.bold()).lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(perf?.pluginInfo == nil ? nil : .accentColor)
    }

    @ViewBuilder
    private var editSoundButton: some View {
        if perf?.pluginInfo != nil {
            Button { showPluginEditor = true } label: {
                Label("Edit Instrument", systemImage: "slider.horizontal.3").font(.caption)
            }
            .buttonStyle(.bordered).tint(.purple)
        }
    }

    @ViewBuilder
    private var volumeControls: some View {
        if perf != nil {
            Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
            Slider(value: volumeBinding, in: 0...1)
                .frame(minWidth: 80, maxWidth: 160)
                .accessibilityLabel("Manual keyboard volume")
            if let id = perf?.id { SongTrackMeter(trackID: id) }
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
        .accessibilityLabel("Close manual keyboard")
    }

    /// A plugin choice waiting on confirmation to stop playback. Wrapped so that
    /// choosing "no plugin" (nil) is still a distinguishable pending value.
    struct PendingPluginChoice: Identifiable {
        let id = UUID()
        let info: PluginInfo?
    }

    private var pluginBinding: Binding<PluginInfo?> {
        Binding(get: { songStore.song.performance?.pluginInfo },
                set: { newInfo in
                    // Same reason as the track picker: loading an AUv3 and building its
                    // UI while the sequencer runs is unreliable for heavy plugins.
                    if songStore.isPlaying {
                        pendingPlugin = PendingPluginChoice(info: newInfo)
                    } else {
                        songStore.setPerformancePlugin(newInfo)
                    }
                })
    }

    private var volumeBinding: Binding<Float> {
        Binding(get: { songStore.song.performance?.mixer.volume ?? 0.8 },
                set: { songStore.setPerformanceVolume($0) })
    }

    private func releaseAll() {
        guard let id = perf?.id else { activeNotes.removeAll(); return }
        for note in activeNotes { AudioEngineManager.shared.stopNote(trackID: id, midiNote: note) }
        activeNotes.removeAll()
    }
}

// MARK: - Playable keyboard (scrollable, wide keys, press-and-hold, chromatic)

private struct PlayableKeyboard: View {
    let onNoteOn: (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lowMidi = 36    // C2
    private static let highMidi = 84   // C6 (≈4 octaves; ~3 visible at a time)
    private static func isWhite(_ m: Int) -> Bool { [0,2,4,5,7,9,11].contains(m % 12) }
    private static let whiteKeys: [Int] = (lowMidi...highMidi).filter { isWhite($0) }
    private static let blackKeys: [Int] = (lowMidi...highMidi).filter { !isWhite($0) }
    private static let whiteIndex: [Int: Int] =
        Dictionary(uniqueKeysWithValues: whiteKeys.enumerated().map { ($1, $0) })

    private let whiteW: CGFloat = 70   // wide, easy to play
    private let keyH: CGFloat = 132
    private var blackW: CGFloat { whiteW * 0.6 }
    private var blackH: CGFloat { keyH * 0.62 }

    @State private var centerC = 60   // middle C — octave-button target (always a C = white)

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
                .frame(maxWidth: .infinity)
                .frame(height: keyH)
                .clipped()
                .onAppear { proxy.scrollTo(centerC, anchor: .center) }
                .onChange(of: centerC) { c in
                    if reduceMotion { proxy.scrollTo(c, anchor: .center) }
                    else { withAnimation { proxy.scrollTo(c, anchor: .center) } }
                }
            }
        }
    }

    @ViewBuilder
    private func octaveLabel(_ m: Int) -> some View {
        if m % 12 == 0 {
            Text("C\(m / 12 - 1)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.bottom, 5).allowsHitTesting(false)
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

    private var noteName: String {
        let names = ["C", "C sharp", "D", "D sharp", "E", "F",
                     "F sharp", "G", "G sharp", "A", "A sharp", "B"]
        return "\(names[midi % 12]) \(midi / 12 - 1)"
    }

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
            .accessibilityElement()
            .accessibilityLabel(noteName)
            .accessibilityValue(pressed ? "Playing" : "Ready")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard !pressed else { return }
                pressed = true
                onNoteOn(UInt8(midi))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    guard pressed else { return }
                    pressed = false
                    onNoteOff(UInt8(midi))
                }
            }
            .onDisappear {
                if pressed {
                    pressed = false
                    onNoteOff(UInt8(midi))
                }
            }
    }
}
