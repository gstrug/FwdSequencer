import SwiftUI

/// Settings ▸ MIDI ▸ Track Inputs…: every track's live-key settings in one place
/// (Graham, 2026-11-20). Which controller and channel reach a track, its key range
/// (for splits, set by pressing two keys), Keys Play (all, lowest or highest note) and
/// Transpose, beside its P. Saved with the song, unlike the rest of Settings ▸ MIDI,
/// which is about the controllers and applies everywhere. Defaults are any controller,
/// any channel and the whole keyboard, which is how keys reached tracks before.
struct TrackInputsView: View {
    @EnvironmentObject var songStore: SongStore
    @ObservedObject private var center = MIDIControlCenter.shared
    @ObservedObject private var learn = MIDIControlCenter.shared.learn
    @Environment(\.dismiss) private var dismiss
    /// The track to scroll to when opened from a track's menu or chip.
    var focusTrackID: UUID? = nil

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    noticeSection
                    ForEach(songStore.song.tracks) { track in
                        trackSection(track).id(track.id)
                    }
                }
                .onAppear {
                    if let focusTrackID {
                        DispatchQueue.main.async { proxy.scrollTo(focusTrackID, anchor: .top) }
                    }
                }
            }
            .navigationTitle("Track Inputs")
            .navigationBarTitleDisplayMode(.inline)
            .helpHost()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { HelpButton() }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear { center.cancelKeyRangeCapture() }
    }

    // MARK: Notices

    @ViewBuilder
    private var noticeSection: some View {
        Section {
            if learn.writeNotesEnabled {
                Label("Write Notes from Keys is on, so your keys go to the armed W track only. These settings apply when it is off.",
                      systemImage: "music.note.list")
                    .font(.callout)
            } else if !learn.keysReachTracks {
                Label("No connected controller has Keys → Tracks on. Turn it on in Settings ▸ MIDI ▸ Controllers & Templates for these settings to play anything.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
        } footer: {
            Text("Saved with this song. Keys reach a track when its P is on and the key comes from the controller, channel and range set here. The defaults — any controller, any channel, the whole keyboard — let every key through, as before.")
        }
    }

    // MARK: A track

    private func trackSection(_ track: SongTrack) -> some View {
        Section {
            Toggle(isOn: Binding(get: { learn.playTrackIDs.contains(track.id) },
                                 set: { _ in center.togglePlay(track.id) })) {
                Label("Keys Play This Track (P)", systemImage: "pianokeys")
            }
            .helpTag(.trackPlayKeys, instance: track.id.uuidString)

            Picker(selection: Binding(get: { track.keysSource ?? "" },
                                      set: { songStore.setKeysSource($0.isEmpty ? nil : $0, for: track.id) })) {
                Text("Any Controller").tag("")
                ForEach(controllerNames(keeping: track.keysSource), id: \.self) { name in
                    Text(isConnected(name) ? name : "\(name) (not connected)").tag(name)
                }
            } label: {
                Label("Keys From", systemImage: "cable.connector")
            }
            .helpTag(.trackInputs, instance: track.id.uuidString)

            Picker(selection: Binding(get: { track.effectiveKeysChannel ?? 0 },
                                      set: { songStore.setKeysChannel($0 == 0 ? nil : $0, for: track.id) })) {
                Text("Any Channel").tag(0)
                ForEach(1...16, id: \.self) { channel in
                    Text("Channel \(channel)").tag(channel)
                }
            } label: {
                Label("Channel", systemImage: "number")
            }

            rangeRow(track)

            Picker(selection: Binding(get: { track.effectiveKeysNotePriority?.rawValue ?? "" },
                                      set: { songStore.setKeysNotePriority(KeysNotePriority(rawValue: $0), for: track.id) })) {
                Text("All Notes").tag("")
                Text("Lowest Note").tag(KeysNotePriority.lowest.rawValue)
                Text("Highest Note").tag(KeysNotePriority.highest.rawValue)
            } label: {
                Label("Keys Play", systemImage: "music.note")
            }
            .helpTag(.trackKeysPlay, instance: track.id.uuidString)

            Picker(selection: Binding(get: { track.effectiveKeysTranspose },
                                      set: { songStore.setKeysTranspose($0, for: track.id) })) {
                ForEach(KeysTransposeMenu.choices(including: track.effectiveKeysTranspose), id: \.self) { value in
                    Text(KeysTransposeMenu.name(value)).tag(value)
                }
            } label: {
                Label("Transpose", systemImage: "arrow.up.arrow.down")
            }
            .helpTag(.trackTranspose, instance: track.id.uuidString)
        } header: {
            Text(track.name)
        } footer: {
            if let source = track.keysSource, !isConnected(source) {
                Text("\(source) is not connected, so no keys reach this track until it is, or Keys From is set to Any Controller.")
            } else if let source = track.keysSource, !center.keysSetting(forDevice: source).toTracks {
                Text("\(source) has Keys → Tracks off, so it does not play tracks. Turn it on in Settings ▸ MIDI ▸ Controllers & Templates.")
            }
        }
    }

    @ViewBuilder
    private func rangeRow(_ track: SongTrack) -> some View {
        let capturing = learn.keyRangeCapture?.trackID == track.id
        HStack {
            Label("Key Range", systemImage: "arrow.left.and.right")
            Spacer()
            if capturing {
                Text(learn.keyRangeCapture?.first == nil ? "Press the lowest key…"
                     : "Lowest \(KeyNames.name(learn.keyRangeCapture?.first ?? 0)). Now the highest…")
                    .foregroundStyle(Color.accentColor)
                Button("Cancel") { center.cancelKeyRangeCapture() }
                    .buttonStyle(.borderless)
            } else {
                Text(track.keysRange.map(KeyNames.range) ?? "Whole Keyboard")
                    .foregroundStyle(.secondary)
                if track.keysRange != nil {
                    Button("Whole Keyboard") { songStore.setKeysRange(nil, for: track.id) }
                        .buttonStyle(.borderless)
                }
                Button("Set…") { center.startKeyRangeCapture(for: track.id) }
                    .buttonStyle(.borderless)
            }
        }
        .helpTag(.trackKeyRange, instance: track.id.uuidString)
    }

    // MARK: Controllers

    /// The controllers connected now, plus the track's own if it is not connected, so
    /// its choice is still shown (and can be kept for when it comes back).
    private func controllerNames(keeping current: String?) -> [String] {
        var names = center.sources.map(\.name).filter { center.isEnabled($0) }
        if let current, !names.contains(current) { names.append(current) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func isConnected(_ name: String) -> Bool {
        center.sources.contains { $0.name == name }
    }
}

/// Key names for ranges: C4 is middle C (MIDI 60), as elsewhere in the app.
enum KeyNames {
    private static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func name(_ midi: Int) -> String {
        "\(names[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
    }

    static func range(_ range: ClosedRange<Int>) -> String {
        range.lowerBound == range.upperBound ? name(range.lowerBound)
            : "\(name(range.lowerBound))–\(name(range.upperBound))"
    }
}
