import SwiftUI
import Combine

// MARK: - Arranger
//
// The order a song's sections play in, using any section as often as you like:
// Section 1, Section 2, Section 1, Section 4… Each place is an ArrangementSlot with its
// own id, so the same section placed twice is two rows, and the one playing can be
// shown. The order itself is worked out in one place, Song.playOrder, which both the
// sequencer (SongStore.flattenedSections) and MIDI export use.
//
// Opened from the Section menu. The Play Arrangement switch is saved with the song.
// Hold and Pattern Trigger Mode work on sections themselves, so while either is on
// the song plays its sections, not the arrangement (SongStore.followsArrangement).

struct ArrangerView: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var help = HelpCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    private var song: Song { songStore.song }
    private var slots: [ArrangementSlot] { songStore.song.arrangement ?? [] }

    private var playsBinding: Binding<Bool> {
        Binding(get: { songStore.song.playsArrangement == true },
                set: { songStore.song.playsArrangement = $0 })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: help.guarded(.arrangerPlay, playsBinding)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Play Arrangement")
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .helpTag(.arrangerPlay)
                    if let note = setAsideNote {
                        Label(note, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if slots.isEmpty {
                        Text("Nothing arranged yet. Add sections below, in the order they should play.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.slot.id) { index, row in
                        slotRow(index, row)
                            .helpTag(.arrangerSlot, instance: row.slot.id.uuidString)
                    }
                    .onMove { songStore.moveInArrangement(from: $0, to: $1) }
                    .onDelete { songStore.removeFromArrangement(at: $0) }
                } header: {
                    Text("Song order")
                } footer: {
                    if !slots.isEmpty {
                        Text("Drag ≡ to reorder. Tap − or swipe left to remove.")
                    }
                }

                Section {
                    ForEach(Array(song.sections.enumerated()), id: \.element.id) { index, section in
                        Button {
                            help.perform(.arrangerAdd) { songStore.appendToArrangement(sectionAt: index) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(section.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(addDetail(section))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 36)
                        }
                        .helpTag(.arrangerAdd, instance: section.id.uuidString)
                    }
                } header: {
                    Text("Add a section")
                } footer: {
                    Text("Tap a section to add it to the end. Any section can be used as often as you like.")
                }

                Section {
                    Button {
                        help.perform(.arrangerFill) { songStore.fillArrangementWithSections() }
                    } label: {
                        Label("Fill with Sections in Order", systemImage: "list.number")
                    }
                    .helpTag(.arrangerFill)
                    Button(role: .destructive) {
                        help.perform(.arrangerClear) { confirmClear = true }
                    } label: {
                        Label("Clear Arrangement", systemImage: "trash")
                    }
                    .disabled(!help.isOn && slots.isEmpty)
                    .helpTag(.arrangerClear)
                }
            }
            // Always editing: the drag handles are the point of this screen.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arranger")
            .navigationBarTitleDisplayMode(.inline)
            .helpHost()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { HelpButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear the arrangement?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear Arrangement", role: .destructive) { songStore.clearArrangement() }
            } message: {
                Text("Your sections are not changed.")
            }
        }
    }

    // MARK: Rows

    private struct Row {
        let slot: ArrangementSlot
        let section: SongSection
        let startBar: Int
    }

    /// Each slot with its section and the bar it starts on. Slots whose section has
    /// gone are left out, exactly as playback leaves them out.
    private var rows: [Row] {
        var byID: [UUID: SongSection] = [:]
        for section in song.sections { byID[section.id] = section }
        var bar = 1
        return slots.compactMap { slot in
            guard let section = byID[slot.sectionID] else { return nil }
            defer { bar += section.numberOfBars }
            return Row(slot: slot, section: section, startBar: bar)
        }
    }

    @ViewBuilder
    private func slotRow(_ index: Int, _ row: Row) -> some View {
        let isPlaying = songStore.isPlaying && songStore.followsArrangement
            && songStore.playingEntryID == row.slot.id
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.section.name).font(.body.weight(.semibold))
                Text("\(row.section.numberOfBars) bar\(row.section.numberOfBars == 1 ? "" : "s") · starts bar \(row.startBar)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPlaying {
                Label("Playing", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.25), in: Capsule())
                    .foregroundStyle(.green)
            }
            Menu {
                Button {
                    songStore.repeatArrangementSlot(at: index)
                } label: {
                    Label("Place Again After This", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                    songStore.removeFromArrangement(at: IndexSet(integer: index))
                } label: {
                    Label("Remove", systemImage: "minus.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for place \(index + 1)")
        }
        .listRowBackground(isPlaying ? Color.green.opacity(0.12) : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Place \(index + 1), \(row.section.name)")
        .accessibilityValue(Text(isPlaying ? "Playing" : ""))
    }

    // MARK: Words

    private var summary: String {
        let entries = rows
        guard !entries.isEmpty else { return "Off: sections play in order." }
        let bars = entries.reduce(0) { $0 + $1.section.numberOfBars }
        let ts = song.timeSignature
        let secondsPerBar = Double(ts.numerator) * (60 / max(1, song.tempo)) * 4 / Double(max(1, ts.denominator))
        let total = Int((Double(bars) * secondsPerBar).rounded())
        let places = "\(entries.count) place\(entries.count == 1 ? "" : "s")"
        return "\(places) · \(bars) bars · \(total / 60):\(String(format: "%02d", total % 60))"
    }

    private func addDetail(_ section: SongSection) -> String {
        let used = slots.filter { $0.sectionID == section.id }.count
        let bars = "\(section.numberOfBars) bar\(section.numberOfBars == 1 ? "" : "s")"
        return used == 0 ? bars : "\(bars) · used \(used)×"
    }

    /// Why the switch is on but the arrangement isn't what plays right now.
    private var setAsideNote: String? {
        guard song.playsArrangement == true, !slots.isEmpty else { return nil }
        if songStore.holdsSection { return "Hold is on, so the held section plays. The arrangement plays again when Hold is off." }
        if songStore.triggerMode { return "Pattern Trigger Mode is on, so pads play sections. The arrangement plays again when it is off." }
        return nil
    }
}
