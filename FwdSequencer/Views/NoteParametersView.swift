import SwiftUI

struct NoteParametersView: View {
    @Binding var notePool: [NoteEntry]
    @Environment(\.dismiss) private var dismiss

    // Remembered between visits, so shaping several tracks the same way is one tap each.
    @AppStorage("noteShape.pattern") private var shapeRaw = NoteShape.rampUp.rawValue
    @AppStorage("noteShape.velocity") private var shapeVelocity = true
    @AppStorage("noteShape.gate") private var shapeGate = false
    /// Percent either side of the defaults, 0...50.
    @AppStorage("noteShape.range") private var shapeRange = 30.0

    private var shape: NoteShape { NoteShape(rawValue: shapeRaw) ?? .rampUp }

    var body: some View {
        NavigationStack {
            Group {
                if notePool.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "pianokeys")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No Notes Selected")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Select notes on the keyboard first")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        shapeBar
                        Divider()
                        ScrollView([.horizontal, .vertical], showsIndicators: true) {
                            HStack(alignment: .top, spacing: 0) {
                                ForEach(notePool.indices, id: \.self) { idx in
                                    NoteStrip(entry: $notePool[idx])
                                    if idx < notePool.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 20)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .navigationTitle("Note Parameters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Shape

extension NoteParametersView {
    /// Set every note's velocity and/or gate to a pattern at once. The faders below
    /// move to show the result and stay editable afterwards. See NoteShaper.
    private var shapeBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Pattern", selection: $shapeRaw) {
                ForEach(NoteShape.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Toggle("Velocity", isOn: $shapeVelocity)
                    .toggleStyle(.button)
                Toggle("Gate", isOn: $shapeGate)
                    .toggleStyle(.button)

                Divider().frame(height: 20)

                Text("Range").font(.caption).foregroundStyle(.secondary)
                Slider(value: $shapeRange, in: 0...(NoteShaper.maximumRange * 100), step: 1)
                    .resetsOnDoubleTap { shapeRange = 30 }
                    .frame(minWidth: 120, maxWidth: 220)
                    .accessibilityLabel("Range")
                    .accessibilityValue("plus or minus \(Int(shapeRange)) percent")
                Text("±\(Int(shapeRange))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .leading)

                Spacer(minLength: 0)

                Button("Reset All") {
                    notePool = NoteShaper.reset(notePool)
                }
                .buttonStyle(.bordered)

                Button {
                    notePool = NoteShaper.apply(shape, to: notePool,
                                                velocity: shapeVelocity, gate: shapeGate,
                                                range: shapeRange / 100,
                                                random: { Double.random(in: 0..<1) })
                } label: {
                    // Random shapes roll again on every press, and the label says so.
                    Text(shape.isRandom ? "Roll" : "Apply")
                        .frame(minWidth: 56)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!shapeVelocity && !shapeGate)
            }
            .controlSize(.small)

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var caption: String {
        let target: String
        switch (shapeVelocity, shapeGate) {
        case (true, true):  target = "velocity and gate"
        case (true, false): target = "velocity"
        case (false, true): target = "gate"
        default:            return "Choose Velocity, Gate or both to shape."
        }
        let detail: String
        switch shape {
        case .rampUp:   detail = "rising from the lowest note to the highest"
        case .rampDown: detail = "falling from the lowest note to the highest"
        case .arch:     detail = "rising to the middle notes, then falling"
        case .valley:   detail = "falling to the middle notes, then rising"
        case .random:   detail = "set at random for each note"
        case .stagger:  detail = "lurching up and down from note to note"
        }
        return "Sets \(target) \(detail), within ±\(Int(shapeRange))% of the default "
            + "(velocity 100, gate 50%). Replaces the current values."
    }
}

// MARK: - Note Strip

struct NoteStrip: View {
    @Binding var entry: NoteEntry

    var body: some View {
        VStack(spacing: 14) {
            Text(noteName(entry.midiNote))
                .font(.caption.bold())
                .frame(width: 56)

            // Velocity fader
            VStack(spacing: 4) {
                Text("\(entry.velocity)")
                    .font(.caption2).monospacedDigit()
                Slider(value: Binding(
                    get: { Double(entry.velocity) },
                    set: { entry.velocity = Int($0) }
                ), in: 1...127, step: 1)
                    // NoteEntry's own default velocity.
                    .resetsOnDoubleTap { entry.velocity = 100 }
                    .frame(width: 130)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 36, height: 130)
                Text("Vel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Gate fader
            VStack(spacing: 4) {
                Text(String(format: "%.0f%%", entry.gateLength * 100))
                    .font(.caption2).monospacedDigit()
                Slider(value: $entry.gateLength, in: 0.05...1.0)
                    .resetsOnDoubleTap { entry.gateLength = 0.5 }
                    .frame(width: 130)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 36, height: 130)
                Text("Gate")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64)
    }

    private func noteName(_ midi: Int) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let oct = (midi / 12) - 1
        return "\(names[midi % 12])\(oct)"
    }
}
