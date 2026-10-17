import Foundation
import Combine
import os

/// The app side of MIDI control: which controllers are connected, which template each
/// one uses, MIDI Learn, and turning incoming messages into changes to the open song.
///
/// One for the whole app, because links are app-wide. Incoming MIDI arrives on CoreMIDI's
/// thread; it is queued there and handled here on the main thread, in batches, so a fader
/// sweep sending a hundred messages a second becomes one change per screen update rather
/// than a hundred.
@MainActor
final class MIDIControlCenter: ObservableObject {
    static let shared = MIDIControlCenter()

    // MARK: Published state

    /// Controllers and keyboards currently connected.
    @Published private(set) var sources: [MIDIInputManager.Source] = [] {
        didSet { learn.linksChanged(); refreshKeyRouting() }
    }
    /// Every template: the built-ins, then the user's own.
    @Published private(set) var templates: [MIDIControllerTemplate] = [] {
        didSet { learn.linksChanged(); refreshKeyRouting() }
    }
    /// Device name → template id. A device with no entry uses a built-in that suits it,
    /// if there is one.
    @Published private(set) var assignments: [String: UUID] = [:] {
        didSet { learn.linksChanged(); refreshKeyRouting() }
    }
    /// Devices switched off in MIDI settings, by name.
    @Published private(set) var disabledDevices: Set<String> = [] {
        didSet { learn.linksChanged(); refreshKeyRouting() }
    }
    /// Device name → where its keys go. A device with no entry: Off.
    @Published private(set) var keyDestinations: [String: MIDIKeysDestination] = [:] {
        didSet { refreshKeyRouting() }
    }
    /// When each device last sent something, for its activity light.
    @Published private(set) var lastActivity: [String: Date] = [:]

    /// Learn mode, kept in its own small object: every learnable control on screen
    /// observes it, and it changes only when Learn is used — not on every MIDI message,
    /// as the activity lights above do.
    let learn = MIDILearnState()

    /// Fires when a controller asks to start or stop recording. Recording's export flow
    /// belongs to the transport bar, so it listens for this rather than it being done here.
    let recordRequests = PassthroughSubject<Void, Never>()
    /// Fires when a controller asks to show or hide the Play keyboard, which is the song
    /// screen's to open and close.
    let playDockRequests = PassthroughSubject<Void, Never>()

    /// The song store controls apply to — the song that is open. Nil from the song list.
    weak var songStore: SongStore? {
        didSet { songStoreChanged() }
    }

    // MARK: Private

    private let input = MIDIInputManager.shared
    private var messageQueue: MIDIMessageQueue!
    private var pickup = MIDIPickup()
    private var tapTimes: [Date] = []
    /// Plays keys straight from CoreMIDI's thread; kept up to date from here.
    private let keyRouter = MIDIKeyRouter()
    private var songObservers: Set<AnyCancellable> = []
    private var learnObservers: Set<AnyCancellable> = []
    /// Write Notes: the keys held down right now, and the first key of the current
    /// press with whether it took a note out — so that a chord adds its notes rather
    /// than toggling each one, and a note already in the track is left in.
    private var writeKeysDown: Set<String> = []
    private var chordStart: (note: Int, removed: Bool)?

    private static let templatesKey = "MIDIControllerTemplates.v1"
    private static let assignmentsKey = "MIDIControllerAssignments.v1"
    private static let disabledKey = "MIDIDisabledDevices.v1"
    private static let keysKey = "MIDIKeyDestinations.v1"

    private init() {
        loadSettings()
        messageQueue = MIDIMessageQueue { [weak self] batch in self?.handle(batch) }
        // Learn and Write Notes change how keys are routed. Received on the next main
        // turn, because @Published announces a change before the value is stored.
        learn.$isOn.combineLatest(learn.$writingTrackID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Armed elsewhere, or disarmed: any keys still down belong to before.
                self?.writeKeysDown.removeAll()
                self?.chordStart = nil
                self?.refreshKeyRouting()
            }
            .store(in: &learnObservers)
    }

