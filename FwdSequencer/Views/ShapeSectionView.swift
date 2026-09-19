import SwiftUI

/// Everything that reshapes a section, in one place.
///
/// Transform and Generate were separate: one a menu acting on every track whether you
/// wanted it to or not, the other a sheet with its own track selection. Two ways to
/// change the same section, disagreeing about scope. One selection now governs both.
///
/// Split by MATERIAL rather than by which menu they used to live in — the note pool and
/// the step sequence are different things, and an operation on one says nothing about
/// the other. Rotating notes leaves the steps alone; generating steps leaves the notes
/// alone.
struct ShapeSectionView: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss

    /// Counts presses so the footer can confirm something happened — the change is
    /// audible rather than visible from in here.
    @State private var generations = 0
    @State private var hasSeededSelection = false

    private var tracks: [SongTrack] { songStore.song.tracks }
    private var selection: Set<UUID> { songStore.shapeTrackSelection }
    private var canShape: Bool { songStore.canAlterSelectedSection && !selection.isEmpty }

    var body: some View {
        NavigationStack {
            List {
                tracksSection
                notesSection
                stepsSection
            }
            .navigationTitle("Shape Section")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear(perform: seedSelection)
        }
    }

    // MARK: Tracks — first, because everything below obeys it

    private var tracksSection: some View {
        Section {
            ForEach(tracks) { track in
                Button {
                    if selection.contains(track.id) { songStore.shapeTrackSelection.remove(track.id) }
                    else { songStore.shapeTrackSelection.insert(track.id) }
                } label: {
                    HStack {
                        Text(track.name)
                        Spacer()
                        Image(systemName: selection.contains(track.id)
                              ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(track.id)
                                             ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Tracks")
        } footer: {
            if !songStore.canAlterSelectedSection {
                Text("Hold this section first, so you can hear what you are changing.")
            } else if selection.isEmpty {
                Text("Select at least one track.")
            } else {
                Text("Everything below applies to these tracks only. The selection is "
                     + "remembered.")
            }
        }
    }

    // MARK: Notes — reshapes the pool, leaves the steps alone

    private var notesSection: some View {
        Section {
            ForEach(SectionTransform.allCases) { transform in
                Button {
                    songStore.transformSelectedSection(transform, for: selection)
                } label: {
                    Label(transform.rawValue, systemImage: transform.systemImage)
                }
                .disabled(!canShape)
            }

            // Up to an octave each way. Further is the same move applied twice, which is
            // easier to offer than a list of twenty-four.
            Menu {
                ForEach((1...12).reversed(), id: \.self) { semitones in
                    Button {
                        songStore.transposeSelectedSection(by: semitones, for: selection)
                    } label: { Text(Self.intervalLabel(semitones)) }
                }
            } label: {
                Label("Transpose Up", systemImage: "arrow.up")
            }
            .disabled(!canShape)

            Menu {
                ForEach(1...12, id: \.self) { semitones in
                    Button {
                        songStore.transposeSelectedSection(by: -semitones, for: selection)
                    } label: { Text(Self.intervalLabel(semitones)) }
                }
            } label: {
                Label("Transpose Down", systemImage: "arrow.down")
            }
            .disabled(!canShape)
        } header: {
            Text("Notes")
        } footer: {
            Text("Changes which notes are in the pool. The step sequence keeps running "
                 + "as it is, so the same pattern plays different notes.")
        }
    }

    // MARK: Steps — rewrites the sequence, leaves the pool alone

    private var stepsSection: some View {
        Section {
            Stepper(value: $songStore.generatorLength, in: StepGenerator.lengthRange) {
                HStack {
                    Text("Length")
                    Spacer()
                    Text("\(songStore.generatorLength)")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            // A slider too: 1 to 32 is a long way by stepper, and a coarse drag then a
            // nudge is how anyone actually lands on 24.
            Slider(
                value: Binding(
                    get: { Double(songStore.generatorLength) },
                    set: { songStore.generatorLength = Int($0.rounded()) }
                ),
                in: StepGenerator.lengthSliderRange, step: 1
            )

            ForEach(StepCharacter.allCases) { option in
                Button {
                    songStore.generatorCharacter = option
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(option.rawValue, systemImage: option.systemImage)
                            // The detail matters more than the name — "Jumpy" alone does
                            // not say what you are about to hear.
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option == songStore.generatorCharacter {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == songStore.generatorCharacter ? [.isSelected] : [])
            }

            Button {
                songStore.generateSteps(count: songStore.generatorLength,
                                        character: songStore.generatorCharacter,
                                        for: selection)
                generations += 1
            } label: {
                Label("Generate Steps", systemImage: "dice").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canShape)
        } header: {
            Text("Steps")
        } footer: {
            if generations > 0 {
                Text("Generated \(generations) time\(generations == 1 ? "" : "s"). Keep "
                     + "pressing until something catches — save a snapshot when it does.")
            } else {
                Text("Replaces the step sequence. The note pool is untouched. Something "
                     + "always sounds on the first step, so even a very short sequence "
                     + "is audible.")
            }
        }
    }

    // MARK: -

    /// Names the interval as well as the count — seven semitones is a fifth, and knowing
    /// that is the difference between choosing one and guessing.
    private static func intervalLabel(_ semitones: Int) -> String {
        let names = ["", "Semitone", "Whole tone", "Minor third", "Major third",
                     "Fourth", "Tritone", "Fifth", "Minor sixth", "Major sixth",
                     "Minor seventh", "Major seventh", "Octave"]
        let interval = semitones < names.count ? names[semitones] : ""
        return interval.isEmpty ? "\(semitones)" : "\(semitones) — \(interval)"
    }

    /// Default to everything on first use: the common case is reshaping the whole
    /// section, and unticking is easier than ticking. After that the stored selection
    /// stands, including an empty one — hence the flag rather than testing for empty.
    private func seedSelection() {
        if !hasSeededSelection {
            hasSeededSelection = true
            if songStore.shapeTrackSelection.isEmpty {
                songStore.shapeTrackSelection = Set(tracks.map(\.id))
            }
        }
        songStore.shapeTrackSelection.formIntersection(Set(tracks.map(\.id)))
    }
}
