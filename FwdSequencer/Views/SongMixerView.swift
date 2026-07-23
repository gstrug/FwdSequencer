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

            VStack(spacing: 2) {
                Text(panLabel).font(.caption2).monospacedDigit()
                Slider(value: $track.mixer.pan, in: -1...1).frame(width: 80)
                Text("Pan").font(.caption2).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Toggle("M", isOn: $track.mixer.isMuted)
                    .toggleStyle(.button).tint(.orange).font(.caption.bold())
                Toggle("S", isOn: $track.mixer.isSoloed)
                    .toggleStyle(.button).tint(.yellow).font(.caption.bold())
            }
        }
        .frame(width: 90)
    }

    private var panLabel: String {
        let p = track.mixer.pan
        if abs(p) < 0.05 { return "C" }
        return p < 0 ? "L\(Int(abs(p)*100))" : "R\(Int(p*100))"
    }
}
