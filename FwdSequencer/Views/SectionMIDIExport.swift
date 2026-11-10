import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export the selected section as MIDI
//
// Section menu ▸ Export MIDI…: the counterpart of Import MIDI. One section, played
// once, as a MIDI file — a loop to take to a DAW, or to import into another section or
// song. The notes come from the song exporter (SongMIDIExporter.data(for:section:)), so
// a section's file is exactly that part of the song's.

extension View {
    /// The choice of file (as played, or on the grid), then the system's location picker.
    func sectionMIDIExport(isPresented: Binding<Bool>) -> some View {
        modifier(SectionMIDIExportModifier(isPresented: isPresented))
    }
}

private struct SectionMIDIExportModifier: ViewModifier {
    @EnvironmentObject var songStore: SongStore
    @Binding var isPresented: Bool
    @State private var document: MIDIFileDocument?
    @State private var filename = "FWD Section"
    @State private var showingPicker = false
    /// Where the copy in the Exports folder went, to say so once the picker closes.
    @State private var savedCopy: String?

    private static let formats: [SongExportFormat] = [.midi, .midiOnGrid]

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Export section as", isPresented: $isPresented, titleVisibility: .visible) {
                ForEach(Self.formats) { format in
                    Button(format.displayName) { export(format) }
                }
            } message: {
                Text(Self.formats.map { "\($0.displayName) — \($0.detail)" }.joined(separator: "\n"))
            }
            .fileExporter(isPresented: $showingPicker, document: document,
                          contentType: .standardMIDI, defaultFilename: filename) { result in
                document = nil
                // The copy in Exports is there whether or not a place was chosen here,
                // so a cancelled picker is not a failure.
                if case .failure(let error) = result,
                   (error as? CocoaError)?.code != .userCancelled {
                    songStore.notice = error.localizedDescription
                } else if let savedCopy {
                    songStore.notice = savedCopy
                }
                savedCopy = nil
            }
    }

    private func export(_ format: SongExportFormat) {
        let index = songStore.selectedSection
        guard songStore.song.sections.indices.contains(index) else { return }
        let section = songStore.song.sections[index]
        do {
            let data = try SongMIDIExporter.data(for: songStore.song, section: section.id,
                                                 includingFeel: format == .midi)
            let name = Self.filename(song: songStore.song.name, section: section.name)
            // Kept in the app's Exports folder as well, as song exports are, so a file
            // exists somewhere findable even if the picker is dismissed.
            savedCopy = SongStorage.saveToExports(data, name: name, fileExtension: format.fileExtension)
                .map { SongStorage.exportLocationDescription(for: $0) }
            document = MIDIFileDocument(data: data)
            filename = name
            showingPicker = true
        } catch {
            songStore.notice = "Export failed. \(error.localizedDescription)"
        }
    }

    /// "Song - Section", without the characters a file name cannot hold.
    private static func filename(song: String, section: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        func clean(_ text: String) -> String {
            text.components(separatedBy: invalid).joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = [clean(song), clean(section)].filter { !$0.isEmpty }
        return parts.isEmpty ? "FWD Section" : parts.joined(separator: " - ")
    }
}
