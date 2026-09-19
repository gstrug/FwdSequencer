import SwiftUI

/// Choose key AND scale together, then apply once.
///
/// They used to be separate pickers, each proposing a change with the other's current
/// value — so moving from C major to A minor asked twice whether to delete notes, and
/// the first answer was given without knowing the second. Since the two decisions are
/// really one, they are made together and confirmed once, against the notes that the
/// final combination would actually drop.
struct KeyScalePickerView: View {
    let currentKey: Int
    let currentScale: MusicalScale
    /// Notes that would be dropped by a given key and scale, so the cost is visible
    /// before committing rather than announced afterwards.
    let droppedCount: (Int, MusicalScale) -> Int
    let onApply: (Int, MusicalScale) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var key: Int
    @State private var scale: MusicalScale

    private static let noteNames = ["C", "C♯", "D", "D♯", "E", "F",
                                    "F♯", "G", "G♯", "A", "A♯", "B"]

    init(currentKey: Int, currentScale: MusicalScale,
         droppedCount: @escaping (Int, MusicalScale) -> Int,
         onApply: @escaping (Int, MusicalScale) -> Void) {
        self.currentKey = currentKey
        self.currentScale = currentScale
        self.droppedCount = droppedCount
        self.onApply = onApply
        _key = State(initialValue: currentKey)
        _scale = State(initialValue: currentScale)
    }

    private var dropped: Int { droppedCount(key, scale) }
    private var unchanged: Bool { key == currentKey && scale == currentScale }

    var body: some View {
        NavigationStack {
            List {
                Section("Key") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6),
                                             count: 6), spacing: 6) {
                        ForEach(0..<12, id: \.self) { value in
                            Button {
                                key = value
                            } label: {
                                Text(Self.noteNames[value])
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .buttonStyle(.bordered)
                            .tint(value == key ? .accentColor : .secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Grouped: the list is long enough now that a flat one is hard to scan.
                ForEach(MusicalScale.Family.allCases) { family in
                    Section(family.rawValue) {
                        ForEach(MusicalScale.scales(in: family), id: \.self) { option in
                            Button {
                                scale = option
                            } label: {
                                HStack {
                                    Text(option.rawValue)
                                    Spacer()
                                    if option == scale {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Key & Scale")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if dropped > 0 {
                        Label("\(dropped) selected note\(dropped == 1 ? "" : "s") would be "
                              + "removed from this track",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button {
                        onApply(key, scale)
                        dismiss()
                    } label: {
                        Text("Use \(Self.noteNames[key]) \(scale.rawValue)")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(unchanged)
                }
                .padding()
                .background(.regularMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}
