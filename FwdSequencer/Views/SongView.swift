import SwiftUI

// MARK: - SongView
//
// Song editor: transport, an arrangement strip of sections, and track rows split
// into a constant "instrument zone" and a per-section "note zone" bound to the
// currently selected section. Parallels ProjectView. See SONG_MODE_PLAN.md.

struct SongView: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPlayDock = false

    var body: some View {
        VStack(spacing: 0) {
            SongTransportBar(onBack: {
                songStore.close()   // captures live plugin state + saves, then tears down
                dismiss()
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
        .overlay(alignment: .bottom) {
            if showPlayDock {
                PlayDockView(onClose: { withAnimation { showPlayDock = false } })
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showPlayDock)
        // Block interaction while instruments load/restore, so user input can't
        // interrupt a plugin (e.g. GeoShred) mid-restore and corrupt its state.
        .overlay {
            if songStore.isLoading {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("Loading instruments…").font(.title3.bold()).foregroundStyle(.white)
                        Text("Please wait — don't tap yet").font(.callout).foregroundStyle(.white.opacity(0.85))
                    }
                    .padding(36)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: songStore.isLoading)
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
    var onBack: () -> Void
    @Binding var showPlayDock: Bool
    @State private var currentBeat: Int = 0
    @State private var tapTimes: [Date] = []
    @State private var savedVisible = false
    @State private var showMixer = false
    @State private var selectAllSongName = false

    private var beatCount: Int { songStore.song.timeSignature.numerator }
    private var currentSectionBars: Int {
        let idx = songStore.currentSection
        return songStore.song.sections.indices.contains(idx) ? songStore.song.sections[idx].numberOfBars : 0
    }

    var body: some View {
        VStack(spacing: 6) {
            // ── Row 1: playback ──────────────────────────────────────────
            HStack(spacing: 14) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)

                Divider().frame(height: 26)

                Button { songStore.rewind() } label: {
                    Image(systemName: "backward.end.fill").font(.body)
                        .foregroundStyle(songStore.isPlaying || songStore.isPaused ? .primary : .secondary)
                }
                .buttonStyle(.plain)

                Button {
                    if songStore.isPlaying      { songStore.pause() }
                    else if songStore.isPaused  { songStore.resume() }
                    else                        { songStore.play() }
                } label: {
                    Image(systemName: songStore.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).foregroundColor(.green).frame(width: 32)
                }
                .buttonStyle(.plain)

                Button { songStore.stop() } label: {
                    Image(systemName: "stop.fill").font(.body)
                        .foregroundStyle(songStore.isPlaying || songStore.isPaused ? .red : .secondary)
                }
                .buttonStyle(.plain)

                Button { songStore.midiPanic() } label: {
                    Text("!").font(.body.bold()).foregroundStyle(.red).frame(width: 20)
                }
                .buttonStyle(.plain)

                Button { songStore.loopEnabled.toggle() } label: {
                    Image(systemName: "repeat").font(.body)
                        .foregroundStyle(songStore.loopEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Loop song")

                Divider().frame(height: 26)

                HStack(spacing: 6) {
                    Text("BPM").font(.caption).foregroundStyle(.secondary)
                    Text("\(Int(songStore.song.tempo))")
                        .font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                    Stepper("", value: $songStore.song.tempo, in: 40...240, step: 1).labelsHidden()
                    Button { handleTap() } label: {
                        Label("Tap", systemImage: "hand.tap.fill").font(.caption)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }

                Divider().frame(height: 26)

                // Metronome beat lights — red on beat 1, green on the rest.
                HStack(spacing: 4) {
                    ForEach(0..<beatCount, id: \.self) { beat in
                        let isActive = songStore.isPlaying && beat == currentBeat
                        Circle()
                            .fill(isActive ? (beat == 0 ? Color.red : Color.green) : Color.gray.opacity(0.25))
                            .frame(width: 10, height: 10)
                            .animation(.easeOut(duration: 0.08), value: isActive)
                    }
                }

                Divider().frame(height: 26)

                SongBarCounter(totalBars: currentSectionBars)

                Spacer()
                    .overlay(alignment: .trailing) {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.bold()).foregroundStyle(.green)
                            .opacity(savedVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.3), value: savedVisible)
                    }
            }

            // ── Row 2: song settings + panels ────────────────────────────
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Text("Time").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $songStore.song.timeSignature.numerator) {
                        ForEach([2,3,4,5,6,7,8], id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.menu).fixedSize()
                    Text("/").font(.body.bold()).foregroundStyle(.secondary)
                    Picker("", selection: $songStore.song.timeSignature.denominator) {
                        ForEach([2,4,8], id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.menu).fixedSize()
                }

                Divider().frame(height: 26)

                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $songStore.song.masterVolume, in: 0...1).frame(width: 130)
                }

                Divider().frame(height: 26)

                SelectAllTextField(
                    text: $songStore.song.name,
                    placeholder: "Song Name",
                    font: .preferredBold(.subheadline),
                    selectAllTrigger: $selectAllSongName
                )
                .frame(minWidth: 120, maxWidth: 240)
                // Long-press the name to highlight it and type over.
                .onLongPressGesture { selectAllSongName = true }

                Spacer()

                Button { showPlayDock.toggle() } label: {
                    Label("Play", systemImage: "pianokeys")
                }
                .buttonStyle(.bordered)
                .tint(showPlayDock ? .accentColor : nil)

                Button { showMixer = true } label: {
                    Label("Mixer", systemImage: "slider.vertical.3")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showMixer) {
            SongMixerView()
                .environmentObject(songStore)
                .environmentObject(songStore.levels)
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
        songStore.song.tempo = min(240, max(40, (60.0 / avg).rounded()))
    }
}

// Enlarge a small icon button's tap target (and glyph) for easier touch use.
private extension View {
    func iconHitTarget(_ size: CGFloat = 36) -> some View {
        self.font(.title3)
            .frame(width: size, height: size)
            .contentShape(Rectangle())
    }
}

// MARK: - Arrangement strip

private struct ArrangementStrip: View {
    @EnvironmentObject var songStore: SongStore
    @State private var renaming: Int? = nil
    @State private var renameText = ""

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Identity-based so deleting a section can't crash on a stale index.
                    ForEach(Array(songStore.song.sections.enumerated()), id: \.element.id) { idx, section in
                        chip(idx, section)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            Divider().frame(height: 28)

            // Section controls act on the selected section.
            let sel = songStore.selectedSection
            Button { songStore.addSection() } label: {
                Image(systemName: "plus").iconHitTarget(40)
            }
            .help("Add section")

            Button { songStore.duplicateSection(at: sel) } label: {
                Image(systemName: "plus.square.on.square").iconHitTarget(40)
            }
            .help("Duplicate section")

            Button { songStore.moveSection(from: sel, to: sel - 1) } label: {
                Image(systemName: "chevron.left").iconHitTarget(40)
            }
            .disabled(sel <= 0)

            Button { songStore.moveSection(from: sel, to: sel + 1) } label: {
                Image(systemName: "chevron.right").iconHitTarget(40)
            }
            .disabled(sel >= songStore.song.sections.count - 1)

            Button(role: .destructive) { songStore.deleteSection(at: sel) } label: {
                Image(systemName: "trash").iconHitTarget(40)
            }
            .disabled(songStore.song.sections.count <= 1)
            .padding(.trailing, 8)
        }
        .background(.regularMaterial)
        .alert("Rename Section", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let i = renaming, songStore.song.sections.indices.contains(i) {
                    songStore.song.sections[i].name = renameText
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
    }
}

// MARK: - Section settings (bars / key / scale for the selected section)

private struct SectionSettingsBar: View {
    @EnvironmentObject var songStore: SongStore
    @State private var selectAllName = false

    var body: some View {
        let sel = songStore.selectedSection
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
                Stepper(value: $songStore.song.sections[sel].numberOfBars, in: 1...32) {
                    Text("\(songStore.song.sections[sel].numberOfBars)")
                        .font(.caption.monospacedDigit()).frame(minWidth: 18)
                }
                .fixedSize()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
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
    @State private var selectAllName = false
    // A proposed key/scale change waiting on confirmation because it would drop notes.
    @State private var pendingKeyScale: (key: Int, scale: MusicalScale)?
    @State private var conflictCount = 0
    @State private var showKeyConflict = false

    private let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

    private func inScale(_ midi: Int, key: Int, scale: MusicalScale) -> Bool {
        let semitone = ((midi % 12) - key + 12) % 12
        return scale.intervals.contains(semitone)
    }

    /// Notes in the pool that would fall outside the given key/scale.
    private func offendingNotes(key: Int, scale: MusicalScale) -> [Int] {
        part.notePool.map(\.midiNote).filter { !inScale($0, key: key, scale: scale) }
    }

    /// Apply a key/scale change AND drop the out-of-key notes, remapping this track's
    /// steps: surviving pool references shift so they keep pointing at the same notes,
    /// and any Play step that referenced a removed note is pruned (chord positions for
    /// removed notes are dropped; a single-note Play of a removed note is deleted).
    /// Only Play steps carry pool positions — other step types are left untouched.
    private func applyKeyScaleDroppingNotes(key: Int, scale: MusicalScale) {
        let old = part.notePool
        // old 0-based index → new 0-based index among survivors (nil = note removed).
        var oldToNew: [Int: Int] = [:]
        var next = 0
        for (i, entry) in old.enumerated() where inScale(entry.midiNote, key: key, scale: scale) {
            oldToNew[i] = next
            next += 1
        }

        var newSteps: [Step] = []
        for var step in part.steps {
            guard step.type == .play else { newSteps.append(step); continue }
            if step.chordPositions.count > 1 {
                let remapped = step.chordPositions.compactMap { pos -> Int? in
                    oldToNew[pos - 1].map { $0 + 1 }
                }
                if remapped.isEmpty { continue }          // every chord note gone → drop step
                step.chordPositions = remapped.count > 1 ? remapped : []
                step.n = remapped[0]                       // count==1 falls back to single-note
                newSteps.append(step)
            } else {
                guard let n = oldToNew[step.n - 1] else { continue }  // note gone → drop step
                step.n = n + 1
                newSteps.append(step)
            }
        }

        part.key = key
        part.scale = scale
        part.notePool = old.filter { inScale($0.midiNote, key: key, scale: scale) }
        part.steps = newSteps
    }

    /// Apply a key/scale change immediately if no selected note falls outside it;
    /// otherwise stash it and raise a confirmation (removing those notes is destructive).
    private func proposeKeyScale(key: Int, scale: MusicalScale) {
        let bad = offendingNotes(key: key, scale: scale)
        if bad.isEmpty {
            part.key = key
            part.scale = scale
        } else {
            pendingKeyScale = (key, scale)
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
                set: { proposeKeyScale(key: $0, scale: part.scale) })
    }
    private var scaleBinding: Binding<MusicalScale> {
        Binding(get: { part.scale },
                set: { proposeKeyScale(key: part.key, scale: $0) })
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedBar
            } else {
                HStack(alignment: .top, spacing: 10) {
                    trackHeader.frame(width: 250)
                    Divider()
                    noteZone
                }
                .padding(10)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: track.pluginInfo) { newPlugin in
            songStore.setPlugin(newPlugin, for: track.id)
        }
        .sheet(isPresented: $showPluginPicker) {
            PluginPickerView(selectedPlugin: $track.pluginInfo)
        }
        .fullScreenCover(isPresented: $showPluginEditor) {
            PluginEditorView(trackID: track.id, trackName: track.name,
                             onCommitState: { songStore.capturePluginState(for: track.id) })
        }
        .sheet(isPresented: $showSteps) {
            StepsView(steps: $part.steps, noteCount: part.notePool.count)
        }
        .sheet(isPresented: $showNoteParams) {
            NoteParametersView(notePool: $part.notePool)
        }
        .sheet(isPresented: $showScalePicker) {
            ScalePickerView(selectedScale: scaleBinding)
        }
        .alert("Notes outside new key", isPresented: $showKeyConflict) {
            Button("Remove \(conflictCount) note\(conflictCount == 1 ? "" : "s")", role: .destructive) {
                if let p = pendingKeyScale {
                    applyKeyScaleDroppingNotes(key: p.key, scale: p.scale)
                }
                pendingKeyScale = nil
            }
            Button("Cancel", role: .cancel) { pendingKeyScale = nil }
        } message: {
            if let p = pendingKeyScale {
                Text("\(conflictCount) selected note\(conflictCount == 1 ? " is" : "s are") not in \(noteNames[p.key]) \(p.scale.rawValue). \(conflictCount == 1 ? "It" : "They") will be removed from this track, along with any Play steps that played \(conflictCount == 1 ? "it" : "them"). Cancel to keep the current key.")
            }
        }
        .alert("Delete \"\(track.name)\"?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { songStore.deleteTrack(track.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this instrument from every section.")
        }
    }

    // Compact one-line row shown when the track is collapsed.
    private var collapsedBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false }
            } label: {
                Image(systemName: "chevron.right").iconHitTarget(34)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)

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
            Slider(value: $track.mixer.volume, in: 0...1).frame(width: 70)
            SongTrackMeter(trackID: track.id)

            Divider().frame(height: 16)

            Toggle("M", isOn: $track.mixer.isMuted).toggleStyle(.button).tint(.orange).font(.caption2.bold())
            Toggle("S", isOn: $track.mixer.isSoloed).toggleStyle(.button).tint(.yellow).font(.caption2.bold())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // Left rail — track-level: instrument + mixer + meter (constant across sections).
    private var trackHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = true }
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
                // Long-press the name to highlight it and type over the default.
                .onLongPressGesture { selectAllName = true }
                Spacer()

                Button { songStore.moveTrackUp(track.id) } label: {
                    Image(systemName: "chevron.up").iconHitTarget(34)
                }
                .buttonStyle(.plain).disabled(index == 0)

                Button { songStore.moveTrackDown(track.id) } label: {
                    Image(systemName: "chevron.down").iconHitTarget(34)
                }
                .buttonStyle(.plain).disabled(index == trackCount - 1)

                Button { songStore.duplicateTrack(track.id) } label: {
                    Image(systemName: "plus.square.on.square").iconHitTarget(34)
                }
                .buttonStyle(.plain)

                Button(role: .destructive) { showDeleteAlert = true } label: {
                    Image(systemName: "trash").foregroundColor(.red).iconHitTarget(34)
                }
                .buttonStyle(.plain)
            }

            Button { showPluginPicker = true } label: {
                Label(track.pluginInfo?.name ?? "Choose Plugin",
                      systemImage: track.pluginInfo == nil ? "puzzlepiece.extension" : "puzzlepiece.extension.fill")
                    .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(track.pluginInfo == nil ? nil : .accentColor)

            if track.pluginInfo != nil {
                Button { showPluginEditor = true } label: {
                    Label("Edit Sound", systemImage: "slider.horizontal.3")
                        .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).tint(.purple)
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $track.mixer.volume, in: 0...1)
                SongTrackMeter(trackID: track.id)
            }

            HStack(spacing: 6) {
                Text("Pan").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $track.mixer.pan, in: -1...1)
                Toggle("M", isOn: $track.mixer.isMuted).toggleStyle(.button).tint(.orange).font(.caption2.bold())
                Toggle("S", isOn: $track.mixer.isSoloed).toggleStyle(.button).tint(.yellow).font(.caption2.bold())
            }
        }
    }

    // Right — section-level: this track's note data for the selected section.
    private var noteZone: some View {
        VStack(alignment: .leading, spacing: 8) {
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

                Button { showScalePicker = true } label: {
                    Text(part.scale.rawValue).font(.caption2).lineLimit(1)
                }
                .buttonStyle(.bordered).controlSize(.small)

                Spacer()

                Text("\(part.notePool.count) notes").font(.caption2).foregroundStyle(.secondary)
            }

            if !part.steps.isEmpty {
                SongMiniSteps(trackID: track.id, steps: part.steps, compact: false)
            }

            SongKeyboard(
                trackID: track.id,
                notePool: $part.notePool,
                scale: part.scale,
                key: part.key,
                onPreview: { midi in
                    let n = UInt8(midi)
                    AudioEngineManager.shared.playNote(trackID: track.id, midiNote: n, velocity: 100)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        AudioEngineManager.shared.stopNote(trackID: track.id, midiNote: n)
                    }
                }
            )

            HStack(spacing: 10) {
                Button { showNoteParams = true } label: {
                    Label("Note Params", systemImage: "slider.vertical.3").font(.caption)
                }
                .buttonStyle(.bordered).disabled(part.notePool.isEmpty)

                Button { showSteps = true } label: {
                    Label(part.steps.isEmpty ? "Steps" : "Steps (\(part.steps.count))",
                          systemImage: "list.number").font(.caption)
                }
                .buttonStyle(.bordered)
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
    let onPreview: (Int) -> Void
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        PianoKeyboardView(
            notePool: $notePool,
            scale: scale,
            playingNotes: playback.playingNotes[trackID] ?? [],
            key: key,
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
                        .animation(.easeInOut(duration: 0.08), value: isActive)
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

    var body: some View {
        let level = levels.trackLevels[trackID] ?? 0
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 2)
                    .fill(level > 0.85 ? Color.red : level > 0.6 ? .orange : level > 0.3 ? .yellow : .green)
                    .frame(width: geo.size.width * CGFloat(min(1, level)))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(width: 40, height: 6)
    }
}
