import SwiftUI

struct TrackRowView: View {
    @Binding var track: Track
    @Binding var isCollapsed: Bool
    @EnvironmentObject var store: ProjectStore
    var index: Int = 0
    var trackCount: Int = 1
    var onDelete: () -> Void

    @State private var showNoteParams = false
    @State private var showSteps = false
    @State private var showDeleteAlert = false
    @State private var showPluginPicker = false
    @State private var showScalePicker = false
    @State private var showPluginEditor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Collapsed bar (always visible) ──────────────────────
            collapsedBar

            // ── Expanded content ─────────────────────────────────────
            if !isCollapsed {
                Divider()
                expandedContent
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: track.pluginInfo) { newPlugin in
            store.setPlugin(newPlugin, for: track.id)
        }
        .onChange(of: track.scale) { _ in pruneNotePool() }
        .onChange(of: track.key)   { _ in pruneNotePool() }
        .sheet(isPresented: $showNoteParams) {
            NoteParametersView(notePool: $track.notePool)
        }
        .sheet(isPresented: $showSteps) {
            StepsView(steps: $track.steps)
        }
        .sheet(isPresented: $showPluginPicker) {
            PluginPickerView(selectedPlugin: $track.pluginInfo)
        }
        .sheet(isPresented: $showScalePicker) {
            ScalePickerView(selectedScale: $track.scale)
        }
        .fullScreenCover(isPresented: $showPluginEditor) {
            PluginEditorView(trackID: track.id, trackName: track.name,
                             onCommitState: { store.capturePluginState(for: track.id) })
        }
        .alert("Delete \"\(track.name)\"?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Collapsed bar

    private var collapsedBar: some View {
        HStack(spacing: 10) {
            // Expand / collapse chevron
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            // Playing dot
            TrackPlayingDot(trackID: track.id)

            // Track name
            Text(track.name)
                .font(.subheadline.bold())
                .lineLimit(1)
                .frame(minWidth: 60, alignment: .leading)

            Divider().frame(height: 16)

            // Instrument + division
            Text(track.pluginInfo?.name ?? "GM")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 80, alignment: .leading)

            Text(track.tempoDivision.abbreviation)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider().frame(height: 16)

            // Key + scale
            Text("\(noteNames[track.key]) \(track.scale.rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: 100, alignment: .leading)

            Divider().frame(height: 16)

            // Mini step indicators
            if !track.steps.isEmpty {
                TrackStepStrip(trackID: track.id, steps: track.steps, compact: true)
                    .frame(width: 180)
            } else {
                Text("\(track.notePool.count) notes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Compact volume slider
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.1")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: $track.mixer.volume, in: 0...1)
                    .frame(width: 70)
            }

            Divider().frame(height: 16)

            // Mini level meter
            TrackLevelMeter(trackID: track.id)

            Divider().frame(height: 16)

            // Mute / Solo
            Toggle("M", isOn: $track.mixer.isMuted)
                .toggleStyle(.button).tint(.orange)
                .font(.caption2.bold())
            Toggle("S", isOn: $track.mixer.isSoloed)
                .toggleStyle(.button).tint(.yellow)
                .font(.caption2.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Expanded content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header row 1: sound controls ────────────────────────
            HStack(spacing: 6) {
                TextField("Name", text: $track.name)
                    .font(.subheadline.bold())
                    .frame(minWidth: 70, maxWidth: 110)

                Divider().frame(height: 20)

                // Key
                Picker("", selection: $track.key) {
                    ForEach(0..<12, id: \.self) { n in Text(noteNames[n]).tag(n) }
                }
                .pickerStyle(.menu)
                .fixedSize()

                // Scale
                Button { showScalePicker = true } label: {
                    Text(track.scale.rawValue)
                        .font(.caption).lineLimit(1)
                }
                .buttonStyle(.bordered)

                Divider().frame(height: 20)

                // Division
                Picker("", selection: $track.tempoDivision) {
                    ForEach(TempoDivision.allCases, id: \.self) {
                        Text($0.abbreviation).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Divider().frame(height: 20)

                // Plugin
                Button { showPluginPicker = true } label: {
                    Label(
                        track.pluginInfo?.name ?? "Plugin",
                        systemImage: track.pluginInfo == nil
                            ? "puzzlepiece.extension"
                            : "puzzlepiece.extension.fill"
                    )
                    .font(.caption).lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(track.pluginInfo == nil ? nil : .accentColor)

                // Edit plugin UI — only shown when an AUv3 is loaded
                if track.pluginInfo != nil {
                    Button { showPluginEditor = true } label: {
                        Label("Edit Sound", systemImage: "slider.horizontal.3")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                }

                Spacer()

                // Track management actions
                Text("\(track.notePool.count) notes")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider().frame(height: 16)

                Button { store.moveTrackUp(at: index) } label: {
                    Image(systemName: "chevron.up").font(.caption)
                }
                .buttonStyle(.plain).disabled(index == 0)

                Button { store.moveTrackDown(at: index) } label: {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .buttonStyle(.plain).disabled(index == trackCount - 1)

                Button { store.copyTrack(at: index) } label: {
                    Image(systemName: "plus.square.on.square").font(.caption)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) { showDeleteAlert = true } label: {
                    Image(systemName: "trash").foregroundColor(.red).font(.caption)
                }
                .buttonStyle(.plain)
            }

            // ── Mini mixer strip ─────────────────────────────────────
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2).foregroundStyle(.secondary)
                Slider(value: $track.mixer.volume, in: 0...1)
                    .frame(width: 90)
                Text("\(Int(track.mixer.volume * 100))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 26)

                Divider().frame(height: 14)

                Text("Pan").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $track.mixer.pan, in: -1...1)
                    .frame(width: 80)
                Text(panLabel)
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 30)

                Divider().frame(height: 14)

                Toggle("M", isOn: $track.mixer.isMuted)
                    .toggleStyle(.button).tint(.orange).font(.caption2.bold())
                Toggle("S", isOn: $track.mixer.isSoloed)
                    .toggleStyle(.button).tint(.yellow).font(.caption2.bold())

                Spacer()
            }

            // ── Step indicator ───────────────────────────────────────
            if !track.steps.isEmpty {
                TrackStepStrip(trackID: track.id, steps: track.steps)
            }

            // ── 88-key keyboard ──────────────────────────────────────
            TrackKeyboard(
                trackID: track.id,
                notePool: $track.notePool,
                scale: track.scale,
                key: track.key,
                onPreview: { midi in
                    let midiNote = UInt8(midi)
                    store.audioEngine.playNote(trackID: track.id, midiNote: midiNote, velocity: 100)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        store.audioEngine.stopNote(trackID: track.id, midiNote: midiNote)
                    }
                }
            )

            // ── Action buttons ───────────────────────────────────────
            HStack(spacing: 10) {
                Button {
                    showNoteParams = true
                } label: {
                    Label("Note Params", systemImage: "slider.vertical.3")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(track.notePool.isEmpty)

                Button {
                    showSteps = true
                } label: {
                    Label(track.steps.isEmpty ? "Steps" : "Steps (\(track.steps.count))",
                          systemImage: "list.number")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
    }

    // MARK: - Helpers

    private var panLabel: String {
        let p = track.mixer.pan
        if abs(p) < 0.05 { return "C" }
        return p < 0 ? "L\(Int(abs(p) * 100))" : "R\(Int(p * 100))"
    }

    private func pruneNotePool() {
        track.notePool.removeAll { entry in
            let semitone = ((entry.midiNote % 12) - track.key + 12) % 12
            return !track.scale.intervals.contains(semitone)
        }
    }

    private let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
}

// MARK: - Telemetry leaf views
//
// Each observes ONLY the relevant monitor so a playback update re-renders just
// the small element that changed — not the whole (per-track) TrackRowView.

private struct TrackPlayingDot: View {
    let trackID: UUID
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        let isPlaying = playback.playingNotes[trackID] != nil
        Circle()
            .fill(isPlaying ? Color.green : Color.secondary.opacity(0.25))
            .frame(width: 8, height: 8)
            .animation(.easeInOut(duration: 0.1), value: isPlaying)
    }
}

private struct TrackLevelMeter: View {
    let trackID: UUID
    @EnvironmentObject var levels: LevelMonitor

    var body: some View {
        let level = levels.trackLevels[trackID] ?? 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(meterColor(level))
                    .frame(width: geo.size.width * CGFloat(min(1, level)))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(width: 50, height: 6)
    }

    private func meterColor(_ level: Float) -> Color {
        if level > 0.85 { return .red }
        if level > 0.6  { return .orange }
        if level > 0.3  { return .yellow }
        return .green
    }
}

private struct TrackStepStrip: View {
    let trackID: UUID
    let steps: [Step]
    var compact: Bool = false
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        let active = playback.activeSteps[trackID]
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: compact ? 3 : 4) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    let isActive = active == idx
                    Text(step.label)
                        .font(.system(size: compact ? 8 : 10,
                                      weight: isActive ? .bold : .regular,
                                      design: .monospaced))
                        .foregroundStyle(isActive ? .black : .secondary)
                        .padding(.horizontal, compact ? 4 : 6)
                        .padding(.vertical, compact ? 2 : 3)
                        .background(
                            isActive ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: compact ? 3 : 4)
                        )
                        .animation(.easeInOut(duration: 0.08), value: isActive)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, compact ? 0 : 2)
        }
    }
}

// Wraps the keyboard so only it (not the whole row) re-renders on note events.
private struct TrackKeyboard: View {
    let trackID: UUID
    @Binding var notePool: [NoteEntry]
    let scale: MusicalScale
    let key: Int
    let onPreview: (Int) -> Void
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        PianoKeyboardView(
            notePool: $notePool,
            scale: scale,
            playingNote: playback.playingNotes[trackID],
            key: key,
            onPreview: onPreview
        )
    }
}
