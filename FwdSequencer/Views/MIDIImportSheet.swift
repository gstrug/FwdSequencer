import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import MIDI into the selected section
//
// Section menu ▸ Import MIDI… picks a file; this sheet then matches each part of the
// file to a track (an existing one, a new one, or none) and chooses the step size.
// The conversion itself is MIDIImportConverter (Models/MIDIImport.swift, tested);
// SongStore.importMIDI applies it.

/// A file read and waiting for its choices.
struct MIDIImportRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let file: ImportedMIDIFile
    let sectionID: UUID
}

extension View {
    /// The file picker for Import MIDI, then the sheet for its choices.
    func midiImport(isPresented: Binding<Bool>) -> some View {
        modifier(MIDIImportModifier(isPresented: isPresented))
    }
}

private struct MIDIImportModifier: ViewModifier {
    @EnvironmentObject var songStore: SongStore
    @Binding var isPresented: Bool
    @State private var request: MIDIImportRequest?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isPresented, allowedContentTypes: [.midi]) { result in
                open(result)
            }
            .sheet(item: $request) { request in
                MIDIImportSheet(request: request)
            }
    }

    private func open(_ result: Result<URL, Error>) {
        guard songStore.song.sections.indices.contains(songStore.selectedSection) else { return }
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let file = try MIDIFileReader.read(Data(contentsOf: url))
            request = MIDIImportRequest(fileName: url.deletingPathExtension().lastPathComponent,
                                        file: file,
                                        sectionID: songStore.song.sections[songStore.selectedSection].id)
        } catch {
            songStore.notice = (error as? LocalizedError)?.errorDescription
                ?? "That MIDI file could not be read. \(error.localizedDescription)"
        }
    }
}

