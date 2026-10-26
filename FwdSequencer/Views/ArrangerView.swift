import SwiftUI

// MARK: - Arranger
//
// The order a song plays in. Each place is a Song Part — a named group of sections,
// such as a Verse made of four 1-bar sections — or a single section, and any of them
// can be placed as often as you like. Each place is an ArrangementSlot with its own
// id, so the same thing placed twice is two rows, and the one playing can be shown.
// The order itself is worked out in one place, Song.playOrder, which both the
// sequencer (SongStore.flattenedSections) and MIDI export use.
//
// Opened from the Section menu and the song order strip. The Play Arrangement switch
// is saved with the song. Hold and Pattern Trigger Mode work on sections themselves,
// so while either is on the song plays its sections, not the arrangement
// (SongStore.followsArrangement).

struct ArrangerView: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var help = HelpCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    /// The Song Part open for editing, pushed onto the stack.
    @State private var path: [UUID] = []
    /// The Song Part being renamed from its ⋯ menu.
    @State private var renamingPart: UUID?
    @State private var renameDraft = ""

    private var song: Song { songStore.song }
    private var slots: [ArrangementSlot] { songStore.song.arrangement ?? [] }
    private var parts: [SongPart] { songStore.song.songParts ?? [] }

    private var playsBinding: Binding<Bool> {
        Binding(get: { songStore.song.playsArrangement == true },
                set: { songStore.song.playsArrangement = $0 })
    }

    var body: some View {
        NavigationStack(path: $path) {
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

                availableSection

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

                songOrderSection
            }
            // Always editing: the drag handles are the point of this screen.
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Arranger")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in SongPartEditor(partID: id) }
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
                Text("Your sections and Song Parts are not changed.")
            }
            .alert("Rename Song Part", isPresented: Binding(
                get: { renamingPart != nil },
                set: { if !$0 { renamingPart = nil } })) {
                TextField("Name", text: $renameDraft)
                Button("Cancel", role: .cancel) { renamingPart = nil }
                Button("Rename") {
                    if let id = renamingPart { songStore.renameSongPart(id, to: renameDraft) }
                    renamingPart = nil
                }
            }
        }
    }

    // MARK: Available: Song Parts and sections

    /// Song Parts first, then single sections. A tap adds one to the end of the song
    /// order; a Song Part's ⋯ edits, renames, duplicates or deletes it.
    private var availableSection: some View {
        Section {
            Button {
                help.perform(.songPartNew) {
                    if let id = songStore.addSongPart() { path.append(id) }
                }
            } label: {
                Label("New Song Part", systemImage: "plus.rectangle.on.rectangle")
                    .frame(minHeight: 36)
            }
            .helpTag(.songPartNew)

            ForEach(parts) { part in
                partRow(part)
            }

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
            Text("Available")
        } footer: {
            Text("Tap a Song Part or a section to add it to the end of the song order. A Song Part is a group of sections, such as a verse, that plays as one; change it and every place it is used changes too.")
        }
    }

    private func partRow(_ part: SongPart) -> some View {
        HStack(spacing: 12) {
            Button {
                help.perform(.songPartAdd) { songStore.appendToArrangement(part: part.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(part.sectionIDs.isEmpty ? Color.secondary : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.stack")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(part.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        Text(partContents(part))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!help.isOn && part.sectionIDs.isEmpty)
            .helpTag(.songPartAdd, instance: part.id.uuidString)

            Menu {
                Button { path.append(part.id) } label: {
                    Label("Edit Sections…", systemImage: "list.bullet")
                }
                Button {
                    renameDraft = part.name
                    renamingPart = part.id
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                Button { songStore.duplicateSongPart(part.id) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Divider()
                Button(role: .destructive) { songStore.deleteSongParts([part.id]) } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Options for \(part.name)")
            .helpTag(.songPartEdit, instance: part.id.uuidString)
        }
    }

    private func partContents(_ part: SongPart) -> String {
        let names = part.sectionIDs.compactMap { id in song.sections.first { $0.id == id }?.name }
        guard !names.isEmpty else { return "Empty — use ⋯ ▸ Edit Sections to add some" }
        let bars = part.sectionIDs.reduce(0) { total, id in
            total + (song.sections.first { $0.id == id }?.numberOfBars ?? 0)
        }
        let used = slots.filter { $0.partID == part.id }.count
        var text = names.joined(separator: " · ") + " — \(bars) bar\(bars == 1 ? "" : "s")"
        if used > 0 { text += " · used \(used)×" }
        return text
    }

    private func addDetail(_ section: SongSection) -> String {
        let used = slots.filter { $0.sectionID == section.id }.count
        let bars = "\(section.numberOfBars) bar\(section.numberOfBars == 1 ? "" : "s")"
        return used == 0 ? bars : "\(bars) · used \(used)×"
    }

    // MARK: Song Order

    struct Row {
        let slotIndex: Int
        let slot: ArrangementSlot
        let name: String
        let isPart: Bool
        let sections: [SongSection]
        let startBar: Int
        var bars: Int { sections.reduce(0) { $0 + $1.numberOfBars } }
    }

    /// Each place with what it plays and the bar it starts on. Places with nothing to
    /// play are left out, exactly as playback leaves them out.
    static func rows(of song: Song) -> [Row] {
        var bar = 1
        return (song.arrangement ?? []).enumerated().compactMap { index, slot in
            let sections = song.sectionIndices(for: slot).map { song.sections[$0] }
            guard !sections.isEmpty else { return nil }
            let part = song.songPart(slot.partID)
            let row = Row(slotIndex: index, slot: slot, name: part?.name ?? sections[0].name,
                          isPart: part != nil, sections: sections, startBar: bar)
            bar += row.bars
            return row
        }
    }

    private var songOrderSection: some View {
        let rows = Self.rows(of: song)
        return Section {
            if rows.isEmpty {
                Text("Nothing arranged yet. Tap Song Parts or sections above, in the order they should play.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.slot.id) { row in
                slotRow(row, number: (rows.firstIndex { $0.slot.id == row.slot.id } ?? 0) + 1)
                    .helpTag(.arrangerSlot, instance: row.slot.id.uuidString)
            }
            .onMove { source, destination in
                // Rows can skip empty places, so move by the places' own positions.
                let from = IndexSet(source.map { rows[$0].slotIndex })
                let to = destination < rows.count ? rows[destination].slotIndex : slots.count
                songStore.moveInArrangement(from: from, to: to)
            }
            .onDelete { offsets in
                songStore.removeFromArrangement(at: IndexSet(offsets.map { rows[$0].slotIndex }))
            }
        } header: {
            Text("Song Order")
        } footer: {
            if !rows.isEmpty {
                Text("Drag ≡ to reorder. Tap − or swipe left to remove.")
            }
        }
    }

    @ViewBuilder
    private func slotRow(_ row: Row, number: Int) -> some View {
        let isPlaying = songStore.playingArrangementSlot == row.slotIndex
        let playingPosition = isPlaying ? songStore.playingEntry?.positionInSlot : nil
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if row.isPart {
                        Image(systemName: "rectangle.stack")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(row.name).font(.body.weight(.semibold))
                }
                Text(rowDetail(row, playingPosition: playingPosition))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.isPart {
                    SectionSegments(sections: row.sections, lit: playingPosition)
                        .frame(height: 6)
                }
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
        }
        .listRowBackground(isPlaying ? Color.green.opacity(0.12) : nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Place \(number), \(row.name)")
        .accessibilityValue(Text(isPlaying ? "Playing" : ""))
    }

    private func rowDetail(_ row: Row, playingPosition: Int?) -> String {
        var text = "\(row.bars) bar\(row.bars == 1 ? "" : "s") · starts bar \(row.startBar)"
        if let playingPosition, row.sections.indices.contains(playingPosition), row.isPart {
            text += " · ▶ \(row.sections[playingPosition].name)"
        }
        return text
    }

    // MARK: Words

    private var summary: String {
        let rows = Self.rows(of: song)
        guard !rows.isEmpty else { return "Off: sections play in order." }
        let bars = rows.reduce(0) { $0 + $1.bars }
        let ts = song.timeSignature
        let secondsPerBar = Double(ts.numerator) * (60 / max(1, song.tempo)) * 4 / Double(max(1, ts.denominator))
        let total = Int((Double(bars) * secondsPerBar).rounded())
        let places = "\(rows.count) place\(rows.count == 1 ? "" : "s")"
        return "\(places) · \(bars) bars · \(total / 60):\(String(format: "%02d", total % 60))"
    }

    /// Why the switch is on but the arrangement isn't what plays right now.
    private var setAsideNote: String? {
        guard song.playsArrangement == true, !slots.isEmpty else { return nil }
        if songStore.holdsSection { return "Hold is on, so the held section plays. The arrangement plays again when Hold is off." }
        if songStore.triggerMode { return "Pattern Trigger Mode is on, so pads play sections. The arrangement plays again when it is off." }
        return nil
    }
}

/// A thin bar per section of a Song Part, sized by its length; the one sounding lit.
struct SectionSegments: View {
    let sections: [SongSection]
    let lit: Int?

    var body: some View {
        GeometryReader { geo in
            let total = max(1, sections.reduce(0) { $0 + $1.numberOfBars })
            let gap: CGFloat = 2
            let usable = max(0, geo.size.width - gap * CGFloat(max(0, sections.count - 1)))
            HStack(spacing: gap) {
                ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index == lit ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: usable * CGFloat(section.numberOfBars) / CGFloat(total))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - One Song Part

private struct SongPartEditor: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var help = HelpCenter.shared
    @Environment(\.dismiss) private var dismiss
    let partID: UUID
    @State private var nameDraft = ""
    @State private var renaming = false

    private var part: SongPart? { songStore.song.songPart(partID) }

    var body: some View {
        List {
            if let part {
                Section {
                    Button {
                        help.perform(.songPartName) {
                            nameDraft = part.name
                            renaming = true
                        }
                    } label: {
                        HStack {
                            Text("Name").foregroundStyle(.primary)
                            Spacer()
                            Text(part.name).foregroundStyle(.secondary)
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                    }
                    .helpTag(.songPartName)
                }

                Section {
                    if part.sectionIDs.isEmpty {
                        Text("No sections yet. Tap sections below, in the order they should play.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(part.sectionIDs.enumerated()), id: \.offset) { index, id in
                        let section = songStore.song.sections.first { $0.id == id }
                        HStack(spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 24, alignment: .trailing)
                            Text(section?.name ?? "Missing section")
                            Spacer()
                            if let section {
                                Text("\(section.numberOfBars) bar\(section.numberOfBars == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .helpTag(.songPartSection, instance: "\(index)")
                    }
                    .onMove { songStore.moveSections(from: $0, to: $1, inPart: partID) }
                    .onDelete { songStore.removeSections(at: $0, fromPart: partID) }
                } header: {
                    Text("Sections in this Song Part")
                } footer: {
                    Text(footer(part))
                }

                Section {
                    ForEach(Array(songStore.song.sections.enumerated()), id: \.element.id) { index, section in
                        Button {
                            help.perform(.songPartAddSection) {
                                songStore.addSection(at: index, toPart: partID)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(section.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(section.numberOfBars) bar\(section.numberOfBars == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 36)
                        }
                        .helpTag(.songPartAddSection, instance: section.id.uuidString)
                    }
                } header: {
                    Text("Available Sections")
                }

                Section {
                    Button(role: .destructive) {
                        help.perform(.songPartDelete) {
                            songStore.deleteSongParts([partID])
                            dismiss()
                        }
                    } label: {
                        Label("Delete Song Part", systemImage: "trash")
                    }
                    .helpTag(.songPartDelete)
                } footer: {
                    Text("Removes it from the song order too. Your sections are not changed.")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(part?.name ?? "Song Part")
        .navigationBarTitleDisplayMode(.inline)
        .helpHost()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { HelpButton() }
        }
        .alert("Rename Song Part", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { songStore.renameSongPart(partID, to: nameDraft) }
        }
    }

    private func footer(_ part: SongPart) -> String {
        let bars = part.sectionIDs.reduce(0) { total, id in
            total + (songStore.song.sections.first { $0.id == id }?.numberOfBars ?? 0)
        }
        let uses = (songStore.song.arrangement ?? []).filter { $0.partID == partID }.count
        let used = uses == 0 ? "Not in the song order yet." : "Used \(uses)× in the song order."
        return "\(bars) bar\(bars == 1 ? "" : "s"). \(used) Drag ≡ to reorder, swipe left to remove."
    }
}
