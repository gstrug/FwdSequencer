import SwiftUI

struct PluginPickerView: View {
    @Binding var selectedPlugin: PluginInfo?
    /// The General MIDI sound the built-in sampler plays, and what to do when one is
    /// chosen. When given, the Included row opens the list of sounds.
    var builtInSound: Int? = nil
    var onChooseBuiltInSound: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = PluginManager.shared
    @State private var searchText = ""

    private var matches: [PluginInfo] {
        guard !searchText.isEmpty else { return manager.instruments }
        return manager.instruments.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.manufacturerName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var favorites: [PluginInfo] { matches.filter(manager.isFavorite) }
    private var others: [PluginInfo] { matches.filter { !manager.isFavorite($0) } }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Select Instrument")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    if selectedPlugin != nil {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Remove") {
                                selectedPlugin = nil
                                dismiss()
                            }
                            .foregroundStyle(.red)
                        }
                    }
                }
                .onAppear { manager.scan() }
                .searchable(text: $searchText, prompt: "Instrument or manufacturer")
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section("Included") {
                if let onChooseBuiltInSound {
                    NavigationLink {
                        BuiltInSoundList(current: selectedPlugin == nil ? (builtInSound ?? 0) : nil) { sound in
                            onChooseBuiltInSound(sound)
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Label("Built-in GM Sound", systemImage: "pianokeys")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(GeneralMIDI.soundName(builtInSound))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if selectedPlugin == nil {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                } else {
                    Button {
                        selectedPlugin = nil
                        dismiss()
                    } label: {
                        HStack {
                            Label("Built-in GM Sound", systemImage: "pianokeys")
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedPlugin == nil {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }

            if manager.isScanning {
                Section("AUv3 Instruments") {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Scanning for plugins…").foregroundStyle(.secondary)
                    }
                }
            } else if manager.instruments.isEmpty {
                Section("AUv3 Instruments") {
                    Text("No AUv3 instruments are installed. The included sound is ready to play.")
                        .foregroundStyle(.secondary)
                }
            } else {
                if matches.isEmpty {
                    Text("No instruments match \"\(searchText)\".")
                        .foregroundStyle(.secondary)
                }
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites, id: \.componentIdentifier) { plugin in pluginRow(plugin) }
                    }
                }
                Section(favorites.isEmpty ? "Instruments" : "All Instruments") {
                    ForEach(others, id: \.componentIdentifier) { plugin in pluginRow(plugin) }
                }
            }
        }
    }

    private func pluginRow(_ plugin: PluginInfo) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedPlugin = plugin
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(plugin.manufacturerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selectedPlugin == plugin {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { manager.toggleFavorite(plugin) } label: {
                Image(systemName: manager.isFavorite(plugin) ? "star.fill" : "star")
                    .foregroundStyle(manager.isFavorite(plugin) ? .yellow : .secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(manager.isFavorite(plugin) ? "Remove from favorites" : "Add to favorites")
        }
        .contextMenu {
            Button { manager.toggleFavorite(plugin) } label: {
                Label(manager.isFavorite(plugin) ? "Remove Favorite" : "Add Favorite",
                      systemImage: manager.isFavorite(plugin) ? "star.slash" : "star")
            }
        }
    }
}

/// The 128 General MIDI instruments by family, and the drum kit, from the bundled
/// sound bank. Choosing one makes the track play it (switching off a plugin).
private struct BuiltInSoundList: View {
    /// The sound playing now, or nil when the track has a plugin.
    let current: Int?
    let choose: (Int) -> Void

    var body: some View {
        List {
            Section {
                row(GeneralMIDI.drumKit)
            }
            ForEach(Array(GeneralMIDI.families.enumerated()), id: \.offset) { family, name in
                Section(name) {
                    ForEach(family * 8 ..< family * 8 + 8, id: \.self) { program in row(program) }
                }
            }
        }
        .navigationTitle("Built-in GM Sound")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ sound: Int) -> some View {
        Button { choose(sound) } label: {
            HStack {
                Text(GeneralMIDI.soundName(sound)).foregroundStyle(.primary)
                Spacer()
                if current == sound {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
    }
}
