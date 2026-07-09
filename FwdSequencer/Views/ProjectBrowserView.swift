import SwiftUI

struct ProjectBrowserView: View {
    @EnvironmentObject var store: ProjectStore
    @State private var projects: [Project] = []
    @State private var showingProject = false
    @State private var renameTarget: Project? = nil
    @State private var renameText = ""
    @State private var deleteTarget: Project? = nil

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("No Projects Yet")
                            .font(.title2.bold())
                        Text("Tap New Project to get started")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(projects) { project in
                            ProjectRow(project: project)
                                .contentShape(Rectangle())
                                .onTapGesture { open(project) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        deleteTarget = project
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        renameTarget = project
                                        renameText = project.name
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                }
            }
            .navigationTitle("FWD Sequencer")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createAndOpen()
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
            }
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            store.saveNow()
        }
        .fullScreenCover(isPresented: $showingProject, onDismiss: {
            store.saveNow()   // flush any pending debounced save before reloading the list
            reload()
        }) {
            ProjectView()
                .environmentObject(store)
        }
        // Rename alert
        .alert("Rename Project", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Project name", text: $renameText)
            Button("Rename") {
                if var p = renameTarget, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    p.name = renameText.trimmingCharacters(in: .whitespaces)
                    if let data = try? JSONEncoder().encode(p) {
                        try? data.write(to: projectFileURL(p), options: .atomic)
                    }
                    // If this is the currently open project, update the store too
                    if store.project.id == p.id { store.project.name = p.name }
                    reload()
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        // Delete confirmation
        .alert("Delete Project?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let p = deleteTarget { ProjectStore.delete(project: p) }
                deleteTarget = nil
                reload()
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("\"\(deleteTarget?.name ?? "")\" will be permanently deleted.")
        }
    }

    // MARK: - Actions

    private func reload() {
        projects = ProjectStore.allSavedProjects()
    }

    private func open(_ project: Project) {
        store.load(project: project)
        showingProject = true
    }

    private func createAndOpen() {
        let p = Project()
        store.load(project: p)
        store.saveNow()
        showingProject = true
    }

    private func projectFileURL(_ project: Project) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent("\(project.id.uuidString).fwdproj")
    }
}

// MARK: - Project Row

struct ProjectRow: View {
    let project: Project

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.headline)
                HStack(spacing: 12) {
                    Label("\(project.tracks.count) track\(project.tracks.count == 1 ? "" : "s")",
                          systemImage: "slider.horizontal.3")
                    Label("\(Int(project.tempo)) BPM", systemImage: "metronome")
                    Label("\(project.timeSignature.numerator)/\(project.timeSignature.denominator)",
                          systemImage: "music.note")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
