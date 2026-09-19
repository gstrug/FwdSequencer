import SwiftUI

/// Name and length for one section.
///
/// These used to sit permanently in the section header beside Transform, Snapshots and
/// Generate — set once when a section is created and then in the way for the rest of the
/// session. They belong with the other section actions, in the menu and on a long press,
/// which also frees the header for the tools that are actually used repeatedly.
struct SectionEditorSheet: View {
    let sectionIndex: Int
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bars = 4
    @State private var loaded = false

    /// Common lengths, so the usual choice is one tap rather than a drag.
    private static let presets = [1, 2, 4, 8, 16, 32]

    private var section: SongSection? {
        songStore.song.sections.indices.contains(sectionIndex)
            ? songStore.song.sections[sectionIndex] : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Section", text: $name)
                        .onSubmit(commit)
                }

                Section {
                    Stepper(value: $bars, in: 1...256) {
                        HStack {
                            Text("Bars")
                            Spacer()
                            Text("\(bars)").font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(Self.presets, id: \.self) { value in
                            Button("\(value)") { bars = value }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(bars == value ? .accentColor : .secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                } header: {
                    Text("Length")
                } footer: {
                    Text("How long this section plays before the song moves on. "
                         + "Steps keep running across the boundary.")
                }
            }
            .navigationTitle("Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(); dismiss() }
                }
            }
            // Seeded once: re-reading on every redraw would fight the text field while
            // it is being typed into.
            .onAppear {
                guard !loaded, let section else { return }
                loaded = true
                name = section.name
                bars = section.numberOfBars
            }
        }
        .presentationDetents([.medium])
    }

    private func commit() {
        guard songStore.song.sections.indices.contains(sectionIndex) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // The validator rejects an empty or over-long section name, which would make the
        // song unsaveable.
        songStore.song.sections[sectionIndex].name = trimmed.isEmpty
            ? "Section"
            : String(trimmed.prefix(SongValidator.maximumNameLength))
        songStore.song.sections[sectionIndex].numberOfBars = min(max(bars, 1), 256)
    }
}
