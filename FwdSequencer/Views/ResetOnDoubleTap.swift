import SwiftUI
import UIKit

/// Double tap a control to return it to its default — the convention in every DAW and
/// most plugins, and the only quick way back to a known value once a slider has been
/// dragged somewhere arbitrary.
///
/// This is UIKit rather than a SwiftUI gesture because SwiftUI has no way to express it
/// on a `Slider`. `onTapGesture`, `gesture` and `simultaneousGesture` all lose the touch
/// to the slider's own tracking, and a `DragGesture(minimumDistance: 0)` — the usual way
/// around that — never reports its end on a slider either. Both were tried and neither
/// fired once.
///
/// UIKit can watch a touch without competing for it, which is the whole trick. The
/// recognizer goes on the *window* rather than on the probe or its superview: a
/// recognizer only sees touches that hit-test into its own view or a descendant, and
/// SwiftUI puts a `background` in a container that is not an ancestor of the slider, so
/// anything closer than the window would simply never be told. The probe itself is only
/// there to measure where this particular slider is.
private final class DoubleTapProbe: UIView, UIGestureRecognizerDelegate {
    var reset: () -> Void = {}

    /// Slower than the system double-tap interval on purpose: this is a deliberate
    /// gesture on a small control, often with a fingertip already resting on it. The
    /// pair is counted here rather than by `numberOfTapsRequired = 2` so that the
    /// interval is ours to choose.
    private static let interval: TimeInterval = 0.45

    private var recognizer: UITapGestureRecognizer?
    private var lastTap: Date?

    /// The probe exists to be measured, never to be touched: returning nil means it is
    /// invisible to hit-testing and so cannot come between a finger and the slider.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }
        guard let window else { return }

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        // The slider must keep receiving its touches untouched; this only observes.
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        window.addGestureRecognizer(tap)
        recognizer = tap
    }

    @objc private func handleTap(_ sender: UITapGestureRecognizer) {
        guard let window else { return }
        // The recognizer sees every tap in the window, so most of them are not ours.
        // A tap elsewhere also breaks a pair in progress — two taps either side of a
        // detour are not a double tap.
        guard convert(bounds, to: window).contains(sender.location(in: window)) else {
            lastTap = nil
            return
        }
        let now = Date()
        if let last = lastTap, now.timeIntervalSince(last) < Self.interval {
            lastTap = nil
            // After the slider, not before it: the slider commits its own value on
            // touch-up too, and whichever runs last wins. Resetting inline lost every
            // time — the fader snapped back to where the finger had left it.
            DispatchQueue.main.async { [reset] in reset() }
        } else {
            lastTap = now
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

private struct DoubleTapProbeView: UIViewRepresentable {
    let reset: () -> Void

    func makeUIView(context: Context) -> DoubleTapProbe {
        let probe = DoubleTapProbe()
        probe.reset = reset
        probe.backgroundColor = .clear
        probe.isUserInteractionEnabled = false
        return probe
    }

    func updateUIView(_ probe: DoubleTapProbe, context: Context) {
        // Refreshed every update: the closure captures the value being reset.
        probe.reset = reset
    }

    static func dismantleUIView(_ probe: DoubleTapProbe, coordinator: Coordinator) {
        probe.removeFromSuperview()   // takes the window recognizer with it
    }
}

extension View {
    /// See `DoubleTapProbe` for why this is not a `TapGesture`.
    ///
    /// A modifier rather than the gesture written out at each call site, so a slider
    /// added later cannot quietly omit it — which is how eight of the thirteen ended up
    /// without one.
    func resetsOnDoubleTap(_ reset: @escaping () -> Void) -> some View {
        background(DoubleTapProbeView(reset: reset))
    }
}