    /// Start listening. Called once the app is up.
    func start() {
        input.onSourcesChanged = { [weak self] list in
            Task { @MainActor in self?.sources = list }
        }
        let queue: MIDIMessageQueue = messageQueue
        let router: MIDIKeyRouter = keyRouter
        input.onMessage = { source, message in
            // Keys are played here, on the MIDI thread, so they sound at once. Whatever
            // still needs the app (links, Learn, Write Notes) goes on to the main thread.
            if router.receive(device: source.name, message) { queue.push(source, message) }
        }
        // Pitch bend and per-note pressure: only ever played through, never linked.
        input.onPerformanceMessage = { source, status, data1, data2 in
            router.receivePerformance(device: source.name, status: status, data1: data1, data2: data2)
        }
        input.start()
        sources = input.sources
    }

    // MARK: Templates and devices

    /// Stored as a device's assignment when the user picked "None", so a device a
    /// built-in suits can still be left with no links at all.
    static let noTemplate = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The template a device uses: the one assigned to it, else a built-in that suits it.
    func template(forDevice name: String) -> MIDIControllerTemplate? {
        if let id = assignments[name] {
            if id == Self.noTemplate { return nil }
            if let t = templates.first(where: { $0.id == id }) { return t }
        }
        return templates.first { $0.isBuiltIn && $0.suits(deviceNamed: name) }
    }

    /// `nil` means "None": the device sends nothing to the app.
    func assign(_ templateID: UUID?, toDevice name: String) {
        assignments[name] = templateID ?? Self.noTemplate
        pickup.reset()
        saveSettings()
    }

    func setDevice(_ name: String, enabled: Bool) {
        if enabled { disabledDevices.remove(name) } else { disabledDevices.insert(name) }
        saveSettings()
    }

    func isEnabled(_ name: String) -> Bool { !disabledDevices.contains(name) }

    // MARK: Keys

    func keysDestination(forDevice name: String) -> MIDIKeysDestination {
        keyDestinations[name] ?? .off
    }

    func setKeysDestination(_ destination: MIDIKeysDestination, forDevice name: String) {
        keyDestinations[name] = destination
        saveSettings()
    }

    // MARK: Write Notes

    /// The W button on a track: arm it for Write Notes, or disarm it if it is the one
    /// armed. One track at a time, so arming another moves it there.
    func toggleWriting(_ trackID: UUID) {
        if learn.writingTrackID == trackID {
            learn.writingTrackID = nil
        } else {
            learn.writeNotesEnabled = true
            learn.writingTrackID = trackID
            learn.lastWritingTrackID = trackID
        }
    }

    /// A track was just added. With Write Notes switched on it is armed at once, so a
    /// new track can be played straight in.
    func trackAdded(_ trackID: UUID) {
        guard learn.writeNotesEnabled else { return }
        learn.writingTrackID = trackID
        learn.lastWritingTrackID = trackID
    }

    /// Punch in and out from a controller button: disarm, or re-arm the track armed
    /// last (the first track if none has been).
    private func punchWriting(_ store: SongStore) {
        if learn.writingTrackID != nil { learn.writingTrackID = nil; return }
        let tracks = store.song.tracks
        guard let id = tracks.first(where: { $0.id == learn.lastWritingTrackID })?.id ?? tracks.first?.id
        else { return }
        toggleWriting(id)
    }

