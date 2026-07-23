import SwiftUI

struct MixerView: View {
    @EnvironmentObject var store: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.project.tracks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("No tracks yet")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 0) {

                            // Master strip — fixed on the left
                            MasterStrip(
                                masterVolume: $store.project.masterVolume
                            )
                            Divider().padding(.vertical, 8)

                            // Per-track strips
                            ForEach(store.project.tracks.indices, id: \.self) { idx in
                                ChannelStrip(
                                    track: $store.project.tracks[idx]
                                )
                                if idx < store.project.tracks.count - 1 {
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

// MARK: - Master Strip

struct MasterStrip: View {
    @Binding var masterVolume: Float

    var body: some View {
        VStack(spacing: 14) {
            Text("MASTER")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 80)

            FaderWithMeter(value: $masterVolume) { MasterVUMeter() }

            Text("Vol")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 90)
        .padding(.trailing, 8)
    }
}

// MARK: - Channel Strip

struct ChannelStrip: View {
    @Binding var track: Track

    var body: some View {
        VStack(spacing: 14) {

            Text(track.name)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)

            FaderWithMeter(value: $track.mixer.volume) { TrackVUMeter(trackID: track.id) }

            Text("Vol")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // Pan
            VStack(spacing: 2) {
                Text(panLabel)
                    .font(.caption2).monospacedDigit()
                Slider(value: $track.mixer.pan, in: -1...1)
                    .frame(width: 80)
                Text("Pan")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Mute / Solo
            HStack(spacing: 6) {
                Toggle("M", isOn: $track.mixer.isMuted)
                    .toggleStyle(.button)
                    .tint(.orange)
                    .font(.caption.bold())
                Toggle("S", isOn: $track.mixer.isSoloed)
                    .toggleStyle(.button)
                    .tint(.yellow)
                    .font(.caption.bold())
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

// MARK: - Fader With Meter (vertical slider + VU side by side)

struct FaderWithMeter<Meter: View>: View {
    @Binding var value: Float
    @ViewBuilder var meter: Meter

    private let faderHeight: CGFloat = 160

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {

            // Value label above + vertical fader
            VStack(spacing: 4) {
                Text("\(Int(value * 100))")
                    .font(.caption2).monospacedDigit()
                    .frame(width: 36)
                Slider(value: $value, in: 0...1)
                    .frame(width: faderHeight)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 36, height: faderHeight)
            }

            // VU meter alongside — an observing leaf so level ticks re-render
            // only the meter, not the whole channel strip.
            meter
                .frame(width: 10, height: faderHeight)
        }
    }
}

// MARK: - VU meter leaves (observe the LevelMonitor directly)

struct TrackVUMeter: View {
    let trackID: UUID
    @EnvironmentObject var levels: LevelMonitor
    var body: some View {
        VUMeter(level: levels.trackLevels[trackID] ?? 0)
    }
}

struct MasterVUMeter: View {
    @EnvironmentObject var levels: LevelMonitor
    var body: some View {
        VUMeter(level: levels.masterLevel)
    }
}

// MARK: - VU Meter

struct VUMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.25))

                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(
                        colors: [.green, .green, .yellow, .orange, .red],
                        startPoint: .bottom,
                        endPoint: .top
                    ))
                    .frame(height: geo.size.height * CGFloat(max(0, min(1, level))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }
}
