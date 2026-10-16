import SwiftUI

/// MIDI settings: which controllers are connected and which template each uses, the
/// templates themselves (save as, rename, delete, see their links), and MIDI clock.
struct MIDISettingsView: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var center = MIDIControlCenter.shared
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
                    Toggle(isOn: $songStore.midiClockEnabled) {
                        Label("MIDI Clock Output", systemImage: "cable.connector")
                    }
                } header: {
                    Text("Clock")
                } footer: {
                    Text("Sends tempo and start/stop to other apps and hardware.")
                }
            }
            .navigationTitle("MIDI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        // Learn happens on the song screen, so close this to get there.
                        center.learn.isOn = true
                        dismiss()
                    } label: {
                        Label("Learn", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Rename Template", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
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
            Text("Each controller uses one template. The nanoKONTROL2 is set up automatically; for any other controller, turn on Learn and link the controls you want. Tracks are linked by position, so Track 1 is the top track in every song.")
        }
    }

    private func controllerRow(_ source: MIDIInputManager.Source) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ActivityLight(lastActivity: center.lastActivity[source.name])
                Text(source.name).font(.body.bold()).lineLimit(1)
                Spacer()
                Toggle("Use", isOn: Binding(
                    get: { center.isEnabled(source.name) },
                    set: { center.setDevice(source.name, enabled: $0) }
                ))
                .labelsHidden()
            }
            Picker("Template", selection: Binding<UUID?>(
                get: { center.template(forDevice: source.name)?.id },
                set: { center.assign($0, toDevice: source.name) }
            )) {
                Text("None").tag(UUID?.none)
                ForEach(center.templates) { t in
                    Text(t.name).tag(UUID?.some(t.id))
                }
            }
            .disabled(!center.isEnabled(source.name))
        }
        .padding(.vertical, 2)
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
            Text("Learning on a factory template makes your own copy first, so the factory one stays as it was. Swipe or long press a template to save a copy, rename or delete it.")
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
