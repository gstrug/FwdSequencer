import SwiftUI

/// New Song ▸ Examples…: the example songs, each saying what it is and which feature
/// it is there to show.
///
/// They used to be a submenu, with each song's description as a second line of the
/// menu item. iOS menus do not draw that second line, so all anyone saw was a list of
/// six names with nothing to choose between them (Graham, 2026-11-10: "at the moment
/// there is just a list of songs"). A sheet has room to say what each one demonstrates,
/// which is the only reason these songs are in the app.
struct ExamplesSheet: View {
    /// Adds a copy of the example and opens it.
    let add: (ExampleSong) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(ExampleSong.allCases) { example in
                Button {
                    dismiss()
                    add(example)
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: example.systemImage)
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 32)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(example.name)
                                .font(.headline)
                            Text(example.summary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(example.demonstrates)
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(example.demonstrates)
            }
            .navigationTitle("Examples")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
