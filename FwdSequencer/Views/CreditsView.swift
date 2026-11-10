import SwiftUI

/// About & Credits, from the song list's ⋯ menu: which version this is, and who made
/// the built-in General MIDI sounds.
///
/// The sound bank (FWD-GM.sf2) is put together from two free banks, and FluidR3's MIT
/// licence asks for its notice to go wherever the bank goes. The licence files were
/// already in the app, where nobody could read them; this shows them. The wording is
/// read from those same files, so there is one copy of each.
struct CreditsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct SoundBank: Identifiable {
        let id: String              // the licence file's name in the app, without ".txt"
        let name: String
        let author: String
        let licenceName: String
        let website: String?
    }

    private static let soundBanks = [
        SoundBank(id: "GeneralUser-GS-LICENSE", name: "GeneralUser GS",
                  author: "S. Christian Collins", licenceName: "GeneralUser GS Licence v2.0",
                  website: "https://www.schristiancollins.com"),
        SoundBank(id: "FluidR3-LICENSE", name: "FluidR3_GM",
                  author: "Frank Wen", licenceName: "MIT Licence", website: nil),
    ]

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let number = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? number : "\(number) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("FWD Sequencer", value: version)
                }

                Section {
                    ForEach(Self.soundBanks) { bank in
                        NavigationLink {
                            LicenceText(title: bank.name, resource: bank.id, website: bank.website)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bank.name)
                                Text("\(bank.author) · \(bank.licenceName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Built-in Sounds")
                } footer: {
                    Text("The built-in General MIDI sounds are taken from these two sound banks, with thanks to their makers.")
                }
            }
            .navigationTitle("About & Credits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// One licence, in full, as its author wrote it.
private struct LicenceText: View {
    let title: String
    let resource: String
    let website: String?

    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "The licence text could not be found in this copy of the app."
        }
        return contents
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let website, let url = URL(string: website) {
                    Link(website, destination: url)
                        .font(.callout)
                }
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
