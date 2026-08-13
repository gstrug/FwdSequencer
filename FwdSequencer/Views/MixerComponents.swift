import SwiftUI

// Shared mixer components (fader, VU meters, master strip) used by SongMixerView.

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .animation(reduceMotion ? nil : .linear(duration: 0.05), value: level)
            }
        }
    }
}
