import SwiftUI

/// Generate step sequences for a section.
///
/// Built around re-rolling rather than configuring: the interesting results come from
/// pressing Generate repeatedly and listening, not from getting the settings right
/// first. So Generate stays put at the bottom and the sheet does not dismiss on use —
/// hold the section, let it loop, and keep pressing until something catches.
struct GenerateStepsView: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss

    @State private var length = 8
    @State private var character: StepCharacter = .flowing
    @State private var selectedTracks: Set<UUID> = []
    /// Counts presses, purely so the footer can confirm something happened — the change
    /// is audible rather than visible from here.
    @State private var generations = 0

    private var tracks: [SongTrack] { songStore.song.tracks }

    var body: some View {
        NavigationStack {
            List {
                Section("Character") {
                    ForEach(StepCharacter.allCases) { option in
                        Button {
                            character = option
                        } label: {
                            HStack {
                                Label(option.rawValue, systemImage: option.systemImage)
                                Spacer()
                                if option == character {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == character ? [.isSelected] : [])
                        // The detail matters more than the name — "Jumpy" alone does not
                        // say what you are about to hear.
                        .listRowSeparator(.hidden, edges: .bottom)
                        Text(option.detail)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Steps") {
                    Picker("Length", selection: $length) {
                        ForEach(StepGenerator.lengthOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(tracks) { track in
                        Button {
                            if selectedTracks.contains(track.id) { selectedTracks.remove(track.id) }
                            else { selectedTracks.insert(track.id) }
                        } label: {
                            HStack {
                                Text(track.name)
                                Spacer()
                                Image(systemName: selectedTracks.contains(track.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedTracks.contains(track.id)
                                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Tracks")
                } footer: {
                    Text("Each track gets its own sequence — they will not move in lockstep.")
                }

                Section {
                    Button {
                        songStore.generateSteps(count: length, character: character,
                                                for: selectedTracks)
                        generations += 1
                    } label: {
                        Label("Generate", systemImage: "dice").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedTracks.isEmpty || !songStore.canAlterSelectedSection)
                } footer: {
                    if !songStore.canAlterSelectedSection {
                        Text("Hold this section first, so you can hear what you are generating.")
                    } else if generations > 0 {
                        Text("Generated \(generations) time\(generations == 1 ? "" : "s"). "
                             + "Keep pressing until something catches — the previous version "
                             + "is in Snapshots.")
                    } else {
                        Text("Replaces the steps of the selected tracks in this section. "
                             + "A snapshot is saved first.")
                    }
                }
            }
            .navigationTitle("Generate Steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Default to everything: the common case is finding a starting point for the
            // whole section, and unticking is easier than ticking.
            .onAppear {
                if selectedTracks.isEmpty { selectedTracks = Set(tracks.map(\.id)) }
            }
        }
    }
}
