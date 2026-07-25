import SwiftUI

struct TrackDetailView: View {
    @Binding var track: Track
    @EnvironmentObject var store: ProjectStore
    var onDelete: () -> Void

    @State private var showNoteParams = false
    @State private var showDeleteAlert = false
    @State private var showScalePicker = false

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
        .sheet(isPresented: $showScalePicker) {
            ScalePickerView(selectedScale: $track.scale)
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
                    Button {
                        showScalePicker = true
                    } label: {
                        Text(track.scale.rawValue)
                    }
                    .buttonStyle(.bordered)
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
                    playingNote: store.playback.playingNotes[track.id],
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

// MARK: - Step Type Picker Sheet

struct StepTypePickerSheet: View {
    @Binding var selectedType: StepType
    @Environment(\.dismiss) private var dismiss

    private func description(for type: StepType) -> String {
        switch type {
        case .fwd:    return "Play the current note, then move the pointer forward"
        case .back:   return "Play the current note, then move the pointer backward"
        case .rep:    return "Play the current note N times without moving"
        case .play:   return "Jump to note N in the pool and play it"
        case .skip:   return "Hold — keep the previous note ringing, don't play a new one"
        case .random: return "Jump to a random step and execute it"
        }
    }

    var body: some View {
        NavigationStack {
            List(StepType.allCases, id: \.self) { type in
                Button {
                    selectedType = type
                    dismiss()
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(type.rawValue)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(description(for: type))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if type == selectedType {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Step Type")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Step Row

struct StepRow: View {
    @Binding var step: Step
    let index: Int
    var noteCount: Int = 0     // pool size, for chord validation
    let onDelete: () -> Void

    @State private var showTypePicker = false
    @State private var chordText = ""

    private var poolHint: String { noteCount > 0 ? " (of \(noteCount))" : "" }

    private var currentDescription: String {
        switch step.type {
        case .fwd:
            return step.n == 1 ? "Play current, move forward 1"
                               : "Play current, move forward \(step.n)"
        case .back:
            return step.n == 1 ? "Play current, move back 1"
                               : "Play current, move back \(step.n)"
        case .rep:
            return step.n == 1 ? "Play current note once"
                               : "Play current note \(step.n) times"
        case .play:
            if step.chordPositions.count > 1 {
                return "Play pool notes \(step.chordPositions.map(String.init).joined(separator: ", ")) together" + poolHint
            }
            return "Jump to pool note \(step.n) and play it" + poolHint
        case .skip:   return "Hold — previous note keeps ringing"
        case .random: return "Jump to a random step and execute it"
        }
    }

    // Parse "1,3,5" → validated, de-duplicated, in-range positions.
    private func parseChord(_ s: String) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for part in s.split(separator: ",") {
            if let v = Int(part.trimmingCharacters(in: .whitespaces)), v >= 1,
               (noteCount <= 0 || v <= noteCount), seen.insert(v).inserted {
                out.append(v)
            }
        }
        return out
    }

    private func syncChordText() {
        chordText = step.chordPositions.count > 1
            ? step.chordPositions.map(String.init).joined(separator: ",")
            : "\(step.n)"
    }

    private var stepperLabel: String? {
        switch step.type {
        case .fwd:  return "Advance: \(step.n)"
        case .back: return "Retreat: \(step.n)"
        case .rep:  return "×\(step.n)"
        case .play: return "Note: \(step.n)"
        default:    return nil
        }
    }

    private var stepperRange: ClosedRange<Int> {
        switch step.type {
        case .rep:  return 1...32
        case .play: return 1...128
        default:    return 1...16
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)

                Button {
                    showTypePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Text(step.type.rawValue)
                            .font(.body)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showTypePicker) {
                    StepTypePickerSheet(selectedType: $step.type)
                }

                if step.type == .play {
                    TextField("1,3,5", text: $chordText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(maxWidth: 150)
                        .onChange(of: chordText) { newVal in
                            let parsed = parseChord(newVal)
                            step.chordPositions = parsed.count > 1 ? parsed : []
                            step.n = parsed.first ?? step.n
                        }
                } else if let label = stepperLabel {
                    Stepper(label, value: $step.n, in: stepperRange)
                        .frame(maxWidth: 150)
                }

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            Text(currentDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 34)
        }
        .padding(.vertical, 4)
        .onAppear { syncChordText() }
        .onChange(of: step.type) { _ in syncChordText() }
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
