import UIKit
import Darwin

/// CI-only probe (never on main): opens a song, then presses a control through
/// accessibility (the route VoiceOver uses), logging each step.
enum FWDProbe {
    static var step: String? { ProcessInfo.processInfo.environment["FWD_PROBE"] }
    static func start() {
        guard let step else { return }
        NSLog("[PROBE] start step=%@", step)
        if let h = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
           let f = dlsym(h, "_AXSSetAutomationEnabled") {
            typealias Fn = @convention(c) (Int32) -> Void
            unsafeBitCast(f, to: Fn.self)(1)
            NSLog("[PROBE] AX automation on")
        } else { NSLog("[PROBE] AX automation unavailable") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { e in
                    NSLog("[PROBE] rotate failed: %@", e.localizedDescription)
                }
            }
            NSLog("[PROBE] asked for landscape")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { act(step) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { if step.hasPrefix("ax2:") { act(step) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) { NSLog("[PROBE] alive after step=%@", step) }
    }

    static func elements(_ root: NSObject, depth: Int = 0, into out: inout [NSObject]) {
        guard depth < 60 else { return }
        if root.isAccessibilityElement { out.append(root) }
        if let els = root.accessibilityElements as? [NSObject] {
            for e in els { elements(e, depth: depth + 1, into: &out) }
        } else {
            let n = root.accessibilityElementCount()
            if n != NSNotFound && n > 0 {
                for i in 0..<n { if let e = root.accessibilityElement(at: i) as? NSObject { elements(e, depth: depth + 1, into: &out) } }
            }
        }
        if let v = root as? UIView { for s in v.subviews { elements(s, depth: depth + 1, into: &out) } }
    }

    static func act(_ step: String) {
        NSLog("[PROBE] acting %@", step)
        if step.hasPrefix("ax:") || step.hasPrefix("ax2:") {
            let label = String(step.split(separator: ":", maxSplits: 1)[1])
            let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            var all: [NSObject] = []
            for w in windows { elements(w, into: &all) }
            let labels = all.compactMap { $0.accessibilityLabel }
            NSLog("[PROBE] %d elements: %@", all.count, labels.joined(separator: " | "))
            if let target = all.first(where: { ($0.accessibilityLabel ?? "").hasPrefix(label) }) {
                let ok = target.accessibilityActivate()
                NSLog("[PROBE] activated '%@' -> %d", target.accessibilityLabel ?? "", ok ? 1 : 0)
            } else { NSLog("[PROBE] no element '%@'", label) }
            return
        }
        guard let store = MIDIControlCenter.shared.songStore else { NSLog("[PROBE] no song store"); return }
        switch step {
        case "learn": MIDIControlCenter.shared.learn.isOn = true
        default: break
        }
        NSLog("[PROBE] did %@", step)
    }
}
