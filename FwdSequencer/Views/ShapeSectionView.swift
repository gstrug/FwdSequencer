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

    // Notes operations are chosen and then applied, rather than firing on tap. Rotate
    // and Transpose need a direction and a distance, and there was no moment to set
    // either — nor any sign afterwards that anything had happened.
    @State private var operation: NoteOperation = .rotate
    @State private var amount = 1
    @State private var movesUp = true

    /// What was last applied, shown back so an operation whose effect is only audible
    /// still confirms itself. Cleared on the next change so it cannot go stale.
    @State private var lastApplied: String?
    @State private var lastGenerated: String?

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
            ForEach(NoteOperation.allCases) { option in
                Button {
                    operation = option
                    lastApplied = nil
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(option.rawValue, systemImage: option.systemImage)
                            Text(option.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if option == operation {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == operation ? [.isSelected] : [])
            }

            if operation.takesAmount {
                Picker("Direction", selection: $movesUp) {
                    Text(operation == .rotate ? "Forward" : "Up").tag(true)
                    Text(operation == .rotate ? "Back" : "Down").tag(false)
                }
                .pickerStyle(.segmented)
                .onChange(of: movesUp) { _ in lastApplied = nil }

                Stepper(value: $amount, in: 1...12) {
                    HStack {
                        Text(operation == .rotate ? "Notes" : "Semitones")
                        Spacer()
                        Text(amountLabel).font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: amount) { _ in lastApplied = nil }
            }

            Button(action: applyNoteOperation) {
                Label("Apply", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canShape)
        } header: {
            Text("Notes")
        } footer: {
            if let lastApplied {
                Label(lastApplied, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Text("Changes which notes are in the pool. The step sequence keeps "
                     + "running as it is, so the same pattern plays different notes.")
            }
        }
    }

    /// Rotate counts notes; Transpose counts semitones and is worth naming as an
    /// interval — seven semitones is a fifth, and knowing that is the difference between
    /// choosing one and guessing.
    private var amountLabel: String {
        operation == .transpose ? Self.intervalLabel(amount) : "\(amount)"
    }

    private func applyNoteOperation() {
        let signed = movesUp ? amount : -amount
        let applied: Bool
        switch operation {
        case .rotate:    applied = songStore.rotateNotes(by: signed, for: selection)
        case .reverse:   applied = songStore.reverseNotes(for: selection)
        case .transpose: applied = songStore.transposeSelectedSection(by: signed, for: selection)
        }
        // Silence would be ambiguous — nothing happening looks the same as a pool too
        // small to rotate. Transpose refusing out of range already explains itself
        // through a notice, so that case stays quiet here.
        guard applied else {
            if operation != .transpose {
                lastApplied = "Nothing to change on the selected tracks"
            }
            return
        }
        let count = selection.count
        let tracks = "\(count) track\(count == 1 ? "" : "s")"
        switch operation {
        case .rotate:
            lastApplied = "Rotated \(movesUp ? "forward" : "back") by \(amount) on \(tracks)"
        case .reverse:
            lastApplied = "Reversed the pool on \(tracks)"
        case .transpose:
            lastApplied = "Transposed \(movesUp ? "up" : "down") \(amount) "
                + "semitone\(amount == 1 ? "" : "s") on \(tracks)"
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
                let count = selection.count
                lastGenerated = "Generated \(songStore.generatorLength) "
                    + "\(songStore.generatorCharacter.rawValue.lowercased()) steps on "
                    + "\(count) track\(count == 1 ? "" : "s")\(generations > 1 ? " (×\(generations))" : "")"
            } label: {
                Label("Generate Steps", systemImage: "dice").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canShape)
        } header: {
            Text("Steps")
        } footer: {
            if let lastGenerated {
                VStack(alignment: .leading, spacing: 2) {
                    Label(lastGenerated, systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Text("Keep pressing until something catches — save a snapshot when it does.")
                        .font(.caption)
                }
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
