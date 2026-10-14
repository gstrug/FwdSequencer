import SwiftUI

// Song mixer — master strip + one channel strip per SongTrack. Reuses the shared
// FaderWithMeter / TrackVUMeter / MasterStrip / VUMeter from MixerView.swift.

struct SongMixerView: View {
    @EnvironmentObject var songStore: SongStore
    @Environment(\.dismiss) private var dismiss

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
                            Divider().padding(.vertical, 8)

                            ForEach(songStore.song.tracks.indices, id: \.self) { idx in
                                SongChannelStrip(track: $songStore.song.tracks[idx])
                                if idx < songStore.song.tracks.count - 1 {
                                    Divider().padding(.vertical, 8)
                                }
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

    var body: some View {
        VStack(spacing: 14) {
            Text(track.name)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)

            FaderWithMeter(value: $track.mixer.volume) { TrackVUMeter(trackID: track.id) }

            Text("Vol").font(.caption2).foregroundStyle(.secondary)

            // Inserts belong on the channel strip, as in a DAW — the sequencer rows
            // stay about notes.
            // Tap: all effects in/out. Long press: edit them.
            EffectsToggleButton(track: track)

            StudioKnob(value: Binding(get: { Double(track.mixer.pan) },
                                      set: { track.mixer.pan = Float($0) }),
                       range: -1...1, defaultValue: 0, bipolar: true, size: 52,
                       label: "Pan \(panLabel)",
                       format: { _ in panLabel })

            HStack(spacing: 6) {
                StudioToggleChip(title: "M", isOn: $track.mixer.isMuted, tint: .orange,
                                 accessibilityLabel: "Mute \(track.name)")
                StudioToggleChip(title: "S", isOn: $track.mixer.isSoloed, tint: .yellow,
                                 accessibilityLabel: "Solo \(track.name)")
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
