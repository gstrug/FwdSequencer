import SwiftUI
import UIKit

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

    /// A track's chain, or the Play keyboard instrument's.
    private var track: SongTrack? {
        songStore.song.tracks.first { $0.id == trackID }
            ?? songStore.song.performance.flatMap { $0.id == trackID ? $0 : nil }
    }
    private var slots: [PluginSlot] { track?.effectSlots ?? [] }

    var body: some View {
        NavigationStack {
            List {
                // The same switch as tapping the FX button, so its state is visible
                // and changeable here too. Each effect's own Bypass is separate.
                if !slots.isEmpty {
                    Section {
                        Toggle("Effects On", isOn: Binding(
                            get: { !(track?.chainBypassed ?? false) },
                            set: { songStore.setEffectsChainBypassed(!$0, for: trackID) }
                        ))
                        .tint(.green)
                    } footer: {
                        Text("Switches the whole chain in or out. Effects bypassed "
                             + "individually stay bypassed when it comes back on.")
                    }
                }

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

/// The state of a track's effects at a glance, for its FX buttons (track row and mixer).
///
/// Grey when there are none, green when at least one is processing, orange when the
/// chain is switched out or every effect is bypassed — orange because that is the
/// colour of the Bypass switch in the effects list, and so as not to be mistaken for
/// the yellow Solo button beside it.
enum EffectsStatus: Equatable {
    case none, active, allBypassed

    init(_ track: SongTrack) {
        let slots = track.effectSlots
        if slots.isEmpty { self = .none }
        else if track.chainBypassed || slots.allSatisfy(\.bypassed) { self = .allBypassed }
        else { self = .active }
    }

    var tint: Color {
        switch self {
        case .none:        return .secondary
        case .active:      return .green
        case .allBypassed: return .orange
        }
    }

    /// "FX", or "FX 3" with how many are loaded.
    static func title(_ slots: [PluginSlot]) -> String {
        slots.isEmpty ? "FX" : "FX \(slots.count)"
    }

    static func accessibilityValue(_ track: SongTrack) -> String {
        let slots = track.effectSlots
        switch EffectsStatus(track) {
        case .none:        return "No effects"
        case .active:
            let on = slots.filter { !$0.bypassed }.count
            return "\(slots.count) loaded, \(on) active"
        case .allBypassed:
            return track.chainBypassed ? "\(slots.count) loaded, switched off"
                                       : "\(slots.count) loaded, all bypassed"
        }
    }
}

/// A track's FX button, on the track row and the mixer channel.
///
/// Tap switches the whole chain in and out — bypassing every effect, or bringing them
/// all back — so comparing with and without effects is one tap. Long press opens the
/// effects list for editing. With no effects loaded there is nothing to switch, so a
/// tap opens the list too.
///
/// Drawn rather than a Button: a Button fires its action at the end of a long press as
/// well, so the chain would toggle every time the list was opened.
struct EffectsToggleButton: View {
    let track: SongTrack
    @EnvironmentObject var songStore: SongStore
    @State private var showEffects = false

    private var trackID: UUID { track.id }
    private var trackName: String { track.name }
    private var slots: [PluginSlot] { track.effectSlots }
    private var status: EffectsStatus { EffectsStatus(track) }

    var body: some View {
        // Same chip as M and S, so the three read as a set.
        StudioChipLabel(title: EffectsStatus.title(slots), tint: status.tint,
                        look: status == .none ? .off : .status)
            .onTapGesture { tap() }
            .onLongPressGesture(minimumDuration: 0.45) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showEffects = true
            }
            .sheet(isPresented: $showEffects) {
                TrackEffectsView(trackID: trackID).environmentObject(songStore)
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Effects for \(trackName)")
            .accessibilityValue(EffectsStatus.accessibilityValue(track))
            .accessibilityHint(slots.isEmpty ? "Opens the effects list"
                               : "Switches all effects on or off. Use the Edit Effects action to change them.")
            .accessibilityAction { tap() }
            .accessibilityAction(named: Text("Edit Effects")) { showEffects = true }
    }

    private func tap() {
        if slots.isEmpty { showEffects = true }
        else { songStore.toggleEffectsChain(for: trackID) }
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
