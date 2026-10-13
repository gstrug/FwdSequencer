import SwiftUI

struct NoteParametersView: View {
    @Binding var notePool: [NoteEntry]
    @Environment(\.dismiss) private var dismiss

    // Remembered between visits, so shaping several tracks the same way is one tap each.
    @AppStorage("noteShape.pattern") private var shapeRaw = NoteShape.rampUp.rawValue
    @AppStorage("noteShape.velocity") private var shapeVelocity = true
    @AppStorage("noteShape.gate") private var shapeGate = false
    // The range each shape spans, as explicit limits. Velocity in MIDI units, gate in
    // percent of the step, matching what the faders below show.
    @AppStorage("noteShape.velocityMin") private var velocityMin = 60.0
    @AppStorage("noteShape.velocityMax") private var velocityMax = 120.0
    @AppStorage("noteShape.gateMin") private var gateMin = 25.0
    @AppStorage("noteShape.gateMax") private var gateMax = 75.0

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

            limitsRow(title: "Velocity", isOn: $shapeVelocity,
                      low: $velocityMin, high: $velocityMax,
                      limits: Double(NoteShaper.velocityLimits.lowerBound)...Double(NoteShaper.velocityLimits.upperBound),
                      defaults: (60, 120), format: { "\(Int($0))" })

            limitsRow(title: "Gate", isOn: $shapeGate,
                      low: $gateMin, high: $gateMax,
                      limits: (NoteShaper.gateLimits.lowerBound * 100)...(NoteShaper.gateLimits.upperBound * 100),
                      defaults: (25, 75), format: { "\(Int($0))%" })

            HStack(spacing: 10) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                // Resets only what is selected, like Apply: velocity back to 100
                // and/or gate back to 50%.
                Button("Reset") {
                    notePool = NoteShaper.reset(notePool, velocity: shapeVelocity, gate: shapeGate)
                }
                .buttonStyle(.bordered)
                .disabled(!shapeVelocity && !shapeGate)

                Button(action: applyShape) {
                    // Random shapes roll again on every press, and the label says so.
                    Text(shape.isRandom ? "Roll" : "Apply")
                        .frame(minWidth: 56)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!shapeVelocity && !shapeGate)
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func applyShape() {
        // Built low-to-high whatever the sliders say: a ClosedRange the wrong way
        // round is a crash, not an empty range.
        var velocity: ClosedRange<Int>? = nil
        if shapeVelocity {
            velocity = Int(min(velocityMin, velocityMax))...Int(max(velocityMin, velocityMax))
        }
        var gate: ClosedRange<Double>? = nil
        if shapeGate {
            gate = (min(gateMin, gateMax) / 100)...(max(gateMin, gateMax) / 100)
        }
        notePool = NoteShaper.apply(shape, to: notePool, velocity: velocity, gate: gate,
                                    random: { Double.random(in: 0..<1) })
    }

    /// One parameter's on/off and its Min and Max. Each limit is pushed along by the
    /// other rather than allowed to cross it, so the pair always reads low → high.
    private func limitsRow(title: String, isOn: Binding<Bool>,
                           low: Binding<Double>, high: Binding<Double>,
                           limits: ClosedRange<Double>, defaults: (Double, Double),
                           format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 10) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.button)
                .frame(width: 92, alignment: .leading)

            Text("Min").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { low.wrappedValue },
                set: { low.wrappedValue = $0; if high.wrappedValue < $0 { high.wrappedValue = $0 } }
            ), in: limits, step: 1)
                .resetsOnDoubleTap { low.wrappedValue = defaults.0 }
                .accessibilityLabel("\(title) minimum")
                .accessibilityValue(format(low.wrappedValue))
            Text(format(low.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .leading)

            Text("Max").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { high.wrappedValue },
                set: { high.wrappedValue = $0; if low.wrappedValue > $0 { low.wrappedValue = $0 } }
            ), in: limits, step: 1)
                .resetsOnDoubleTap { high.wrappedValue = defaults.1 }
                .accessibilityLabel("\(title) maximum")
                .accessibilityValue(format(high.wrappedValue))
            Text(format(high.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .leading)
        }
        .controlSize(.small)
        .opacity(isOn.wrappedValue ? 1 : 0.5)
    }

    private var caption: String {
        let detail: String
        switch shape {
        case .rampUp:   detail = "Rises from Min on the lowest note to Max on the highest."
        case .rampDown: detail = "Falls from Max on the lowest note to Min on the highest."
        case .arch:     detail = "Rises from Min to Max at the middle notes, then falls."
        case .valley:   detail = "Falls from Max to Min at the middle notes, then rises."
        case .alternate: detail = "Max, Min, Max, Min… from the lowest note up."
        case .random:   detail = "Each note anywhere between Min and Max."
        case .stagger:  detail = "Lurches up and down between Min and Max, note to note."
        }
        guard shapeVelocity || shapeGate else { return "Turn on Velocity, Gate or both to shape." }
        return detail + " Replaces the current values."
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
