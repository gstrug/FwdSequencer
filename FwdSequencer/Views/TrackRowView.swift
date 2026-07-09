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

    private var activeStep: Int? { store.activeSteps[track.id] }
    private var isPlaying: Bool { store.playingNotes[track.id] != nil }
    private var level: Float { store.trackLevels[track.id] ?? 0 }

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
            Circle()
                .fill(isPlaying ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.1), value: isPlaying)

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

            // Mini step indicators
            if !track.steps.isEmpty {
                miniStepIndicators
            } else {
                Text("\(track.notePool.count) notes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Mini level meter
            miniLevelMeter

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

    private var miniStepIndicators: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(track.steps.enumerated()), id: \.element.id) { idx, step in
                    let isActive = activeStep == idx
                    Text(step.type.abbreviation)
                        .font(.system(size: 8, weight: isActive ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(isActive ? .black : .secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            isActive ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                        .animation(.easeInOut(duration: 0.08), value: isActive)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(width: 180)
    }

    private var miniLevelMeter: some View {
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

    // MARK: - Expanded content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {

            // ── Header ──────────────────────────────────────────────
            HStack(spacing: 8) {
                TextField("Name", text: $track.name)
                    .font(.subheadline.bold())
                    .frame(minWidth: 80, maxWidth: 120)

                Divider().frame(height: 20)

                Picker("", selection: $track.key) {
                    ForEach(0..<12, id: \.self) { n in
                        Text(noteNames[n]).tag(n)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Picker("", selection: $track.scale) {
                    ForEach(MusicalScale.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Divider().frame(height: 20)

                Picker("", selection: $track.tempoDivision) {
                    ForEach(TempoDivision.allCases, id: \.self) {
                        Text($0.rawValue).tag($0)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()

                Divider().frame(height: 20)

                Button {
                    showPluginPicker = true
                } label: {
                    Label(
                        track.pluginInfo?.name ?? "Plugin",
                        systemImage: track.pluginInfo == nil
                            ? "puzzlepiece.extension"
                            : "puzzlepiece.extension.fill"
                    )
                    .font(.caption)
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(track.pluginInfo == nil ? nil : .accentColor)

                Spacer()

                Text("\(track.notePool.count) notes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button { store.moveTrackUp(at: index) } label: {
                    Image(systemName: "chevron.up").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)

                Button { store.moveTrackDown(at: index) } label: {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(index == trackCount - 1)

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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(track.steps.enumerated()), id: \.element.id) { idx, step in
                            let isActive = activeStep == idx
                            Text(step.type.abbreviation)
                                .font(.system(size: 10,
                                              weight: isActive ? .bold : .regular,
                                              design: .monospaced))
                                .foregroundStyle(isActive ? .black : .secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    isActive ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                                .animation(.easeInOut(duration: 0.08), value: isActive)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }

            // ── 88-key keyboard ──────────────────────────────────────
            PianoKeyboardView(
                notePool: $track.notePool,
                scale: track.scale,
                playingNote: store.playingNotes[track.id],
                key: track.key
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
