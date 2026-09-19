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

    /// Length, character and selection live on the store, so they survive closing the
    /// sheet. Generating is iterative and re-picking the same tracks each visit was
    /// tedious.
    /// Counts presses, purely so the footer can confirm something happened — the change
    /// is audible rather than visible from here.
    @State private var generations = 0
    @State private var hasSeededSelection = false

    private var tracks: [SongTrack] { songStore.song.tracks }

    var body: some View {
        NavigationStack {
            List {
                // Steps first: how long the sequence is shapes what a character even
                // means, so it is the decision to make before the others.
                Section {
                    Stepper(value: $songStore.generatorLength,
                            in: StepGenerator.lengthRange) {
                        HStack {
                            Text("Steps")
                            Spacer()
                            Text("\(songStore.generatorLength)")
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    // A slider as well: 1 to 32 is a long way to travel by stepper when
                    // you want 24, and a coarse drag then a nudge is the usual pattern.
                    Slider(
                        value: Binding(
                            get: { Double(songStore.generatorLength) },
                            set: { songStore.generatorLength = Int($0.rounded()) }
                        ),
                        in: StepGenerator.lengthSliderRange,
                        step: 1
                    )
                } header: {
                    Text("Length")
                } footer: {
                    Text("Any length from 1 to 32. Something always sounds on the first "
                         + "step, so even a very short sequence is audible.")
                }

                Section {
                    ForEach(tracks) { track in
                        Button {
                            if songStore.generatorTrackSelection.contains(track.id) {
                                songStore.generatorTrackSelection.remove(track.id)
                            } else {
                                songStore.generatorTrackSelection.insert(track.id)
                            }
                        } label: {
                            HStack {
                                Text(track.name)
                                Spacer()
                                Image(systemName: songStore.generatorTrackSelection.contains(track.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(songStore.generatorTrackSelection.contains(track.id)
                                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Tracks")
                } footer: {
                    Text("Each track gets its own sequence — they will not move in "
                         + "lockstep. This selection is remembered.")
                }

                Section("Character") {
                    ForEach(StepCharacter.allCases) { option in
                        Button {
                            songStore.generatorCharacter = option
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(option.rawValue, systemImage: option.systemImage)
                                    // The detail matters more than the name — "Jumpy"
                                    // alone does not say what you are about to hear.
                                    Text(option.detail)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if option == songStore.generatorCharacter {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(option == songStore.generatorCharacter
                                                ? [.isSelected] : [])
                    }
                }

                Section {
                    Button {
                        songStore.generateSteps(count: songStore.generatorLength,
                                                character: songStore.generatorCharacter,
                                                for: songStore.generatorTrackSelection)
                        generations += 1
                    } label: {
                        Label("Generate", systemImage: "dice").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(songStore.generatorTrackSelection.isEmpty
                              || !songStore.canAlterSelectedSection)
                } footer: {
                    if !songStore.canAlterSelectedSection {
                        Text("Hold this section first, so you can hear what you are generating.")
                    } else if generations > 0 {
                        Text("Generated \(generations) time\(generations == 1 ? "" : "s"). "
                             + "Keep pressing until something catches — save a snapshot "
                             + "when it does.")
                    } else {
                        Text("Replaces the steps of the selected tracks in this section.")
                    }
                }
            }
            .navigationTitle("Generate Steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            // Default to everything on first use: the common case is finding a starting
            // point for the whole section, and unticking is easier than ticking. After
            // that the stored selection stands, including an empty one if that is what
            // the user left it as — hence the flag rather than testing for empty.
            .onAppear {
                if !hasSeededSelection {
                    hasSeededSelection = true
                    if songStore.generatorTrackSelection.isEmpty {
                        songStore.generatorTrackSelection = Set(tracks.map(\.id))
                    }
                }
                // Drop any track that has since been deleted.
                let live = Set(tracks.map(\.id))
                songStore.generatorTrackSelection.formIntersection(live)
            }
        }
    }
}
