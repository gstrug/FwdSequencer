import SwiftUI

extension View {
    /// Double tap a control to return it to its default — the convention in every DAW
    /// and most plugins, and the only quick way back to a known value once a slider has
    /// been dragged somewhere arbitrary.
    ///
    /// `simultaneousGesture` rather than `onTapGesture`, which is not a style choice:
    /// `Slider` consumes taps for its own dragging, so a plain tap gesture attached to
    /// one never fires. That cost an afternoon the first time, when double-tap-to-reset
    /// was added to the faders and silently did nothing.
    ///
    /// A modifier rather than the gesture written out at each call site, so a slider
    /// added later cannot quietly omit it — which is how eight of the thirteen ended up
    /// without it.
    func resetsOnDoubleTap(_ reset: @escaping () -> Void) -> some View {
        simultaneousGesture(TapGesture(count: 2).onEnded(reset))
    }
}
