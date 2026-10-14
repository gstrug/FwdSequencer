import SwiftUI
import UIKit

// MARK: - Studio controls
//
// The app's own fader, knob and meter, drawn in the same "soft depth" style as the
// piano keys (PianoKeyFace): light from above, a recessed track, a raised rounded cap,
// a domed knob. The app is always dark (UIUserInterfaceStyle in Info.plist), so these
// are drawn for a dark surface only.
//
// Behaviour shared by the fader and the knob:
// - Drag to change. Moving the finger sideways, away from the control, slows it down
//   for fine trims: the further away, the finer.
// - A detent at the default (0 dB, pan centre): the value holds there for a short
//   stretch of travel, with a light haptic tap, so it can be found by feel.
// - A bubble shows the exact value while dragging.
// - Double tap returns to the default.
// - VoiceOver can swipe up and down to adjust.
//
// Drag state lives in @GestureState, which SwiftUI resets by itself when a gesture is
// cancelled rather than ended — so an interrupted drag can never leave the bubble up
// or the next drag starting from a stale position.

enum StudioStyle {
    static let trackTop = Color(white: 0.04)
    static let trackBottom = Color(white: 0.11)
    static let capTop = Color(white: 0.36)
    static let capBottom = Color(white: 0.18)
    static let unlit = Color(white: 0.17)
    static let scaleText = Color(white: 0.56)
}

/// The drag arithmetic shared by fader and knob.
private struct DragTrack {
    /// The value before the detent is applied, so the detent can hold and release.
    var raw: Double
    var lastY: CGFloat = 0
    var inDetent: Bool = false
}

private func fineFactor(forSideways dx: CGFloat) -> Double {
    // Full speed within 40 pt of the control; then progressively finer, down to a
    // tenth of the speed at about 300 pt away.
    let away = max(0, abs(dx) - 40)
    return 1 / (1 + Double(away) / 30)
}

private let detentHaptic = UISelectionFeedbackGenerator()

/// Apply one step of a drag. Returns the value to show.
private func applyDrag(_ track: inout DragTrack, translation: CGSize, travel: CGFloat,
                  range: ClosedRange<Double>, detent: Double?) -> Double {
    let dy = translation.height - track.lastY
    track.lastY = translation.height
    let span = range.upperBound - range.lowerBound
    track.raw -= Double(dy / max(travel, 1)) * span * fineFactor(forSideways: translation.width)
    track.raw = min(max(track.raw, range.lowerBound), range.upperBound)
    guard let detent else { return track.raw }
    // Hold at the detent for 3% of the travel either side of it.
    let holding = abs(track.raw - detent) < span * 0.03
    if holding && !track.inDetent { detentHaptic.selectionChanged() }
    track.inDetent = holding
    return holding ? detent : track.raw
}

/// A small dark label floated above a control while it is being dragged.
private struct ValueBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color(white: 0.24)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08)))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

// MARK: - Fader

/// A vertical fader with a printed scale, a value fill, a raised cap, a detent at its
/// default and a value bubble while dragging.
struct StudioFader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Where the detent sits and where double tap returns to.
    let defaultValue: Double
    /// Printed beside the track: value and label.
    var marks: [(Double, String)] = []
    var height: CGFloat = 160
    var accessibilityLabel: String = "Fader"
    let format: (Double) -> String

    @GestureState private var drag: DragTrack? = nil

    private let capHeight: CGFloat = 24
    private var travel: CGFloat { height - capHeight }

    private func y(for v: Double) -> CGFloat {
        let f = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        return capHeight / 2 + travel * CGFloat(1 - min(max(f, 0), 1))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if !marks.isEmpty { scale }
            ZStack(alignment: .top) {
                // Recessed track.
                Capsule()
                    .fill(LinearGradient(colors: [StudioStyle.trackTop, StudioStyle.trackBottom],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 10, height: height - capHeight + 8)
                    .offset(y: capHeight / 2 - 4)
                // Value fill, from the bottom up to the cap.
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: max(0, height - capHeight / 2 - y(for: value)))
                    .frame(height: height - capHeight, alignment: .bottom)
                    .offset(y: capHeight / 2)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 2)
                cap
                    .offset(y: y(for: value) - capHeight / 2)
                if drag != nil {
                    ValueBubble(text: format(value))
                        .offset(y: y(for: value) - capHeight / 2 - 24)
                }
            }
            .frame(width: 40, height: height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .updating($drag) { g, state, _ in
                        var t = state ?? DragTrack(raw: value)
                        value = applyDrag(&t, translation: g.translation, travel: travel,
                                     range: range, detent: defaultValue)
                        state = t
                    }
            )
            .onTapGesture(count: 2) { value = defaultValue }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let stepSize = (range.upperBound - range.lowerBound) / 40
            switch direction {
            case .increment: value = min(range.upperBound, value + stepSize)
            case .decrement: value = max(range.lowerBound, value - stepSize)
            @unknown default: break
            }
        }
    }

    private var cap: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(LinearGradient(colors: [StudioStyle.capTop, StudioStyle.capBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .top) {
                // Light catching the top edge.
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    .mask(Rectangle().frame(height: 3).frame(maxHeight: .infinity, alignment: .top))
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.45), lineWidth: 0.5))
            .overlay(Capsule().fill(Color.accentColor).frame(width: 22, height: 2))
            .frame(width: 36, height: capHeight)
            .shadow(color: .black.opacity(0.55), radius: 2.5, y: 3)
    }

    private var scale: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(marks.indices, id: \.self) { i in
                let mark = marks[i]
                HStack(spacing: 3) {
                    Text(mark.1)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(StudioStyle.scaleText)
                    Rectangle()
                        .fill(mark.0 == defaultValue ? StudioStyle.scaleText : Color(white: 0.30))
                        .frame(width: mark.0 == defaultValue ? 10 : 6, height: 1)
                }
                .frame(height: 10)
                .offset(y: y(for: mark.0) - 5)
            }
        }
        .frame(width: 30, height: height, alignment: .topTrailing)
        .accessibilityHidden(true)
    }
}

