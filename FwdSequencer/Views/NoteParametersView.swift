import SwiftUI

struct NoteParametersView: View {
    @Binding var notePool: [NoteEntry]
    @Environment(\.dismiss) private var dismiss

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
                Slider(value: $entry.gateLength, in: 0.01...8.0)
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
