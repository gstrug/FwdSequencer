import SwiftUI

/// Double tap a control to return it to its default — the convention in every DAW and
/// most plugins, and the only quick way back to a known value once a slider has been
/// dragged somewhere arbitrary.
///
/// The tap is detected from a zero-distance drag rather than with `TapGesture`, which
/// does not work on a `Slider`. A slider runs its own drag recogniser, and attaching a
/// tap alongside it — whether by `gesture`, `simultaneousGesture` or `onTapGesture` —
/// leaves the two competing: the slider claims the touch and the tap never completes.
/// A `DragGesture(minimumDistance: 0)` runs happily beside it and reports every
/// touch-up, taps included, so the pair is counted here instead.
///
/// Movement is checked because that same gesture also ends after a real drag. Without
/// it, nudging a fader twice in quick succession would reset it — the opposite of what
/// was wanted, and worse than not having the feature.
private struct ResetOnDoubleTap: ViewModifier {
    let reset: () -> Void

    /// When the first tap of a possible pair landed.
    @State private var firstTap: Date?

    /// Slower than the system double-tap interval on purpose: this is a deliberate
    /// gesture on a small control, often with a fingertip already resting on it.
    private static let interval: TimeInterval = 0.45
    /// A touch that moves further than this was a drag, however short.
    private static let movementTolerance: CGFloat = 8

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    guard abs(value.translation.width) < Self.movementTolerance,
                          abs(value.translation.height) < Self.movementTolerance else {
                        firstTap = nil        // that was a drag, not a tap
                        return
                    }
                    let now = Date()
                    if let first = firstTap, now.timeIntervalSince(first) < Self.interval {
                        firstTap = nil
                        reset()
                    } else {
                        firstTap = now
                    }
                }
        )
    }
}

extension View {
    /// See `ResetOnDoubleTap` for why this is not a `TapGesture`.
    ///
    /// A modifier rather than the gesture written out at each call site, so a slider
    /// added later cannot quietly omit it — which is how eight of the thirteen ended up
    /// without one.
    func resetsOnDoubleTap(_ reset: @escaping () -> Void) -> some View {
        modifier(ResetOnDoubleTap(reset: reset))
    }
}