    private func songStoreChanged() {
        songObservers.removeAll()
        if let store = songStore {
            // Track list or Play instrument changed, or instruments started or finished
            // restoring: the keys' instruments need working out again.
            store.$song
                // Which instruments exist, and whether each can be heard: keys follow
                // mute and solo, so a muted channel's keys fall silent too.
                .map { song in
                    song.tracks.map { "\($0.id)\(song.isAudible($0))" }
                        + [song.performance.map { "\($0.id)\(song.isPlayKeyboardAudible)" }].compactMap { $0 }
                }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshKeyRouting() }
                .store(in: &songObservers)
            store.$isLoading
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshKeyRouting() }
                .store(in: &songObservers)
        } else {
            // Song closed: Learn and Write Notes end with it.
            learn.isOn = false
            learn.writingTrackID = nil
        }
        refreshKeyRouting()
    }

    /// Tell the MIDI thread where each controller's keys go now.
    private func refreshKeyRouting() {
        let store = songStore
        var instruments: [String: UUID] = [:]
        var linked: [String: Set<MIDIControlSource>] = [:]
        var linkedControls: [String: Set<MIDIControlSource>] = [:]
        var needsPlayInstrument = false
        for source in sources where isEnabled(source.name) {
            if let t = template(forDevice: source.name) {
                linked[source.name] = Set(t.mappings.map(\.source).filter { $0.kind == .note })
                linkedControls[source.name] = Set(t.mappings.map(\.source).filter { $0.kind == .controlChange })
            }
            guard let store else { continue }
            switch keysDestination(forDevice: source.name) {
            case .off:
                break
            case .playKeyboard:
                if let performance = store.song.performance {
                    if store.song.isPlayKeyboardAudible { instruments[source.name] = performance.id }
                } else {
                    needsPlayInstrument = true
                }
            case .track(let i):
                // Muted (or silenced by a solo elsewhere): its keys are silent too.
                if store.song.tracks.indices.contains(i), store.song.isAudible(store.song.tracks[i]) {
                    instruments[source.name] = store.song.tracks[i].id
                }
            }
        }
        // The track armed for Write Notes: its keys sound only if it can be heard, but
        // notes are written either way. Gone (deleted, or another song): disarm.
        var writing = false
        var armedInstrument: UUID?
        if let armedID = learn.writingTrackID {
            if let store, let armed = store.song.tracks.first(where: { $0.id == armedID }) {
                writing = true
                if store.song.isAudible(armed) { armedInstrument = armed.id }
            } else if store != nil {
                DispatchQueue.main.async { [weak self] in
                    if self?.learn.writingTrackID == armedID { self?.learn.writingTrackID = nil }
                }
            }
        }
        let paused = store.map { $0.isLoading } ?? true
        let learning = learn.isOn
        let disabled = disabledDevices
        keyRouter.reconfigure { c in
            c.instruments = instruments
            c.linkedNotes = linked
            c.linkedControls = linkedControls
            c.disabledDevices = disabled
            c.learning = learning
            c.writingNotes = writing
            c.armedInstrument = armedInstrument
            c.paused = paused
        }
        // The Play keyboard's instrument is made the first time it is needed, as the
        // Play dock does. Later, not now: it changes the song, which may be publishing.
        if needsPlayInstrument, let store, !store.isLoading {
            DispatchQueue.main.async { store.ensurePerformanceInstrument() }
        }
    }

    /// A copy of a template under a new name — "save as" for a learned layout, or a way
    /// to start your own from a built-in.
    @discardableResult
    func duplicate(_ templateID: UUID, named name: String? = nil) -> MIDIControllerTemplate? {
        guard let source = templates.first(where: { $0.id == templateID }) else { return nil }
        let copy = MIDIControllerTemplate(
            name: uniqueName(name ?? source.name.replacingOccurrences(of: " (factory)", with: "") + " copy"),
            mappings: source.mappings.map { MIDIControlMapping(source: $0.source, target: $0.target, pickup: $0.pickup) },
            isBuiltIn: false, deviceNameHint: source.deviceNameHint)
        templates.append(copy)
        saveSettings()
        return copy
    }

    /// A new, empty template.
    @discardableResult
    func newTemplate(named name: String, deviceNameHint: String? = nil) -> MIDIControllerTemplate {
        let fresh = MIDIControllerTemplate(name: uniqueName(name), deviceNameHint: deviceNameHint)
        templates.append(fresh)
        saveSettings()
        return fresh
    }

    func rename(_ templateID: UUID, to name: String) {
        guard let i = templates.firstIndex(where: { $0.id == templateID }), !templates[i].isBuiltIn else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        templates[i].name = uniqueName(trimmed, excluding: templateID)
        saveSettings()
    }

    func delete(_ templateID: UUID) {
        guard let i = templates.firstIndex(where: { $0.id == templateID }), !templates[i].isBuiltIn else { return }
        templates.remove(at: i)
        for (device, id) in assignments where id == templateID { assignments.removeValue(forKey: device) }
        saveSettings()
    }

    /// Whether a target is linked on any connected controller, and to what — for the
    /// label Learn mode shows on each control.
    func linkDescription(for target: MIDIControlTarget) -> String? {
        for source in sources where isEnabled(source.name) {
            if let mapping = template(forDevice: source.name)?.mapping(for: target) {
                return mapping.source.displayName
            }
        }
        return nil
    }

    /// Remove a control's link from every connected controller's template.
    func forget(_ target: MIDIControlTarget) {
        for source in sources {
            guard let id = editableTemplateID(forDevice: source.name, creating: false),
                  let i = templates.firstIndex(where: { $0.id == id }) else { continue }
            templates[i].forget(target)
        }
        saveSettings()
    }

    /// Remove one link from a template of the user's own (built-ins stay as shipped).
    func removeLink(_ target: MIDIControlTarget, fromTemplate templateID: UUID) {
        guard let i = templates.firstIndex(where: { $0.id == templateID }), !templates[i].isBuiltIn else { return }
        templates[i].forget(target)
        pickup.reset()
        saveSettings()
    }

    // MARK: Receiving

    /// A batch of messages, in arrival order, on the main thread.
    private func handle(_ batch: [(MIDIInputManager.Source, MIDIControlMessage)]) {
        guard !batch.isEmpty else { return }

        // Activity lights: once per device per batch.
        let now = Date()
        for name in Set(batch.map { $0.0.name }) { lastActivity[name] = now }

        // A continuous control only needs its LAST position in a batch; buttons are
        // handled in order, every press and release, so none is lost.
        var lastContinuous: [String: Int] = [:]
        for (i, (source, message)) in batch.enumerated() where message.kind == .controlChange {
            lastContinuous["\(source.name)|\(message.channel)|\(message.number)"] = i
        }

        for (i, (source, message)) in batch.enumerated() {
            guard isEnabled(source.name) else { continue }
            if learn.isOn, let target = learn.target {
                makeLink(target, from: source, message)
                continue
            }
            let mappings = template(forDevice: source.name)?.mappings(matching: message) ?? []
            if mappings.isEmpty {
                // A key nothing is linked to: with a track armed for Write Notes, it sets
                // or clears that note in the armed track (a chord only adds).
                if message.kind == .note, let armed = learn.writingTrackID {
                    let key = "\(source.name)|\(message.channel)|\(message.number)"
                    if message.isPress {
                        writePress(message.number, key: key, into: armed)
                    } else {
                        writeKeysDown.remove(key)
                        if writeKeysDown.isEmpty { chordStart = nil }
                    }
                }
                continue
            }
            for mapping in mappings {
                if mapping.target.isContinuous {
                    let key = "\(source.name)|\(message.channel)|\(message.number)"
                    guard lastContinuous[key] == i || message.kind == .note else { continue }
                    applyContinuous(mapping, message.fraction)
                } else {
                    applyButton(mapping.target, pressed: message.isPress)
                }
            }
        }
    }

    // MARK: Learn

    private func makeLink(_ target: MIDIControlTarget, from source: MIDIInputManager.Source,
                          _ message: MIDIControlMessage) {
        // Ignore the release half of a button press, or a knob turned back to zero, so
        // the link is made from the message that was meant.
        if message.kind == .note && !message.isPress { return }
        guard let id = editableTemplateID(forDevice: source.name, creating: true),
              let i = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[i].learn(MIDIControlSource(message), for: target)
        saveSettings()
        learn.target = nil
        pickup.reset()
    }

    /// The template Learn should write to for a device. Built-ins are never edited: the
    /// first link learned on one makes the device its own copy, so the factory layout
    /// stays intact to go back to. A device with no template gets one named after it.
    private func editableTemplateID(forDevice name: String, creating: Bool) -> UUID? {
        if let current = template(forDevice: name) {
            if !current.isBuiltIn { return current.id }
            guard creating, let copy = duplicate(current.id, named: name) else { return nil }
            assign(copy.id, toDevice: name)
            return copy.id
        }
        guard creating else { return nil }
        let fresh = MIDIControllerTemplate(name: uniqueName(name), deviceNameHint: name)
        templates.append(fresh)
        assign(fresh.id, toDevice: name)
        return fresh.id
    }

    // MARK: Applying to the song

    /// The open song, unless instruments are being restored. While "Restoring
    /// instruments…" is up, touches are blocked on purpose (a fragile plugin can crash if
    /// interrupted then), and a controller must be held off for the same reason.
    private var activeStore: SongStore? {
        guard let store = songStore, !store.isLoading else { return nil }
        return store
    }

    private func applyContinuous(_ mapping: MIDIControlMapping, _ fraction: Double) {
        guard let store = activeStore else { return }
        switch mapping.target {
        case .masterVolume:
            let current = Double(store.song.masterVolume)
            guard pickup.shouldApply(mapping, incoming: fraction, current: current) else { return }
            store.song.masterVolume = Float(fraction)
        case .tempo:
            let current = MIDIControlScaling.fraction(forTempo: store.song.tempo)
            guard pickup.shouldApply(mapping, incoming: fraction, current: current) else { return }
            store.song.tempo = MIDIControlScaling.tempo(forFraction: fraction)
        case .trackVolume(let index):
            guard store.song.tracks.indices.contains(index) else { return }
            let current = MIDIControlScaling.fraction(forGain: store.song.tracks[index].mixer.volume)
            guard pickup.shouldApply(mapping, incoming: fraction, current: current) else { return }
            store.song.tracks[index].mixer.volume = MIDIControlScaling.gain(forFraction: fraction)
        case .trackPan(let index):
            guard store.song.tracks.indices.contains(index) else { return }
            let current = MIDIControlScaling.fraction(forPan: store.song.tracks[index].mixer.pan)
            guard pickup.shouldApply(mapping, incoming: fraction, current: current) else { return }
            store.song.tracks[index].mixer.pan = MIDIControlScaling.pan(forFraction: fraction)
        case .playVolume:
            guard let performance = store.song.performance else { return }
            let current = MIDIControlScaling.fraction(forGain: performance.mixer.volume)
            guard pickup.shouldApply(mapping, incoming: fraction, current: current) else { return }
            store.song.performance?.mixer.volume = MIDIControlScaling.gain(forFraction: fraction)
        case .playPan:
            guard let performance = store.song.performance else { return }
            let current = MIDIControlScaling.fraction(forPan: performance.mixer.pan)
            guard pickup.shouldApply(mapping, incoming: fraction, current: current) else { return }
            store.song.performance?.mixer.pan = MIDIControlScaling.pan(forFraction: fraction)
        default:
            // A button target reached through a knob: treat crossing half way as a press.
            applyButton(mapping.target, pressed: fraction >= 0.5)
        }
    }

    /// Buttons act on the press. Section pads in Trigger mode also hear the release,
    /// for hold-to-play.
    private func applyButton(_ target: MIDIControlTarget, pressed: Bool) {
        guard let store = activeStore else { return }
        if case .section(let index) = target, store.triggerMode {
            if pressed { store.triggerSection(at: index) } else { store.releaseTrigger() }
            return
        }
        guard pressed else { return }
        switch target {
        case .playPause:
            if store.isPlaying { store.pause() }
            else if store.isPaused { store.resume() }
            else { store.play() }
        case .stop:        store.stop()
        case .rewind:      store.rewind()
        case .record:      recordRequests.send()
        case .loop:        store.loopEnabled.toggle()
        case .panic:       store.midiPanic()
        case .hold:        store.holdsSection.toggle()
        case .tapTempo:    tapTempo(store)
        case .trackMute(let i):
            guard store.song.tracks.indices.contains(i) else { return }
            store.song.tracks[i].mixer.isMuted.toggle()
        case .trackSolo(let i):
            guard store.song.tracks.indices.contains(i) else { return }
            store.song.tracks[i].mixer.isSoloed.toggle()
        case .trackEffects(let i):
            guard store.song.tracks.indices.contains(i) else { return }
            store.toggleEffectsChain(for: store.song.tracks[i].id)
        case .section(let i):
            guard store.song.sections.indices.contains(i) else { return }
            store.selectedSection = i
        case .previousSection:
            store.selectedSection = max(0, store.selectedSection - 1)
        case .nextSection:
            store.selectedSection = max(0, min(store.song.sections.count - 1, store.selectedSection + 1))
        case .writeNotes:
            punchWriting(store)
        case .trackWriteNotes(let i):
            guard store.song.tracks.indices.contains(i) else { return }
            toggleWriting(store.song.tracks[i].id)
        case .playMute:
            store.song.performance?.mixer.isMuted.toggle()
        case .playSolo:
            store.song.performance?.mixer.isSoloed.toggle()
        case .playEffects:
            if let id = store.song.performance?.id { store.toggleEffectsChain(for: id) }
        case .togglePlayDock:
            playDockRequests.send()
        case .triggerMode:
            store.triggerMode.toggle()
        case .tempo, .masterVolume, .trackVolume, .trackPan, .playVolume, .playPan:
            break   // continuous, handled above
        }
    }

    /// Set or clear a note in the selected section of the armed track — exactly what
    /// tapping that key on the track's on-screen keyboard does, including leaving out
    /// notes the track's scale does not allow.
    ///
    /// It used to write to the track a controller's "Keys play" pointed at, and did
    /// nothing at all when that was Off or the Play keyboard. Arming the track itself
    /// makes where notes go visible and independent of that setting.
    ///
    /// `adding` (a key in a chord): only ever adds — a note already there stays.
    /// Returns true when a note was taken out.
    @discardableResult
    private func writeNote(_ midi: Int, into trackID: UUID, adding: Bool = false) -> Bool {
        guard let store = activeStore,
              store.song.tracks.contains(where: { $0.id == trackID }) else { return false }
        let section = store.selectedSection
        guard store.song.sections.indices.contains(section) else { return false }

        let existing = store.song.sections[section].parts.firstIndex { $0.trackID == trackID }
        var part = existing.map { store.song.sections[section].parts[$0] } ?? Part(trackID: trackID)
        let semitone = ((midi % 12) - part.key + 12) % 12
        guard part.scale.intervals.contains(semitone) else { return false }

        var removed = false
        if let i = part.notePool.firstIndex(where: { $0.midiNote == midi }) {
            guard !adding else { return false }
            part.notePool.remove(at: i)
            removed = true
        } else {
            let insertAt = part.notePool.firstIndex { $0.midiNote > midi } ?? part.notePool.endIndex
            part.notePool.insert(NoteEntry(midiNote: midi), at: insertAt)
        }
        if let existing {
            store.song.sections[section].parts[existing] = part
        } else {
            store.song.sections[section].parts.append(part)
        }
        return removed
    }

    /// A key pressed with Write Notes on. A single key toggles its note, as on screen.
    /// A key pressed while another is still down is part of a chord: its note is only
    /// ever added, and if the chord's first key took its note out, that is put back —
    /// the first key could not know a chord was coming.
    private func writePress(_ midi: Int, key: String, into trackID: UUID) {
        writeKeysDown.remove(key)   // the same key again, without a release between
        if writeKeysDown.isEmpty {
            chordStart = (midi, writeNote(midi, into: trackID))
        } else {
            writeNote(midi, into: trackID, adding: true)
            if let start = chordStart, start.removed {
                writeNote(start.note, into: trackID, adding: true)
                chordStart = (start.note, false)
            }
        }
        writeKeysDown.insert(key)
    }

    /// The same averaging as the on-screen Tap button.
    private func tapTempo(_ store: SongStore) {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 8 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }
        let intervals = zip(tapTimes.dropLast(), tapTimes.dropFirst()).map { $1.timeIntervalSince($0) }
        let average = intervals.reduce(0, +) / Double(intervals.count)
        store.song.tempo = min(400, max(20, (60.0 / average).rounded()))
    }

    // MARK: Persistence

    private func uniqueName(_ base: String, excluding id: UUID? = nil) -> String {
        let taken = Set(templates.filter { $0.id != id }.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        var user: [MIDIControllerTemplate] = []
        if let data = defaults.data(forKey: Self.templatesKey),
           let decoded = try? JSONDecoder().decode([MIDIControllerTemplate].self, from: data) {
            user = decoded.filter { !$0.isBuiltIn }
        }
        templates = MIDIBuiltInTemplates.all + user
        if let data = defaults.data(forKey: Self.assignmentsKey),
           let decoded = try? JSONDecoder().decode([String: UUID].self, from: data) {
            assignments = decoded
        }
        disabledDevices = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if let data = defaults.data(forKey: Self.keysKey),
           let decoded = try? JSONDecoder().decode([String: MIDIKeysDestination].self, from: data) {
            keyDestinations = decoded
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        // Built-ins come from the code, so only the user's own are stored.
        if let data = try? JSONEncoder().encode(templates.filter { !$0.isBuiltIn }) {
            defaults.set(data, forKey: Self.templatesKey)
        }
        if let data = try? JSONEncoder().encode(assignments) {
            defaults.set(data, forKey: Self.assignmentsKey)
        }
        defaults.set(Array(disabledDevices).sorted(), forKey: Self.disabledKey)
        if let data = try? JSONEncoder().encode(keyDestinations) {
            defaults.set(data, forKey: Self.keysKey)
        }
    }
}

/// Collects messages on CoreMIDI's thread and hands them to the main thread in batches:
/// one main-thread turn for however many arrived since the last, rather than one each.
nonisolated final class MIDIMessageQueue: @unchecked Sendable {
    typealias Item = (MIDIInputManager.Source, MIDIControlMessage)
    private let lock = OSAllocatedUnfairLock()
    private var items: [Item] = []
    private var scheduled = false
    private let deliver: ([Item]) -> Void

    /// `deliver` runs on the main thread.
    init(deliver: @escaping ([Item]) -> Void) { self.deliver = deliver }

    func push(_ source: MIDIInputManager.Source, _ message: MIDIControlMessage) {
        lock.lock()
        items.append((source, message))
        let start = !scheduled
        scheduled = true
        lock.unlock()
        guard start else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            lock.lock()
            let batch = items
            items.removeAll(keepingCapacity: true)
            scheduled = false
            lock.unlock()
            deliver(batch)
        }
    }
}

