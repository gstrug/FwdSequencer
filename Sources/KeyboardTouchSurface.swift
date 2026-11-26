import SwiftUI
import UIKit

/// Where each key of a playable keyboard sits, so a touch point can be turned into a
/// note. Black keys are checked first because they sit on top of the white ones.
struct KeyboardLayout {
    let whiteKeys: [Int]
    let whiteWidth: CGFloat
    /// Each black key's note and the x of its left edge.
    let blackKeys: [(midi: Int, x: CGFloat)]
    let blackWidth: CGFloat
    let blackHeight: CGFloat

    func key(at point: CGPoint) -> Int? {
        if point.y >= 0, point.y < blackHeight,
           let black = blackKeys.first(where: { point.x >= $0.x && point.x < $0.x + blackWidth }) {
            return black.midi
        }
        guard point.x >= 0, whiteWidth > 0 else { return nil }
        let index = Int(point.x / whiteWidth)
        return whiteKeys.indices.contains(index) ? whiteKeys[index] : nil
    }
}

/// One touch surface laid over a whole keyboard, following every finger on it.
///
/// Replaces a gesture per key, which had two problems. A key only heard its own touch
/// begin and end, so sliding a finger across the keys played nothing new until it was
/// lifted. And a SwiftUI drag gesture that is taken away mid-touch — by the keyboard's
/// scroll view starting to scroll, a sheet appearing, the system claiming the touch —
/// ends WITHOUT calling `onEnded`, so the key never heard the finger lift and its note
/// hung.
///
/// UIKit reports every touch's whole life, including `touchesCancelled` for exactly
/// those interruptions. Each finger is tracked by its own touch: when it moves onto a
/// different key the old note is released and the new one played (a glissando), and
/// when it lifts or is cancelled its note is always released. Two fingers on the same
/// key are counted, so lifting one does not silence the other. Anything still held
/// when the surface leaves the screen is released too.
struct KeyboardTouchSurface: UIViewRepresentable {
    let keyAt: (CGPoint) -> Int?
    let onPress: (Int) -> Void
    let onRelease: (Int) -> Void

    func makeUIView(context: Context) -> TouchSurfaceView {
        let view = TouchSurfaceView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isExclusiveTouch = false
        update(view)
        return view
    }

    func updateUIView(_ view: TouchSurfaceView, context: Context) {
        // Refreshed every update: the layout (and so the hit-testing) can change with
        // the keyboard's size.
        update(view)
    }

    static func dismantleUIView(_ view: TouchSurfaceView, coordinator: ()) {
        view.releaseAll()
    }

    private func update(_ view: TouchSurfaceView) {
        view.keyAt = keyAt
        view.onPress = onPress
        view.onRelease = onRelease
    }
}

final class TouchSurfaceView: UIView {
    var keyAt: (CGPoint) -> Int? = { _ in nil }
    var onPress: (Int) -> Void = { _ in }
    var onRelease: (Int) -> Void = { _ in }

    /// The note each finger is currently holding.
    private var noteForTouch: [ObjectIdentifier: Int] = [:]
    /// How many fingers hold each note, so a note sounds once however many press it.
    private var holdCount: [Int: Int] = [:]

    private func hold(_ note: Int) {
        holdCount[note, default: 0] += 1
        if holdCount[note] == 1 { onPress(note) }
    }

    private func letGo(_ note: Int) {
        guard let count = holdCount[note] else { return }
        if count <= 1 {
            holdCount.removeValue(forKey: note)
            onRelease(note)
        } else {
            holdCount[note] = count - 1
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let note = keyAt(touch.location(in: self)) else { continue }
            noteForTouch[ObjectIdentifier(touch)] = note
            hold(note)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            let now = keyAt(touch.location(in: self))
            let before = noteForTouch[id]
            guard now != before else { continue }
            // Slid onto another key: play the new one before releasing the old, so a
            // legato instrument glides rather than re-attacking from silence.
            if let now { hold(now); noteForTouch[id] = now } else { noteForTouch.removeValue(forKey: id) }
            if let before { letGo(before) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // The case that used to hang notes: the touch was taken away, not lifted.
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            if let note = noteForTouch.removeValue(forKey: ObjectIdentifier(touch)) {
                letGo(note)
            }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil { releaseAll() }
    }

    /// Release everything held — the keyboard is going away mid-touch.
    func releaseAll() {
        for note in holdCount.keys { onRelease(note) }
        holdCount.removeAll()
        noteForTouch.removeAll()
    }
}
