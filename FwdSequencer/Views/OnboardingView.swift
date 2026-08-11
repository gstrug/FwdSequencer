import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var completed: Bool
    @State private var page = 0

    private let pages: [(icon: String, title: String, body: String)] = [
        ("point.3.filled.connected.trianglepath.dotted",
         "Notes become movement",
         "Choose a small pool of notes. Fwd, Back, Repeat, Random, Hold, and Rest decide how each track travels through it."),
        ("square.stack.3d.up",
         "Sections become a song",
         "Each section keeps its own notes and steps while the instrument and mixer stay consistent across the arrangement."),
        ("puzzlepiece.extension.fill",
         "Start simple, then add sounds",
         "Every template works immediately with the built-in GM sound. Choose an AUv3 instrument whenever you are ready.")
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
