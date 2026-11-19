import SwiftUI

// MARK: - MIDI Learn on screen
//
// How Learn works, AUM-style: switch Learn on, tap a control on screen (it lights up
// orange), then move a knob or press a button on the controller. The two are linked,
// and the control shows which message it answers to. A long press on a linked control
// removes the link. Everything else keeps working: the controller still plays the
// controls it is already linked to while Learn is on.

extension View {
    /// Make this control linkable to a MIDI controller with MIDI Learn.
    func midiLearnable(_ target: MIDIControlTarget) -> some View {
        modifier(MIDILearnableModifier(target: target))
    }
}

private struct MIDILearnableModifier: ViewModifier {
    let target: MIDIControlTarget
    // Observes only Learn's own small state, which changes when Learn is used — not the
    // control centre, whose activity lights change with every message.
    @ObservedObject private var learn = MIDIControlCenter.shared.learn

    func body(content: Content) -> some View {
        content.overlay {
            if learn.isOn { MIDILearnOverlay(target: target, learn: learn) }
        }
    }
}

/// Sits over a control in Learn mode and takes its taps, so a tap selects the control
/// for linking instead of using it.
private struct MIDILearnOverlay: View {
    let target: MIDIControlTarget
    @ObservedObject var learn: MIDILearnState

    var body: some View {
        // Read so the label refreshes when links change.
        let _ = learn.revision
        let selected = learn.target == target
        let link = MIDIControlCenter.shared.linkDescription(for: target)
        let tint: Color = selected ? .orange : (link != nil ? .green : .orange)

        RoundedRectangle(cornerRadius: 6)
            .fill(tint.opacity(selected ? 0.35 : (link != nil ? 0.16 : 0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(selected || link != nil ? 1 : 0.75),
                                  style: StrokeStyle(lineWidth: selected ? 2.5 : 1.5,
                                                     dash: selected || link != nil ? [] : [4, 3]))
            )
            .overlay(alignment: .bottom) {
                if let link {
                    Text(link)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .fixedSize()
                        .offset(y: 7)
                }
            }
            .padding(-3)
            .contentShape(Rectangle())
            .onTapGesture { learn.target = selected ? nil : target }
            .contextMenu {
                if link != nil {
                    Button(role: .destructive) {
                        MIDIControlCenter.shared.forget(target)
                    } label: {
                        Label("Remove MIDI Link", systemImage: "xmark.circle")
                    }
                }
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Learn \(target.displayName)")
            .accessibilityValue(selected ? "Waiting for MIDI" : (link.map { "Linked to \($0)" } ?? "Not linked"))
    }
}

/// The Learn switch for a toolbar or the transport.
struct MIDILearnButton: View {
    @ObservedObject private var learn = MIDIControlCenter.shared.learn

    var body: some View {
        Button { learn.isOn.toggle() } label: {
            Label("Learn", systemImage: "dot.radiowaves.left.and.right")
        }
        .buttonStyle(.bordered)
        .tint(learn.isOn ? .orange : nil)
        .help("MIDI Learn: link the controls on screen to a MIDI controller")
        .accessibilityLabel("MIDI Learn")
        .accessibilityValue(learn.isOn ? "On" : "Off")
        .helpTag(.midiLearn)
    }
}

/// Shown under the transport while Learn is on: what to do next, and the few things
/// that can be linked but have no control of their own on screen.
struct MIDILearnBanner: View {
    @ObservedObject private var learn = MIDIControlCenter.shared.learn
    @ObservedObject private var center = MIDIControlCenter.shared

    var body: some View {
        if learn.isOn {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.orange)
                Text(instruction)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Previous and next section have no button on screen, so they get one
                // here, only to be linked.
                learnChip("◀ Section", .previousSection)
                learnChip("Section ▶", .nextSection)
                learnChip("Write Notes", .writeNotes)
                // In the Settings menu, which can't be tapped in Learn mode.
                learnChip("Trigger Mode", .triggerMode)

                Button("Done") { learn.isOn = false }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var instruction: String {
        if center.sources.isEmpty {
            return "MIDI Learn — no controller is connected. Plug one in over USB or pair one with Bluetooth MIDI."
        }
        if let target = learn.target {
            return "Now move or press the control on your controller for \(target.displayName)."
        }
        return "MIDI Learn — tap a control, then move or press the one on your controller. Long press a linked control to remove its link."
    }

    private func learnChip(_ title: String, _ target: MIDIControlTarget) -> some View {
        Text(title)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
            .midiLearnable(target)
    }
}

/// Shown under the transport while a track is armed for Write Notes, so it is never on
/// by accident: which track and section notes are going into, and Done.
struct MIDIWriteNotesBanner: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var learn = MIDIControlCenter.shared.learn

    var body: some View {
        if let armed = learn.writingTrackID,
           let track = songStore.song.tracks.first(where: { $0.id == armed }) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.red)
                Text(instruction(track))
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { learn.writingTrackID = nil }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func instruction(_ track: SongTrack) -> String {
        let sections = songStore.song.sections
        let section = sections.indices.contains(songStore.selectedSection)
            ? sections[songStore.selectedSection].name : "this section"
        return "Writing notes into \(track.name), \(section). Keys on your controller add or remove notes and play \(track.name)."
    }
}

/// A track's W button: arm it for Write Notes from Keys, one track at a time. Only
/// shown while Write Notes from Keys is switched on in Settings ▸ MIDI.
struct TrackWriteNotesButton: View {
    let track: SongTrack
    let index: Int
    @ObservedObject private var learn = MIDIControlCenter.shared.learn

    /// Shown when a controller's keys go to the tracks (or Write Notes is on).
    ///
    /// - Write Notes on: **W** (red) — arms this track; one track at a time. Keys play
    ///   it and add or remove notes in it.
    /// - Write Notes off: **P** (green) — keys play this track. Any number at once.
    var body: some View {
        if learn.keysReachTracks || learn.writeNotesEnabled {
            if learn.writeNotesEnabled {
                StudioToggleChip(title: "W",
                                 isOn: Binding(get: { learn.writingTrackID == track.id },
                                               set: { _ in MIDIControlCenter.shared.toggleWriting(track.id) }),
                                 tint: .red,
                                 accessibilityLabel: "Write notes from keys into \(track.name)")
                    .midiLearnable(.trackWriteNotes(index))
                    .helpTag(.trackWrite, instance: track.id.uuidString)
            } else {
                StudioToggleChip(title: "P",
                                 isOn: Binding(get: { learn.playTrackIDs.contains(track.id) },
                                               set: { _ in MIDIControlCenter.shared.togglePlay(track.id) }),
                                 tint: .green,
                                 accessibilityLabel: "Keys play \(track.name)")
                    .midiLearnable(.trackWriteNotes(index))
                    .helpTag(.trackPlayKeys, instance: track.id.uuidString)
            }
            // Beside W or P, since it only matters when keys reach the tracks.
            KeysTransposeMenu(channel: track, help: .trackTranspose)
        }
    }
}

/// Transpose for the notes played live into a track or the Play keyboard. The chip
/// reads T at 0 and the amount otherwise ("−12"), lit so a shifted track stands out.
struct KeysTransposeMenu: View {
    let channel: SongTrack
    let help: HelpTopic
    @EnvironmentObject private var songStore: SongStore

    private var value: Int { channel.effectiveKeysTranspose }

    static func label(_ semitones: Int) -> String {
        semitones == 0 ? "0" : (semitones > 0 ? "+\(semitones)" : "−\(-semitones)")
    }

    var body: some View {
        Menu {
            Section("Transpose Keys: \(Self.label(value))") {
                step("Up an Octave", by: 12, systemImage: "arrow.up.to.line")
                step("Up a Semitone", by: 1, systemImage: "arrow.up")
                step("Down a Semitone", by: -1, systemImage: "arrow.down")
                step("Down an Octave", by: -12, systemImage: "arrow.down.to.line")
            }
            if value != 0 {
                Button { songStore.setKeysTranspose(0, for: channel.id) } label: {
                    Label("No Transpose", systemImage: "arrow.uturn.backward")
                }
            }
        } label: {
            StudioChipLabel(title: value == 0 ? "T" : Self.label(value), tint: .cyan,
                            look: value == 0 ? .off : .status)
        }
        .accessibilityLabel("Transpose keys for \(channel.name)")
        .accessibilityValue(value == 0 ? "None" : "\(Self.label(value)) semitones")
        .helpTag(help, instance: channel.id.uuidString)
    }

    @ViewBuilder
    private func step(_ title: String, by amount: Int, systemImage: String) -> some View {
        let target = value + amount
        Button { songStore.setKeysTranspose(target, for: channel.id) } label: {
            Label(title, systemImage: systemImage)
        }
        .disabled(!SongTrack.keysTransposeRange.contains(target))
    }
}

/// The MIDI targets of one mixer channel: a track's, by position, or the Play keyboard's.
struct MIDIChannelTargets {
    let volume: MIDIControlTarget
    let pan: MIDIControlTarget
    let mute: MIDIControlTarget
    let solo: MIDIControlTarget
    let effects: MIDIControlTarget

    static func track(_ index: Int) -> MIDIChannelTargets {
        MIDIChannelTargets(volume: .trackVolume(index), pan: .trackPan(index),
                           mute: .trackMute(index), solo: .trackSolo(index),
                           effects: .trackEffects(index))
    }

    static let play = MIDIChannelTargets(volume: .playVolume, pan: .playPan,
                                         mute: .playMute, solo: .playSolo,
                                         effects: .playEffects)
}
