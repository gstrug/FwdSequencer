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
    // Menus get a help screen of their own (`.helpMenu`, below). These are a safety net
    // for any menu that still opens in help mode, such as a collapsed track's long
    // press: choosing an item then shows its help rather than doing it.

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

// MARK: - Menu help screens
//
// In help mode a menu button does not open its menu. It is outlined like any other
// control, and a tap opens a help screen that lists the menu's items — same icons,
// same order — each with its own help, so the whole menu can be read at once.

/// One menu, as its help screen shows it.
struct HelpMenuPage: Identifiable {
    struct Item: Identifiable {
        let icon: String
        let label: String
        let topic: HelpTopic
        var id: String { label }
    }
    struct ItemGroup: Identifiable {
        /// A submenu's name, or nil for items at the top level.
        let heading: String?
        let items: [Item]
        var id: String { heading ?? items.first?.label ?? "" }
    }

    let title: String
    /// A line about the menu as a whole, shown at the top.
    let intro: HelpTopic?
    let groups: [ItemGroup]
    var id: String { title }

    static let section = HelpMenuPage(title: "Section Menu", intro: .sectionMenu, groups: [
        ItemGroup(heading: nil, items: [
            Item(icon: "hand.tap", label: "Pattern Trigger Mode", topic: .triggerMode),
            Item(icon: "hand.point.up.left", label: "Trigger Holds to Play", topic: .triggerHold),
        ]),
        ItemGroup(heading: "The selected section", items: [
            Item(icon: "pencil", label: "Rename…", topic: .sectionRename),
            Item(icon: "plus", label: "Add Section", topic: .sectionAdd),
            Item(icon: "plus.square.on.square", label: "Duplicate", topic: .sectionDuplicate),
            Item(icon: "arrow.left.arrow.right", label: "Move Earlier / Move Later", topic: .sectionMove),
            Item(icon: "trash", label: "Delete", topic: .sectionDelete),
        ]),
    ])

    static let track = HelpMenuPage(title: "Track Menu", intro: .trackMenu, groups: [
        ItemGroup(heading: nil, items: [
            Item(icon: "chevron.up.chevron.down", label: "Move Up / Move Down", topic: .trackMove),
            Item(icon: "plus.square.on.square", label: "Duplicate Track", topic: .trackDuplicate),
        ]),
        ItemGroup(heading: "Feel", items: [
            Item(icon: "hand.draw", label: "Chord Roll", topic: .feelChordRoll),
            Item(icon: "waveform.path.ecg", label: "Accent", topic: .feelAccent),
            Item(icon: "dice", label: "Variation", topic: .feelVariation),
            Item(icon: "metronome", label: "Swing", topic: .feelSwing),
            Item(icon: "waveform.path", label: "Timing", topic: .feelTiming),
        ]),
        ItemGroup(heading: nil, items: [
            Item(icon: "fx", label: "Effects", topic: .trackEffectsMenu),
            Item(icon: "trash", label: "Delete Track", topic: .trackDelete),
        ]),
    ])

    static let settings = HelpMenuPage(title: "Settings", intro: .settingsMenu, groups: [
        ItemGroup(heading: "MIDI", items: [
            Item(icon: "dot.radiowaves.left.and.right", label: "MIDI Learn", topic: .midiLearn),
            Item(icon: "music.note.list", label: "Write Notes from Keys", topic: .midiWriteNotes),
            Item(icon: "slider.horizontal.3", label: "Controllers & Templates…", topic: .midiControllersPage),
            Item(icon: "metronome", label: "MIDI Clock Output", topic: .midiClock),
        ]),
    ])
}

/// The help screen for one menu.
struct HelpMenuSheet: View {
    let page: HelpMenuPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let intro = page.intro {
                    Section {
                        Text(intro.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(page.groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.icon)
                                    .font(.body)
                                    .foregroundStyle(.cyan)
                                    .frame(width: 26)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.label).font(.body.bold())
                                    Text(item.topic.text)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        if let heading = group.heading { Text(heading) }
                    }
                }
            }
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct HelpMenuModifier: ViewModifier {
    let page: HelpMenuPage
    let instance: String
    @ObservedObject private var help = HelpCenter.shared
    @State private var showing = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if help.isOn {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.cyan.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.cyan.opacity(0.7),
                                              style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        )
                        .padding(-3)
                        .contentShape(Rectangle())
                        .onTapGesture { showing = true }
                        .accessibilityElement()
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Help: \(page.title)")
                }
            }
            .sheet(isPresented: $showing) { HelpMenuSheet(page: page) }
    }
}

extension View {
    /// For a menu button: outlined in help mode, and a tap opens a help screen listing
    /// the menu's items with their help, instead of the menu.
    func helpMenu(_ page: HelpMenuPage, instance: String = "") -> some View {
        modifier(HelpMenuModifier(page: page, instance: instance))
    }

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

    /// An inset, not an overlay: the card takes its own room at the bottom, so lists
    /// and scrolling screens can still bring their last item into view above it. Laid
    /// over the content, it hid whatever was underneath (the last step type, Pause).
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
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
                    Text("Tap anything with an outline to see what it does.")
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
