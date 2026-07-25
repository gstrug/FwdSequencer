import SwiftUI

struct StepsView: View {
    @Binding var steps: [Step]
    var noteCount: Int = 0     // pool size, passed to rows for chord validation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if steps.isEmpty {
                    Spacer()
                    Text("No steps — notes play in order by default")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Spacer()
                } else {
                    List {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { idx, _ in
                            StepRow(step: $steps[idx], index: idx, noteCount: noteCount) {
                                steps.remove(at: idx)
                            }
                        }
                        .onMove { from, to in steps.move(fromOffsets: from, toOffset: to) }
                    }
                    .environment(\.editMode, .constant(.active))
                }

                HStack {
                    Button {
                        steps.append(Step(type: .fwd))
                    } label: {
                        Label("Add Step", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if !steps.isEmpty {
                        Button("Clear All", role: .destructive) {
                            steps.removeAll()
                        }
                        .font(.caption)
                    }
                }
                .padding()
            }
            .navigationTitle("Step Sequence")
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
