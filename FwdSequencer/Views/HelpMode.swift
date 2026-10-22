import SwiftUI
import Combine

// MARK: - Help mode
//
// Tap the ? on any screen and help mode comes on: every control that has help is
// outlined, and tapping one shows what it does in a card at the bottom of the screen.
// While help is on, taps only explain — nothing is pressed, started or deleted by
// accident — until Done.
//
// It works like MIDI Learn (MIDILearnable.swift): an overlay on each control takes its
// taps while the mode is on. The words themselves are all in HelpTopics.swift, so they
// can be read and corrected in one place.

/// Help mode's state, shared by every screen: the ? on a sheet turns on the same mode
/// as the one on the song screen.
@MainActor
final class HelpCenter: ObservableObject {
    static let shared = HelpCenter()

    @Published var isOn = false {
        didSet {
            if !isOn { selection = nil }
            // One mode that takes over taps at a time.
            if isOn { MIDIControlCenter.shared.learn.isOn = false }
        }
    }

    /// The control whose help is showing: its topic, and which one it is when the same
    /// control appears more than once (every track has a volume fader).
    @Published var selection: Selection?

    struct Selection: Equatable {
        let topic: HelpTopic
        let instance: String
    }

    private init() {}

    // MARK: Menus
    //
    // The items in an open menu are drawn by the system, so help outlines cannot reach
    // them. Instead, in help mode a menu still opens, and choosing an item shows its
    // help rather than doing it — the same rule as everywhere else in help mode.

    /// Show `topic`, as if its control had been tapped in help mode.
    func show(_ topic: HelpTopic) {
        selection = Selection(topic: topic, instance: "menu")
    }

    /// For a menu item's action: in help mode, show `topic` instead of acting.
    func perform(_ topic: HelpTopic, _ action: () -> Void) {
        if isOn { show(topic) } else { action() }
    }

    /// For a toggle or picker in a menu: in help mode, choosing shows `topic` and
    /// changes nothing.
    func guarded<Value>(_ topic: HelpTopic, _ binding: Binding<Value>) -> Binding<Value> {
        Binding(get: { binding.wrappedValue },
                set: { newValue in
                    if self.isOn { self.show(topic) } else { binding.wrappedValue = newValue }
                })
    }
}

/// In help mode only: a first item in a menu that explains the menu as a whole.
struct HelpMenuIntro: View {
    let topic: HelpTopic
    @ObservedObject private var help = HelpCenter.shared

    var body: some View {
        if help.isOn {
            Button { help.show(topic) } label: {
                Label("About this menu", systemImage: "questionmark.circle")
            }
            Divider()
        }
    }
}

extension View {
    /// Give this control help: outlined in help mode, and a tap shows `topic`.
    /// `instance` tells apart copies of the same control, such as each track's fader.
    func helpTag(_ topic: HelpTopic, instance: String = "") -> some View {
        modifier(HelpTagModifier(topic: topic, instance: instance))
    }

    /// Put on each screen's outermost view, once: shows the help card and the bar that
    /// says help is on. Sheets are separate screens and need their own.
    func helpHost() -> some View {
        modifier(HelpHostModifier())
    }
}

private struct HelpTagModifier: ViewModifier {
    let topic: HelpTopic
    let instance: String
    @ObservedObject private var help = HelpCenter.shared

    func body(content: Content) -> some View {
        content
            // The same words, read out by VoiceOver.
            .accessibilityHint(Text(topic.text))
            .overlay {
                if help.isOn {
                    let selected = help.selection == HelpCenter.Selection(topic: topic, instance: instance)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.cyan.opacity(selected ? 0.3 : 0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.cyan.opacity(selected ? 1 : 0.7),
                                              style: StrokeStyle(lineWidth: selected ? 2.5 : 1.2,
                                                                 dash: selected ? [] : [4, 3]))
                        )
                        .padding(-3)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            help.selection = selected ? nil
                                : HelpCenter.Selection(topic: topic, instance: instance)
                        }
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Help: \(topic.title)")
                }
            }
    }
}

private struct HelpHostModifier: ViewModifier {
    @ObservedObject private var help = HelpCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if help.isOn { HelpCard() }
        }
    }
}

/// The card at the bottom of the screen: the chosen control's help, or what to do.
private struct HelpCard: View {
    @ObservedObject private var help = HelpCenter.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "questionmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 4) {
                if let topic = help.selection?.topic {
                    Text(topic.title).font(.headline)
                    Text(topic.text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Help is on").font(.headline)
                    Text("Tap anything outlined to see what it does. Nothing you tap does anything until you tap Done.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done") { help.isOn = false }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
        }
        .padding(16)
        .frame(maxWidth: 720)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.cyan.opacity(0.5)))
        .shadow(radius: 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// A toolbar item that explains itself in help mode.
///
/// The system draws toolbar items in its own bar, which does not let an overlay take
/// their taps: with help on, a tagged ＋ or ⋯ in the toolbar still opened its menu. So
/// in help mode the item is swapped for a plain button showing its help, drawn the
/// same but with the help outline.
struct HelpToolbarItem<Content: View>: View {
    let topic: HelpTopic
    @ViewBuilder var content: Content
    @ObservedObject private var help = HelpCenter.shared

    var body: some View {
        if help.isOn {
            let selected = help.selection?.topic == topic
            Button {
                help.selection = selected ? nil : HelpCenter.Selection(topic: topic, instance: "toolbar")
            } label: {
                content
                    .allowsHitTesting(false)
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.cyan, style: StrokeStyle(lineWidth: selected ? 2.5 : 1.2,
                                                                         dash: selected ? [] : [4, 3]))
                    )
            }
            .accessibilityLabel("Help: \(topic.title)")
        } else {
            content
        }
    }
}

/// The ? button that turns help mode on and off. One on every screen.
struct HelpButton: View {
    @ObservedObject private var help = HelpCenter.shared

    var body: some View {
        Button { help.isOn.toggle() } label: {
            Image(systemName: help.isOn ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(help.isOn ? Color.cyan : Color.secondary)
        .accessibilityLabel("Help")
        .accessibilityValue(help.isOn ? "On" : "Off")
        .accessibilityHint("Shows what each control on this screen does")
    }
}