/// Plays controller keys from CoreMIDI's thread. MIDIKeyRouting decides; this holds it
/// behind a lock and sends the notes to the engine, which is safe from any thread.
nonisolated final class MIDIKeyRouter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var routing = MIDIKeyRouting()

    /// On the MIDI thread. True when the message still needs the main thread.
    func receive(device: String, _ message: MIDIControlMessage) -> Bool {
        lock.lock()
        var decision = routing.route(device: device, message)
        // A controller nothing is linked to — sustain, mod wheel — is played through too.
        if message.kind == .controlChange {
            decision.actions += routing.routeControl(
                device: device, status: 0xB0 | UInt8((message.channel - 1) & 0x0F),
                data1: UInt8(message.number), data2: UInt8(message.value))
        }
        lock.unlock()
        perform(decision.actions)
        return decision.passOn
    }

    /// On the MIDI thread: pitch bend or per-note pressure, played through.
    func receivePerformance(device: String, status: UInt8, data1: UInt8, data2: UInt8) {
        lock.lock()
        let actions = routing.routeControl(device: device, status: status, data1: data1, data2: data2)
        lock.unlock()
        perform(actions)
    }

    func reconfigure(_ change: (inout MIDIKeyRouting.Config) -> Void) {
        lock.lock()
        let releases = routing.reconfigure(change)
        lock.unlock()
        perform(releases)
    }

    private func perform(_ actions: [MIDIKeyRouting.Action]) {
        let engine = AudioEngineManager.shared
        for action in actions {
            switch action {
            case .play(let id, let note, let velocity):
                engine.playNote(trackID: id, midiNote: note, velocity: velocity)
            case .stop(let id, let note):
                engine.stopNote(trackID: id, midiNote: note)
            case .control(let id, let status, let data1, let data2):
                engine.sendPerformanceMessage(trackID: id, status: status, data1: data1, data2: data2)
            }
        }
    }
}

