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

    // Notes operations are chosen and then applied, rather than firing on tap. Rotate
    // and Transpose need a direction and a distance, and there was no moment to set
    // either — nor any sign afterwards that anything had happened.
    @State private var operation: NoteOperation = .rotate
    // Each operation keeps its OWN direction and distance. They shared one pair, so
    // setting a transpose interval silently changed how far Rotate would turn, and the
    // controls sat below the list belonging to nothing in particular.
    @State private var rotateBy = 1
    @State private var rotateForward = true
    @State private var transposeBy = 1
    @State private var transposeUp = true

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
                    // The row is the target, not just its text — the tick is the obvious
                    // place to aim for and hitting it did nothing without this.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Tracks")
        } footer: {
            if !songStore.canAlterSelectedSection {
                Text("Hold this section first, so you can hear what you are changing.")
            } else if selection.isEmpty {
                Text("Pick the tracks to change. Nothing is selected to begin with, so "
                     + "a section cannot be rewritten wholesale by accident.")
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
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        operation = option
                        lastApplied = nil
                    } label: {
                        HStack {
                            Label(option.rawValue, systemImage: option.systemImage)
                            Spacer()
                            if option == operation {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        // Without this only the text and icon are hit-testable, so
                        // tapping the obvious place — the end of the row, where the tick
                        // is — did nothing at all.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text(option.detail).font(.caption).foregroundStyle(.secondary)

                    // On the row it belongs to, and only while it is the one selected,
                    // so the list stays readable and there is no doubt which operation a
                    // control is setting.
                    if option == operation, option.takesAmount {
                        parameters(for: option)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(option == operation ? [.isSelected] : [])
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

    /// Direction and distance on ONE line, sharing the row with the operation they
    /// belong to. Stacked, with a full-width segmented control and a labelled stepper,
    /// they took three lines for what is really one small setting — and the words
    /// "Notes" and "Interval" only repeated what the operation above already said.
    @ViewBuilder
    private func parameters(for option: NoteOperation) -> some View {
        switch option {
        case .rotate:
            HStack(spacing: 12) {
                Picker("", selection: $rotateForward) {
                    Text("Fwd").tag(true)
                    Text("Back").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 128)
                .onChange(of: rotateForward) { _ in lastApplied = nil }

                Spacer(minLength: 0)

                Text("\(rotateBy)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Stepper("", value: $rotateBy, in: 1...12)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: rotateBy) { _ in lastApplied = nil }
            }

        case .transpose:
            HStack(spacing: 12) {
                Picker("", selection: $transposeUp) {
                    Text("Up").tag(true)
                    Text("Down").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 128)
                .onChange(of: transposeUp) { _ in lastApplied = nil }

                Spacer(minLength: 0)

                // The interval is worth naming — seven semitones is a fifth, and knowing
                // that is the difference between choosing one and guessing.
                Text(Self.intervalLabel(transposeBy))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Stepper("", value: $transposeBy, in: 1...12)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: transposeBy) { _ in lastApplied = nil }
            }

        case .reverse:
            EmptyView()
        }
    }

    private func applyNoteOperation() {
        let applied: Bool
        switch operation {
        case .rotate:
            applied = songStore.rotateNotes(by: rotateForward ? rotateBy : -rotateBy,
                                            for: selection)
        case .reverse:
            applied = songStore.reverseNotes(for: selection)
        case .transpose:
            applied = songStore.transposeSelectedSection(
                by: transposeUp ? transposeBy : -transposeBy, for: selection)
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
            lastApplied = "Rotated \(rotateForward ? "forward" : "back") by \(rotateBy) on \(tracks)"
        case .reverse:
            lastApplied = "Reversed the pool on \(tracks)"
        case .transpose:
            lastApplied = "Transposed \(transposeUp ? "up" : "down") \(transposeBy) "
                + "semitone\(transposeBy == 1 ? "" : "s") on \(tracks)"
        }
    }

    // MARK: Steps — rewrites the sequence, leaves the pool alone

    private var stepsSection: some View {
        Section {
            Stepper(value: $songStore.generatorLength, in: StepGenerator.lengthRange) {
                HStack {
                    Text("Number of Steps")
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
            .resetsOnDoubleTap { songStore.generatorLength = 8 }

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
                    .contentShape(Rectangle())
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
        return interval.isEmpty ? "\(semitones)" : "\(semitones) · \(interval)"
    }

    /// Nothing is selected until you say so.
    ///
    /// It used to default to every track, which made it far too easy to rewrite every
    /// pattern in a section at once while meaning to change one. Shaping is destructive
    /// and the Apply and Generate buttons stay disabled until something is ticked, so an
    /// empty default fails safe rather than silently doing the most damage.
    private func seedSelection() {
        songStore.shapeTrackSelection.formIntersection(Set(tracks.map(\.id)))
    }
}