private struct MIDIImportSheet: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var help = HelpCenter.shared
    @Environment(\.dismiss) private var dismiss
    let request: MIDIImportRequest

    @State private var targets: [Int: SongStore.MIDIImportTarget] = [:]
    @State private var division: TempoDivision = .sixteenth
    @State private var startAtFirstNote = true
    @State private var fitLength = true
    @State private var useFileTiming = false
    @State private var useFileInstruments = true
    @State private var failure: String?

    private var parts: [ImportedPart] { request.file.parts.filter { !$0.notes.isEmpty } }
    private var section: SongSection? {
        songStore.song.sections.first { $0.id == request.sectionID }
    }
    private var chosen: [ImportedPart] {
        parts.filter { (targets[$0.id] ?? .skip) != .skip }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(parts) { part in
                        Picker(selection: binding(for: part)) {
                            Text("Don't import").tag(SongStore.MIDIImportTarget.skip)
                            Text("New Track").tag(SongStore.MIDIImportTarget.newTrack)
                            ForEach(songStore.song.tracks) { track in
                                Text(track.name).tag(SongStore.MIDIImportTarget.track(track.id))
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.name)
                                Text(partDetail(part))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .helpTag(.midiImportPart, instance: "\(part.id)")
                    }
                } header: {
                    Text("Parts in \(request.fileName)")
                } footer: {
                    Text("Choose a track for each part. An existing track's notes and steps in this section are replaced; they are saved first as the snapshot \"Before MIDI import\".")
                }

                Section {
                    Picker("Step Size", selection: $division) {
                        ForEach(MIDIImportConverter.divisions, id: \.self) { d in
                            Text("\(d.rawValue) (\(d.abbreviation))").tag(d)
                        }
                    }
                    .helpTag(.midiImportStepSize)
                    Toggle("Start at the First Note", isOn: $startAtFirstNote)
                        .helpTag(.midiImportStart)
                    Toggle(isOn: $fitLength) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set Section Length to Fit")
                            Text(lengthDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .helpTag(.midiImportFit)
                    if parts.contains(where: { GeneralMIDI.sound(for: $0) != nil }) {
                        Toggle("Use the File's Instruments", isOn: $useFileInstruments)
                            .helpTag(.midiImportInstruments)
                    }
                    if request.file.hasTiming {
                        Toggle(fileTimingLabel, isOn: $useFileTiming)
                            .helpTag(.midiImportTempo)
                    }
                } header: {
                    Text("Timing")
                } footer: {
                    Text(timingFooter)
                }

                if let summary {
                    Section {
                        Text(summary).font(.callout)
                    }
                }
            }
            .navigationTitle("Import MIDI into \(section?.name ?? "Section")")
            .navigationBarTitleDisplayMode(.inline)
            .helpHost()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) { HelpButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { help.perform(.midiImportButton) { runImport() } }
                        .disabled(!help.isOn && (chosen.isEmpty || section == nil))
                }
            }
            .alert("Can't Import", isPresented: Binding(get: { failure != nil },
                                                         set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
            .onAppear(perform: setUp)
        }
    }

    private func binding(for part: ImportedPart) -> Binding<SongStore.MIDIImportTarget> {
        Binding(get: { targets[part.id] ?? .skip }, set: { targets[part.id] = $0 })
    }

    /// Every part but drums to a track: first to the song's empty tracks, so a blank
    /// song's first track is used rather than left over, then to new ones named after
    /// the part. And the step size that suits the file's rhythm.
    private func setUp() {
        guard targets.isEmpty else { return }
        var empty = emptyTracks
        let room = SongStore.maximumEditableTrackCount - songStore.song.tracks.count
        var used = 0
        for part in parts {
            if part.isDrums {
                targets[part.id] = .skip
            } else if !empty.isEmpty {
                targets[part.id] = .track(empty.removeFirst())
            } else if used < room {
                targets[part.id] = .newTrack
                used += 1
            } else {
                targets[part.id] = .skip
            }
        }
        // A song with no notes yet takes the file's tempo and time signature.
        useFileTiming = songStore.song.sections.allSatisfy { section in
            section.parts.allSatisfy { $0.notePool.isEmpty }
        }
        division = MIDIImportConverter.suggestedDivision(for: parts.flatMap(\.notes),
                                                         ticksPerQuarter: request.file.ticksPerQuarter)
    }

    /// Tracks with nothing in them yet: no plugin, and no notes or steps in any section.
    private var emptyTracks: [UUID] {
        songStore.song.tracks.filter { track in
            track.pluginInfo == nil && songStore.song.sections.allSatisfy { section in
                section.parts.first { $0.trackID == track.id }.map { $0.notePool.isEmpty && $0.steps.isEmpty } ?? true
            }
        }.map(\.id)
    }

    private func partDetail(_ part: ImportedPart) -> String {
        var text = "\(part.notes.count) note\(part.notes.count == 1 ? "" : "s") · \(noteName(part.lowestPitch))–\(noteName(part.highestPitch))"
        if part.isDrums { text += " · drums" }
        return text
    }

    private func noteName(_ midi: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[midi % 12])\(midi / 12 - 1)"
    }

    /// The time signature bars are counted in: the file's when its timing is used.
    private var timeSignature: TimeSignature {
        useFileTiming ? (request.file.usableTimeSignature ?? songStore.song.timeSignature)
                      : songStore.song.timeSignature
    }

    private var fileTimingLabel: String {
        var details: [String] = []
        if let tempo = request.file.usableTempo { details.append("\(Int(tempo)) BPM") }
        if let ts = request.file.usableTimeSignature { details.append("\(ts.numerator)/\(ts.denominator)") }
        return "Use the File's Tempo and Time Signature (\(details.joined(separator: ", ")))"
    }

    private var plan: MIDIImportPlan {
        MIDIImportPlan(file: request.file, parts: chosen.isEmpty ? parts : chosen,
                       timeSignature: timeSignature, division: division,
                       startAtFirstNote: startAtFirstNote, fitLength: fitLength,
                       currentBars: section?.numberOfBars ?? 4)
    }

    private var lengthDetail: String {
        let now = section?.numberOfBars ?? 0
        return fitLength ? "\(plan.bars) bar\(plan.bars == 1 ? "" : "s") (now \(now))"
            : "Keeps \(now) bar\(now == 1 ? "" : "s"); notes after that are left out"
    }

    private var timingFooter: String {
        var text = "Notes are moved to the nearest step. The suggested size fits the file's rhythm; a smaller one keeps more detail but makes more steps."
        if let ts = request.file.usableTimeSignature, ts != timeSignature {
            text += " The file is in \(ts.numerator)/\(ts.denominator); bars are counted in the song's \(timeSignature.numerator)/\(timeSignature.denominator)."
        }
        return text
    }

    /// What each chosen part becomes, or why it can't.
    private var summary: String? {
        guard !chosen.isEmpty else { return nil }
        let plan = self.plan
        return chosen.map { part in
            do {
                let result = try plan.convert(part)
                var line = "\(part.name): \(result.notePool.count) notes, \(result.steps.count) steps"
                if result.notesLeftOut > 0 { line += ", \(result.notesLeftOut) left out" }
                return line
            } catch {
                return "\(part.name): \((error as? LocalizedError)?.errorDescription ?? "can't be imported")"
            }
        }.joined(separator: "\n")
    }

    private func runImport() {
        do {
            try songStore.importMIDI(request.file, intoSection: request.sectionID, targets: targets,
                                     division: division, startAtFirstNote: startAtFirstNote,
                                     fitLength: fitLength, useFileTiming: useFileTiming,
                                     useFileInstruments: useFileInstruments)
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
