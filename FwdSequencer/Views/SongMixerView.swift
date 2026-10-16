import SwiftUI

// Song mixer — master strip + one channel strip per SongTrack. Reuses the shared
// FaderWithMeter / TrackVUMeter / MasterStrip / VUMeter from MixerView.swift.

struct SongMixerView: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss

    /// The Play keyboard's instrument, for its strip. Only shown when it exists.
    private var performanceBinding: Binding<SongTrack> {
        Binding(get: { songStore.song.performance ?? SongTrack(name: "Play Keyboard") },
                set: { songStore.song.performance = $0 })
    }

    var body: some View {
        NavigationStack {
            Group {
                if songStore.song.tracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No tracks yet").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {
                            MasterStrip(masterVolume: $songStore.song.masterVolume)
                                .midiLearnable(.masterVolume)
                            Divider().padding(.vertical, 8)

                            ForEach(songStore.song.tracks.indices, id: \.self) { idx in
                                SongChannelStrip(track: $songStore.song.tracks[idx], midi: .track(idx))
                                if idx < songStore.song.tracks.count - 1 {
                                    Divider().padding(.vertical, 8)
                                }
                            }

                            // The Play keyboard's instrument, once the song has one: a
                            // channel like the tracks, with its own fader, pan, mute,
                            // solo and effects.
                            if songStore.song.performance != nil {
                                Divider().padding(.vertical, 8)
                                SongChannelStrip(track: performanceBinding, midi: .play,
                                                 title: "Play Keyboard")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 20)
                    }
                }
            }
            .navigationTitle("Mixer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Learn works here too, so the strips can be linked to a controller's
                // faders without leaving the mixer.
                ToolbarItem(placement: .navigationBarLeading) { MIDILearnButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct SongChannelStrip: View {
    @Binding var track: SongTrack
    /// What this strip's controls are called for MIDI Learn: a track's (by position) or
    /// the Play keyboard's.
    let midi: MIDIChannelTargets
    /// Shown instead of the track's name.
    var title: String? = nil

    var body: some View {
        VStack(spacing: 14) {
            Text(title ?? track.name)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)

            FaderWithMeter(value: $track.mixer.volume) { TrackVUMeter(trackID: track.id) }
                .midiLearnable(midi.volume)

            Text("Vol").font(.caption2).foregroundStyle(.secondary)

            // Inserts belong on the channel strip, as in a DAW — the sequencer rows
            // stay about notes.
            // Tap: all effects in/out. Long press: edit them.
            EffectsToggleButton(track: track)
                .midiLearnable(midi.effects)

            StudioKnob(value: Binding(get: { Double(track.mixer.pan) },
                                      set: { track.mixer.pan = Float($0) }),
                       range: -1...1, defaultValue: 0, bipolar: true, size: 52,
                       label: "Pan \(panLabel)",
                       format: { _ in panLabel })
                .midiLearnable(midi.pan)

            HStack(spacing: 6) {
                StudioToggleChip(title: "M", isOn: $track.mixer.isMuted, tint: .orange,
                                 accessibilityLabel: "Mute \(track.name)")
                    .midiLearnable(midi.mute)
                StudioToggleChip(title: "S", isOn: $track.mixer.isSoloed, tint: .yellow,
                                 accessibilityLabel: "Solo \(track.name)")
                    .midiLearnable(midi.solo)
            }
        }
        .frame(width: 104)
    }

    private var panLabel: String {
        let p = track.mixer.pan
        if abs(p) < 0.05 { return "C" }
        return p < 0 ? "L\(Int(abs(p)*100))" : "R\(Int(p*100))"
    }
}