/// MIDI Learn's on-screen state. See MIDIControlCenter.learn.
@MainActor
final class MIDILearnState: ObservableObject {
    /// Learnable controls are outlined and a tap selects one instead of using it.
    @Published var isOn = false {
        didSet {
            if !isOn { target = nil }
            // Learn and help mode both take over taps; only one at a time.
            if isOn { HelpCenter.shared.isOn = false }
        }
    }
    /// Write Notes from Keys, switched on in Settings ▸ MIDI: tracks show their W
    /// button. Remembered between launches. Switching it off disarms.
    @Published var writeNotesEnabled = UserDefaults.standard.bool(forKey: "MIDIWriteNotesEnabled") {
        didSet {
            UserDefaults.standard.set(writeNotesEnabled, forKey: "MIDIWriteNotesEnabled")
            if !writeNotesEnabled { writingTrackID = nil }
        }
    }
    /// The one track armed for Write Notes: controller keys play it and set or clear
    /// notes in it. Not saved: arming is for now, like a punch-in.
    @Published var writingTrackID: UUID?
    /// The track armed last, for punching back in from a controller button.
    var lastWritingTrackID: UUID?
    var writingNotes: Bool { writingTrackID != nil }
    /// The control waiting to be linked to the next message that arrives.
    @Published var target: MIDIControlTarget?
    /// Bumped whenever links, templates or devices change, so the link labels on
    /// controls refresh.
    @Published private(set) var revision = 0

    func linksChanged() { revision &+= 1 }
}
