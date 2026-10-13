import SwiftUI

/// A track's AUv3 effect chain: instrument → effects, in signal order, → mixer.
///
/// A sheet rather than anything on the track row. The row is already dense and its
/// alignment has been fussy to get right; effects are set up occasionally and then left
/// alone, so they do not earn permanent space next to the controls used on every take.
/// Reached from the track's ⋯ menu and from the mixer channel strip, which is where a
/// DAW keeps inserts.
struct TrackEffectsView: View {
    let trackID: UUID
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var editingIndex: Int?
    /// The slot whose effect is being swapped for another, if any.
    @State private var replacingIndex: Int?

    private var track: SongTrack? { songStore.song.tracks.first { $0.id == trackID } }
    private var slots: [PluginSlot] { track?.effectSlots ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if slots.isEmpty {
                        Text("No effects").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                            row(index: index, slot: slot)
                                // Removing is the row's own Remove button; without this,
                                // the always-on edit mode below would add a red delete
                                // control as well.
                                .deleteDisabled(true)
                        }
                        .onMove { source, destination in
                            songStore.moveEffects(from: source, to: destination, for: trackID)
                        }
                    }
                } header: {
                    Text("Chain")
                } footer: {
                    Text("Effects process this track's instrument before it reaches the "
                         + "mixer, top to bottom. Their own settings are saved with the "
                         + "song."
                         + (slots.count > 1 ? " Drag the handles to reorder them." : ""))
                }

                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Add Effect", systemImage: "plus")
                    }
                    .disabled(slots.count >= SongTrack.maximumEffects)
                } footer: {
                    if slots.count >= SongTrack.maximumEffects {
                        // Say why, rather than leaving a disabled button unexplained.
                        Text(SongTrack.maximumEffects == 1
                             ? "One effect per track for now, while the cost of hosting "
                               + "more is measured on real hardware. Watch the CPU "
                               + "readout on the transport."
                             : "Up to \(SongTrack.maximumEffects) effects per track.")
                    }
                }
            }
            // Reordering is always on once there is an order to change, so the drag handles
            // are simply there. It used to sit behind an Edit button, which nobody thought
            // to press: the natural thing is to grab an effect and move it.
            .environment(\.editMode, .constant(slots.count > 1 ? .active : .inactive))
            .navigationTitle(track?.name ?? "Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                EffectPickerView { info in
                    songStore.addEffect(info, to: trackID)
                    showPicker = false
                }
            }
            .sheet(item: Binding(
                get: { replacingIndex.map { EffectEditorTarget(index: $0) } },
                set: { replacingIndex = $0?.index }
            )) { target in
                EffectPickerView { info in
                    songStore.replaceEffect(at: target.index, with: info, for: trackID)
                    replacingIndex = nil
                }
            }
            .sheet(item: Binding(
                get: { editingIndex.map { EffectEditorTarget(index: $0) } },
                set: { editingIndex = $0?.index }
            )) { target in
                PluginEditorView(
                    trackID: trackID,
                    trackName: slots[safe: target.index]?.pluginInfo.name ?? "Effect",
                    effectIndex: target.index,
                    // Capture on close, exactly as an instrument's editor does, so a
                    // tweak survives without the user thinking to save anything.
                    onCommitState: { songStore.captureEffectState(at: target.index, for: trackID) }
                )
            }
        }
    }

    @ViewBuilder
    private func row(index: Int, slot: PluginSlot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(slot.pluginInfo.name).font(.body).lineLimit(1)
            Text(slot.pluginInfo.manufacturerName).font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button { editingIndex = index } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered).controlSize(.small)

                Toggle("Bypass", isOn: Binding(
                    get: { slot.bypassed },
                    set: { songStore.setEffectBypassed($0, at: index, for: trackID) }
                ))
                .toggleStyle(.button).controlSize(.small).tint(.orange)

                Spacer(minLength: 0)

                // Swap for a different effect in the same place in the chain, rather
                // than removing it, adding the new one and dragging it back into line.
                Button { replacingIndex = index } label: {
                    Label("Replace", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered).controlSize(.small)

                Button(role: .destructive) {
                    songStore.removeEffect(at: index, from: trackID)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Identifiable wrapper so a plain index can drive `.sheet(item:)`.
private struct EffectEditorTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Effect chooser. Separate from the instrument picker because it lists a different
/// scan (`aufx`/`aumf`) and has no "no plugin" option — removing is how you clear a slot.
struct EffectPickerView: View {
    @ObservedObject private var manager = PluginManager.shared
    @Environment(\.dismiss) private var dismiss
    let onSelect: (PluginInfo) -> Void

    var body: some View {
        NavigationStack {
            List {
                if manager.effects.isEmpty {
                    Text(manager.isScanning ? "Scanning…" : "No AUv3 effects installed")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.effects) { info in
                        Button {
                            onSelect(info)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.name).lineLimit(1)
                                Text(info.manufacturerName)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Effect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { manager.scan() }
        }
    }
}
