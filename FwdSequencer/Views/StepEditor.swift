import SwiftUI

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
        case .random: return "Play a random note from the pool"
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

            // Per-step gate — scales how long this step's note(s) sustain.
            if step.type != .skip {
                HStack(spacing: 8) {
                    Text("Gate").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $step.gate, in: 0.05...1.0)
                    Text("\(Int(step.gate * 100))%")
                        .font(.caption2).monospacedDigit().frame(width: 34)
                }
                .padding(.leading, 34)
            }
        }
        .padding(.vertical, 4)
        .onAppear { syncChordText() }
        .onChange(of: step.type) { _ in syncChordText() }
    }
}

