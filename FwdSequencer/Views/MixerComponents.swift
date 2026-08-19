import SwiftUI

/// Faders operate in decibels, not in linear gain.
///
/// A linear 0...1 fader puts every useful mixing decision in the bottom of its
/// travel — a plugin that needs -20 dB sits at 0.1, with almost no resolution left
/// to trim it. Storage stays linear (so saved songs are unchanged); only the
/// control is logarithmic, with a little headroom for quiet instruments.
enum FaderScale {
    static let minDB: Float = -60      // treated as silence
    static let maxDB: Float = 6

    static func dB(fromLinear linear: Float) -> Float {
        linear <= 0 ? minDB : max(minDB, 20 * log10(linear))
    }

    static func linear(fromDB db: Float) -> Float {
        db <= minDB ? 0 : pow(10, db / 20)
    }

    /// Wraps a linear gain so a Slider can drive it in dB.
    static func binding(_ gain: Binding<Float>) -> Binding<Float> {
        Binding(get: { dB(fromLinear: gain.wrappedValue) },
                set: { gain.wrappedValue = linear(fromDB: $0) })
    }

    static func label(forLinear linear: Float) -> String {
        let db = dB(fromLinear: linear)
        if db <= minDB { return "-∞" }
        return String(format: "%+.1f", db)
    }
}

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
                Text(FaderScale.label(forLinear: value))
                    .font(.caption2).monospacedDigit()
                    .frame(width: 36)
                Slider(value: FaderScale.binding($value),
                       in: FaderScale.minDB...FaderScale.maxDB)
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
        VUMeter(level: levels.trackLevels[trackID] ?? .silent)
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
    let level: AudioLevel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Latches when the signal touches full scale, so a brief over is still visible
    /// after it has passed. Tap the meter to clear it.
    @State private var clipped = false
    /// Highest recent peak, so a transient leaves a mark instead of flashing by.
    @State private var heldPeak: CGFloat = 0
    @State private var holdExpiry = Date.distantPast

    // Colour stops placed by dB, not by bar fraction: green to -18, yellow to -6,
    // orange to -3, red to 0 dBFS.
    private var gradient: Gradient {
        Gradient(stops: [
            .init(color: .green,  location: 0),
            .init(color: .green,  location: AudioLevel.fraction(ofDB: -18)),
            .init(color: .yellow, location: AudioLevel.fraction(ofDB: -6)),
            .init(color: .orange, location: AudioLevel.fraction(ofDB: -3)),
            .init(color: .red,    location: 1),
        ])
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.25))

                // Body of the meter is RMS — how loud it actually sounds.
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(gradient: gradient,
                                         startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * level.rmsFraction)
                    .animation(reduceMotion ? nil : .linear(duration: 0.05),
                               value: level.rmsFraction)

                // Peak marker — this is the one that decides clipping.
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(height: 1.5)
                    .offset(y: -(geo.size.height * heldPeak) + 0.75)
                    .opacity(heldPeak > 0 ? 1 : 0)

                // Clip indicator, latched.
                if clipped {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(height: 3)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { clipped = false; heldPeak = 0 }
        }
        .onChange(of: level) { newValue in
            if newValue.isOver { clipped = true }
            let now = Date()
            if newValue.peakFraction >= heldPeak || now > holdExpiry {
                heldPeak = newValue.peakFraction
                holdExpiry = now.addingTimeInterval(1.5)
            }
        }
        .accessibilityLabel("Level")
        .accessibilityValue(level.peakDB.isFinite
                            ? String(format: "%.0f decibels%@", level.peakDB, clipped ? ", clipping" : "")
                            : "Silent")
    }
}
