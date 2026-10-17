import SwiftUI

/// MIDI settings: which controllers are connected and which template each uses, the
/// templates themselves (save as, rename, delete, see their links), and MIDI clock.
struct MIDISettingsView: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var center = MIDIControlCenter.shared
    @ObservedObject private var learn = MIDIControlCenter.shared.learn
    @Environment(\.dismiss) private var dismiss

    /// The template being renamed, and the name being typed.
    @State private var renaming: MIDIControllerTemplate?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                controllersSection
                templatesSection
                Section {
                    Toggle(isOn: $learn.writeNotesEnabled) {
                        Label("Write Notes from Keys", systemImage: "music.note.list")
                    }
                    .helpTag(.midiWriteNotes)
                } header: {
                    Text("Write Notes")
                } footer: {
                    Text("Adds a W button to every track. Tap W on a track to arm it — one track at a time: keys on any controller then play that track and add or remove notes in the section you are on, as tapping its keyboard does. A new track is armed as soon as you add it. Keys linked with Learn keep doing what they are linked to.")
                }
                Section {
                    Toggle(isOn: $songStore.midiClockEnabled) {
                        Label("MIDI Clock Output", systemImage: "cable.connector")
                    }
                    .helpTag(.midiClock)
                } header: {
                    Text("Clock")
                } footer: {
                    Text("Sends tempo and start/stop to other apps and hardware.")
                }
            }
            .navigationTitle("MIDI")
            .navigationBarTitleDisplayMode(.inline)
            .helpHost()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        // Learn happens on the song screen, so close this to get there.
                        center.learn.isOn = true
                        dismiss()
                    } label: {
                        Label("Learn", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .helpTag(.midiLearn)
                }
                ToolbarItem(placement: .navigationBarLeading) { HelpButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Template Name", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let t = renaming { center.rename(t.id, to: newName) }
                    renaming = nil
                }
            }
        }
    }

    // MARK: Controllers

    private var controllersSection: some View {
        Section {
            if center.sources.isEmpty {
                Text("No MIDI controllers connected. Plug one in over USB, or pair a Bluetooth MIDI device, and it appears here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(center.sources) { source in
                controllerRow(source)
            }
        } header: {
            Text("Controllers")
        } footer: {
            Text("Each controller uses one template. Load switches it to another; Save As keeps its current links under a new name. Links you make with MIDI Learn are saved into the template straight away. The nanoKONTROL2 is set up automatically. Keys play sends a keyboard's notes to the Play keyboard's instrument or a track's; keys linked with Learn keep doing what they are linked to. Tracks are chosen by position, so Track 1 is the top track in every song.")
        }
    }

    private func controllerRow(_ source: MIDIInputManager.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    ActivityLight(lastActivity: center.lastActivity[source.name])
                    Text(source.name).font(.body.bold()).lineLimit(1)
                }
                .helpTag(.midiController, instance: source.name)
                Spacer()
                Toggle("Use", isOn: Binding(
                    get: { center.isEnabled(source.name) },
                    set: { center.setDevice(source.name, enabled: $0) }
                ))
                .labelsHidden()
                .helpTag(.midiUse, instance: source.name)
            }
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text("Template").foregroundStyle(.secondary)
                    Text(center.template(forDevice: source.name)?.name ?? "None")
                        .bold().lineLimit(1)
                }
                .helpTag(.midiTemplate, instance: source.name)
                Spacer(minLength: 8)
                Menu {
                    loadChoices(forDevice: source.name)
                } label: {
                    Label("Load", systemImage: "folder")
                }
                .helpTag(.midiLoad, instance: source.name)
                Button { saveAs(forDevice: source.name) } label: {
                    Label("Save As…", systemImage: "square.and.arrow.down")
                }
                .helpTag(.midiSaveAs, instance: source.name)
            }
            // Bordered so each button takes its own taps; in a Form row plain buttons
            // would all fire together.
            .buttonStyle(.bordered)
            .disabled(!center.isEnabled(source.name))

            Picker(selection: Binding(
                get: { center.keysDestination(forDevice: source.name) },
                set: { center.setKeysDestination($0, forDevice: source.name) }
            )) {
                ForEach(keyChoices(forDevice: source.name), id: \.self) { choice in
                    Text(keyChoiceName(choice)).tag(choice)
                }
            } label: {
                Label("Keys play", systemImage: "pianokeys")
            }
            .pickerStyle(.menu)
            .disabled(!center.isEnabled(source.name))
            .helpTag(.midiKeysPlay, instance: source.name)
        }
        .padding(.vertical, 2)
    }

    /// Off, the Play keyboard, and every track in the open song — plus the device's
    /// current choice, if it points past the last track of this song.
    private func keyChoices(forDevice name: String) -> [MIDIKeysDestination] {
        var choices: [MIDIKeysDestination] = [.off, .playKeyboard]
        choices += songStore.song.tracks.indices.map { .track($0) }
        let current = center.keysDestination(forDevice: name)
        if !choices.contains(current) { choices.append(current) }
        return choices
    }

    /// "Track 2 · Bass" when the open song has that track.
    private func keyChoiceName(_ choice: MIDIKeysDestination) -> String {
        if case .track(let i) = choice, songStore.song.tracks.indices.contains(i) {
            return "\(choice.displayName) · \(songStore.song.tracks[i].name)"
        }
        return choice.displayName
    }

    /// Templates to load onto a controller, the current one ticked.
    @ViewBuilder
    private func loadChoices(forDevice name: String) -> some View {
        let current = center.template(forDevice: name)?.id
        Button { center.assign(nil, toDevice: name) } label: {
            if current == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
        }
        Divider()
        ForEach(center.templates) { t in
            Button { center.assign(t.id, toDevice: name) } label: {
                if current == t.id { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
            }
        }
    }

    /// Keep a controller's current links under a new name and switch it to that copy,
    /// so further Learn changes go into the new template and the old one stays as it was.
    private func saveAs(forDevice name: String) {
        let copy: MIDIControllerTemplate
        if let current = center.template(forDevice: name),
           let duplicate = center.duplicate(current.id) {
            copy = duplicate
        } else {
            copy = center.newTemplate(named: name, deviceNameHint: name)
        }
        center.assign(copy.id, toDevice: name)
        newName = copy.name
        renaming = copy
    }

    // MARK: Templates

    private var templatesSection: some View {
        Section {
            ForEach(center.templates) { template in
                NavigationLink {
                    MIDITemplateDetailView(templateID: template.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        // A factory template's name already says so.
                        Text(template.name)
                        Text(usage(of: template))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu { actions(for: template) }
                .helpTag(.midiTemplates, instance: template.id.uuidString)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !template.isBuiltIn {
                        Button(role: .destructive) { center.delete(template.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    Button { saveAs(template) } label: {
                        Label("Save As", systemImage: "plus.square.on.square")
                    }
                    .tint(.blue)
                }
            }
        } header: {
            Text("Templates")
        } footer: {
            Text("Learning on a factory template makes your own copy first, so the factory one stays as it was. Tap a template to see its links; swipe or long press it to save a copy, rename or delete it.")
        }
    }

    @ViewBuilder
    private func actions(for template: MIDIControllerTemplate) -> some View {
        Button { saveAs(template) } label: {
            Label("Save As…", systemImage: "plus.square.on.square")
        }
        if !template.isBuiltIn {
            Button {
                newName = template.name
                renaming = template
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button(role: .destructive) { center.delete(template.id) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Copy, then straight into naming the copy.
    private func saveAs(_ template: MIDIControllerTemplate) {
        guard let copy = center.duplicate(template.id) else { return }
        newName = copy.name
        renaming = copy
    }

    private func usage(of template: MIDIControllerTemplate) -> String {
        let links = "\(template.mappings.count) link\(template.mappings.count == 1 ? "" : "s")"
        let users = center.sources.filter { center.template(forDevice: $0.name)?.id == template.id }
        guard !users.isEmpty else { return links }
        return links + " · used by " + users.map(\.name).joined(separator: ", ")
    }
}

/// One template's links, listed. A user template's links can be removed here.
private struct MIDITemplateDetailView: View {
    let templateID: UUID
    @ObservedObject private var center = MIDIControlCenter.shared

    private var template: MIDIControllerTemplate? {
        center.templates.first { $0.id == templateID }
    }

    var body: some View {
        List {
            if let template {
                if template.mappings.isEmpty {
                    Text("No links yet. Turn on Learn, tap a control, then move or press the one on your controller.")
                        .foregroundStyle(.secondary)
                }
                ForEach(template.mappings) { mapping in
                    HStack {
                        Text(mapping.target.displayName)
                        Spacer()
                        Text(mapping.source.displayName)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if !template.isBuiltIn {
                            Button(role: .destructive) {
                                center.removeLink(mapping.target, fromTemplate: template.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(template?.name ?? "Template")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Lit briefly whenever a controller sends something, so you can see it is connected
/// and which one a knob belongs to.
private struct ActivityLight: View {
    let lastActivity: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let lit = lastActivity.map { context.date.timeIntervalSince($0) < 0.25 } ?? false
            Circle()
                .fill(lit ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 10, height: 10)
                .shadow(color: lit ? .green : .clear, radius: 3)
        }
        .accessibilityHidden(true)
    }
}
