import SwiftUI

struct TrackDetailView: View {
    @Binding var track: Track
    @EnvironmentObject var store: ProjectStore
    var onDelete: () -> Void

    @State private var showNoteParams = false
    @State private var showDeleteAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                instrumentSection
                notesSection
                stepsSection
            }
            .padding()
        }
        .onChange(of: track.scale) { _ in pruneNotePool() }
        .onChange(of: track.key)   { _ in pruneNotePool() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Track Name", text: $track.name)
                    .multilineTextAlignment(.center)
                    .font(.headline)
                    .frame(minWidth: 160)
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showNoteParams = true
                } label: {
                    Label("Note Params", systemImage: "music.note.list")
                }
                Button {
                    showDeleteAlert = true
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .sheet(isPresented: $showNoteParams) {
            NoteParametersView(notePool: $track.notePool)
        }
        .alert("Delete \"\(track.name)\"?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Instrument

    private var instrumentSection: some View {
        GroupBox(label: Label("Instrument", systemImage: "pianokeys")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(track.pluginInfo?.name ?? "No plugin loaded")
                        .foregroundStyle(track.pluginInfo == nil ? .secondary : .primary)
                    Spacer()
                    Button("Select Plugin") { }
                        .buttonStyle(.bordered)
                }
                HStack {
                    Text("Tempo Division")
                    Spacer()
                    Picker("", selection: $track.tempoDivision) {
                        ForEach(TempoDivision.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("Key")
                    Spacer()
                    Picker("", selection: $track.key) {
                        ForEach(0..<12, id: \.self) { n in
                            Text(Self.noteNames[n]).tag(n)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("", selection: $track.scale) {
                        ForEach(MusicalScale.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Notes

    private var notesSection: some View {
        GroupBox(label: Label("Notes (\(track.notePool.count) selected)", systemImage: "music.note")) {
            VStack(alignment: .leading, spacing: 12) {
                PianoKeyboardView(
                    notePool: $track.notePool,
                    scale: track.scale,
                    playingNote: store.playingNotes[track.id],
                    key: track.key
                )

                if track.notePool.isEmpty {
                    Text("Tap keys above to add notes to the pool")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    HStack {
                        Spacer()
                        Button {
                            showNoteParams = true
                        } label: {
                            Label("Note Parameters", systemImage: "slider.vertical.3")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Step Sequence

    private var stepsSection: some View {
        GroupBox(label: Label("Step Sequence", systemImage: "list.number")) {
            VStack(alignment: .leading, spacing: 4) {
                if track.steps.isEmpty {
                    Text("No steps — sequencer plays notes in order by default")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.vertical, 4)
                } else {
                    ForEach(track.steps.indices, id: \.self) { idx in
                        StepRow(step: $track.steps[idx], index: idx) {
                            track.steps.remove(at: idx)
                        }
                        if idx < track.steps.count - 1 { Divider() }
                    }
                }

                HStack {
                    Button {
                        track.steps.append(Step(type: .fwd))
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                    Spacer()
                    if !track.steps.isEmpty {
                        Button("Clear", role: .destructive) {
                            track.steps.removeAll()
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.vertical, 8)
        }
    }

    private func pruneNotePool() {
        track.notePool.removeAll { entry in
            let semitone = ((entry.midiNote % 12) - track.key + 12) % 12
            return !track.scale.intervals.contains(semitone)
        }
    }

    static let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
}

// MARK: - Step Row

struct StepRow: View {
    @Binding var step: Step
    let index: Int
    let onDelete: () -> Void

    private var usesN: Bool {
        step.type == .fwd || step.type == .back
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            Picker("", selection: $step.type) {
                ForEach(StepType.allCases, id: \.self) {
                    Text($0.rawValue).tag($0)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)

            if usesN {
                Stepper("N: \(step.n)", value: $step.n, in: 1...8)
                    .frame(maxWidth: 130)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Note Parameter Row (shared with NoteParametersView)

struct NoteParameterRow: View {
    @Binding var entry: NoteEntry

    private var noteName: String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let octave = entry.midiNote / 12 - 1
        return "\(names[entry.midiNote % 12])\(octave)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(noteName)
                .font(.system(.body, design: .monospaced))
                .frame(width: 34)
            VStack(spacing: 6) {
                HStack {
                    Text("Vel").font(.caption2).foregroundStyle(.secondary).frame(width: 28)
                    Slider(value: Binding(
                        get: { Double(entry.velocity) },
                        set: { entry.velocity = Int($0) }
                    ), in: 1...127, step: 1)
                    Text("\(entry.velocity)").font(.caption2).monospacedDigit().frame(width: 28)
                }
                HStack {
                    Text("Gate").font(.caption2).foregroundStyle(.secondary).frame(width: 28)
                    Slider(value: $entry.gateLength, in: 0.05...1.0)
                    Text("\(Int(entry.gateLength * 100))%").font(.caption2).monospacedDigit().frame(width: 28)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