// MARK: - Knob

/// A domed rotary knob with a value arc. Drag up to turn it up, down to turn it down;
/// sideways for fine adjustment. Bipolar knobs (pan) draw their arc out from the
/// centre, so the direction reads at a glance.
struct StudioKnob: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var bipolar: Bool = false
    var size: CGFloat = 56
    var tint: Color = .accentColor
    var label: String? = nil
    let format: (Double) -> String

    @GestureState private var drag: DragTrack? = nil

    /// The arc runs from 7:30 round to 4:30, a 270° sweep, like most hardware.
    private static let startAngle: Double = 135
    private static let sweep: Double = 270

    private func fraction(_ v: Double) -> Double {
        min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    var body: some View {
        VStack(spacing: 4) {
            dial
                .frame(width: size, height: size)
                .overlay(alignment: .top) {
                    if drag != nil {
                        ValueBubble(text: format(value)).offset(y: -22)
                    }
                }
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($drag) { g, state, _ in
                            var t = state ?? DragTrack(raw: value)
                            // A full sweep takes about two and a half knob heights of
                            // travel, so it is quick without being twitchy.
                            value = applyDrag(&t, translation: g.translation,
                                         travel: max(size * 2.5, 120),
                                         range: range, detent: defaultValue)
                            state = t
                        }
                )
                .onTapGesture(count: 2) { value = defaultValue }
            if let label {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.78))
                    .lineLimit(1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? "Knob")
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let stepSize = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + stepSize)
            case .decrement: value = max(range.lowerBound, value - stepSize)
            @unknown default: break
            }
        }
    }

    private var dial: some View {
        let ring = max(3, size * 0.075)
        let f = fraction(value)
        let from = bipolar ? min(0.5, f) : 0
        let to = bipolar ? max(0.5, f) : f
        let pointerAngle = Angle.degrees(Self.startAngle + Self.sweep * f)
        return ZStack {
            // Track of the arc.
            Circle()
                .trim(from: 0, to: Self.sweep / 360)
                .stroke(StudioStyle.trackTop, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                .rotationEffect(.degrees(Self.startAngle))
            // The value.
            Circle()
                .trim(from: from * Self.sweep / 360, to: to * Self.sweep / 360)
                .stroke(tint, style: StrokeStyle(lineWidth: ring, lineCap: .round))
                .rotationEffect(.degrees(Self.startAngle))
                .shadow(color: tint.opacity(0.6), radius: 2)
            // The dome.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.38), Color(white: 0.22), Color(white: 0.14)],
                                     center: UnitPoint(x: 0.4, y: 0.3),
                                     startRadius: 0, endRadius: size * 0.42))
                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5))
                .overlay(
                    Circle().trim(from: 0.55, to: 0.95)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        .padding(1.5)
                )
                .padding(ring * 1.6)
                .shadow(color: .black.opacity(0.55), radius: 2.5, y: 3)
            // Pointer: a short line on the dome towards the value.
            Capsule()
                .fill(tint)
                .frame(width: max(2, size * 0.05), height: size * 0.16)
                .offset(y: -size * 0.2)
                .rotationEffect(pointerAngle + .degrees(90))
        }
    }
}

// MARK: - Segmented meter

/// A level meter built of rounded segments, lit from the bottom (or left). The body
/// shows RMS — how loud it sounds — one segment holds the recent peak, and the top
/// segment latches red on an over until the level has settled or it is tapped.
struct SegmentedMeter: View {
    let level: AudioLevel
    var segments: Int = 16
    var vertical: Bool = true

    @State private var latch = ClipLatch()
    @State private var heldPeak: CGFloat = 0
    @State private var holdExpiry = Date.distantPast

    /// Colour by where the segment sits in dBFS: green to -18, yellow to -6, orange
    /// to -3, red above.
    private func color(forSegment i: Int) -> Color {
        let top = AudioLevel.floorDB * (1 - Float(i + 1) / Float(segments))
        if top > -3 { return Color(red: 1.0, green: 0.27, blue: 0.23) }
        if top > -6 { return .orange }
        if top > -18 { return Color(red: 1.0, green: 0.84, blue: 0.04) }
        return Color(red: 0.19, green: 0.82, blue: 0.35)
    }

    var body: some View {
        let lit = Int((level.rmsFraction * CGFloat(segments)).rounded())
        let peakSegment = heldPeak > 0 ? min(segments - 1, Int(heldPeak * CGFloat(segments))) : -1
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            // Segment 0 is the quietest. A column lists the loudest first (top), a row
            // the quietest first (left).
            ForEach(vertical ? Array((0..<segments).reversed()) : Array(0..<segments), id: \.self) { i in
                let isLit = i < lit || i == peakSegment || (i == segments - 1 && latch.isLit)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isLit ? color(forSegment: i) : StudioStyle.unlit)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { latch.clear(); heldPeak = 0 }
        .onChange(of: level) { newValue in
            let now = Date()
            latch.update(with: newValue, now: now)
            if newValue.peakFraction >= heldPeak || now > holdExpiry {
                heldPeak = newValue.peakFraction
                holdExpiry = now.addingTimeInterval(1.5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(level.peakDB.isFinite
                            ? String(format: "%.0f decibels%@", level.peakDB, latch.isLit ? ", clipping" : "")
                            : "Silent")
    }
}
