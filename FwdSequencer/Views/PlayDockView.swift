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

    @State private var showBuiltInSounds = false
    @State private var showPluginPicker = false
    @State private var showScalePicker = false
    @State private var activeNotes = Set<UInt8>()
    /// Key on screen → note sent, so each release stops the note its press played even
    /// if the transpose changed while the key was down.
    @State private var sentNotes: [UInt8: UInt8] = [:]

    private var perf: SongTrack? { songStore.song.performance }

    var body: some View {
        VStack(spacing: 8) {
            header
            if let p = perf {
                PlayableKeyboard(
                    performanceID: p.id,
                    scale: songStore.song.playKeyboardScale,
                    onNoteOn: { note in
                        activeNotes.insert(note)
                        // Mute and solo apply here as they do to a track: muted, or
                        // silenced by a soloed track, and the keys make no sound.
                        guard songStore.song.isPlayKeyboardAudible else { return }
                        // Keys transpose; the scale check was on the key pressed.
                        let shifted = Int(note) + (songStore.song.performance?.effectiveKeysTranspose ?? 0)
                        guard (0...127).contains(shifted) else { return }
                        if let previous = sentNotes[note] {
                            AudioEngineManager.shared.stopNote(trackID: p.id, midiNote: previous)
                        }
                        sentNotes[note] = UInt8(shifted)
                        AudioEngineManager.shared.playNote(trackID: p.id, midiNote: UInt8(shifted), velocity: 100)
                    },
                    onNoteOff: { note in
                        activeNotes.remove(note)
                        let sent = sentNotes.removeValue(forKey: note) ?? note
                        AudioEngineManager.shared.stopNote(trackID: p.id, midiNote: sent)
                    }
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)          // span the screen, never wider
        .background(.regularMaterial)
        .clipped()                           // keep the wide keyboard from spilling past the edges
        .overlay(alignment: .top) { Divider() }
        // Deferred: this creates the performance track, mutating @Published song state.
        // Doing that straight from onAppear publishes a change during the view update
        // that presented the dock.
        .onAppear {
            DispatchQueue.main.async { songStore.ensurePerformanceInstrument() }
        }
        .onDisappear { releaseAll() }
        .sheet(isPresented: $showPluginPicker) {
            PluginPickerView(selectedPlugin: pluginBinding,
                             builtInSound: songStore.song.performance?.builtInSound)
        }
        .sheet(isPresented: $showBuiltInSounds) {
            BuiltInSoundSheet(title: "Play Keyboard: GM Sound",
                              current: songStore.song.performance?.builtInSound ?? 0) { sound in
                if let id = songStore.song.performance?.id { songStore.setBuiltInSound(sound, forTrack: id) }
            }
        }
        .sheet(isPresented: $showScalePicker) {
            let current = songStore.song.playKeyboardScale ?? PlayKeyboardScale()
            KeyScalePickerView(currentKey: current.key, currentScale: current.scale,
                               droppedCount: { _, _ in 0 }) { key, scale in
                setScale(PlayKeyboardScale(key: key, scale: scale))
            }
        }
        .fullScreenCover(isPresented: $showPluginEditor) {
            if let p = perf {
                PluginEditorView(trackID: p.id, trackName: p.name,
                                 onCommitState: { songStore.capturePerformanceState() })
            }
        }
    }

    // Instrument picker + Edit Sound + volume + close.
    //
    // All on one line when it fits. Otherwise two rows: the instrument with the close
    // button at the far end, then Edit Sound, scale, transpose and the volume controls
    // (the slider takes what width is left), centred. RowOrTwoRows rather than
    // ViewThatFits, which crashes on iPadOS 16 (see AdaptiveLayouts.swift).
    private var header: some View {
        RowOrTwoRows(wideSpacing: 12, compactSpacing: 8, rowGap: 8, centersSecondRow: true) {
            instrumentButton.compactRow(.first)
            editSoundButton
            scaleButton
            transposeButton
            volumeControls
            closeButton.compactRow(.firstTrailing)
        }
    }

    private var instrumentButton: some View {
        Button { showPluginPicker = true } label: {
            Label(perf?.pluginInfo?.name ?? "Built-in GM Sound", systemImage: "pianokeys")
                .font(.subheadline.bold()).lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(.accentColor)
        .helpTag(.playInstrument)
    }

    @ViewBuilder
    private var editSoundButton: some View {
        if perf != nil {
            // A plugin's own window, or for the built-in GM sound its list of sounds.
            Button {
                if perf?.pluginInfo != nil { showPluginEditor = true } else { showBuiltInSounds = true }
            } label: {
                Label(perf?.pluginInfo != nil ? "Edit Instrument" : GeneralMIDI.soundName(perf?.builtInSound),
                      systemImage: "slider.horizontal.3").font(.caption)
            }
            .buttonStyle(.bordered).tint(.purple)
            .helpTag(.playEditInstrument)
        }
    }

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F",
                                    "F♯", "G", "G♯", "A", "A♯", "B"]

    private static func name(key: Int, scale: MusicalScale) -> String {
        "\(noteNames[((key % 12) + 12) % 12]) \(scale.rawValue)"
    }

    private struct TrackScale: Identifiable {
        let id: UUID
        let name: String
        let key: Int
        let scale: MusicalScale
    }

    /// The tracks in the selected section that follow a scale, to copy one from.
    private var trackScales: [TrackScale] {
        let song = songStore.song
        guard song.sections.indices.contains(songStore.selectedSection) else { return [] }
        let parts = song.sections[songStore.selectedSection].parts
        return song.tracks.compactMap { track in
            guard let part = parts.first(where: { $0.trackID == track.id }),
                  part.scale != .chromatic else { return nil }
            return TrackScale(id: track.id, name: track.name, key: part.key, scale: part.scale)
        }
    }

    /// Key and scale for the Play keyboard: its own, a track's, or every key.
    @ViewBuilder
    private var scaleButton: some View {
        if perf != nil {
            let current = songStore.song.playKeyboardScale
            let limits = current?.limitsKeys ?? false
            Menu {
                Button { showScalePicker = true } label: {
                    Label("Choose Key & Scale…", systemImage: "music.quarternote.3")
                }
                let tracks = trackScales
                if !tracks.isEmpty {
                    Section("Match a Track") {
                        ForEach(tracks) { t in
                            Button("\(t.name): \(Self.name(key: t.key, scale: t.scale))") {
                                setScale(PlayKeyboardScale(key: t.key, scale: t.scale))
                            }
                        }
                    }
                }
                if limits {
                    Button { setScale(nil) } label: {
                        Label("All Keys", systemImage: "pianokeys")
                    }
                }
            } label: {
                Label(limits ? Self.name(key: current!.key, scale: current!.scale) : "All Keys",
                      systemImage: "music.quarternote.3")
                    .font(.caption).lineLimit(1)
            }
            .buttonStyle(.bordered)
            .tint(limits ? .accentColor : .secondary)
            .accessibilityLabel("Play keyboard key and scale")
            .accessibilityValue(limits ? Self.name(key: current!.key, scale: current!.scale) : "All keys")
            .helpTag(.playScale)
        }
    }

    /// Keys transpose for the Play keyboard (screen keys and MIDI keys alike).
    @ViewBuilder
    private var transposeButton: some View {
        if let p = perf {
            KeysTransposeMenu(channel: p, help: .playTranspose)
        }
    }

    /// Chromatic is saved as nil: it is the same as every key.
    private func setScale(_ scale: PlayKeyboardScale?) {
        let value = (scale?.limitsKeys ?? false) ? scale : nil
        guard songStore.song.playKeyboardScale != value else { return }
        // Keys held on screen are released by the keyboard itself; this only changes
        // which keys play from now on.
        songStore.song.playKeyboardScale = value
    }

    // One row, so in the two-row header it takes the spare width as a whole and the
    // slider and meter share it as before. (Placed one by one in RowOrTwoRows, the
    // meter got its frame but did not draw on iOS 16.)
    @ViewBuilder
    private var volumeControls: some View {
        if perf != nil {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
                StudioSlider.volume(volumeBinding, label: "Manual keyboard volume")
                    .midiLearnable(.playVolume)
                    .helpTag(.playVolume)
                    .frame(minWidth: 80, maxWidth: 160)
                if let p = perf {
                    SongTrackMeter(trackID: p.id)
                    // The same channel buttons as a track's, so the Play keyboard can be
                    // muted, soloed and have its effects switched here as on the mixer.
                    StudioToggleChip(title: "M", isOn: mixerFlag(\.isMuted), tint: .orange,
                                     accessibilityLabel: "Mute Play keyboard")
                        .midiLearnable(.playMute)
                        .helpTag(.playMute)
                    StudioToggleChip(title: "S", isOn: mixerFlag(\.isSoloed), tint: .yellow,
                                     accessibilityLabel: "Solo Play keyboard")
                        .midiLearnable(.playSolo)
                        .helpTag(.playSolo)
                    EffectsToggleButton(track: p)
                        .midiLearnable(.playEffects)
                        .helpTag(.playEffects)
                }
            }
            .compactRow(.secondFlexible)
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
        .helpTag(.playClose)
    }

    private var pluginBinding: Binding<PluginInfo?> {
        Binding(get: { songStore.song.performance?.pluginInfo },
                set: { newInfo in songStore.setPerformancePlugin(newInfo) })
    }

    private func mixerFlag(_ flag: WritableKeyPath<MixerState, Bool>) -> Binding<Bool> {
        Binding(get: { songStore.song.performance?.mixer[keyPath: flag] ?? false },
                set: { songStore.song.performance?.mixer[keyPath: flag] = $0 })
    }

    private var volumeBinding: Binding<Float> {
        Binding(get: { songStore.song.performance?.mixer.volume ?? 0.8 },
                set: { songStore.setPerformanceVolume($0) })
    }

    private func releaseAll() {
        guard let id = perf?.id else { activeNotes.removeAll(); sentNotes.removeAll(); return }
        for note in activeNotes {
            AudioEngineManager.shared.stopNote(trackID: id, midiNote: sentNotes[note] ?? note)
        }
        activeNotes.removeAll()
        sentNotes.removeAll()
    }
}

// MARK: - Playable keyboard (wide keys, multi-touch, slide between notes, chromatic)

private struct PlayableKeyboard: View {
    /// The Play keyboard's instrument, to light keys held on a MIDI controller.
    let performanceID: UUID
    /// Keys outside it are dimmed and play nothing. nil: every key plays.
    let scale: PlayKeyboardScale?
    @EnvironmentObject private var playback: PlaybackMonitor
    let onNoteOn: (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lowMidi = 36    // C2
    private static let highMidi = 84   // C6 (≈4 octaves; ~2–3 visible at a time)
    private static func isWhite(_ m: Int) -> Bool { [0,2,4,5,7,9,11].contains(m % 12) }
    private static let whiteKeys: [Int] = (lowMidi...highMidi).filter { isWhite($0) }
    private static let blackKeys: [Int] = (lowMidi...highMidi).filter { !isWhite($0) }
    /// White keys with a black key just above them (C, D, F, G, A), within the range.
    private static let hasBlackAfter: Set<Int> =
        Set(whiteKeys.filter { $0 + 1 <= highMidi && !isWhite($0 + 1) })
    private static let whiteIndex: [Int: Int] =
        Dictionary(uniqueKeysWithValues: whiteKeys.enumerated().map { ($1, $0) })

    private let whiteW: CGFloat = 70   // wide, easy to play
    private let keyH: CGFloat = 132
    private var blackW: CGFloat { whiteW * 0.6 }
    private var blackH: CGFloat { keyH * 0.62 }
    private var totalW: CGFloat { CGFloat(Self.whiteKeys.count) * whiteW }

    @State private var centerC = 60   // middle C — octave-button target (always a C = white)
    /// Notes currently held by a finger, for drawing them pressed.
    @State private var held = Set<Int>()
    /// Notes held on a MIDI controller routed to the Play keyboard.
    private var controllerHeld: Set<Int> { playback.heldKeys[performanceID] ?? [] }

    private func plays(_ m: Int) -> Bool {
        guard let scale, scale.limitsKeys else { return true }
        return scale.allows(m)
    }

    private var layout: KeyboardLayout {
        KeyboardLayout(whiteKeys: Self.whiteKeys, whiteWidth: whiteW,
                       blackKeys: Self.blackKeys.map { (midi: $0, x: blackX($0)) },
                       blackWidth: blackW, blackHeight: blackH)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Button { shift(-12) } label: {
                    Label("Octave", systemImage: "chevron.left").font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(centerC <= Self.lowMidi)
                .helpTag(.playOctave, instance: "down")

                Spacer()
                Text("C\(centerC / 12 - 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()

                Button { shift(12) } label: {
                    Label("Octave", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(centerC >= Self.highMidi - 12)
                .helpTag(.playOctave, instance: "up")
            }
            .padding(.horizontal, 8)

            // No scroll view any more: sliding a finger along the keys now PLAYS them,
            // so a drag cannot also scroll. The octave buttons move the view instead.
            // (The scroll view was also one of the ways a touch got taken from a key
            // mid-press, leaving its note hanging.)
            GeometryReader { geo in
                let visible = geo.size.width
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(Self.whiteKeys, id: \.self) { m in
                            PlayKey(midi: m, isBlack: false, width: whiteW, height: keyH,
                                    pressed: held.contains(m) || controllerHeld.contains(m),
                                    enabled: plays(m),
                                    onNoteOn: onNoteOn, onNoteOff: onNoteOff)
                                .overlay(alignment: .bottom) { octaveLabel(m) }
                        }
                    }
                    // The black keys as one row, like the white keys: each white key's
                    // slot carries the black key on its right-hand edge. Placed one by
                    // one (each offset from the left end), iPadOS 16 and 17 did not draw
                    // them once the keyboard was slid to the middle octave: they still
                    // played but were invisible until an octave change redrew them
                    // (Graham, 2026-11-26; reproduced on iOS 16.4 and 17.5 simulators,
                    // and this row fixes it there; iPadOS 26 drew them either way).
                    HStack(spacing: 0) {
                        ForEach(Self.whiteKeys, id: \.self) { w in
                            Color.clear
                                .frame(width: whiteW, height: blackH)
                                .overlay(alignment: .topTrailing) {
                                    if Self.hasBlackAfter.contains(w) {
                                        let m = w + 1
                                        PlayKey(midi: m, isBlack: true, width: blackW, height: blackH,
                                                pressed: held.contains(m) || controllerHeld.contains(m),
                                                enabled: plays(m),
                                                onNoteOn: onNoteOn, onNoteOff: onNoteOff)
                                            .offset(x: blackW / 2)
                                    }
                                }
                        }
                    }
                }
                .frame(width: totalW, height: keyH, alignment: .topLeading)
                .keyboardCase()
                .overlay {
                    KeyboardTouchSurface(
                        keyAt: { layout.key(at: $0) },
                        // A key outside the scale plays nothing. A release is sent only
                        // for a note that was played, so changing the scale while a key
                        // is down still lets it go.
                        onPress: { note in
                            guard plays(note) else { return }
                            held.insert(note); onNoteOn(UInt8(note))
                        },
                        onRelease: { note in
                            if held.remove(note) != nil { onNoteOff(UInt8(note)) }
                        }
                    )
                    // VoiceOver plays the keys through their own actions instead.
                    .accessibilityHidden(true)
                }
                .offset(x: -scrollOffset(visible: visible))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: centerC)
                .frame(width: visible, height: keyH, alignment: .topLeading)
                .clipped()
            }
            .frame(height: keyH)
            // On the keys only, so the octave buttons above keep their own help.
            .helpTag(.playKeys)
        }
    }

    /// How far the keyboard is slid left so the chosen C sits in the middle, without
    /// running past either end.
    private func scrollOffset(visible: CGFloat) -> CGFloat {
        let centre = CGFloat(Self.whiteIndex[centerC] ?? 0) * whiteW + whiteW / 2
        return min(max(0, centre - visible / 2), max(0, totalW - visible))
    }

    @ViewBuilder
    private func octaveLabel(_ m: Int) -> some View {
        if m % 12 == 0 {
            Text("C\(m / 12 - 1)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.bottom, 9).allowsHitTesting(false)
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

/// A single key's look and its VoiceOver action. Touch is handled for the whole
/// keyboard by KeyboardTouchSurface, which is what lets a finger slide between keys.
private struct PlayKey: View {
    let midi: Int
    let isBlack: Bool
    let width: CGFloat
    let height: CGFloat
    let pressed: Bool
    /// In the Play keyboard's scale. Outside it the key is dimmed and plays nothing.
    var enabled: Bool = true
    let onNoteOn: (UInt8) -> Void
    let onNoteOff: (UInt8) -> Void

    private var noteName: String {
        let names = ["C", "C sharp", "D", "D sharp", "E", "F",
                     "F sharp", "G", "G sharp", "A", "A sharp", "B"]
        return "\(names[midi % 12]) \(midi / 12 - 1)"
    }

    var body: some View {
        PianoKeyFace(isBlack: isBlack,
                     tint: pressed ? .colored(.accentColor) : (enabled ? .natural : .dimmed),
                     pressed: pressed, width: width, height: height)
            .frame(width: width, height: height)
            .accessibilityElement()
            .accessibilityLabel(noteName)
            .accessibilityValue(pressed ? "Playing" : (enabled ? "Ready" : "Outside the scale"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard enabled else { return }
                onNoteOn(UInt8(midi))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onNoteOff(UInt8(midi)) }
            }
    }
}
