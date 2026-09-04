import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var completed: Bool
    @State private var page = 0

    private let pages: [(icon: String, title: String, body: String)] = [
        ("point.3.filled.connected.trianglepath.dotted",
         "Notes become movement",
         "Choose a small pool of notes. Fwd, Back, Repeat, Random, Hold, and Rest decide how each track travels through it."),
        ("square.stack.3d.up",
         "Sections become a song",
         "Each section keeps its own notes and steps while the instrument and mixer stay consistent across the arrangement."),
        ("dial.medium",
         "Shape it without losing it",
         "Probability and Divide add movement without changing the sequence. Snapshots save a section's notes so you can experiment and restore them at any time."),
        ("puzzlepiece.extension.fill",
         "Play first, finish anywhere",
         "Templates work immediately with built-in sound. Add AUv3 instruments, record the mix, or export deterministic MIDI when you are ready.")
    ]

    var body: some View {
        VStack(spacing: 24) {
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
                Button("Skip") { finish() }
                    .buttonStyle(.bordered)
                Spacer()
                Text("\(page + 1) of \(pages.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(page == pages.count - 1 ? "Choose a Template" : "Next") {
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

    private func finish() {
        completed = true
        dismiss()
    }
}
