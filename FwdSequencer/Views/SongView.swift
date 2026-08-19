import SwiftUI

// MARK: - SongView
//
// Song editor: transport, an arrangement strip of sections, and track rows split
// into a constant "instrument zone" and a per-section "note zone" bound to the
// currently selected section. Parallels ProjectView. See SONG_MODE_PLAN.md.

struct SongView: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPlayDock = false

    var body: some View {
        VStack(spacing: 0) {
            SongTransportBar(onBack: {
                songStore.close { saved in
                    if saved { dismiss() }
                }
            }, showPlayDock: $showPlayDock)

            ArrangementStrip()

            SectionSettingsBar()

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 12) {
                    // Identity-based binding ForEach — safe to delete from (an index-based
                    // ForEach crashes when the array shrinks and a stale index binding is
                    // still evaluated).
                    ForEach($songStore.song.tracks) { $track in
                        SongTrackRowView(
                            track: $track,
                            part: partBinding(trackID: track.id),
                            index: songStore.song.tracks.firstIndex(where: { $0.id == track.id }) ?? 0,
                            trackCount: songStore.song.tracks.count,
                            isCollapsed: Binding(
                                get: { track.collapsed ?? false },
                                set: { $track.wrappedValue.collapsed = $0 }
                            )
                        )
                    }

                    Button {
                        songStore.addTrack()
                    } label: {
                        Label("Add Track", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                            .padding(10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(songStore.song.tracks.count >= SongStore.maximumEditableTrackCount)
                }
                .padding(12)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear { songStore.activate() }
        // Override the environment monitors for this subtree so telemetry routes
        // to the song's monitors, not the pattern store's.
        .environmentObject(songStore.levels)
        .environmentObject(songStore.playback)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showPlayDock {
                PlayDockView(onClose: {
                    if reduceMotion { showPlayDock = false }
                    else { withAnimation { showPlayDock = false } }
                })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showPlayDock)
        // BLOCKING while instruments load/restore — this must capture touches.
        // Engine-side track suspension only gates sequencer MIDI; it does not stop the
        // user opening a plugin's UI, swapping the plugin again, or playing keys during
        // the ~1–2 s instantiate+restore window. Interrupting a fragile AUv3 (GeoShred)
        // in that window crashes its extension, so input is blocked until it finishes.
        // Do not add .allowsHitTesting(false) here. See PLUGIN_HOSTING.md §2.
        .overlay {
            if songStore.isLoading {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("Restoring instruments…")
                            .font(.title3.bold()).foregroundStyle(.white)
                        Text("Please wait — don't tap yet")
                            .font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(36)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .contentShape(Rectangle())   // capture every touch in the overlay
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: songStore.isLoading)
        .alert("FWD Sequencer", isPresented: Binding(
            get: { songStore.notice != nil },
            set: { if !$0 { songStore.notice = nil } }
        )) {
            Button("OK") { songStore.notice = nil }
        } message: {
            Text(songStore.notice ?? "")
        }
        .interactiveDismissDisabled()
    }

    /// Binding to a track's Part in the currently selected section. Falls back to
    /// an empty Part if the section/part can't be found (keeps the editor stable
    /// during section add/delete churn).
    private func partBinding(trackID: UUID) -> Binding<Part> {
        Binding(
            get: {
                let sel = songStore.selectedSection
                guard songStore.song.sections.indices.contains(sel),
                      let p = songStore.song.sections[sel].parts.first(where: { $0.trackID == trackID })
                else { return Part(trackID: trackID) }
                return p
            },
            set: { newValue in
                let sel = songStore.selectedSection
                guard songStore.song.sections.indices.contains(sel) else { return }
                if let pi = songStore.song.sections[sel].parts.firstIndex(where: { $0.trackID == trackID }) {
                    songStore.song.sections[sel].parts[pi] = newValue
                } else {
                    songStore.song.sections[sel].parts.append(newValue)
                }
            }
        )
    }
}

// MARK: - Transport

private struct SongTransportBar: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onBack: () -> Void
    @Binding var showPlayDock: Bool
    @State private var currentBeat: Int = 0
    @State private var tapTimes: [Date] = []
    @State private var savedVisible = false
    @State private var showMixer = false
    @State private var selectAllSongName = false
    @State private var exportingRecording = false
    @State private var recordingDocument: AudioRecordingDocument?
    /// A finished take waiting for the user to pick an export format.
    @State private var finishedRecordingURL: URL?
    @State private var recordingFormat: RecordingFormat = .wav

    private var beatCount: Int { songStore.song.timeSignature.numerator }
    private var currentSectionBars: Int {
        let idx = songStore.currentSection
        return songStore.song.sections.indices.contains(idx) ? songStore.song.sections[idx].numberOfBars : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            // ── Row 1: playback ──────────────────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").iconHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to songs")

                Divider().frame(height: 26)

                Button { songStore.rewind() } label: {
                    Image(systemName: "backward.end.fill").iconHitTarget()
                        .foregroundStyle(songStore.isPlaying || songStore.isPaused ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewind song")

                Button {
                    if songStore.isPlaying      { songStore.pause() }
                    else if songStore.isPaused  { songStore.resume() }
                    else                        { songStore.play() }
                } label: {
                    Image(systemName: songStore.isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.green).iconHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(songStore.isPlaying ? "Pause song" : "Play song")

                Button { songStore.stop() } label: {
                    Image(systemName: "stop.fill").iconHitTarget()
                        .foregroundStyle(songStore.isPlaying || songStore.isPaused ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop song")

                Button { toggleRecording() } label: {
                    Image(systemName: songStore.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(songStore.isRecording ? .red : .secondary)
                        .iconHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(songStore.isRecording ? "Stop and export recording" : "Record master output")

                // MIDI panic — needs to be one tap on the transport, not buried in a
                // menu: it is what you reach for when a note hangs mid-performance.
                Button { songStore.midiPanic() } label: {
                    Image(systemName: "exclamationmark.octagon.fill").iconHitTarget()
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Panic — stop all notes")
                .accessibilityLabel("Panic, stop all notes")

                Button { songStore.loopEnabled.toggle() } label: {
                    Image(systemName: "repeat").iconHitTarget()
                        .foregroundStyle(songStore.loopEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Loop song")
                .accessibilityLabel("Loop song")
                .accessibilityValue(songStore.loopEnabled ? "On" : "Off")

                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.bold()).foregroundStyle(.green)
                        .opacity(savedVisible ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: savedVisible)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            // ── Row 2: song settings + panels ────────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("BPM").font(.caption).foregroundStyle(.secondary)
                            Text("\(Int(songStore.song.tempo))")
                                .font(.caption.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                            Stepper("", value: $songStore.song.tempo, in: 20...400, step: 1)
                                .labelsHidden()
                            Button { handleTap() } label: {
                                Label("Tap", systemImage: "hand.tap.fill").font(.caption)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        }

                        Divider().frame(height: 26)

                        HStack(spacing: 4) {
                            ForEach(0..<beatCount, id: \.self) { beat in
                                let isActive = songStore.isPlaying && beat == currentBeat
                                Circle()
                                    .fill(isActive ? (beat == 0 ? Color.red : Color.green) : Color.gray.opacity(0.25))
                                    .frame(width: 10, height: 10)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isActive)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Beat \(currentBeat + 1) of \(beatCount)")

                        Divider().frame(height: 26)
                        SongBarCounter(totalBars: currentSectionBars)
                        Divider().frame(height: 26)

                        HStack(spacing: 4) {
                            Text("Time").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $songStore.song.timeSignature.numerator) {
                                ForEach(1...32, id: \.self) { Text("\($0)").tag($0) }
                            }.pickerStyle(.menu).fixedSize()
                            Text("/").font(.body.bold()).foregroundStyle(.secondary)
                            Picker("", selection: $songStore.song.timeSignature.denominator) {
                                ForEach([1,2,4,8,16,32], id: \.self) { Text("\($0)").tag($0) }
                            }.pickerStyle(.menu).fixedSize()
                        }

                        Divider().frame(height: 26)

                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2).foregroundStyle(.secondary)
                            Slider(value: $songStore.song.masterVolume, in: 0...1)
                                .frame(width: 130)
                                .accessibilityLabel("Master volume")
                        }

                        Divider().frame(height: 26)

                        SelectAllTextField(
                            text: $songStore.song.name,
                            placeholder: "Song Name",
                            font: .preferredBold(.subheadline),
                            selectAllTrigger: $selectAllSongName
                        )
                        .frame(minWidth: 120, maxWidth: 240)
                        .onLongPressGesture { selectAllSongName = true }
                Button { showPlayDock.toggle() } label: {
                    Label("Play", systemImage: "pianokeys")
                }
                .buttonStyle(.bordered)
                .tint(showPlayDock ? .accentColor : nil)

                Button { showMixer = true } label: {
                    Label("Mixer", systemImage: "slider.vertical.3")
                }
                .buttonStyle(.bordered)

                Menu {
                    Section("Time Signature") {
                        Picker("Beats per Bar", selection: $songStore.song.timeSignature.numerator) {
                            ForEach(1...32, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Picker("Beat Unit", selection: $songStore.song.timeSignature.denominator) {
                            ForEach([1,2,4,8,16,32], id: \.self) { Text("1/\($0)").tag($0) }
                        }
                    }
                    Button { songStore.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!songStore.canUndo)
                    Button { songStore.redo() } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!songStore.canRedo)
                    Divider()
                    Toggle(isOn: $songStore.midiClockEnabled) {
                        Label("MIDI Clock Output", systemImage: "cable.connector")
                    }
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showMixer) {
            SongMixerView()
                .environmentObject(songStore)
                .environmentObject(songStore.levels)
        }
        .fileExporter(isPresented: $exportingRecording,
                      document: recordingDocument,
                      contentType: recordingFormat.contentType,
                      defaultFilename: recordingFilename) { result in
            if case .failure(let error) = result { songStore.notice = error.localizedDescription }
            recordingDocument = nil
        }
        .confirmationDialog("Export recording as",
                            isPresented: Binding(get: { finishedRecordingURL != nil },
                                                 set: { if !$0 { discardFinishedRecording() } }),
                            titleVisibility: .visible) {
            ForEach(RecordingFormat.allCases) { format in
                Button(format.displayName) { exportRecording(as: format) }
            }
            Button("Discard", role: .destructive) { discardFinishedRecording() }
        } message: {
            Text(RecordingFormat.allCases.map { "\($0.displayName) — \($0.detail)" }
                    .joined(separator: "\n"))
        }
        .onReceive(songStore.savedSignal) {
            savedVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedVisible = false }
        }
        .onReceive(songStore.beatSignal) { isDownbeat in
            if isDownbeat { currentBeat = 0 }
            else { currentBeat = (currentBeat + 1) % max(1, beatCount) }
        }
        .onChange(of: songStore.isPlaying) { playing in
            if !playing { currentBeat = 0 }
        }
    }

    private func handleTap() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropLast(), tapTimes.dropFirst()).map { $1.timeIntervalSince($0) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        songStore.song.tempo = min(400, max(20, (60.0 / avg).rounded()))
    }

    private var recordingFilename: String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let name = songStore.song.name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "FWD" : name) + " Recording"
    }

    /// Convert the finished take to the chosen format and hand it to the exporter.
    private func exportRecording(as format: RecordingFormat) {
        guard let url = finishedRecordingURL else { return }
        finishedRecordingURL = nil
        do {
            let prepared = try RecordingExporter.prepare(url, as: format)
            recordingFormat = format
            recordingDocument = AudioRecordingDocument(data: prepared.data)
            exportingRecording = true
            // Keep a copy in the app's Exports folder so the take is never lost just
            // because the location picker was dismissed.
            var message: [String] = []
            if prepared.didClip {
                message.append(String(
                    format: "The mix peaked at %+.1f dBFS, so this %@ file is clipped. "
                          + "Lower the levels and record again, or export as CAF to keep the "
                          + "take exactly as played.",
                    prepared.peakDBFS, format.displayName))
            }
            if let saved = SongStorage.saveToExports(prepared.data,
                                                     name: recordingFilename,
                                                     fileExtension: format.fileExtension) {
                message.append(SongStorage.exportLocationDescription(for: saved))
            }
            if !message.isEmpty { songStore.notice = message.joined(separator: "\n\n") }
        } catch {
            songStore.notice = error.localizedDescription
        }
        songStore.discardRecording(at: url)
    }

    private func discardFinishedRecording() {
        if let url = finishedRecordingURL { songStore.discardRecording(at: url) }
        finishedRecordingURL = nil
    }

    private func toggleRecording() {
        do {
            if songStore.isRecording {
                // Ask which format before converting — see the confirmationDialog below.
                finishedRecordingURL = try songStore.finishRecording()
            } else {
                try songStore.beginRecording()
            }
        } catch {
            songStore.notice = error.localizedDescription
        }
    }
}

// Enlarge a small icon button's tap target (and glyph) for easier touch use.
private extension View {
    func iconHitTarget(_ size: CGFloat = 36) -> some View {
        self.font(.title3)
            .frame(width: max(44, size), height: max(44, size))
            .contentShape(Rectangle())
    }
}

// MARK: - Arrangement strip

private struct ArrangementStrip: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renaming: Int? = nil
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Identity-based so deleting a section can't crash on a stale index.
                        ForEach(Array(songStore.song.sections.enumerated()), id: \.element.id) { idx, section in
                            chip(idx, section).id(section.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: songStore.selectedSection) { index in
                    guard songStore.song.sections.indices.contains(index) else { return }
                    if reduceMotion {
                        proxy.scrollTo(songStore.song.sections[index].id, anchor: .center)
                    } else {
                        withAnimation { proxy.scrollTo(songStore.song.sections[index].id, anchor: .center) }
                    }
                }
            }

            let sel = songStore.selectedSection
            Menu {
                Button { songStore.addSection() } label: {
                    Label("Add Section", systemImage: "plus")
                }
                .disabled(songStore.song.sections.count >= SongStore.maximumEditableSectionCount)
                Button { songStore.duplicateSection(at: sel) } label: {
                    Label("Duplicate Selected", systemImage: "plus.square.on.square")
                }
                .disabled(songStore.song.sections.count >= SongStore.maximumEditableSectionCount)
                Divider()
                Button { songStore.moveSection(from: sel, to: sel - 1) } label: {
                    Label("Move Earlier", systemImage: "arrow.left")
                }
                .disabled(sel <= 0)
                Button { songStore.moveSection(from: sel, to: sel + 1) } label: {
                    Label("Move Later", systemImage: "arrow.right")
                }
                .disabled(sel >= songStore.song.sections.count - 1)
                Divider()
                Button(role: .destructive) { songStore.deleteSection(at: sel) } label: {
                    Label("Delete Selected", systemImage: "trash")
                }
                .disabled(songStore.song.sections.count <= 1)
            } label: {
                Label("Section", systemImage: "ellipsis.circle")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .padding(.trailing, 8)
        }
        .background(.regularMaterial)
        .alert("Rename Section", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let i = renaming, songStore.song.sections.indices.contains(i) {
                    songStore.song.sections[i].name = String(renameText.prefix(SongValidator.maximumNameLength))
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func chip(_ idx: Int, _ section: SongSection) -> some View {
        let isSelected = songStore.selectedSection == idx
        let isPlaying  = songStore.isPlaying && songStore.currentSection == idx

        VStack(spacing: 2) {
            Text(section.name).font(.caption.bold()).lineLimit(1)
            Text("\(section.numberOfBars) bar\(section.numberOfBars == 1 ? "" : "s")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 84)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPlaying ? Color.green : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { songStore.selectedSection = idx }
        .onLongPressGesture {
            renameText = section.name
            renaming = idx
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Section \(idx + 1), \(section.name)")
        .accessibilityValue(
            "\(section.numberOfBars) bars"
                + (isSelected ? ", selected" : "")
                + (isPlaying ? ", playing" : "")
        )
        .accessibilityAction { songStore.selectedSection = idx }
        .accessibilityAction(named: Text("Rename section")) {
            renameText = section.name
            renaming = idx
        }
    }
}

// MARK: - Section settings (bars / key / scale for the selected section)

private struct SectionSettingsBar: View {
    @EnvironmentObject var songStore: SongStore
    @State private var selectAllName = false

    var body: some View {
        let sel = songStore.selectedSection
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if songStore.song.sections.indices.contains(sel) {
                Image(systemName: "square.stack").foregroundStyle(.secondary)
                // Inline, editable name — same as track naming: long-press to select all.
                SelectAllTextField(
                    text: $songStore.song.sections[sel].name,
                    placeholder: "Section",
                    font: .preferredBold(.caption1),
                    selectAllTrigger: $selectAllName
                )
                .frame(maxWidth: 160)
                .onLongPressGesture { selectAllName = true }
                // Rebuild the field when the selected section changes, so the reused
                // UITextField can't carry a stale cursor/text between sections.
                .id(songStore.song.sections[sel].id)

                Divider().frame(height: 20)

                Text("Bars").font(.caption).foregroundStyle(.secondary)
                Stepper(value: $songStore.song.sections[sel].numberOfBars, in: 1...256) {
                    Text("\(songStore.song.sections[sel].numberOfBars)")
                        .font(.caption.monospacedDigit()).frame(minWidth: 18)
                }
                .fixedSize()

                Divider().frame(height: 20)

                Menu {
                    ForEach(SectionTransform.allCases) { transform in
                        Button { songStore.transformSelectedSection(transform) } label: {
                            Label(transform.rawValue, systemImage: transform.systemImage)
                        }
                    }
                } label: {
                    Label("Transform", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .help("Reshape this section's notes and steps in place — a single undoable edit")

                Menu {
                    Button { songStore.captureVariation() } label: {
                        Label("Save Current Snapshot", systemImage: "camera")
                    }
                    .disabled(songStore.song.sections[sel].variations.count >= 32)

                    if !songStore.song.sections[sel].variations.isEmpty {
                        Divider()
                        ForEach(songStore.song.sections[sel].variations) { variation in
                            Menu(variation.name) {
                                Button { songStore.applyVariation(variation.id) } label: {
                                    Label("Apply", systemImage: "arrow.uturn.backward.circle")
                                }
                                Button(role: .destructive) {
                                    songStore.deleteVariation(variation.id)
                                } label: {
                                    Label("Delete Snapshot", systemImage: "trash")
                                }
                            }
                        }
                    }
                } label: {
                    Label(
                        "Variations \(songStore.song.sections[sel].variations.count)",
                        systemImage: "square.stack.3d.up"
                    )
                }
                .buttonStyle(.bordered)
                .help("Save and recall alternate versions without adding arrangement sections")

                Toggle(isOn: $songStore.followsPlayhead) {
                    Label("Follow", systemImage: "scope")
                }
                .toggleStyle(.button)
                .help("Keep the editor on the section currently playing")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

// MARK: - Song track row

private struct SongTrackRowView: View {
    @Binding var track: SongTrack
    @Binding var part: Part
    let index: Int
    let trackCount: Int
    @Binding var isCollapsed: Bool
    @EnvironmentObject var songStore: SongStore

    @State private var showPluginPicker = false
    @State private var showPluginEditor = false
    @State private var showSteps = false
    @State private var showNoteParams = false
    @State private var showScalePicker = false
    @State private var showDeleteAlert = false
    @State private var stepsBaseline: Song?
    @State private var noteParametersBaseline: Song?
    @State private var stepsSectionID: UUID?
    @State private var noteParametersSectionID: UUID?
    @State private var scaleSectionID: UUID?
    @State private var selectAllName = false
    // A proposed key/scale change waiting on confirmation because it would drop notes.
    @State private var pendingKeyScale: (sectionID: UUID, key: Int, scale: MusicalScale)?
    @State private var conflictCount = 0
    @State private var showKeyConflict = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

    private func inScale(_ midi: Int, key: Int, scale: MusicalScale) -> Bool {
        let semitone = ((midi % 12) - key + 12) % 12
        return scale.intervals.contains(semitone)
    }

    /// Notes in the pool that would fall outside the given key/scale.
    private var selectedSectionID: UUID? {
        let index = songStore.selectedSection
        guard songStore.song.sections.indices.contains(index) else { return nil }
        return songStore.song.sections[index].id
    }

    /// Sheets and delayed confirmations use a section identity captured when they
    /// open. Playback may continue following the playhead without rebinding an open
    /// editor to a different section underneath the user's hands.
    private func pinnedPartBinding(sectionID: UUID) -> Binding<Part> {
        Binding(
            get: {
                guard let sectionIndex = songStore.song.sections.firstIndex(where: { $0.id == sectionID }),
                      let value = songStore.song.sections[sectionIndex].parts.first(where: { $0.trackID == track.id })
                else { return Part(trackID: track.id) }
                return value
            },
            set: { newValue in
                guard let sectionIndex = songStore.song.sections.firstIndex(where: { $0.id == sectionID }) else { return }
                if let partIndex = songStore.song.sections[sectionIndex].parts.firstIndex(where: { $0.trackID == track.id }) {
                    songStore.song.sections[sectionIndex].parts[partIndex] = newValue
                } else {
                    songStore.song.sections[sectionIndex].parts.append(newValue)
                }
            }
        )
    }

    private func offendingNotes(in target: Part, key: Int, scale: MusicalScale) -> [Int] {
        target.notePool.map(\.midiNote).filter { !inScale($0, key: key, scale: scale) }
    }

    /// Apply a key/scale change and drop the out-of-key notes from the pool. No step is
    /// ever deleted. Play steps have the removed notes pruned from their positions and
    /// the surviving positions remapped to the new (renumbered) pool, so the same notes
    /// keep playing — e.g. Play 1,2,3,4 with note 2 removed becomes Play 1,2,3 (the old
    /// notes 1,3,4). A Play that referenced only removed notes stays as a step but plays
    /// nothing. Other step types carry no pool positions and are untouched.
    private func applyKeyScaleDroppingNotes(sectionID: UUID, key: Int, scale: MusicalScale) {
        songStore.checkpointForUndo()
        let targetBinding = pinnedPartBinding(sectionID: sectionID)
        var target = targetBinding.wrappedValue
        let old = target.notePool
        // old 0-based index → new 0-based index among survivors (nil = note removed).
        var oldToNew: [Int: Int] = [:]
        var next = 0
        for (i, entry) in old.enumerated() where inScale(entry.midiNote, key: key, scale: scale) {
            oldToNew[i] = next
            next += 1
        }
        let newCount = next

        for i in target.steps.indices where target.steps[i].type == .play {
            var step = target.steps[i]
            // Positions this Play references (chord list, else the single-note n).
            let refs = step.chordPositions.count > 1 ? step.chordPositions : [step.n]
            // Keep surviving references, remapped to new 1-based positions; drop removed.
            var seen = Set<Int>()
            var mapped: [Int] = []
            for pos in refs {
                if let n = oldToNew[pos - 1], seen.insert(n).inserted { mapped.append(n + 1) }
            }
            if mapped.count > 1 {
                step.chordPositions = mapped
                step.n = mapped[0]
            } else if mapped.count == 1 {
                step.chordPositions = []
                step.n = mapped[0]
            } else {
                // Every referenced note is gone — keep the step but make it a no-op
                // (position past the pool → playIndices returns empty → skipped).
                step.chordPositions = []
                step.n = newCount + 1
            }
            target.steps[i] = step
        }

        target.key = key
        target.scale = scale
        target.notePool = old.filter { inScale($0.midiNote, key: key, scale: scale) }
        targetBinding.wrappedValue = target
    }

    /// Apply a key/scale change immediately if no selected note falls outside it;
    /// otherwise stash it and raise a confirmation (removing those notes is destructive).
    private func proposeKeyScale(sectionID: UUID, key: Int, scale: MusicalScale) {
        let targetBinding = pinnedPartBinding(sectionID: sectionID)
        var target = targetBinding.wrappedValue
        let bad = offendingNotes(in: target, key: key, scale: scale)
        if bad.isEmpty {
            guard target.key != key || target.scale != scale else { return }
            songStore.checkpointForUndo()
            target.key = key
            target.scale = scale
            targetBinding.wrappedValue = target
        } else {
            pendingKeyScale = (sectionID, key, scale)
            conflictCount = bad.count
            // Defer so the alert reliably appears after the scale sheet finishes
            // dismissing (presenting both in the same runloop can drop the alert).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showKeyConflict = true }
        }
    }

    // Proxy bindings so the pickers route through proposeKeyScale. On cancel the
    // change is simply never applied, so the picker snaps back to the current value.
    private var keyBinding: Binding<Int> {
        Binding(get: { part.key },
                set: { newKey in
                    guard let sectionID = selectedSectionID else { return }
                    let target = pinnedPartBinding(sectionID: sectionID).wrappedValue
                    proposeKeyScale(sectionID: sectionID, key: newKey, scale: target.scale)
                })
    }
    private var scaleBinding: Binding<MusicalScale> {
        Binding(
            get: {
                guard let sectionID = scaleSectionID else { return part.scale }
                return pinnedPartBinding(sectionID: sectionID).wrappedValue.scale
            },
            set: { newScale in
                guard let sectionID = scaleSectionID else { return }
                let target = pinnedPartBinding(sectionID: sectionID).wrappedValue
                proposeKeyScale(sectionID: sectionID, key: target.key, scale: newScale)
            }
        )
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedBar
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 10) {
                        trackHeader.frame(width: 250)
                        Divider()
                        noteZone.frame(minWidth: 400)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        trackHeader.frame(maxWidth: .infinity)
                        Divider()
                        noteZone
                    }
                }
                .padding(10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showPluginPicker) {
            PluginPickerView(selectedPlugin: pluginBinding)
        }
        .fullScreenCover(isPresented: $showPluginEditor) {
            PluginEditorView(trackID: track.id, trackName: track.name,
                             onCommitState: { songStore.capturePluginState(for: track.id) },
                             onReload: { songStore.reloadPlugin(for: track.id) })
        }
        .sheet(isPresented: $showSteps, onDismiss: {
            if let baseline = stepsBaseline { songStore.recordUndoSnapshot(baseline) }
            stepsBaseline = nil
            stepsSectionID = nil
        }) {
            if let sectionID = stepsSectionID {
                let target = pinnedPartBinding(sectionID: sectionID)
                StepsView(steps: target.steps, noteCount: target.wrappedValue.notePool.count)
            }
        }
        .sheet(isPresented: $showNoteParams, onDismiss: {
            if let baseline = noteParametersBaseline { songStore.recordUndoSnapshot(baseline) }
            noteParametersBaseline = nil
            noteParametersSectionID = nil
        }) {
            if let sectionID = noteParametersSectionID {
                NoteParametersView(notePool: pinnedPartBinding(sectionID: sectionID).notePool)
            }
        }
        .sheet(isPresented: $showScalePicker, onDismiss: {
            if pendingKeyScale == nil { scaleSectionID = nil }
        }) {
            ScalePickerView(selectedScale: scaleBinding)
        }
        .alert("Notes outside new key", isPresented: $showKeyConflict) {
            Button("Remove \(conflictCount) note\(conflictCount == 1 ? "" : "s")", role: .destructive) {
                if let p = pendingKeyScale {
                    applyKeyScaleDroppingNotes(sectionID: p.sectionID, key: p.key, scale: p.scale)
                }
                pendingKeyScale = nil
                scaleSectionID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingKeyScale = nil
                scaleSectionID = nil
            }
        } message: {
            if let p = pendingKeyScale {
                Text("\(conflictCount) selected note\(conflictCount == 1 ? " is" : "s are") not in \(noteNames[p.key]) \(p.scale.rawValue). \(conflictCount == 1 ? "It" : "They") will be removed from this track. Steps keep running, and Play chords drop just the removed note\(conflictCount == 1 ? "" : "s") while their other notes keep playing. Cancel to keep the current key.")
            }
        }
        .alert("Delete \"\(track.name)\"?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { songStore.deleteTrack(track.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this instrument from every section.")
        }
    }

    private var pluginBinding: Binding<PluginInfo?> {
        Binding(
            get: { track.pluginInfo },
            set: { newInfo in songStore.setPlugin(newInfo, for: track.id) }
        )
    }

    // Compact one-line row shown when the track is collapsed.
    private var collapsedBar: some View {
        ViewThatFits(in: .horizontal) {
            collapsedWideBar.fixedSize(horizontal: true, vertical: false)
            collapsedCompactBar
        }
        // The wide variant is fixed-size, so without this it floats in the centre of
        // the row. Minimised tracks should line up with the expanded ones.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var collapsedWideBar: some View {
        HStack(spacing: 10) {
            Button {
                if reduceMotion { isCollapsed = false }
                else { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false } }
            } label: {
                Image(systemName: "chevron.right").iconHitTarget(34)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel("Expand \(track.name)")

            Text(track.name).font(.subheadline.bold()).lineLimit(1)

            Divider().frame(height: 16)

            Text(track.pluginInfo?.name ?? "No plugin")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            Divider().frame(height: 16)

            // Division + step indicator for the selected/playing section.
            Text(part.tempoDivision.abbreviation)
                .font(.caption2).foregroundStyle(.secondary)

            if !part.steps.isEmpty {
                SongMiniSteps(trackID: track.id, steps: part.steps)
            } else {
                Text("\(part.notePool.count) notes")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "speaker.wave.1").font(.system(size: 9)).foregroundStyle(.secondary)
            Slider(value: FaderScale.binding($track.mixer.volume), in: FaderScale.minDB...FaderScale.maxDB).frame(width: 70)
                .simultaneousGesture(TapGesture(count: 2).onEnded { track.mixer.volume = 1.0 })   // reset to 0 dB
                .accessibilityLabel("\(track.name) volume")
            SongTrackMeter(trackID: track.id)

            Divider().frame(height: 16)

            Toggle("M", isOn: $track.mixer.isMuted).toggleStyle(.button).tint(.orange).font(.caption2.bold())
                .accessibilityLabel("Mute \(track.name)")
            Toggle("S", isOn: $track.mixer.isSoloed).toggleStyle(.button).tint(.yellow).font(.caption2.bold())
                .accessibilityLabel("Solo \(track.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var collapsedCompactBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if reduceMotion { isCollapsed = false }
                    else { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false } }
                } label: {
                    Image(systemName: "chevron.right").iconHitTarget(34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Expand \(track.name)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name).font(.subheadline.bold()).lineLimit(1)
                    Text(track.pluginInfo?.name ?? "Built-in Sound")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Toggle("M", isOn: $track.mixer.isMuted)
                    .toggleStyle(.button).tint(.orange).font(.caption2.bold())
                    .accessibilityLabel("Mute \(track.name)")
                Toggle("S", isOn: $track.mixer.isSoloed)
                    .toggleStyle(.button).tint(.yellow).font(.caption2.bold())
                    .accessibilityLabel("Solo \(track.name)")
            }
            HStack(spacing: 8) {
                Text(part.tempoDivision.abbreviation).font(.caption2).foregroundStyle(.secondary)
                if !part.steps.isEmpty {
                    SongMiniSteps(trackID: track.id, steps: part.steps)
                } else {
                    Text("\(part.notePool.count) notes").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "speaker.wave.1").font(.caption2).foregroundStyle(.secondary)
                Slider(value: FaderScale.binding($track.mixer.volume), in: FaderScale.minDB...FaderScale.maxDB)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { track.mixer.volume = 1.0 })   // reset to 0 dB
                    .frame(minWidth: 70, maxWidth: 150)
                    .accessibilityLabel("\(track.name) volume")
                SongTrackMeter(trackID: track.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Left rail — track-level: instrument + mixer + meter (constant across sections).
    private var trackHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Button {
                    if reduceMotion { isCollapsed = true }
                    else { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = true } }
                } label: {
                    Image(systemName: "chevron.down").iconHitTarget(34)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)

                SelectAllTextField(
                    text: $track.name,
                    placeholder: "Name",
                    font: .preferredBold(.subheadline),
                    selectAllTrigger: $selectAllName
                )
                .frame(minWidth: 0, maxWidth: .infinity)
                .layoutPriority(1)
                // Long-press the name to highlight it and type over the default.
                .onLongPressGesture { selectAllName = true }

                Menu {
                    Button { songStore.moveTrackUp(track.id) } label: {
                        Label("Move Up", systemImage: "chevron.up")
                    }
                    .disabled(index == 0)

                    Button { songStore.moveTrackDown(track.id) } label: {
                        Label("Move Down", systemImage: "chevron.down")
                    }
                    .disabled(index == trackCount - 1)

                    Button { songStore.duplicateTrack(track.id) } label: {
                        Label("Duplicate Track", systemImage: "plus.square.on.square")
                    }
                    .disabled(trackCount >= SongStore.maximumEditableTrackCount)

                    Divider()

                    Button(role: .destructive) { showDeleteAlert = true } label: {
                        Label("Delete Track", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").iconHitTarget(34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Actions for \(track.name)")
            }

            Button { showPluginPicker = true } label: {
                Label(track.pluginInfo?.name ?? "Choose Plugin",
                      systemImage: track.pluginInfo == nil ? "puzzlepiece.extension" : "puzzlepiece.extension.fill")
                    .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(track.pluginInfo == nil ? nil : .accentColor)

            if let status = songStore.pluginStatuses[track.id] {
                switch status {
                case .loading(let name):
                    Label("Loading \(name)…", systemImage: "hourglass")
                        .font(.caption2).foregroundStyle(.secondary)
                case .ready:
                    Label("Instrument ready", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 6) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange).lineLimit(3)
                        Button("Choose Replacement") { showPluginPicker = true }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }

            if track.pluginInfo != nil {
                // Embedding a plugin's UI while it is still loading is how a hosted
                // scene ends up invalid (white view), so the editor stays shut until
                // the instrument reports ready.
                let isReady: Bool = {
                    if case .loading = songStore.pluginStatuses[track.id] { return false }
                    return true
                }()
                Button { showPluginEditor = true } label: {
                    Label(isReady ? "Edit Instrument" : "Loading…", systemImage: "slider.horizontal.3")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).tint(.purple)
                .disabled(!isReady)
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
                Slider(value: FaderScale.binding($track.mixer.volume), in: FaderScale.minDB...FaderScale.maxDB)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { track.mixer.volume = 1.0 })   // reset to 0 dB
                SongTrackMeter(trackID: track.id)
            }

            HStack(spacing: 6) {
                Text("Pan").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $track.mixer.pan, in: -1...1)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { track.mixer.pan = 0 })
                Toggle("M", isOn: $track.mixer.isMuted)
                    .toggleStyle(.button).tint(.orange).font(.caption2.bold())
                    .accessibilityLabel("Mute \(track.name)")
                Toggle("S", isOn: $track.mixer.isSoloed)
                    .toggleStyle(.button).tint(.yellow).font(.caption2.bold())
                    .accessibilityLabel("Solo \(track.name)")
            }
        }
    }

    // Right — section-level: this track's note data for the selected section.
    private var noteZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Rate").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $part.tempoDivision) {
                        ForEach(TempoDivision.allCases, id: \.self) { Text($0.abbreviation).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()

                    Divider().frame(height: 16)

                    Text("Key").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: keyBinding) {
                        ForEach(0..<12, id: \.self) { Text(noteNames[$0]).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()

                    Button {
                        guard let sectionID = selectedSectionID else { return }
                        scaleSectionID = sectionID
                        showScalePicker = true
                    } label: {
                        Text(part.scale.rawValue).font(.caption2).lineLimit(1)
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Text("\(part.notePool.count) notes").font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if !part.steps.isEmpty {
                SongMiniSteps(trackID: track.id, steps: part.steps, compact: false)
            }

            SongKeyboard(
                trackID: track.id,
                notePool: $part.notePool,
                scale: part.scale,
                key: part.key,
                onBeforeChange: { songStore.checkpointForUndo() },
                onPreview: { midi in
                    let n = UInt8(midi)
                    AudioEngineManager.shared.playNote(trackID: track.id, midiNote: n, velocity: 100)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        AudioEngineManager.shared.stopNote(trackID: track.id, midiNote: n)
                    }
                }
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                Button {
                    guard let sectionID = selectedSectionID else { return }
                    noteParametersBaseline = songStore.song
                    noteParametersSectionID = sectionID
                    showNoteParams = true
                } label: {
                    Label("Note Params", systemImage: "slider.vertical.3").font(.caption)
                }
                .buttonStyle(.bordered).disabled(part.notePool.isEmpty)

                Button {
                    guard let sectionID = selectedSectionID else { return }
                    stepsBaseline = songStore.song
                    stepsSectionID = sectionID
                    showSteps = true
                } label: {
                    Label(part.steps.isEmpty ? "Steps" : "Steps (\(part.steps.count))",
                          systemImage: "list.number").font(.caption)
                }
                .buttonStyle(.bordered)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

// MARK: - Leaf views observing the song's monitors

/// Piano keyboard whose playing-note highlight tracks the PlaybackMonitor.
private struct SongKeyboard: View {
    let trackID: UUID
    @Binding var notePool: [NoteEntry]
    let scale: MusicalScale
    let key: Int
    let onBeforeChange: () -> Void
    let onPreview: (Int) -> Void
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        PianoKeyboardView(
            notePool: $notePool,
            scale: scale,
            playingNotes: playback.playingNotes[trackID] ?? [],
            key: key,
            onBeforeChange: onBeforeChange,
            onPreview: onPreview
        )
    }
}

/// Step-sequence indicator with the active step highlighted (observes PlaybackMonitor).
private struct SongMiniSteps: View {
    let trackID: UUID
    let steps: [Step]
    var compact: Bool = true
    @EnvironmentObject var playback: PlaybackMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activeStep = playback.activeSteps[trackID]
        let size: CGFloat = compact ? 8 : 10
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                    let isActive = activeStep == idx
                    Text(step.label)
                        .font(.system(size: size, weight: isActive ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(isActive ? .black : .secondary)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(isActive ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 3))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.08), value: isActive)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: compact ? 160 : .infinity)
    }
}

/// Bar counter — current bar within the playing section (observes PlaybackMonitor).
private struct SongBarCounter: View {
    let totalBars: Int
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        HStack(spacing: 6) {
            Text("Bar").font(.caption).foregroundStyle(.secondary)
            Text("\(playback.currentBar + 1)")
                .font(.caption.monospacedDigit()).frame(minWidth: 18, alignment: .trailing)
            Text("of").font(.caption).foregroundStyle(.secondary)
            Text("\(totalBars)").font(.caption.monospacedDigit())
        }
    }
}

struct SongTrackMeter: View {
    let trackID: UUID
    @EnvironmentObject var levels: LevelMonitor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var latch = ClipLatch()
    @State private var heldPeak: CGFloat = 0
    @State private var holdExpiry = Date.distantPast

    var body: some View {
        let level = levels.trackLevels[trackID] ?? .silent
        // Same dBFS scale as the mixer meters: RMS fills the bar, a marker shows the
        // recent peak, and the cap latches red on an over until the level settles.
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2))

                RoundedRectangle(cornerRadius: 2)
                    .fill(level.peakDB > -6 ? Color.orange
                          : level.peakDB > -18 ? .yellow : .green)
                    .frame(width: geo.size.width * level.rmsFraction)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08),
                               value: level.rmsFraction)

                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 1.5)
                    .offset(x: geo.size.width * heldPeak - 0.75)
                    .opacity(heldPeak > 0 ? 1 : 0)

                if latch.isLit {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: 3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { latch.clear(); heldPeak = 0 }
        }
        .frame(width: 40, height: 6)
        .onChange(of: level) { newValue in
            let now = Date()
            latch.update(with: newValue, now: now)
            if newValue.peakFraction >= heldPeak || now > holdExpiry {
                heldPeak = newValue.peakFraction
                holdExpiry = now.addingTimeInterval(1.5)
            }
        }
    }
}
