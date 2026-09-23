import SwiftUI

/// The tutorial, shown on first launch and on demand from the song list.
///
/// Kept deliberately short. It explains the ideas the app is built on — a pool of notes
/// traversed by rules, sections over a shared instrument set, Hold as the way to work on
/// one part — rather than listing controls, which go stale the moment anything is
/// renamed. Page three previously described "Transform", a name that had since changed,
/// which is the failure mode this ordering is meant to avoid.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var completed: Bool
    /// First run ends by sending you to pick a template; opened from the menu it just
    /// closes, since there is already a song in front of you.
    var isFirstRun: Bool = true
    @State private var page = 0

    private let pages: [(icon: String, title: String, body: String)] = [
        ("point.3.filled.connected.trianglepath.dotted",
         "Notes become movement",
         "Pick a small pool of notes. Steps decide how a track travels through it — "
         + "Fwd and Back walk, Play jumps to a position, Repeat holds the place, Random "
         + "leaps, Hold sustains and Pause rests. A short pool and a few steps go a "
         + "long way."),

        ("dial.medium",
         "Every step can breathe",
         "Probability lets a step play only sometimes, and Divide splits it into "
         + "repeats. Neither changes the sequence, so a pattern keeps its shape while "
         + "never repeating exactly."),

        ("square.stack.3d.up",
         "Sections become a song",
         "Each section holds its own notes and steps. Instruments and the mixer stay "
         + "constant across the arrangement, so swapping a sound changes the whole song "
         + "and never disturbs the notes."),

        ("repeat.1",
         "Hold is how you work",
         "Hold repeats the selected section so you can hear what you are changing. It is "
         + "required before shaping a section or saving snapshots — there is no point "
         + "judging either without listening."),

        ("wand.and.stars",
         "Shape a section",
         "Shape rotates, reverses or transposes the note pool, and generates whole step "
         + "sequences from a character — Flowing, Sparse or Jumpy. It applies to the "
         + "tracks you tick, so you can rework one and leave the rest. Keep pressing "
         + "Generate until something catches."),

        ("camera",
         "Snapshots are your way back",
         "Holding a section saves a protected Original you can always return to. Save "
         + "your own snapshots as you go — they cover just the ticked tracks, so you can "
         + "keep one part while experimenting on another."),

        ("slider.horizontal.3",
         "Make it sound played",
         "Each track has Feel: roll chords instead of striking them, accent the beat, "
         + "vary velocity and length, and add swing or loose timing. Small amounts go "
         + "a long way toward not sounding like a machine."),

        ("fx",
         "Instruments and effects",
         "Load an AUv3 instrument on any track and up to four effects after it. Watch "
         + "the CPU readout on the transport — hosted plugins are where the processing "
         + "goes, and dropouts start when it runs out."),

        ("square.and.arrow.up",
         "Play first, finish anywhere",
         "Templates work straight away with built-in sound. Record the mix, or export "
         + "MIDI that matches what you heard, note for note.")
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
                Button(page == 0 ? (isFirstRun ? "Skip" : "Close") : "Back") {
                    if page == 0 { finish() }
                    else if reduceMotion { page -= 1 }
                    else { withAnimation { page -= 1 } }
                }
                .buttonStyle(.bordered)
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
