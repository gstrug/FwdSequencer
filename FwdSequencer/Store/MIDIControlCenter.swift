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
        didSet { learn.linksChanged() }
    }
    /// Every template: the built-ins, then the user's own.
    @Published private(set) var templates: [MIDIControllerTemplate] = [] {
        didSet { learn.linksChanged() }
    }
    /// Device name → template id. A device with no entry uses a built-in that suits it,
    /// if there is one.
    @Published private(set) var assignments: [String: UUID] = [:] {
        didSet { learn.linksChanged() }
    }
    /// Devices switched off in MIDI settings, by name.
    @Published private(set) var disabledDevices: Set<String> = [] {
        didSet { learn.linksChanged() }
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

    /// The song store controls apply to — the song that is open.
    weak var songStore: SongStore?

    // MARK: Private

    private let input = MIDIInputManager.shared
    private var messageQueue: MIDIMessageQueue!
    private var pickup = MIDIPickup()
    private var tapTimes: [Date] = []

    private static let templatesKey = "MIDIControllerTemplates.v1"
    private static let assignmentsKey = "MIDIControllerAssignments.v1"
    private static let disabledKey = "MIDIDisabledDevices.v1"

    private init() {
        loadSettings()
        messageQueue = MIDIMessageQueue { [weak self] batch in self?.handle(batch) }
    }

    /// Start listening. Called once the app is up.
    func start() {
        input.onSourcesChanged = { [weak self] list in
            Task { @MainActor in self?.sources = list }
        }
        let queue: MIDIMessageQueue = messageQueue
        input.onMessage = { source, message in queue.push(source, message) }
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
            guard let template = template(forDevice: source.name) else { continue }
            for mapping in template.mappings(matching: message) {
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
        case .tempo, .masterVolume, .trackVolume, .trackPan:
            break   // continuous, handled above
        }
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

/// MIDI Learn's on-screen state. See MIDIControlCenter.learn.
@MainActor
final class MIDILearnState: ObservableObject {
    /// Learnable controls are outlined and a tap selects one instead of using it.
    @Published var isOn = false {
        didSet { if !isOn { target = nil } }
    }
    /// The control waiting to be linked to the next message that arrives.
    @Published var target: MIDIControlTarget?
    /// Bumped whenever links, templates or devices change, so the link labels on
    /// controls refresh.
    @Published private(set) var revision = 0

    func linksChanged() { revision &+= 1 }
}
