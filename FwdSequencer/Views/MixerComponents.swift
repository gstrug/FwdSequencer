import SwiftUI


/// Latched clip state shared by both meter styles.
///
/// A clip indicator has to persist — an over lasts one buffer and would otherwise
/// flash past unseen. It clears itself once the signal has stayed below full scale
/// for a moment, so pulling a hot track down visibly resolves it, and it can also
/// be cleared by tapping the meter.
struct ClipLatch {
    private(set) var isLit = false
    private var lastOver = Date.distantPast
    /// How long the signal must stay clean before the indicator clears itself.
    static let clearAfter: TimeInterval = 2.0

    mutating func update(with level: AudioLevel, now: Date = Date()) {
        if level.isOver {
            isLit = true
            lastOver = now
        } else if isLit, now.timeIntervalSince(lastOver) > Self.clearAfter {
            isLit = false
        }
    }

    mutating func clear() { isLit = false; lastOver = .distantPast }
}

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
        .frame(width: 104)
        .padding(.trailing, 8)
    }
}
// MARK: - Fader With Meter (studio fader + segmented meter side by side)

struct FaderWithMeter<Meter: View>: View {
    @Binding var value: Float
    @ViewBuilder var meter: Meter

    private let faderHeight: CGFloat = 180

    /// The fader works in dB; the model stores linear gain (see FaderScale).
    private var dBBinding: Binding<Double> {
        Binding(get: { Double(FaderScale.dB(fromLinear: value)) },
                set: { value = FaderScale.linear(fromDB: Float($0)) })
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(FaderScale.label(forLinear: value))
                .font(.caption2).monospacedDigit()
                .foregroundStyle(Color(white: 0.85))
            HStack(alignment: .top, spacing: 6) {
                StudioFader(value: dBBinding,
                            range: Double(FaderScale.minDB)...Double(FaderScale.maxDB),
                            defaultValue: 0,   // unity
                            marks: [(6, "+6"), (0, "0"), (-10, "-10"), (-20, "-20"),
                                    (-40, "-40"), (Double(FaderScale.minDB), "-∞")],
                            height: faderHeight,
                            accessibilityLabel: "Volume",
                            format: { db in
                                db <= Double(FaderScale.minDB) ? "-∞" : String(format: "%+.1f dB", db)
                            })
                // An observing leaf, so level ticks re-render only the meter.
                meter
                    .frame(width: 10, height: faderHeight - 16)
                    .padding(.top, 8)
            }
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

/// The mixer's meter: the segmented studio meter (see StudioControls).
struct VUMeter: View {
    let level: AudioLevel
    var body: some View { SegmentedMeter(level: level, segments: 18) }
}
