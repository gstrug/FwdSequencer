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

            // Only there while MIDI Learn is on: what to do next, and Done.
            MIDILearnBanner()
            MIDIWriteNotesBanner()

            ArrangementStrip()

            SectionSettingsBar()

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                // Lazy: only the rows on screen are built and laid out. With a plain
                // VStack every track row — each choosing between two layouts, expanded
                // ones carrying an 88-key keyboard — was laid out again on a rotation,
                // all at once, which held up the processor long enough for the
                // sequencer to stall and plugins to crackle.
                LazyVStack(spacing: 12) {
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
                    .helpTag(.addTrack)
                }
                .padding(12)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            songStore.activate()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        // The device has turned: the screen is about to be laid out again at the new
        // size. Hold the meters and note highlights off while that happens so they are
        // not competing with it; they resume by themselves.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            songStore.audioEngine.quietTelemetry(forSeconds: 0.8)
        }
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
        // The help card, when help mode is on. Above the Play keyboard.
        .helpHost()
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
    /// In help mode, menu items explain themselves instead of acting.
    @ObservedObject private var help = HelpCenter.shared
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
    @State private var showingMIDISettings = false
    /// The two-wheel time signature picker, from Other….
    @State private var showingTimeSignature = false
    /// For the MIDI Learn switch in Settings ▸ MIDI.
    @ObservedObject private var midiLearn = MIDIControlCenter.shared.learn
    /// Typing an exact tempo, from a tap on the tempo display.
    @State private var editingTempo = false
    @State private var tempoText = ""

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
                .helpTag(.backToSongs)

                // Which song this is sits with the way back to the song list, and the
                // "Saved" confirmation beside the name it refers to.
                HStack(spacing: 8) {
                    songNameField
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold()).foregroundStyle(.green)
                        .opacity(savedVisible ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: savedVisible)
                }

                Divider().frame(height: 26)

                Button { songStore.rewind() } label: {
                    Image(systemName: "backward.end.fill").iconHitTarget()
                        .foregroundStyle(songStore.isPlaying || songStore.isPaused ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewind song")
                .midiLearnable(.rewind)
                .helpTag(.rewind)

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
                .midiLearnable(.playPause)
                .helpTag(.playPause)

                Button { songStore.stop() } label: {
                    Image(systemName: "stop.fill").iconHitTarget()
                        .foregroundStyle(songStore.isPlaying || songStore.isPaused ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop song")
                .midiLearnable(.stop)
                .helpTag(.stop)

                Button { toggleRecording() } label: {
                    Image(systemName: songStore.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(songStore.isRecording ? .red : .secondary)
                        .iconHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(songStore.isRecording ? "Stop and export recording" : "Record master output")
                .midiLearnable(.record)
                .helpTag(.record)

                // MIDI panic — needs to be one tap on the transport, not buried in a
                // menu: it is what you reach for when a note hangs mid-performance.
                Button { songStore.midiPanic() } label: {
                    Image(systemName: "exclamationmark.octagon.fill").iconHitTarget()
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Panic — stop all notes")
                .accessibilityLabel("Panic, stop all notes")
                .midiLearnable(.panic)
                .helpTag(.panic)

                Button { songStore.loopEnabled.toggle() } label: {
                    Image(systemName: "repeat").iconHitTarget()
                        .foregroundStyle(songStore.loopEnabled ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Loop song")
                .accessibilityLabel("Loop song")
                .accessibilityValue(songStore.loopEnabled ? "On" : "Off")
                .midiLearnable(.loop)
                .helpTag(.loop)

                // Tempo sits with the transport: it is what you reach for alongside
                // play. One child, as the row is at SwiftUI's ten-view limit.
                HStack(spacing: 8) {
                    Divider().frame(height: 26)
                    tempoReadout
                        .midiLearnable(.tempo)
                        .helpTag(.tempo)
                    StudioTapButton(title: "TAP") { handleTap() }
                        .accessibilityLabel("Tap tempo")
                        .midiLearnable(.tapTempo)
                        .helpTag(.tapTempo)
                }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            // ── Row 2: time, output, panels ──────────────────────────────
            // Wrapped rather than scrolled sideways. This row is wider than an iPad in
            // portrait, and the horizontal ScrollView it used to live in gave no sign of
            // that: the song name was cut mid-word and Mixer and Song Settings sat off
            // the right-hand edge with nothing on screen to say they were there.
            //
            // Grouped in threes only because a Layout's ViewBuilder takes ten children
            // at most. Groups are flattened into subviews, so they do not affect where
            // the row breaks.
            // No dividers between the clusters any more: one landing at a row break
            // dangles with nothing after it, and one starting a row is worse. Wider
            // spacing separates them instead, and each cluster stays whole when the row
            // breaks because it is a single subview.
            //
            // Ordered by what each cluster is about: time (tempo, meter, where the
            // song is), then output (master level and volume, CPU), then the panels.
            //
            // When it all fits on one line the panels sit at the right-hand end; when
            // it does not, the same clusters wrap instead.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    positionIndicator
                    timeSignatureMenu
                    masterOutputControl
                    CPUReadout().helpTag(.cpu)
                    Spacer(minLength: 20)
                    panelButtons
                }
                FlowLayout(horizontalSpacing: 20, verticalSpacing: 8) {
                    positionIndicator
                    timeSignatureMenu
                    masterOutputControl
                    CPUReadout().helpTag(.cpu)
                    panelButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .sheet(isPresented: $showingTimeSignature) {
            TimeSignatureSheet(timeSignature: $songStore.song.timeSignature)
        }
        .sheet(isPresented: $showingMIDISettings) {
            MIDISettingsView()
                .environmentObject(songStore)
        }
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
        .onReceive(MIDIControlCenter.shared.recordRequests) { toggleRecording() }
        .onReceive(MIDIControlCenter.shared.playDockRequests) { showPlayDock.toggle() }
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

    // The pieces of row 2, each its own property. They were inline until the row had to
    // wrap: a Layout needs them as separate subviews, and the whole row in one expression
    // was already close to what the SwiftUI type-checker will accept.

    private var panelButtons: some View {
        HStack(spacing: 10) {
            Button { showPlayDock.toggle() } label: {
                Label("Play", systemImage: "pianokeys")
            }
            .buttonStyle(.bordered)
            .tint(showPlayDock ? .accentColor : nil)
            .midiLearnable(.togglePlayDock)
            .helpTag(.playButton)

            Button { showMixer = true } label: {
                Label("Mixer", systemImage: "slider.vertical.3")
            }
            .buttonStyle(.bordered)
            .helpTag(.mixerButton)

            songSettingsMenu

            // Help mode: tap any control to see what it does.
            HelpButton()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Tempo in a display window: drag to change, double tap for 120, tap to type.
    private var tempoReadout: some View {
        StudioReadout(value: $songStore.song.tempo, range: 20...400, defaultValue: 120,
                      unit: "BPM", accessibilityLabel: "Tempo",
                      onTap: {
                          tempoText = "\(Int(songStore.song.tempo))"
                          editingTempo = true
                      },
                      format: { "\(Int($0.rounded()))" })
            .alert("Tempo", isPresented: $editingTempo) {
                TextField("BPM", text: $tempoText)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {}
                Button("Set") {
                    if let bpm = Double(tempoText.trimmingCharacters(in: .whitespaces)) {
                        songStore.song.tempo = min(400, max(20, bpm.rounded()))
                    }
                }
            } message: {
                Text("20 to 400 BPM")
            }
    }

    /// The signatures most music uses, one tap each. Anything else is under Other….
    private static let commonTimeSignatures: [TimeSignature] = [
        (2, 4), (3, 4), (4, 4), (5, 4), (6, 8), (7, 8), (9, 8), (12, 8),
    ].map { TimeSignature(numerator: $0.0, denominator: $0.1) }

    /// Time signature in the same display style; a tap opens the choices.
    ///
    /// It used to be two separate pickers, beats and note value, which made every
    /// change two trips through a menu. Now the common signatures are one tap, and
    /// Other… opens two wheels side by side for anything unusual.
    private var timeSignatureMenu: some View {
        let current = songStore.song.timeSignature
        return Menu {
            // An unusual signature in use is shown, ticked, above the common ones.
            if !Self.commonTimeSignatures.contains(current) {
                Label("\(current.numerator)/\(current.denominator)", systemImage: "checkmark")
                Divider()
            }
            ForEach(Self.commonTimeSignatures, id: \.numerator) { signature in
                Button {
                    songStore.song.timeSignature = signature
                } label: {
                    if signature == current {
                        Label("\(signature.numerator)/\(signature.denominator)", systemImage: "checkmark")
                    } else {
                        Text("\(signature.numerator)/\(signature.denominator)")
                    }
                }
            }
            Divider()
            Button { showingTimeSignature = true } label: {
                Label("Other…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(songStore.song.timeSignature.numerator)/\(songStore.song.timeSignature.denominator)")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StudioStyle.displayText)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(StudioStyle.scaleText)
            }
            .studioWindow()
        }
        .accessibilityLabel("Time signature")
        .accessibilityValue("\(songStore.song.timeSignature.numerator) \(songStore.song.timeSignature.denominator)")
        .helpTag(.timeSignature)
    }

    /// Beat dots and bar counter together: both say where the song is.
    private var positionIndicator: some View {
        HStack(spacing: 10) {
            beatIndicator
            SongBarCounter(totalBars: currentSectionBars)
        }
        .fixedSize(horizontal: true, vertical: false)
        .helpTag(.beatAndBar)
    }

    private var beatIndicator: some View {
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
    }

    /// Master volume with the master level meter directly under it, so what the
    /// slider does and what is coming out are read together.
    private var masterOutputControl: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption2).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                StudioSlider(value: Binding(get: { Double(songStore.song.masterVolume) },
                                            set: { songStore.song.masterVolume = Float($0) }),
                             range: 0...1, defaultValue: 1, accessibilityLabel: "Master volume",
                             format: { "\(Int(($0 * 100).rounded()))%" })
                    .midiLearnable(.masterVolume)
                    .helpTag(.masterVolume)
                MasterLevelBar()
                    .padding(.horizontal, 10)
            }
            .frame(width: 150)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var songNameField: some View {
        SelectAllTextField(
            text: $songStore.song.name,
            placeholder: "Song Name",
            font: .preferredBold(.subheadline),
            selectAllTrigger: $selectAllSongName
        )
        .frame(width: 200)
        .onLongPressGesture { selectAllSongName = true }
        .helpTag(.songName)
    }

    private var songSettingsMenu: some View {
        Menu {
            // Pattern Trigger Mode lives in the Section menu now: it is about what the
            // section chips do.
            // Everything MIDI in one place: Learn, the controllers and their
            // templates, and clock output.
            Menu {
                Toggle(isOn: help.guarded(.midiLearn, $midiLearn.isOn)) {
                    Label("MIDI Learn", systemImage: "dot.radiowaves.left.and.right")
                }
                Toggle(isOn: help.guarded(.midiWriteNotes, $midiLearn.writeNotesEnabled)) {
                    Label("Write Notes from Keys", systemImage: "music.note.list")
                }
                Button { help.perform(.midiControllersPage) { showingMIDISettings = true } } label: {
                    Label("Controllers & Templates…", systemImage: "slider.horizontal.3")
                }
                Divider()
                Toggle(isOn: help.guarded(.midiClock, $songStore.midiClockEnabled)) {
                    Label("MIDI Clock Output", systemImage: "metronome")
                }
            } label: {
                Label("MIDI", systemImage: "cable.connector")
            }
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)
        // In help mode: a help screen listing the menu's items, instead of the menu.
        .helpMenu(.settings)
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

/// Any time signature: two wheels side by side, beats over note value, as in most
/// music software. Changes apply as the wheels turn.
private struct TimeSignatureSheet: View {
    @Binding var timeSignature: TimeSignature
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text("Beats").font(.caption).foregroundStyle(.secondary)
                    Picker("Beats per bar", selection: $timeSignature.numerator) {
                        ForEach(1...32, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 110)
                }
                Text("/")
                    .font(.system(size: 34, weight: .light, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                VStack(spacing: 4) {
                    Text("Note value").font(.caption).foregroundStyle(.secondary)
                    Picker("Beat value", selection: $timeSignature.denominator) {
                        ForEach([1, 2, 4, 8, 16, 32], id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.wheel)
                    .frame(width: 110)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .navigationTitle("Time Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
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

/// Identifiable wrapper so a section index, and which of its settings is being
/// edited, can drive `.sheet(item:)`.
private struct SectionTarget: Identifiable {
    let index: Int
    let field: SectionEditorSheet.Field
    var id: String { "\(index)-\(field)" }
}

/// Deliver a touch on a pad the moment it lands.
///
/// A UIScrollView holds content touches for about 150 ms while it works out whether the
/// gesture is a scroll, and the section strip is a scroll view — so pressing a pad waited
/// that long before anything sounded. Pressing a SECOND pad while one was already held
/// did not wait, because the scroll view had already settled that question for the touch
/// sequence in progress. That asymmetry is what identified it: the audio path is the same
/// in both cases, so the delay could not have been in the audio path.
///
/// Only in Trigger mode, where a chip IS a pad and immediacy is the whole point. Left on
/// elsewhere, because with the delay off a touch that turns into a scroll sounds the
/// pattern before it is cancelled — worth it for a pad, not for a chip you tap to select.
private struct ImmediateTouches: UIViewRepresentable {
    let enabled: Bool

    final class Probe: UIView {
        var enabled = false { didSet { apply() } }
        private weak var scrollView: UIScrollView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view: UIView? = superview
            while let current = view {
                if let scroll = current as? UIScrollView { scrollView = scroll; break }
                view = current.superview
            }
            apply()
        }

        private func apply() {
            // canCancelContentTouches is left alone: dragging the strip must still scroll,
            // and the pad must be released rather than left sounding when it does.
            scrollView?.delaysContentTouches = !enabled
        }
    }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.enabled = enabled
        return probe
    }

    func updateUIView(_ view: Probe, context: Context) { view.enabled = enabled }
}

private struct ArrangementStrip: View {
    @EnvironmentObject var songStore: SongStore
    /// In help mode, menu items explain themselves instead of acting.
    @ObservedObject private var help = HelpCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingSection: SectionTarget? = nil
    @State private var showArranger = false
    @State private var importingMIDI = false
    /// Drives the queued chip's pulse. A single flag for the strip rather than one per
    /// chip, so every queued pad would flash in step — there is only ever one, but it
    /// keeps the animation owned in one place.
    @State private var queuePulse = false

    var body: some View {
        VStack(spacing: 0) {
            // The song order, while Play Arrangement is on: where you are in the song,
            // and a tap queues a place.
            if songStore.song.arrangementIsActive {
                SongOrderStrip(openArranger: { showArranger = true })
                Divider()
            }
            chipRow
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Identity-based so deleting a section can't crash on a stale index.
                        ForEach(Array(songStore.song.sections.enumerated()), id: \.element.id) { idx, section in
                            chip(idx, section)
                                .midiLearnable(.section(idx))
                                .helpTag(.sectionChip, instance: section.id.uuidString)
                                .id(section.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(ImmediateTouches(enabled: songStore.triggerMode))
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

            Menu {
                // What the section chips do. Here rather than in Settings: it is a
                // section matter. Only in this menu, not a chip's long press, which
                // Trigger mode switches off anyway.
                Toggle(isOn: help.guarded(.triggerMode, $songStore.triggerMode)) {
                    Label("Pattern Trigger Mode", systemImage: "hand.tap")
                }
                Toggle(isOn: help.guarded(.triggerHold, $songStore.triggerHoldToPlay)) {
                    Label("Trigger Holds to Play", systemImage: "hand.point.up.left")
                }
                .disabled(!songStore.triggerMode && !help.isOn)
                Divider()
                Button { help.perform(.arranger) { showArranger = true } } label: {
                    Label("Arranger…", systemImage: "list.number")
                }
                Button { help.perform(.sectionImportMIDI) { importingMIDI = true } } label: {
                    Label("Import MIDI…", systemImage: "square.and.arrow.down")
                }
                Divider()
                sectionActions(for: songStore.selectedSection)
            } label: {
                Label("Section", systemImage: "ellipsis.circle")
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            // Tinted while Trigger mode is on: the chips behave differently, and that
            // needs to be visible without opening the menu.
            .tint(songStore.triggerMode ? .accentColor : nil)
            // In help mode: a help screen listing the menu's items, instead of the menu.
            .helpMenu(.section)
            .padding(.trailing, 8)
        }
        .background(.regularMaterial)
        // Started once and left running: the pulse is only visible where a chip opts in,
        // so there is nothing to start and stop as the queue changes.
        .onAppear { queuePulse = true }
        .sheet(item: $editingSection) { target in
            SectionEditorSheet(sectionIndex: target.index, field: target.field)
        }
        .sheet(isPresented: $showArranger) { ArrangerView() }
        .midiImport(isPresented: $importingMIDI)
    }

    /// The actions for one section. Shared by the Section button and by a long press on
    /// a chip, so the two cannot drift apart.
    @ViewBuilder
    private func sectionActions(for index: Int) -> some View {
        // Length is not here: it is the bars button under the section chips.
        // In help mode each item explains itself instead of acting, and none is
        // greyed out, so every one can be asked about.
        Button {
            help.perform(.sectionRename) {
                songStore.selectedSection = index
                editingSection = SectionTarget(index: index, field: .name)
            }
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Divider()
        Button { help.perform(.sectionAdd) { songStore.addSection() } } label: {
            Label("Add Section", systemImage: "plus")
        }
        .disabled(!help.isOn && songStore.song.sections.count >= SongStore.maximumEditableSectionCount)
        Button { help.perform(.sectionDuplicate) { songStore.duplicateSection(at: index) } } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        .disabled(!help.isOn && songStore.song.sections.count >= SongStore.maximumEditableSectionCount)
        Divider()
        Button { help.perform(.sectionMove) { songStore.moveSection(from: index, to: index - 1) } } label: {
            Label("Move Earlier", systemImage: "arrow.left")
        }
        .disabled(!help.isOn && index <= 0)
        Button { help.perform(.sectionMove) { songStore.moveSection(from: index, to: index + 1) } } label: {
            Label("Move Later", systemImage: "arrow.right")
        }
        .disabled(!help.isOn && index >= songStore.song.sections.count - 1)
        Divider()
        Button(role: .destructive) { help.perform(.sectionDelete) { songStore.deleteSection(at: index) } } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(!help.isOn && songStore.song.sections.count <= 1)
    }

    /// Built outside the view body: inline, this concatenation pushed the SwiftUI
    /// type-checker past its limit once the chip gained a context menu.
    private func chipAccessibilityValue(_ section: SongSection,
                                        isSelected: Bool, isPlaying: Bool) -> String {
        var value = "\(section.numberOfBars) bars"
        if isSelected { value += ", selected" }
        if isPlaying { value += ", playing" }
        return value
    }

    // @ViewBuilder so the body can keep its local lets: without it the function needs
    // an explicit return, and the chain is long enough that inference gives up.
    @ViewBuilder
    private func chip(_ idx: Int, _ section: SongSection) -> some View {
        let isPlaying  = songStore.isPlaying && songStore.currentSection == idx
        let isQueued   = songStore.queuedSection == idx
        // In Trigger mode the chips are pads, and a pad lit before anything has been
        // pressed is just confusing — so the highlight follows what is SOUNDING rather
        // than what happens to be selected, and nothing is lit until something plays.
        let isSelected = songStore.triggerMode ? isPlaying : songStore.selectedSection == idx

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
        // Queued: pulsing, and in a different colour from the solid green of the section
        // actually sounding — "next" and "now" have to be distinguishable at a glance.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange, lineWidth: 2)
                .opacity(isQueued ? (queuePulse ? 1 : 0.15) : 0)
                .animation(reduceMotion ? nil
                           : .easeInOut(duration: 0.45).repeatForever(autoreverses: true),
                           value: queuePulse)
        )
        .overlay(alignment: .topTrailing) {
            // Says the chip is pressable without taking room from the name.
            if songStore.triggerMode {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        // In Trigger mode a press IS the action, so the tap and the long-press menu
        // stand aside rather than competing with it.
        .onTapGesture { if !songStore.triggerMode { songStore.selectedSection = idx } }
        .contextMenu { if !songStore.triggerMode { sectionActions(for: idx) } }
        // minimumDuration .infinity so `perform` never fires: only the press and release
        // edges matter, and the sound has to start on touch-down or it feels broken.
        .onLongPressGesture(minimumDuration: .infinity, pressing: { isPressing in
            guard songStore.triggerMode else { return }
            if isPressing { songStore.triggerSection(at: idx) }
            else { songStore.releaseTrigger() }
        }, perform: {})
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Section \(idx + 1), \(section.name)")
        .accessibilityValue(chipAccessibilityValue(section, isSelected: isSelected,
                                                   isPlaying: isPlaying))
        .accessibilityAction { songStore.selectedSection = idx }
        .accessibilityAction(named: Text("Rename section")) {
            songStore.selectedSection = idx
            editingSection = SectionTarget(index: idx, field: .name)
        }
        .accessibilityAction(named: Text("Set number of bars")) {
            songStore.selectedSection = idx
            editingSection = SectionTarget(index: idx, field: .bars)
        }
    }
}

// MARK: - Song order strip

/// The arrangement's places along the top of the section chips, sized by length, while
/// Play Arrangement is on. The place playing is green, with the section sounding lit
/// inside a Song Part. A tap goes to a place when the place playing ends (tap again
/// to cancel); stopped, it plays from there. Dimmed while Hold or Pattern Trigger Mode
/// sets the arrangement aside.
private struct SongOrderStrip: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var help = HelpCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openArranger: () -> Void
    @State private var pulse = false

    var body: some View {
        let rows = ArrangerView.rows(of: songStore.song)
        let totalBars = max(1, rows.reduce(0) { $0 + $1.bars })
        let active = songStore.followsArrangement
        HStack(spacing: 6) {
            Button { help.perform(.songOrderStripOpen, openArranger) } label: {
                Image(systemName: "list.number")
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Open the Arranger")
            .helpTag(.songOrderStripOpen)

            GeometryReader { geo in
                let spacing: CGFloat = 3
                let usable = max(0, geo.size.width - spacing * CGFloat(max(0, rows.count - 1)))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: spacing) {
                        ForEach(rows, id: \.slot.id) { row in
                            segment(row, width: max(64, usable * CGFloat(row.bars) / CGFloat(totalBars)))
                        }
                    }
                    // Rebuilt whenever the order or a name changes, so a place that was
                    // removed or renamed can never be left drawn.
                    .id(rows.map { "\($0.slot.id)\($0.name)" }.joined())
                }
            }
            .frame(height: 40)
            .opacity(active ? 1 : 0.4)
            .disabled(!active && !help.isOn)
            .helpTag(.songOrderStrip)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.regularMaterial)
        .onAppear { pulse = true }
    }

    @ViewBuilder
    private func segment(_ row: ArrangerView.Row, width: CGFloat) -> some View {
        let isPlaying = songStore.playingArrangementSlot == row.slotIndex
        let isQueued = songStore.queuedArrangementSlot == row.slotIndex
        let lit = isPlaying ? songStore.playingEntry?.positionInSlot : nil
        Button { songStore.queueArrangementSlot(row.slotIndex) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                if row.isPart {
                    SectionSegments(sections: row.sections, lit: lit)
                        .frame(height: 4)
                } else {
                    Color.clear.frame(height: 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPlaying ? Color.green.opacity(0.28) : Color.secondary.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isPlaying ? Color.green : Color.clear, lineWidth: 1.5)
            )
            // Queued: pulsing orange, as for a queued pattern pad.
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange, lineWidth: 2)
                    .opacity(isQueued ? (pulse ? 1 : 0.2) : 0)
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 0.45).repeatForever(autoreverses: true),
                               value: pulse)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.name)
        .accessibilityValue(Text(isPlaying ? "Playing" : (isQueued ? "Queued" : "")))
        .accessibilityHint(Text("Plays this place next"))
    }
}

// MARK: - Section settings (bars / key / scale for the selected section)

private struct SectionSettingsBar: View {
    @EnvironmentObject var songStore: SongStore
    @State private var showSnapshots = false
    @State private var showShape = false
    /// The selected section's length, being set from the bars button.
    @State private var editingBars: SectionTarget?

    /// Pulled out of the view body: inline, the string building pushed the SwiftUI
    /// type-checker past its limit for the whole bar.
    private func barsLabel(_ index: Int) -> String {
        guard songStore.song.sections.indices.contains(index) else { return "" }
        let bars = songStore.song.sections[index].numberOfBars
        return "\(bars) bar" + (bars == 1 ? "" : "s")
    }

    var body: some View {
        let sel = songStore.selectedSection
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if songStore.song.sections.indices.contains(sel) {
                // The name is shown read-only so you know where you are; it is set in the
                // section menu. The length is a button, drawn like M / S / FX, and the
                // only place to set it: it is changed often, so it is never in a menu.
                Image(systemName: "square.stack").foregroundStyle(.secondary)
                Text(songStore.song.sections[sel].name)
                    .font(.caption.bold()).lineLimit(1)
                StudioChipLabel(title: barsLabel(sel), tint: .accentColor, look: .status)
                    .onTapGesture { editingBars = SectionTarget(index: sel, field: .bars) }
                    .accessibilityElement()
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Number of bars")
                    .accessibilityValue(barsLabel(sel))
                    .help("Change how many bars this section lasts")
                    .helpTag(.sectionBars)

                Divider().frame(height: 20)

                Button { showShape = true } label: {
                    Label("Shape", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .disabled(!songStore.canAlterSelectedSection)
                .help(songStore.canAlterSelectedSection
                      ? "Reshape this section's notes and steps, on the tracks you choose"
                      : "Turn on Hold first — reshaping is only worth doing while you can hear it.")
                          .helpTag(.shape)

                // A sheet rather than a Menu: snapshots are renameable now, and a menu
                // cannot host an editable text field.
                Button { showSnapshots = true } label: {
                    Label(
                        songStore.song.sections[sel].variations.isEmpty
                            ? "Snapshots"
                            : "Snapshots (\(songStore.song.sections[sel].variations.count))",
                        systemImage: "camera"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!songStore.canAlterSelectedSection)
                .help(songStore.canAlterSelectedSection
                      ? "Save and restore versions of this section's notes and steps"
                      : "Turn on Hold first — Hold repeats this section so you can hear each version as you restore it.")
                          .helpTag(.snapshots)

                Toggle(isOn: $songStore.holdsSection) {
                    Label("Hold", systemImage: "repeat.1")
                }
                .toggleStyle(.button)
                .midiLearnable(.hold)
                .helpTag(.hold)
                .help("Repeat the selected section and stop the editor following the playhead, so it can be edited")

                // Transform and Snapshots are gated on Hold, so say so rather than
                // leaving two greyed-out buttons to explain themselves.
                if !songStore.canAlterSelectedSection {
                    Text("Hold to alter this section")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .sheet(isPresented: $showSnapshots) { SectionSnapshotsSheet() }
        .sheet(isPresented: $showShape) { ShapeSectionView() }
        .sheet(item: $editingBars) { target in
            SectionEditorSheet(sectionIndex: target.index, field: target.field)
        }
    }
}

// MARK: - Section snapshots
//
// Named checkpoints of ONE section's note data — every track's note pool, steps,
// tempo division, key and scale. Instruments, plugin state and mixer settings live on
// the track, not the section, so they are untouched by both saving and restoring.
//
// Restoring is non-destructive: SongStore snapshots the current state before it
// overwrites anything, here and for Transform, because the app has no undo.

private struct SectionSnapshotsSheet: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss

    /// Naming happens in a prompt rather than inline in the row. An inline field wrote
    /// on every keystroke, so deleting the last character handed the sanitiser an empty
    /// string, which it replaced with "Snapshot" and wrote straight back into the field
    /// — the name could never be typed over. A prompt sanitises once, on commit.
    @State private var nameDraft = ""
    @State private var renaming: UUID?
    @State private var showNamePrompt = false

    private var sel: Int { songStore.selectedSection }
    private var section: SongSection? {
        songStore.song.sections.indices.contains(sel) ? songStore.song.sections[sel] : nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(songStore.song.tracks) { track in
                        Button {
                            if songStore.shapeTrackSelection.contains(track.id) {
                                songStore.shapeTrackSelection.remove(track.id)
                            } else {
                                songStore.shapeTrackSelection.insert(track.id)
                            }
                        } label: {
                            HStack {
                                Text(track.name)
                                Spacer()
                                Image(systemName: songStore.shapeTrackSelection.contains(track.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(songStore.shapeTrackSelection.contains(track.id)
                                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }
                            // The whole row, not just its text: the tick is where the
                            // eye goes and tapping it did nothing without this.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .helpTag(.snapshotTracks, instance: track.id.uuidString)
                    }

                    Button {
                        renaming = nil
                        nameDraft = songStore.suggestedSnapshotName()
                        showNamePrompt = true
                    } label: {
                        Label("Save snapshot…", systemImage: "camera")
                    }
                    .disabled(songStore.shapeTrackSelection.isEmpty)
                    .helpTag(.snapshotSave)
                } header: {
                    Text("Save")
                } footer: {
                    // The same selection the Shape sheet uses, so "the tracks I am
                    // working on" means one thing wherever you are.
                    Text("Captures the note pool, steps, division, key and scale for the "
                         + "ticked tracks only — so you can keep one track while "
                         + "reworking another. Instruments and mixer settings are not "
                         + "included.")
                }

                if let section, !section.variations.isEmpty {
                    Section {
                        ForEach(section.variations) { snapshot in
                            snapshotRow(snapshot).contentShape(Rectangle())
                        }
                        // Swiping the Original away is refused by the store; filter it
                        // here too so the gesture does not look like it silently failed.
                        .onDelete { offsets in
                            for id in offsets.map({ section.variations[$0] })
                                        .filter({ !$0.isProtected }).map(\.id) {
                                songStore.deleteVariation(id)
                            }
                        }
                    } header: {
                        Text("Saved")
                    } footer: {
                        Text("Audition plays a snapshot without changing anything. "
                             + "Restore replaces this section's notes with it and uses it "
                             + "up; Restore & Keep leaves it in the list. \"Original\" is "
                             + "saved automatically the first time a section is held, and "
                             + "is always kept.")
                    }
                }
            }
            .navigationTitle("Snapshots")
            .navigationBarTitleDisplayMode(.inline)
            .helpHost()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { HelpButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // An audition is playback-only state; it must not outlive this sheet, or the
            // sequencer would keep playing notes the document does not contain.
            .onDisappear { songStore.stopAudition() }
            .alert(renaming == nil ? "Name this snapshot" : "Rename snapshot",
                   isPresented: $showNamePrompt) {
                TextField("Name", text: $nameDraft)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    if let renaming { songStore.renameVariation(renaming, to: nameDraft) }
                    else {
                        songStore.captureVariation(named: nameDraft,
                                                   tracks: songStore.shapeTrackSelection)
                    }
                }
            } message: {
                Text("Describe what changed, so you know which version to come back to.")
            }
        }
    }

    @ViewBuilder
    private func snapshotRow(_ snapshot: SectionVariation) -> some View {
        let isAuditioning = songStore.auditioningSnapshot == snapshot.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if snapshot.isProtected {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Protected")
                }
                Text(snapshot.name).font(.body).lineLimit(2)
                Spacer(minLength: 6)
                // Scope is the thing you need at a glance now that snapshots can cover
                // one track: restoring the wrong one would quietly revert other work.
                Text(songStore.scopeDescription(of: snapshot))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button {
                    if isAuditioning { songStore.stopAudition() }
                    else { songStore.auditionSnapshot(snapshot.id) }
                } label: {
                    Label(isAuditioning ? "Stop" : "Audition",
                          systemImage: isAuditioning ? "stop.fill" : "play.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(isAuditioning ? .orange : nil)
                .helpTag(.snapshotAudition, instance: snapshot.id.uuidString)

                // The Original is never consumed, so a separate "keep" button for it
                // would offer a choice that does not exist.
                if snapshot.isProtected {
                    Button("Restore") { songStore.applyVariation(snapshot.id, keeping: true) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .helpTag(.snapshotRestore, instance: snapshot.id.uuidString)
                } else {
                    Button("Restore") { songStore.applyVariation(snapshot.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .helpTag(.snapshotRestore, instance: snapshot.id.uuidString)

                    Button("Restore & Keep") { songStore.applyVariation(snapshot.id, keeping: true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .helpTag(.snapshotRestoreKeep, instance: snapshot.id.uuidString)
                }

                Button {
                    renaming = snapshot.id
                    nameDraft = snapshot.name
                    showNamePrompt = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .helpTag(.snapshotRename, instance: snapshot.id.uuidString)

                Spacer(minLength: 0)
            }
            // A List row makes the whole row tappable, which would fire the first
            // button; each button owns its own hit area instead.
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }
}

/// Effects, alongside Mute and Solo.
///
/// Lettered rather than an icon so it reads as one set with M and S, and fixed-width so
/// adding it cannot disturb the column alignment of the collapsed rows. Tinted when the
/// track has effects, so their presence is visible without opening anything.
private struct TrackEffectsButton: View {
    let track: SongTrack

    // Tap: whole chain in/out. Long press: edit. See EffectsToggleButton.
    var body: some View { EffectsToggleButton(track: track) }
}

/// Process CPU load, as a fraction of one core.
///
/// Hosting AUv3s is where this app spends its time and the ceiling is real — a single
/// master limiter once caused audible crackle with a heavy sampled instrument. With
/// effects able to multiply that, the point is to watch the limit approach rather than
/// meet it as a dropout.
private struct CPUReadout: View {
    @StateObject private var monitor = CPUMonitor()

    private var tint: Color {
        monitor.load >= CPUMonitor.warningLoad ? .orange
            : monitor.load >= CPUMonitor.warningLoad * 0.7 ? .yellow : .secondary
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "cpu").font(.caption2)
            Text("\(Int((monitor.load * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                // Fixed width so the transport does not shuffle as the number changes.
                .frame(minWidth: 34, alignment: .trailing)
        }
        .foregroundStyle(tint)
        .fixedSize()
        .help("Processor load. Hosted plugins are the main cost; crackle and dropouts "
              + "start when this runs out.")
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
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
    /// In help mode, menu items explain themselves instead of acting.
    @ObservedObject private var help = HelpCenter.shared

    @State private var showEffects = false
    @State private var showPluginPicker = false
    @State private var showPluginEditor = false
    @State private var showSteps = false
    @State private var showNoteParams = false
    @State private var showScalePicker = false
    @State private var showDeleteAlert = false
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
            stepsSectionID = nil
        }) {
            if let sectionID = stepsSectionID {
                let target = pinnedPartBinding(sectionID: sectionID)
                StepsView(steps: target.steps, noteCount: target.wrappedValue.notePool.count)
            }
        }
        .sheet(isPresented: $showEffects) {
            TrackEffectsView(trackID: track.id)
        }
        .sheet(isPresented: $showNoteParams, onDismiss: {
            noteParametersSectionID = nil
        }) {
            if let sectionID = noteParametersSectionID {
                NoteParametersView(notePool: pinnedPartBinding(sectionID: sectionID).notePool)
            }
        }
        .sheet(isPresented: $showScalePicker, onDismiss: {
            if pendingKeyScale == nil { scaleSectionID = nil }
        }) {
            KeyScalePickerView(
                currentKey: part.key,
                currentScale: part.scale,
                droppedCount: { key, scale in
                    guard let sectionID = scaleSectionID else { return 0 }
                    return offendingNotes(in: pinnedPartBinding(sectionID: sectionID).wrappedValue,
                                          key: key, scale: scale).count
                },
                onApply: { key, scale in
                    guard let sectionID = scaleSectionID else { return }
                    proposeKeyScale(sectionID: sectionID, key: key, scale: scale)
                }
            )
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

    /// A menu entry that says whether it is doing anything, so the state is visible at
    /// the level above rather than only inside the submenu.
    private func feelLabel(_ name: String, on: Bool) -> String {
        on ? "\(name) ✓" : name
    }

    /// Steps for the step INDICATOR, which is a playback readout rather than an editor.
    ///
    /// The selection now follows the playhead, so in normal use this agrees with
    /// `part.steps`. It still matters in the gap where the two disagree: tapping another
    /// section in the arrangement strip mid-playback moves the selection until the next
    /// boundary snaps it back. The active-step index comes from the sequencer and refers
    /// to the section SOUNDING, so drawing it against a different section's step list
    /// would highlight an unrelated step.
    private var indicatorSteps: [Step] {
        guard songStore.isPlaying || songStore.isPaused else { return part.steps }
        let playing = songStore.currentSection
        guard songStore.song.sections.indices.contains(playing),
              let p = songStore.song.sections[playing].parts.first(where: { $0.trackID == track.id })
        else { return part.steps }
        return p.steps
    }

    /// Move, duplicate and delete. Shared by the expanded row's menu and by a long press
    /// on a collapsed row, so the two cannot drift apart.
    @ViewBuilder
    private var arrangeActions: some View {
        Button { help.perform(.trackMove) { songStore.moveTrackUp(track.id) } } label: {
            Label("Move Up", systemImage: "chevron.up")
        }
        .disabled(!help.isOn && index == 0)

        Button { help.perform(.trackMove) { songStore.moveTrackDown(track.id) } } label: {
            Label("Move Down", systemImage: "chevron.down")
        }
        .disabled(!help.isOn && index == trackCount - 1)

        Button { help.perform(.trackDuplicate) { songStore.duplicateTrack(track.id) } } label: {
            Label("Duplicate Track", systemImage: "plus.square.on.square")
        }
        .disabled(!help.isOn && trackCount >= SongStore.maximumEditableTrackCount)

        // The built-in General MIDI sound, used while the track has no plugin.
        if track.pluginInfo == nil || help.isOn {
            builtInSoundMenu
        }
    }

    /// Every General MIDI instrument, by family, plus the drum kit.
    private var builtInSoundMenu: some View {
        Menu {
            ForEach(Array(GeneralMIDI.families.enumerated()), id: \.offset) { family, name in
                Menu(name) {
                    ForEach(family * 8 ..< family * 8 + 8, id: \.self) { program in
                        soundButton(program)
                    }
                }
            }
            Divider()
            soundButton(GeneralMIDI.drumKit)
        } label: {
            Label("Built-in Sound: \(GeneralMIDI.soundName(track.builtInSound))", systemImage: "pianokeys")
        }
    }

    private func soundButton(_ sound: Int) -> some View {
        Button {
            help.perform(.trackBuiltInSound) { songStore.setBuiltInSound(sound, forTrack: track.id) }
        } label: {
            if (track.builtInSound ?? 0) == sound {
                Label(GeneralMIDI.soundName(sound), systemImage: "checkmark")
            } else {
                Text(GeneralMIDI.soundName(sound))
            }
        }
    }

    /// The same actions plus expand and delete, for a collapsed row — which has no menu
    /// button of its own.
    ///
    /// A long press rather than the left swipe that was asked for. A collapsed row
    /// contains a horizontally scrolling step strip, so a horizontal drag on the row
    /// would fight it for the gesture; and these rows sit in a plain stack rather than a
    /// List, so there is no `swipeActions` to lean on.
    @ViewBuilder
    private var collapsedRowActions: some View {
        Button {
            help.perform(.trackExpand) {
                if reduceMotion { isCollapsed = false }
                else { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false } }
            }
        } label: {
            Label("Expand", systemImage: "chevron.down")
        }
        // The row's long press is this menu, which takes the long press from the FX
        // button too, so the effects are reachable from here as well.
        Button { help.perform(.trackEffectsMenu) { showEffects = true } } label: {
            Label("Effects…", systemImage: "fx")
        }
        Divider()
        arrangeActions
        Divider()
        Button(role: .destructive) { help.perform(.trackDelete) { showDeleteAlert = true } } label: {
            Label("Delete Track", systemImage: "trash")
        }
    }

    // Compact one-line row shown when the track is collapsed.
    /// Below this the wide one-line layout is too cramped and ViewThatFits falls back
    /// to the stacked compact bar. It replaces a `.fixedSize` on the wide variant: that
    /// pinned the row to its intrinsic width, which left no slack for the step strip to
    /// grow into. A minimum width still gives ViewThatFits a real threshold to test,
    /// while letting the row stretch — and hand the surplus to the strip — above it.
    private static let wideCollapsedMinWidth: CGFloat = 620

    private var collapsedBar: some View {
        ViewThatFits(in: .horizontal) {
            collapsedWideBar
                .frame(minWidth: Self.wideCollapsedMinWidth, maxWidth: .infinity, alignment: .leading)
            collapsedCompactBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { collapsedRowActions }
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
            .helpTag(.trackExpand, instance: track.id.uuidString)

            // Mixer controls lead the row, ahead of the variable-width text.
            //
            // They used to trail a Spacer, but this bar is laid out at its intrinsic
            // width (`.fixedSize` in collapsedBar), so that width tracked the track and
            // plugin names — and the controls landed at a different x on every row.
            // Every element before the toggles is now a fixed width, so volume, mute
            // and solo line up down the whole track list regardless of naming.
            Image(systemName: "speaker.wave.1").font(.system(size: 9)).foregroundStyle(.secondary)
            StudioSlider.volume($track.mixer.volume, label: "\(track.name) volume")
                .midiLearnable(.trackVolume(index))
                .helpTag(.trackVolume, instance: track.id.uuidString)
                .frame(width: 70)
            // Explicit width: the meter is maxWidth-greedy, which has no intrinsic size
            // to resolve inside a fixed-size row.
            SongTrackMeter(trackID: track.id).frame(width: 44)
                .helpTag(.trackMeter, instance: track.id.uuidString)

            StudioToggleChip(title: "M", isOn: $track.mixer.isMuted, tint: .orange,
                             accessibilityLabel: "Mute \(track.name)")
                .midiLearnable(.trackMute(index))
                .helpTag(.trackMute, instance: track.id.uuidString)
            StudioToggleChip(title: "S", isOn: $track.mixer.isSoloed, tint: .yellow,
                             accessibilityLabel: "Solo \(track.name)")
                .midiLearnable(.trackSolo(index))
                .helpTag(.trackSolo, instance: track.id.uuidString)
            TrackEffectsButton(track: track)
                .midiLearnable(.trackEffects(index))
                .helpTag(.trackEffects, instance: track.id.uuidString)
            // W or P: only there when a controller's keys go to the tracks.
            TrackWriteNotesButton(track: track, index: index)

            Divider().frame(height: 16)

            Text(track.name).font(.subheadline.bold()).lineLimit(1)
                // A folded track's menu is a long press; in help mode its name opens
                // the track menu's help screen.
                .helpMenu(.track, instance: track.id.uuidString)

            Divider().frame(height: 16)

            Text(track.pluginInfo?.name ?? "No plugin")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            Divider().frame(height: 16)

            // Division + step indicator for the selected/playing section.
            Text(part.tempoDivision.abbreviation)
                .font(.caption2).foregroundStyle(.secondary)

            // The strip takes ALL the remaining width — no trailing Spacer competing
            // with it for the slack — so it shows as many steps as the row can hold and
            // only scrolls once they overflow that.
            // Always there, so the row keeps its height when the steps come and go —
            // see SongMiniSteps.emptyLabel.
            SongMiniSteps(trackID: track.id, steps: indicatorSteps,
                          emptyLabel: "No steps · instrument only")
                .helpTag(.trackSteps, instance: track.id.uuidString)
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
                .helpTag(.trackExpand, instance: track.id.uuidString)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name).font(.subheadline.bold()).lineLimit(1)
                // A folded track's menu is a long press; in help mode its name opens
                // the track menu's help screen.
                .helpMenu(.track, instance: track.id.uuidString)
                    Text(track.pluginInfo?.name ?? "Built-in Sound")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                StudioToggleChip(title: "M", isOn: $track.mixer.isMuted, tint: .orange,
                                 accessibilityLabel: "Mute \(track.name)")
                    .midiLearnable(.trackMute(index))
                    .helpTag(.trackMute, instance: track.id.uuidString)
                StudioToggleChip(title: "S", isOn: $track.mixer.isSoloed, tint: .yellow,
                                 accessibilityLabel: "Solo \(track.name)")
                    .midiLearnable(.trackSolo(index))
                    .helpTag(.trackSolo, instance: track.id.uuidString)
                TrackEffectsButton(track: track)
                    .midiLearnable(.trackEffects(index))
                    .helpTag(.trackEffects, instance: track.id.uuidString)
                // W or P: only there when a controller's keys go to the tracks.
                TrackWriteNotesButton(track: track, index: index)
            }
            HStack(spacing: 8) {
                Text(part.tempoDivision.abbreviation).font(.caption2).foregroundStyle(.secondary)
                SongMiniSteps(trackID: track.id, steps: indicatorSteps,
                              emptyLabel: "No steps · instrument only")
                    .helpTag(.trackSteps, instance: track.id.uuidString)
                Spacer(minLength: 4)
                Image(systemName: "speaker.wave.1").font(.caption2).foregroundStyle(.secondary)
                StudioSlider.volume($track.mixer.volume, label: "\(track.name) volume")
                    .midiLearnable(.trackVolume(index))
                    .helpTag(.trackVolume, instance: track.id.uuidString)
                    .frame(minWidth: 70, maxWidth: 150)
                SongTrackMeter(trackID: track.id)
                    .helpTag(.trackMeter, instance: track.id.uuidString)
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
                .helpTag(.trackExpand, instance: track.id.uuidString)

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
                .helpTag(.trackName, instance: track.id.uuidString)

                Menu {
                    arrangeActions
                    Divider()

                    // Feel lives in the track menu rather than on the row: it is set
                    // once per instrument and then left alone, so it does not earn
                    // permanent space next to the controls used every take.
                    Menu {
                        Picker("Chord Roll", selection: help.guarded(.feelChordRoll, Binding(
                            get: { Int(track.effectiveChordSpread.rounded()) },
                            set: { track.chordSpread = Double($0) }
                        ))) {
                            Text("Off (block chords)").tag(0)
                            Text("Subtle — 15 ms").tag(15)
                            Text("Played — 30 ms").tag(30)
                            Text("Loose — 55 ms").tag(55)
                            Text("Harp — 90 ms").tag(90)
                        }
                    } label: {
                        Label(feelLabel("Chord Roll", on: track.effectiveChordSpread > 0), systemImage: "hand.draw")
                    }

                    Menu {
                        Picker("Accent", selection: help.guarded(.feelAccent, Binding(
                            get: { track.effectiveAccent },
                            set: { track.accent = $0 }
                        ))) {
                            Text("Off (even)").tag(0)
                            Text("Light").tag(12)
                            Text("Medium").tag(24)
                            Text("Strong").tag(40)
                        }
                    } label: {
                        Label(feelLabel("Accent", on: track.effectiveAccent > 0), systemImage: "waveform.path.ecg")
                    }

                    Menu {
                        Picker("Variation", selection: help.guarded(.feelVariation, Binding(
                            get: { track.effectiveVariation },
                            set: { track.variation = $0 }
                        ))) {
                            Text("Off (identical)").tag(0)
                            Text("Light").tag(10)
                            Text("Medium").tag(22)
                            Text("Strong").tag(40)
                        }
                    } label: {
                        Label(feelLabel("Variation", on: track.effectiveVariation > 0), systemImage: "dice")
                    }

                    Menu {
                        Picker("Swing", selection: help.guarded(.feelSwing, Binding(
                            get: { Int(track.effectiveSwing.rounded()) },
                            set: { track.swing = Double($0) }
                        ))) {
                            Text("Off (straight)").tag(0)
                            Text("Light — 25%").tag(25)
                            Text("Medium — 50%").tag(50)
                            Text("Hard — 75%").tag(75)
                            Text("Full triplet — 100%").tag(100)
                        }
                    } label: {
                        Label(feelLabel("Swing", on: track.effectiveSwing > 0), systemImage: "metronome")
                    }

                    Menu {
                        Picker("Timing", selection: help.guarded(.feelTiming, Binding(
                            get: { Int(track.effectiveTimingJitter.rounded()) },
                            set: { track.timingJitter = Double($0) }
                        ))) {
                            Text("Off (exact)").tag(0)
                            Text("Tight — 10 ms").tag(10)
                            Text("Human — 22 ms").tag(22)
                            Text("Loose — 40 ms").tag(40)
                        }
                    } label: {
                        Label(feelLabel("Timing", on: track.effectiveTimingJitter > 0), systemImage: "waveform.path")
                    }

                    Divider()

                    Button { help.perform(.trackEffectsMenu) { showEffects = true } } label: {
                        Label(track.effectSlots.isEmpty
                              ? "Effects" : "Effects (\(track.effectSlots.count))",
                              systemImage: "fx")
                    }

                    Divider()

                    Button(role: .destructive) { help.perform(.trackDelete) { showDeleteAlert = true } } label: {
                        Label("Delete Track", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").iconHitTarget(34)
                        // Tinted when any Feel setting is on. They live two menus deep,
                        // so a track could be swung, accented and loosened with nothing
                        // on screen to say why it sounded different from its neighbour.
                        .foregroundStyle(track.hasFeel ? AnyShapeStyle(.tint)
                                                       : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Actions for \(track.name)")
                // In help mode: a help screen listing the menu's items, instead of the menu.
                .helpMenu(.track, instance: track.id.uuidString)
            }

            Button { showPluginPicker = true } label: {
                Label(track.pluginInfo?.name ?? "Choose Plugin",
                      systemImage: track.pluginInfo == nil ? "puzzlepiece.extension" : "puzzlepiece.extension.fill")
                    .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .tint(track.pluginInfo == nil ? nil : .accentColor)
            .helpTag(.trackInstrument, instance: track.id.uuidString)

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
                .helpTag(.trackEditInstrument, instance: track.id.uuidString)
            }

            // Volume gets its own line; the meter sits beside pan, matching its size,
            // so the level is readable rather than a 6pt sliver.
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                StudioSlider.volume($track.mixer.volume, label: "\(track.name) volume")
                    .midiLearnable(.trackVolume(index))
                    .helpTag(.trackVolume, instance: track.id.uuidString)
            }

            HStack(spacing: 6) {
                Text("Pan").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .leading)
                // A knob, as on the mixer: a small square instead of a slider's width.
                StudioKnob(value: Binding(get: { Double(track.mixer.pan) },
                                          set: { track.mixer.pan = Float($0) }),
                           range: -1...1, defaultValue: 0, bipolar: true, size: 30,
                           format: { p in
                               abs(p) < 0.05 ? "C" : (p < 0 ? "L\(Int(abs(p) * 100))" : "R\(Int(p * 100))")
                           })
                    .accessibilityLabel("\(track.name) pan")
                    .midiLearnable(.trackPan(index))
                    .helpTag(.trackPan, instance: track.id.uuidString)
                Spacer(minLength: 0)
                StudioToggleChip(title: "M", isOn: $track.mixer.isMuted, tint: .orange,
                                 accessibilityLabel: "Mute \(track.name)")
                    .midiLearnable(.trackMute(index))
                    .helpTag(.trackMute, instance: track.id.uuidString)
                StudioToggleChip(title: "S", isOn: $track.mixer.isSoloed, tint: .yellow,
                                 accessibilityLabel: "Solo \(track.name)")
                    .midiLearnable(.trackSolo(index))
                    .helpTag(.trackSolo, instance: track.id.uuidString)
                TrackEffectsButton(track: track)
                    .midiLearnable(.trackEffects(index))
                    .helpTag(.trackEffects, instance: track.id.uuidString)
                // W or P: only there when a controller's keys go to the tracks.
                TrackWriteNotesButton(track: track, index: index)
            }

            // Level meter spans the row beneath the controls, where it has room to read.
            SongTrackMeter(trackID: track.id)
                .helpTag(.trackMeter, instance: track.id.uuidString)
        }
    }

    // Right — section-level: this track's note data for the selected section.
    private var noteZone: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // "Time" rather than "Rate": it is how long each step lasts, and
                    // a step of 4/1 is not something anyone would call a rate.
                    Text("Time").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $part.tempoDivision) {
                        ForEach(TempoDivision.allCases, id: \.self) { Text($0.abbreviation).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()
                    .helpTag(.trackTime, instance: track.id.uuidString)

                    Divider().frame(height: 16)

                    // Key and scale are one control: choosing them separately asked
                    // twice whether to drop notes, and answered the first question
                    // without knowing the second.
                    Button {
                        guard let sectionID = selectedSectionID else { return }
                        scaleSectionID = sectionID
                        showScalePicker = true
                    } label: {
                        Text("\(noteNames[part.key]) \(part.scale.rawValue)")
                            .font(.caption2).lineLimit(1)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .helpTag(.trackKeyScale, instance: track.id.uuidString)

                    Text("\(part.notePool.count) notes").font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            SongMiniSteps(trackID: track.id, steps: indicatorSteps, compact: false,
                          emptyLabel: "No steps: instrument only. Add a step to sequence.")
                .helpTag(.trackSteps, instance: track.id.uuidString)

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

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                Button {
                    guard let sectionID = selectedSectionID else { return }
                    noteParametersSectionID = sectionID
                    showNoteParams = true
                } label: {
                    Label("Note Params", systemImage: "slider.vertical.3").font(.caption)
                }
                .buttonStyle(.bordered).disabled(part.notePool.isEmpty)
                .helpTag(.trackNoteParams, instance: track.id.uuidString)

                Button {
                    guard let sectionID = selectedSectionID else { return }
                    stepsSectionID = sectionID
                    showSteps = true
                } label: {
                    Label(part.steps.isEmpty ? "Steps" : "Steps (\(part.steps.count))",
                          systemImage: "list.number").font(.caption)
                }
                .buttonStyle(.bordered)
                .helpTag(.trackStepsButton, instance: track.id.uuidString)
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
    let onPreview: (Int) -> Void
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        // Redrawn only when this track's notes change, not on every note of every
        // track (see SongMiniSteps).
        TrackKeyboardContent(
            notePool: $notePool,
            scale: scale,
            key: key,
            // What the sequencer is sounding, plus keys held on a MIDI controller.
            playing: (playback.playingNotes[trackID] ?? [])
                + (playback.heldKeys[trackID].map { Array($0).sorted() } ?? []),
            onPreview: onPreview
        )
        .equatable()
        .helpTag(.trackKeyboard, instance: trackID.uuidString)
    }
}

private struct TrackKeyboardContent: View, Equatable {
    @Binding var notePool: [NoteEntry]
    let scale: MusicalScale
    let key: Int
    let playing: [Int]
    let onPreview: (Int) -> Void

    static func == (a: TrackKeyboardContent, b: TrackKeyboardContent) -> Bool {
        a.playing == b.playing && a.key == b.key && a.scale == b.scale && a.notePool == b.notePool
    }

    var body: some View {
        PianoKeyboardView(notePool: $notePool, scale: scale, playingNotes: playing,
                          key: key, onPreview: onPreview)
    }
}

/// Step-sequence indicator with the active step highlighted (observes PlaybackMonitor).
/// Step-sequence indicator for one track, with the playing step lit.
///
/// Reads the playing step here and hands it to StepStrip, which is only redrawn when
/// ITS track's step or steps change. Every strip observing the shared PlaybackMonitor
/// used to rebuild on every step of every track: with eleven imported parts of
/// hundreds of steps each, that alone held the processor over 100% and caused
/// dropouts, muted or not.
private struct SongMiniSteps: View {
    let trackID: UUID
    let steps: [Step]
    var compact: Bool = true
    var emptyLabel: String = ""
    @EnvironmentObject var playback: PlaybackMonitor

    var body: some View {
        StepStrip(steps: steps, compact: compact, emptyLabel: emptyLabel,
                  activeStep: playback.activeSteps[trackID])
            .equatable()
    }
}

private struct StepStrip: View, Equatable {
    let steps: [Step]
    var compact: Bool = true
    /// Shown in place of the steps when there are none, in the same font and padding as
    /// a step chip, so the strip is exactly as tall either way.
    ///
    /// The strip used to be left out when a part had no steps. While playing it shows
    /// the section that is SOUNDING and when stopped the one SELECTED, so whenever one of
    /// those had steps and the other did not — and Stop returns playback to the first
    /// section — starting or stopping made the strip vanish or reappear, and every track
    /// below jumped by its height.
    var emptyLabel: String = ""
    let activeStep: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (a: StepStrip, b: StepStrip) -> Bool {
        a.activeStep == b.activeStep && a.compact == b.compact
            && a.emptyLabel == b.emptyLabel && a.steps == b.steps
    }

    /// The strip fills whatever width the row has left and only scrolls once the steps
    /// overflow it, so a short sequence is shown whole and stays still.
    ///
    /// A fixed six-step window was tried first and was hard to read: it scrolled
    /// constantly, even for sequences that would have fitted comfortably. This is the
    /// floor for that fill — enough that the strip is never a useless sliver in a
    /// narrow row — not a target.
    private static let visibleSteps: CGFloat = 6
    private var chipSpacing: CGFloat { 3 }
    private var chipMinWidth: CGFloat { compact ? 26 : 30 }
    private var windowWidth: CGFloat {
        Self.visibleSteps * chipMinWidth
            + (Self.visibleSteps - 1) * chipSpacing
            + 4   // the HStack's horizontal padding
    }

    var body: some View {
        let size: CGFloat = compact ? 8 : 10
        // A long step list cannot fit the row, so the strip scrolls — but scrolling it
        // by hand while the sequencer runs is hopeless. Keep the playing step in view
        // instead: the strip follows the playhead, and dragging it still works for
        // inspecting a stopped sequence.
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy: only the chips in view are built. An imported part can have
                // hundreds of steps, and building every one on each step was costly.
                LazyHStack(spacing: chipSpacing) {
                    if steps.isEmpty {
                        Text(emptyLabel.isEmpty ? " " : emptyLabel)
                            .font(.system(size: size, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .lineLimit(1)
                    }
                    ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                        let isActive = activeStep == idx
                        Text(step.label)
                            .font(.system(size: size, weight: isActive ? .bold : .regular, design: .monospaced))
                            .foregroundStyle(isActive ? .black : .secondary)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .frame(minWidth: chipMinWidth)
                            .background(isActive ? Color.accentColor : Color.secondary.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.08), value: isActive)
                            // Scroll target keyed by the step's own id, matching the
                            // ForEach identity — an index-based .id() would override
                            // that stable identity and churn the views on reorder.
                            .id(step.id)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: activeStep) { step in
                guard let step, steps.indices.contains(step) else { return }
                // No anchor, deliberately: that scrolls the MINIMUM needed to bring the
                // step into view, so a sequence that fits does not move at all and a
                // longer one only nudges when the playhead reaches the edge. Anchoring
                // to .center instead re-centred on every step, which kept the whole
                // strip in constant motion and was near-impossible to read.
                let target = steps[step].id
                if reduceMotion {
                    proxy.scrollTo(target)
                } else {
                    withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(target) }
                }
            }
        }
        // Fill the row's remaining width, with the window as a floor. Scrolling then
        // only happens when the steps genuinely outgrow the space available, rather
        // than on every sequence longer than an arbitrary count.
        // idealWidth is pinned, not just min/max. Without it the strip's ideal size is
        // its CONTENT's — every chip in the sequence — because that is what a ScrollView
        // reports. The collapsed row is one candidate in a ViewThatFits, which measures
        // candidates at their ideal size, so a part with many steps inflated the row's
        // ideal past the available width, the wide one-line layout was judged not to
        // fit, and the whole row silently fell back to the stacked compact bar: step
        // display first, mixer controls no longer aligned down the list. The measured
        // width must not depend on how many steps a part happens to have.
        .frame(minWidth: windowWidth, idealWidth: windowWidth,
               maxWidth: .infinity, alignment: .leading)
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

/// The master output level, on its side, for the transport. Observes the levels
/// itself so a level tick re-renders only this, not the transport.
private struct MasterLevelBar: View {
    @EnvironmentObject var levels: LevelMonitor
    var body: some View {
        SegmentedMeter(level: levels.masterLevel, segments: 16, vertical: false)
            .frame(height: 6)
            .accessibilityLabel("Master level")
    }
}

struct SongTrackMeter: View {
    let trackID: UUID
    @EnvironmentObject var levels: LevelMonitor

    var body: some View {
        // The mixer's segmented meter, laid on its side: RMS body, held peak segment,
        // latching red clip segment (tap to clear). Observes the levels itself, so a
        // level tick re-renders only this.
        SegmentedMeter(level: levels.trackLevels[trackID] ?? .silent,
                       segments: 12, vertical: false)
            .frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8)
    }
}
