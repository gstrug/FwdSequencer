import SwiftUI

/// The tutorial, shown on first launch and from Settings ▸ Show Tutorial.
///
/// A few pages that get you going and show you where help lives, nothing more. It used
/// to explain the ideas behind the app at length; testers found that too wordy and not
/// specific enough. What each control does is now answered on the screen itself by help
/// mode (the ? button, HelpMode.swift), so this only has to point there.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var completed: Bool
    /// First run ends by sending you to pick a template; opened from the menu it just
    /// closes, since there is already a song in front of you.
    var isFirstRun: Bool = true
    @State private var page = 0

    private let pages: [(icon: String, title: String, body: String)] = [
        ("music.note.list",
         "Welcome to FWD",
         "Each track plays from a small pool of notes you pick on its keyboard. Steps "
         + "decide which note comes next. Sections are the parts of your song."),

        ("questionmark.circle",
         "Help is on every screen",
         "Tap the ? button at the top of any screen. Every control gets an outline."),

        ("hand.tap",
         "Tap anything to see what it does",
         "With help on, tap an outlined control and a card at the bottom explains it. "
         + "Nothing you tap does anything while help is on, so you can't change your song "
         + "by accident."),

        ("checkmark.circle",
         "Done when you are",
         "Tap Done on the card, or the ? again, and the controls work normally. You can "
         + "see this guide again from Settings ▸ Show Tutorial.")
    ]

    var body: some View {
        VStack(spacing: 24) {
            // Leave at any point, from any page.
            HStack {
                Spacer()
                Button("Exit") { finish() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Closes the tutorial")
            }
            Spacer()
            Image(systemName: pages[page].icon)
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(pages[page].title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(pages[page].body)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            Spacer()
            HStack {
                // Back only: Exit, at the top, leaves from any page.
                Button("Back") {
                    if reduceMotion { page -= 1 }
                    else { withAnimation { page -= 1 } }
                }
                .buttonStyle(.bordered)
                .opacity(page == 0 ? 0 : 1)
                .disabled(page == 0)
                Spacer()
                Text("\(page + 1) of \(pages.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(nextTitle) {
                    if page == pages.count - 1 { finish() }
                    else if reduceMotion { page += 1 }
                    else { withAnimation { page += 1 } }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .interactiveDismissDisabled()
    }

    private var nextTitle: String {
        guard page == pages.count - 1 else { return "Next" }
        return isFirstRun ? "Choose a Template" : "Done"
    }

    private func finish() {
        completed = true
        dismiss()
    }
}
