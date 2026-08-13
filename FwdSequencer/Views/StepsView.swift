import SwiftUI

struct StepsView: View {
    @Binding var steps: [Step]
    var noteCount: Int = 0     // pool size, passed to rows for chord validation
    @Environment(\.dismiss) private var dismiss
    // Set when a step is appended; the List's onChange scrolls to it once the row
    // actually exists (scrolling in the same runloop as append is unreliable).
    @State private var scrollTarget: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    if steps.isEmpty {
                        Spacer()
                        Text("No steps — notes play in order by default")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Spacer()
                    } else {
                        List {
                            ForEach($steps) { $step in
                                let stepID = step.id
                                StepRow(
                                    step: $step,
                                    index: steps.firstIndex(where: { $0.id == stepID }) ?? 0,
                                    noteCount: noteCount
                                ) {
                                    steps.removeAll { $0.id == stepID }
                                }
                            }
                            .onMove { from, to in steps.move(fromOffsets: from, toOffset: to) }
                        }
                        .environment(\.editMode, .constant(.active))
                        // Scroll to a freshly-added step once its row has been inserted.
                        .onChange(of: steps.count) { _ in
                            guard let target = scrollTarget else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if reduceMotion {
                                    proxy.scrollTo(target, anchor: .bottom)
                                } else {
                                    withAnimation { proxy.scrollTo(target, anchor: .bottom) }
                                }
                                scrollTarget = nil
                            }
                        }
                    }

                    HStack {
                        Button {
                            let new = Step(type: .fwd)
                            steps.append(new)
                            scrollTarget = new.id   // onChange(of: steps.count) scrolls once inserted
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
