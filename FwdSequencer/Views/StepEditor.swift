import SwiftUI

// MARK: - Step Type Picker Sheet

struct StepTypePickerSheet: View {
    @Binding var selectedType: StepType
    @Environment(\.dismiss) private var dismiss

    private func description(for type: StepType) -> String {
        switch type {
        case .fwd:    return "Move forward N and play — a plain run walks the pool"
        case .back:   return "Move back N and play"
        case .rep:    return "Replay the current note N times"
        case .play:   return "Jump to note N (or a chord) and play it"
        case .random: return "Play a random note from the pool"
        case .hold:   return "Keep the previous note ringing for N steps"
        case .pause:  return "Rest — note-off, silence for N steps"
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
        .presentationDetents([.large])
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
            return step.n == 1 ? "Move forward 1 and play"
                               : "Move forward \(step.n) and play"
        case .back:
            return step.n == 1 ? "Move back 1 and play"
                               : "Move back \(step.n) and play"
        case .rep:
            return step.n == 1 ? "Play current note once"
                               : "Play current note \(step.n) times"
        case .play:
            if step.chordPositions.count > 1 {
                return "Play pool notes \(step.chordPositions.map(String.init).joined(separator: ", ")) together" + poolHint
            }
            return "Jump to pool note \(step.n) and play it" + poolHint
        case .random: return "Play a random note from the pool"
        case .hold:
            return step.n == 1 ? "Hold — previous note keeps ringing"
                               : "Hold the previous note for \(step.n) steps"
        case .pause:
            return step.n == 1 ? "Rest — silence (note off)"
                               : "Rest (note off) for \(step.n) steps"
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
        case .fwd:   return "Advance: \(step.n)"
        case .back:  return "Retreat: \(step.n)"
        case .rep:   return "×\(step.n)"
        case .play:  return "Note: \(step.n)"
        case .hold:  return "Hold: \(step.n)"
        case .pause: return "Rest: \(step.n)"
        default:     return nil
        }
    }

    private var stepperRange: ClosedRange<Int> {
        1...4_096
    }

    private var positionLabel: some View {
        Text("\(index + 1)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 22, alignment: .trailing)
    }

    private var typeButton: some View {
        Button { showTypePicker = true } label: {
            HStack(spacing: 4) {
                Text(step.type.rawValue).font(.body)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showTypePicker) {
            StepTypePickerSheet(selectedType: $step.type)
        }
        .accessibilityLabel("Step \(index + 1) type, \(step.type.rawValue)")
    }

    @ViewBuilder
    private var valueEditor: some View {
        if step.type == .play {
            TextField("1,3,5", text: $chordText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .frame(minWidth: 100, maxWidth: 180)
                .onChange(of: chordText) { newValue in
                    let parsed = parseChord(newValue)
                    step.chordPositions = parsed.count > 1 ? parsed : []
                    step.n = parsed.first ?? step.n
                }
                .accessibilityLabel("Pool note positions")
        } else if let label = stepperLabel {
            Stepper(label, value: $step.n, in: stepperRange)
                .frame(minWidth: 120, maxWidth: 190)
        }
    }

    /// Chance and Ratchets are easy to mistake for pattern controls; they are not.
    private var articulationHelp: String {
        var parts: [String] = []
        if step.probability < 1 {
            parts.append("Chance \(Int((step.probability * 100).rounded()))% — this step is "
                         + "sometimes silent. The sequence still advances, so only the rhythm "
                         + "changes, and it repeats the same way every play.")
        }
        if step.ratchets > 1 {
            parts.append("Ratchets \(step.ratchets) — retriggers this note \(step.ratchets) times "
                         + "inside the step, so each hit is shorter. The sequence is unaffected.")
        }
        if parts.isEmpty {
            parts.append("Chance skips a step's note without changing the sequence. "
                         + "Ratchets retrigger it within its own step.")
        }
        return parts.joined(separator: "\n")
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Image(systemName: "minus.circle.fill")
                .foregroundColor(.red)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete step \(index + 1)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    positionLabel
                    typeButton
                    valueEditor
                    deleteButton
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        positionLabel
                        typeButton
                        Spacer(minLength: 4)
                        deleteButton
                    }
                    valueEditor
                }
            }

            Text(currentDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 34)

            // Per-step gate — scales how long this step's note(s) sustain.
            // Hidden for Hold/Pause, which don't play a note.
            if step.type != .hold && step.type != .pause {
                VStack(spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Gate").font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Slider(value: $step.gate, in: 0.05...1.0)
                        Text("\(Int(step.gate * 100))%")
                            .font(.caption2).monospacedDigit().frame(width: 38)
                    }
                    HStack(spacing: 8) {
                        Text("Chance").font(.caption2).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Slider(value: $step.probability, in: 0...1, step: 0.05)
                        Text("\(Int((step.probability * 100).rounded()))%")
                            .font(.caption2).monospacedDigit().frame(width: 38)
                    }
                    Stepper("Ratchets: \(step.ratchets)", value: $step.ratchets, in: 1...8)
                        .font(.caption2)
                    Text(articulationHelp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
        .onAppear { syncChordText() }
        .onChange(of: step.type) { _ in syncChordText() }
    }
}

