import Foundation
@preconcurrency import AVFoundation
import AudioToolbox
import CoreMIDI

nonisolated enum AudioEngineStatus: Equatable {
    case ready
    case interrupted
    case recovering
    case failed(String)
}

nonisolated enum PluginLoadError: LocalizedError {
    case trackUnavailable
    case cancelled
    case timedOut(String)
    case instantiationFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .trackUnavailable:
            return "The track is no longer available."
        case .cancelled:
            return "Instrument loading was cancelled."
        case .timedOut(let name):
            return "\(name) took too long to load. The GM instrument is active instead."
        case .instantiationFailed(let name, let detail):
            return "\(name) could not be loaded. The built-in GM sound is active instead. \(detail)"
        }
    }
}

nonisolated enum AudioRecordingError: LocalizedError {
    case unavailable
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Add a track before recording the mix."
        case .writeFailed(let detail): return "The recording could not be written. \(detail)"
        }
    }
}

/// Audio graph access is protected by `auLock`; MIDI-clock state is confined to
/// `midiClockQueue`; recording writes are protected by `recordingLock`; callbacks
/// shared by the main and render threads are copied under `callbackLock`.
nonisolated final class AudioEngineManager: SequencerAudioOutput, @unchecked Sendable {
    // One shared audio engine / session for the whole app. Pattern playback and
    // song playback both route through it (only one document plays at a time).
    static let shared = AudioEngineManager()

    private var engine = AVAudioEngine()
    private var masterTapInstalled = false
    private let recordingLock = NSLock()
    private var recordingFile: AVAudioFile?
    private let midiClockQueue = DispatchQueue(label: "com.fwd.midi-clock", qos: .userInteractive)
    private var midiClient = MIDIClientRef()
    private var midiClockSource = MIDIEndpointRef()
    private var midiClockTimer: DispatchSourceTimer?
    private var samplers: [UUID: AVAudioUnitSampler] = [:]
    private var auv3Units: [UUID: AVAudioUnit] = [:]
    private var trackMixers: [UUID: AVAudioMixerNode] = [:]

    private let callbackLock = NSLock()
    private var _onLevelUpdate: ((UUID, Float) -> Void)?
    private var _onMasterLevelUpdate: ((Float) -> Void)?
    private var _onStatusChange: ((AudioEngineStatus) -> Void)?
    private var _onPlaybackInterrupted: ((String) -> Void)?
    private var _onRecoveryRequired: (() -> Void)?
    private var _onRecordingError: ((String) -> Void)?
    private var status: AudioEngineStatus = .recovering
    private func withCallbackLock<T>(_ body: () -> T) -> T {
        callbackLock.lock(); defer { callbackLock.unlock() }; return body()
    }
    var onLevelUpdate: ((UUID, Float) -> Void)? {
        get { withCallbackLock { _onLevelUpdate } }
        set { withCallbackLock { _onLevelUpdate = newValue } }
    }
    var onMasterLevelUpdate: ((Float) -> Void)? {
        get { withCallbackLock { _onMasterLevelUpdate } }
        set { withCallbackLock { _onMasterLevelUpdate = newValue } }
    }
    var onStatusChange: ((AudioEngineStatus) -> Void)? {
        get { withCallbackLock { _onStatusChange } }
        set { withCallbackLock { _onStatusChange = newValue } }
    }
    var onPlaybackInterrupted: ((String) -> Void)? {
        get { withCallbackLock { _onPlaybackInterrupted } }
        set { withCallbackLock { _onPlaybackInterrupted = newValue } }
    }
    var onRecoveryRequired: (() -> Void)? {
        get { withCallbackLock { _onRecoveryRequired } }
        set { withCallbackLock { _onRecoveryRequired = newValue } }
    }
    var onRecordingError: ((String) -> Void)? {
        get { withCallbackLock { _onRecordingError } }
        set { withCallbackLock { _onRecordingError = newValue } }
    }
    var currentStatus: AudioEngineStatus { withCallbackLock { status } }
    private var _telemetryPaused = false
    /// Suspends VU metering and level callbacks. Set while a plugin's UI is being
    /// constructed: hosting an out-of-process AUv3 view is main-thread and CoreAnimation
    /// heavy, and a big plugin (GeoShred) can fail to establish its hosted scene while we
    /// are also pushing 20 Hz meter updates per track. Audio and MIDI are unaffected.
    var telemetryPaused: Bool {
        get { withCallbackLock { _telemetryPaused } }
        set { withCallbackLock { _telemetryPaused = newValue } }
    }
    private var sessionObservers: [NSObjectProtocol] = []
    private struct PluginLoadRequest {
        let id: UUID
        let completion: (Result<Void, PluginLoadError>) -> Void
    }
    private var loadRequests: [UUID: PluginLoadRequest] = [:]

    // All access to the node dictionaries and to a hosted AU's state/MIDI is serialised
    // through this lock. The sequencer tick sends MIDI from a background queue while the
    // main thread loads/swaps/removes instruments and reads plugin state — without it, a
    // dictionary mutated during a concurrent read (or MIDI sent to a node mid-swap) is a
    // hard crash. Recursive so a locked method can safely call another.
    /// How long a newly instantiated AUv3 is left alone before it is sent MIDI (and
    /// before saved state is restored). Covers the extension building its DSP; sending
    /// MIDI inside this window crashes fragile plugins.
    ///
    /// 1.0 s — the value the codebase used throughout the period plugin hosting was
    /// working, kept for its original purpose: many AUv3s need a runloop cycle after
    /// being attached before they will accept `fullState`/`fullStateForDocument`.
    ///
    /// It is NOT a crash mitigation, despite having been raised to 4.0 s while chasing
    /// one. Crash times tracked this value almost exactly (1.0 s → died 4.1 s after the
    /// extension launched; 4.0 s → died 7.6 s), i.e. the plugin always died on the first
    /// MIDI event it received, whenever that arrived. The actual causes were our own
    /// all-notes-off flush and an unbalanced MIDI-gate release, both since fixed — so
    /// there is nothing to buy by inflating this, only slower instrument loads.
    static let instrumentSettleDelay: TimeInterval = 1.0

    private let auLock = NSRecursiveLock()
    private func withLock<T>(_ body: () -> T) -> T {
        auLock.lock(); defer { auLock.unlock() }; return body()
    }
    // Tracks whose instrument is mid-load/swap/restore. MIDI to a suspended track is
    // dropped so the tick can't hit a half-attached node or a not-yet-restored preset.
    //
    // REFERENCE COUNTED, deliberately. Suspension has independent owners — a plugin
    // load, and the open plugin editor — and with a plain flag whichever one resumed
    // first opened the gate for everyone. That is a real crash: closing the editor
    // during a load cleared the load's suspend, and a note-on reached GeoShred before
    // its extension had finished instantiating: a note-on was delivered before the
    // instantiate callback had even returned. Each owner must balance its own
    // suspend/resume; the gate lifts only when the last one releases.
    private var suspendCounts: [UUID: Int] = [:]
    private func isSuspended(_ id: UUID) -> Bool { suspendCounts[id] != nil }
    /// Instruments that have finished their settle window and may be sent MIDI. An AUv3
    /// is NOT in this set between attach and the end of `instrumentSettleDelay`.
    ///
    /// This gates the all-notes-off flushes too, which bypass `suspended` because they
    /// call `sendMIDI` directly. That matters: a flush is 129 MIDI events, and delivering
    /// even one to an unsettled plugin crashes it (GeoShred:
    /// `PerformanceHandler_runMidiEvent` on a null handler) — which happened just by
    /// opening its editor, with the sequencer stopped. Skipping the flush is always safe
    /// for an unsettled unit: MIDI was gated the whole time, so it has no ringing notes.
    private var settledInstruments: Set<UUID> = []
    /// Notes currently sounding per track, so a quiesce can send note-offs ONLY for
    /// what is actually ringing. Previously every suspend blasted 128 note-offs + CC123
    /// at the plugin; opening GeoShred's editor did exactly that and killed it
    /// (first event `80 00 00`). With nothing ringing this now sends nothing at all.
    private var activeNotes: [UUID: Set<UInt8>] = [:]

    /// Gate MIDI to a track and silence anything ringing on it. Call around a plugin
    /// swap/restore; balance with `resumeTrack`.
    func suspendTrack(_ id: UUID) {
        withLock {
            suspendCounts[id, default: 0] += 1
            stopAllNotesLocked(on: id)
        }
    }

    func resumeTrack(_ id: UUID) {
        withLock {
            guard let count = suspendCounts[id] else { return }   // ignore unbalanced resume
            if count <= 1 { suspendCounts.removeValue(forKey: id) }
            else { suspendCounts[id] = count - 1 }
        }
    }

    // Caller must hold auLock.
    private func stopAllNotesLocked(on id: UUID) {
        let ringing = activeNotes[id] ?? []
        activeNotes[id] = []
        guard !ringing.isEmpty else { return }   // nothing sounding → send NOTHING
        if let unit = auv3Units[id] {
            // Never address an unsettled plugin (see settledInstruments), and only ever
            // release notes we actually started. A blanket 0...127 sweep is 129 MIDI
            // events into a plugin that may not tolerate them.
            guard settledInstruments.contains(id) else { return }
            for n in ringing { sendMIDI(to: unit, bytes: [0x80, n, 0]) }
        } else if let sampler = samplers[id] {
            for n in ringing { sampler.stopNote(n, onChannel: 0) }
        }
    }

    init() {
        configureMIDIClockSource()
        registerForAudioSessionEvents()
        do {
            try configureAudioSession()
            configureMasterGraph()
            setStatus(.ready)
        } catch {
            setStatus(.failed(error.localizedDescription))
        }
    }

    deinit {
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        midiClockTimer?.cancel()
        if midiClockSource != 0 { MIDIEndpointDispose(midiClockSource) }
        if midiClient != 0 { MIDIClientDispose(midiClient) }
    }

    private func configureMIDIClockSource() {
        guard MIDIClientCreate("FWD Sequencer" as CFString, nil, nil, &midiClient) == noErr else { return }
        if MIDISourceCreate(midiClient, "FWD Sequencer Clock" as CFString, &midiClockSource) != noErr {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
    }

    func startMIDIClock(tempo: Double, continuing: Bool = false) {
        midiClockQueue.async { [weak self] in
            guard let self else { return }
            stopMIDIClockTimer()
            sendMIDIRealtime(continuing ? 0xFB : 0xFA)
            installMIDIClockTimer(tempo: tempo)
        }
    }

    func updateMIDIClockTempo(_ tempo: Double) {
        midiClockQueue.async { [weak self] in
            guard let self, midiClockTimer != nil else { return }
            stopMIDIClockTimer()
            installMIDIClockTimer(tempo: tempo)
        }
    }

    func stopMIDIClock() {
        midiClockQueue.async { [weak self] in
            guard let self else { return }
            stopMIDIClockTimer()
            sendMIDIRealtime(0xFC)
        }
    }

    private func installMIDIClockTimer(tempo: Double) {
        let interval = 60.0 / min(400, max(20, tempo)) / 24.0
        let timer = DispatchSource.makeTimerSource(queue: midiClockQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval,
                       leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in self?.sendMIDIRealtime(0xF8) }
        timer.resume()
        midiClockTimer = timer
    }

    private func stopMIDIClockTimer() {
        midiClockTimer?.setEventHandler {}
        midiClockTimer?.cancel()
        midiClockTimer = nil
    }

    private func sendMIDIRealtime(_ status: UInt8) {
        guard midiClockSource != 0 else { return }
        var packet = MIDIPacket()
        packet.timeStamp = 0
        packet.length = 1
        packet.data.0 = status
        var list = MIDIPacketList(numPackets: 1, packet: packet)
        MIDIReceived(midiClockSource, &list)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        // Instrument plugins (MIDI in, audio out) never need audio input, so use the
        // lighter, higher-quality .playback category instead of .playAndRecord — the
        // record path adds overhead and a more glitch-prone route, and .playback gets
        // full-quality Bluetooth (A2DP) rather than call-grade HFP.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        // Give the render callback more time per buffer. Hosting a CPU-heavy, disk-
        // streaming sampled instrument (e.g. Ravenscroft piano) overruns a small buffer,
        // producing crackle even at low levels (distinct from clipping). ~23 ms is a
        // stable size; latency is still fine for sequenced playback and live keys.
        try session.setPreferredIOBufferDuration(0.023)
        try session.setActive(true)
    }

    private func configureMasterGraph() {
        // No master effect on the output bus. A master AUPeakLimiter here transiently
        // clamps and adds CPU on the mix bus, which produces audible crackle on heavy
        // sampled instruments (e.g. the Ravenscroft piano) — distinct from clipping.
        // Connect the mix straight to the output. Do this explicitly rather than relying
        // on mainMixerNode's lazy auto-connection, which did not establish the output
        // path here (removing the limiter left the mix with nowhere to go → silence).
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
    }

    private func setStatus(_ newStatus: AudioEngineStatus) {
        withCallbackLock { status = newStatus }
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(newStatus) }
    }

    private func deliver(_ result: Result<Void, PluginLoadError>,
                         to completion: @escaping (Result<Void, PluginLoadError>) -> Void) {
        if Thread.isMainThread { completion(result) }
        else { DispatchQueue.main.async { completion(result) } }
    }

    private func startEngineIfNeeded() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            setStatus(.ready)
            return true
        } catch {
            setStatus(.failed(error.localizedDescription))
            return false
        }
    }

    private func registerForAudioSessionEvents() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
        sessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildAfterMediaServicesReset()
        })
    }

    private func handleInterruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            stopMIDIClock()
            allNotesOff()
            engine.pause()
            setStatus(.interrupted)
            onPlaybackInterrupted?("Playback paused because audio was interrupted.")
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume) else {
                setStatus(.interrupted)
                return
            }
            do {
                try configureAudioSession()
                _ = startEngineIfNeeded()
            } catch {
                setStatus(.failed(error.localizedDescription))
            }
        @unknown default:
            setStatus(.interrupted)
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        stopMIDIClock()
        allNotesOff()
        onPlaybackInterrupted?("Playback paused because the audio output changed.")
    }

    private func rebuildAfterMediaServicesReset() {
        stopMIDIClock()
        setStatus(.recovering)
        var recordingWasInterrupted = false
        let cancelled = withLock { () -> [(Result<Void, PluginLoadError>) -> Void] in
            engine.stop()
            samplers.removeAll()
            auv3Units.removeAll()
            trackMixers.removeAll()
            suspendCounts.removeAll()
            let completions = loadRequests.values.map(\.completion)
            loadRequests.removeAll()
            engine = AVAudioEngine()
            masterTapInstalled = false
            recordingLock.lock()
            recordingWasInterrupted = recordingFile != nil
            recordingFile = nil
            recordingLock.unlock()
            return completions
        }
        cancelled.forEach { deliver(.failure(.cancelled), to: $0) }
        if recordingWasInterrupted {
            onRecordingError?("The audio system restarted before the recording finished.")
        }

        do {
            try configureAudioSession()
            configureMasterGraph()
            setStatus(.ready)
            onRecoveryRequired?()
        } catch {
            setStatus(.failed(error.localizedDescription))
        }
    }

    func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = volume
    }

    private func installMasterTap() {
        guard !masterTapInstalled else { return }
        let main = engine.mainMixerNode
        guard main.numberOfInputs > 0 else { return }
        var lastLevelTimestamp: Double = 0
        main.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            recordingLock.lock()
            if let file = recordingFile {
                do { try file.write(from: buffer) }
                catch {
                    recordingFile = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onRecordingError?(error.localizedDescription)
                    }
                }
            }
            recordingLock.unlock()
            // Recording (above) is unconditional; metering is throttled and pausable.
            let now = CACurrentMediaTime()
            guard now - lastLevelTimestamp > 0.05 else { return }
            lastLevelTimestamp = now
            guard !self.telemetryPaused else { return }
            self.onMasterLevelUpdate?(self.rms(buffer))
        }
        masterTapInstalled = true
    }

    func startRecording(to url: URL) throws {
        guard masterTapInstalled else { throw AudioRecordingError.unavailable }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecordingError.unavailable
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            recordingLock.lock()
            recordingFile = file
            recordingLock.unlock()
        } catch {
            throw AudioRecordingError.writeFailed(error.localizedDescription)
        }
    }

    func stopRecording() {
        recordingLock.lock()
        recordingFile = nil
        recordingLock.unlock()
    }

    func addTrack(id: UUID, volume: Float = 0.8, pan: Float = 0.0) {
        withLock {
            guard samplers[id] == nil, auv3Units[id] == nil else { return }
            let sampler = AVAudioUnitSampler()
            let mixerNode = AVAudioMixerNode()
            engine.attach(sampler)
            engine.attach(mixerNode)
            // Set volume/pan BEFORE connecting so the node enters the mix at the correct level
            mixerNode.volume = volume
            mixerNode.pan = pan
            engine.connect(sampler, to: mixerNode, format: nil)
            engine.connect(mixerNode, to: engine.mainMixerNode, format: nil)
            loadGMBank(sampler)
            samplers[id] = sampler
            trackMixers[id] = mixerNode
            settledInstruments.insert(id)   // GM sampler is in-process, always safe
            if !engine.isRunning {
                _ = startEngineIfNeeded()
                installMasterTap()
            }
            installLevelTap(id: id, node: mixerNode)
        }
    }

    func hasInstrument(for id: UUID) -> Bool {
        withLock { auv3Units[id] != nil || samplers[id] != nil }
    }

    func removeTrack(id: UUID) {
        var cancelled: ((Result<Void, PluginLoadError>) -> Void)?
        withLock {
            suspendCounts.removeValue(forKey: id)
            settledInstruments.remove(id)
            cancelled = loadRequests.removeValue(forKey: id)?.completion
            if let mixer = trackMixers.removeValue(forKey: id) {
                mixer.removeTap(onBus: 0)
                engine.detach(mixer)
            }
            if let auv3 = auv3Units.removeValue(forKey: id) {
                // No deallocateRenderResources() here either — see retireInstrument.
                engine.detach(auv3)
            }
            if let sampler = samplers.removeValue(forKey: id) {
                engine.detach(sampler)
            }
        }
        if let cancelled { deliver(.failure(.cancelled), to: cancelled) }
    }

    // Swap the instrument on a track. Completion fires only after state restoration or
    // fallback, allowing the UI to reflect real readiness instead of a fixed delay.
    func loadPlugin(_ pluginInfo: PluginInfo?, for trackID: UUID, stateData: Data? = nil,
                    completion: @escaping (Result<Void, PluginLoadError>) -> Void = { _ in }) {
        let requestID = UUID()
        let result: (mixer: AVAudioMixerNode?, cancelled: ((Result<Void, PluginLoadError>) -> Void)?) = withLock {
            let oldCompletion = loadRequests.removeValue(forKey: trackID)?.completion
            // The incoming instrument is unsettled until its settle window completes.
            settledInstruments.remove(trackID)
            guard let mixer = trackMixers[trackID] else { return (nil, oldCompletion) }
            loadRequests[trackID] = PluginLoadRequest(id: requestID, completion: completion)
            return (mixer, oldCompletion)
        }
        if let cancelled = result.cancelled { deliver(.failure(.cancelled), to: cancelled) }
        guard let mixer = result.mixer else {
            deliver(.failure(.trackUnavailable), to: completion)
            return
        }


        // Gate MIDI to this track until the new instrument is attached (and its state
        // restored). Prevents the tick from hitting a half-attached node mid-swap.
        suspendTrack(trackID)

        if let pluginInfo {
            let desc = AudioComponentDescription(
                componentType: pluginInfo.componentType,
                componentSubType: pluginInfo.componentSubType,
                componentManufacturer: pluginInfo.componentManufacturer,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            AVAudioUnit.instantiate(with: desc, options: []) { [weak self] avAudioUnit, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.isCurrentLoad(requestID, for: trackID) else { return }
                    if let unit = avAudioUnit {
                        self.swapInstrument(unit, for: trackID, mixer: mixer)
                        let au = unit.auAudioUnit
                        // A freshly instantiated AUv3 is NOT ready for MIDI yet: its
                        // extension process is still building its DSP. finishPluginLoad
                        // resumes MIDI, so it must never run in the same turn as the
                        // attach. GeoShred segfaults in PerformanceHandler_runMidiEvent
                        // (null handler) ~2 s after its extension launches when a note
                        // arrives that early — which is why loads WITH saved state used
                        // to survive (this delay covered them) while a new track or a
                        // plugin change (state cleared → nil) crashed immediately.
                        // Both paths now settle for the same window before resuming.
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.instrumentSettleDelay) {
                            guard self.isCurrentLoad(requestID, for: trackID) else { return }
                            if let data = stateData {
                                self.applyPluginState(data, for: trackID)
                            }
                            self.finishPluginLoad(requestID, for: trackID, result: .success(()))
                        }
                    } else {
                        let detail = error?.localizedDescription ?? "The Audio Unit returned no instrument."
                        self.attachSampler(for: trackID, mixer: mixer)
                        self.finishPluginLoad(
                            requestID, for: trackID,
                            result: .failure(.instantiationFailed(pluginInfo.name, detail))
                        )
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, isCurrentLoad(requestID, for: trackID) else { return }
                attachSampler(for: trackID, mixer: mixer)
                finishPluginLoad(requestID, for: trackID,
                                 result: .failure(.timedOut(pluginInfo.name)))
            }
        } else {
            attachSampler(for: trackID, mixer: mixer)
            finishPluginLoad(requestID, for: trackID, result: .success(()))
        }
    }

    private func isCurrentLoad(_ requestID: UUID, for trackID: UUID) -> Bool {
        withLock { loadRequests[trackID]?.id == requestID && trackMixers[trackID] != nil }
    }

    private func finishPluginLoad(_ requestID: UUID, for trackID: UUID,
                                  result: Result<Void, PluginLoadError>) {
        let completion = withLock { () -> ((Result<Void, PluginLoadError>) -> Void)? in
            guard loadRequests[trackID]?.id == requestID else { return nil }
            // The settle window has elapsed (or a GM sampler took over, which is
            // in-process and always safe): MIDI, including flushes, may flow again.
            settledInstruments.insert(trackID)
            return loadRequests.removeValue(forKey: trackID)?.completion
        }
        guard let completion else { return }
        resumeTrack(trackID)
        deliver(result, to: completion)
    }

    // Return the live AVAudioUnit for a track (nil if using GM sampler).
    func auv3Unit(for id: UUID) -> AVAudioUnit? { withLock { auv3Units[id] } }

    // Serialise the plugin's current full state (preset + parameters) to Data.
    // Strategy:
    //   1. fullStateForDocument / fullState (non-empty) — standard AUv3 plugins
    //   2. parameterTree values + currentPreset — AudioKit and other plugins that
    //      return nil or an empty dict from fullState
    func getPluginState(for id: UUID) -> Data? {
        withLock { getPluginStateLocked(for: id) }
    }

    /// Read plugin state with the track briefly quiesced — MIDI gated and ringing notes
    /// flushed — so the read can't race an in-flight note-on. Use this for capture.
    /// (Do not call during a plugin load; the load already owns the suspend for that track.)
    func captureState(for id: UUID) -> Data? {
        suspendTrack(id)
        defer { resumeTrack(id) }
        return getPluginState(for: id)
    }

    /// Stable identity of the audio component backing a unit. Saved alongside plugin
    /// state so a blob captured from one plugin is never restored into another.
    private func componentIdentifier(for unit: AVAudioUnit) -> String {
        let d = unit.audioComponentDescription
        return "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)"
    }

    private func getPluginStateLocked(for id: UUID) -> Data? {
        guard let unit = auv3Units[id] else { return nil }
        let au = unit.auAudioUnit

        // Read the document state first; only fall back to fullState if it's absent.
        // Reading BOTH (and re-reading currentPreset) on every save makes the host poke
        // the plugin's state/preset machinery repeatedly, which can crash fragile plugins
        // (GeoShred's extension drops its connection "while in use"). One read is enough.
        let fsd = au.fullStateForDocument
        let isDocument = (fsd != nil)
        let state = fsd ?? au.fullState
        let params = au.parameterTree?.allParameters ?? []

        // Use PropertyListSerialization — handles NSData/NSString/NSNumber/NSDictionary
        // natively without the type-allowlist issues of NSKeyedUnarchiver.
        var combined: [String: Any] = [:]

        let fullStateIsSubstantial: Bool
        if let state, !state.isEmpty {
            combined["_fullState"] = state
            // Record which property the state came from so restore writes back to the
            // SAME one — setting both can corrupt synths that distinguish document state.
            combined["_fullStateIsDocument"] = isDocument
            // A fullState with >5 keys contains real sound data (e.g. EG Pulse pad volumes).
            // ≤5 keys is typically just metadata (e.g. AudioKit's AUPresetName/Version).
            fullStateIsSubstantial = state.count > 5
        } else {
            fullStateIsSubstantial = false
        }

        if !params.isEmpty {
            var paramDict: [String: Double] = [:]
            for p in params { paramDict["\(p.address)"] = Double(p.value) }
            combined["_parameterTree"] = paramDict
        }

        // Tell the restore path whether parameterTree is needed.
        // If fullState is substantial, it is authoritative and parameterTree must not overwrite it.
        combined["_parameterTreeRequired"] = !fullStateIsSubstantial

        // Which plugin this state came from, so restore can reject a foreign blob.
        combined["_componentIdentifier"] = componentIdentifier(for: unit)

        guard !combined.isEmpty else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: combined,
            format: .binary,
            options: 0
        )
    }

    // Restore a previously serialised plugin state.
    func applyPluginState(_ data: Data, for id: UUID) {
        withLock { applyPluginStateLocked(data, for: id) }
    }

    private func applyPluginStateLocked(_ data: Data, for id: UUID) {
        guard let unit = auv3Units[id] else { return }
        let au = unit.auAudioUnit

        // Try plist format first (current), fall back to legacy NSKeyedArchiver format.
        let outer: [String: Any]
        if let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            outer = plist
        } else if let legacy = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSNumber.self, NSData.self],
            from: data) as? [String: Any] {
            outer = legacy
        } else {
            return
        }

        // Never restore a blob captured from a DIFFERENT plugin. Songs saved while the
        // instrument-swap bug was live paired a new plugin with the old plugin's state;
        // writing that foreign fullState / parameter addresses can leave the synth
        // silent. Skipping leaves the plugin at its own defaults, and the next capture
        // overwrites the bad blob. Legacy saves have no identifier → applied as before.
        if let saved = outer["_componentIdentifier"] as? String,
           saved != componentIdentifier(for: unit) {
            return
        }

        // Apply fullState — authoritative for plugins like EG Pulse that store all
        // sound data here (pad volumes, patterns, etc.).
        if let state = outer["_fullState"] as? [String: Any] {
            // Restore to the SAME property the state was captured from. Writing both
            // can corrupt complex synths (GeoShred). Legacy saves (no flag) fall back
            // to the old set-both behaviour for compatibility.
            if let isDocument = outer["_fullStateIsDocument"] as? Bool {
                if isDocument {
                    au.fullStateForDocument = state
                } else {
                    au.fullState = state
                }
            } else {
                au.fullStateForDocument = state
                au.fullState = state
            }
        }

        // Only apply parameterTree when flagged as required (AudioKit-style plugins
        // where fullState is sparse metadata and the tree holds the real sound state).
        // Skipping this for plugins with substantial fullState prevents the tree from
        // overwriting values that fullState already restored correctly.
        let paramTreeRequired = outer["_parameterTreeRequired"] as? Bool ?? true
        if paramTreeRequired,
           let paramDict = outer["_parameterTree"] as? [String: Double],
           let tree = au.parameterTree {
            for p in tree.allParameters {
                if let value = paramDict["\(p.address)"] { p.value = AUValue(value) }
            }
        }
    }

    /// Remove whatever instrument currently feeds `mixer` for this track.
    ///
    /// An AUv3 is disconnected and detached, and released synchronously.
    ///
    /// Deliberately does NOT call `deallocateRenderResources()` on the outgoing unit.
    /// Tearing an out-of-process AU's render resources down immediately before another
    /// is instantiated left the INCOMING plugin's hosted view blank: swapping
    /// instrument -> GeoShred failed every time, while GeoShred on a fresh track — which
    /// retires only the in-process GM sampler below — always worked. Build 13, the last
    /// known-good build, never called it either.
    ///
    /// Nor is the release deferred to "outlive the render cycle": that overlaps the
    /// outgoing instance with the incoming one, which broke loading in its own right.
    private func retireInstrument(for trackID: UUID, mixer: AVAudioMixerNode) {
        settledInstruments.remove(trackID)
        if let auv3 = auv3Units.removeValue(forKey: trackID) {
            engine.disconnectNodeInput(mixer)
            engine.detach(auv3)
        } else if let sampler = samplers.removeValue(forKey: trackID) {
            engine.disconnectNodeInput(mixer)
            engine.detach(sampler)
        }
    }

    private func swapInstrument(_ newUnit: AVAudioUnit, for trackID: UUID, mixer: AVAudioMixerNode) {
        withLock {
            retireInstrument(for: trackID, mixer: mixer)
            engine.attach(newUnit)
            engine.connect(newUnit, to: mixer, format: nil)
            auv3Units[trackID] = newUnit
            _ = startEngineIfNeeded()
        }
    }

    private func attachSampler(for trackID: UUID, mixer: AVAudioMixerNode) {
        withLock {
            retireInstrument(for: trackID, mixer: mixer)
            let sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: mixer, format: nil)
            loadGMBank(sampler)
            samplers[trackID] = sampler
            _ = startEngineIfNeeded()
        }
    }

    private func installLevelTap(id: UUID, node: AVAudioMixerNode) {
        var lastLevelTimestamp: Double = 0
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            // Throttle FIRST: rms() walks every sample, and this ran on the audio thread
            // for every buffer even though the result is used 20×/sec.
            let now = CACurrentMediaTime()
            guard now - lastLevelTimestamp > 0.05 else { return }
            lastLevelTimestamp = now
            guard !self.telemetryPaused else { return }
            self.onLevelUpdate?(id, self.rms(buffer))
        }
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        let channels = max(1, Int(buffer.format.channelCount))
        for channel in 0..<channels {
            for i in 0..<count { sum += data[channel][i] * data[channel][i] }
        }
        return min(1.0, sqrt(sum / Float(count * channels)) * 8)
    }

    private func loadGMBank(_ sampler: AVAudioUnitSampler) {
        // Locate the DLS file via the CoreAudio bundle rather than a hardcoded path
        if let bundle = Bundle(identifier: "com.apple.audio.CoreAudio"),
           let url = bundle.url(forResource: "gs_instruments", withExtension: "dls") {
            try? sampler.loadSoundBankInstrument(at: url, program: 0, bankMSB: 0x79, bankLSB: 0)
            return
        }
        // Fallback: let the sampler use whatever default sounds it has built in
    }

    func playNote(trackID: UUID, midiNote: UInt8, velocity: UInt8) {
        withLock {
            guard !isSuspended(trackID) else { return }
            activeNotes[trackID, default: []].insert(midiNote)
            if let unit = auv3Units[trackID] {
                sendMIDI(to: unit, bytes: [0x90, midiNote, velocity])
            } else {
                samplers[trackID]?.startNote(midiNote, withVelocity: velocity, onChannel: 0)
            }
        }
    }

    func stopNote(trackID: UUID, midiNote: UInt8) {
        withLock {
            // Note-offs are gated too. A note-off is still a MIDI event: delivering one
            // to a plugin that isn't ready crashes it exactly like a note-on (GeoShred
            // segfaults in PerformanceHandler_runMidiEvent on a null handler). Nothing
            // hangs, because suspendTrack() flushes all notes with a direct all-notes-off
            // before the gate closes, and the unit is silent for the whole window.
            guard !isSuspended(trackID) else { return }
            activeNotes[trackID]?.remove(midiNote)
            if let unit = auv3Units[trackID] {
                sendMIDI(to: unit, bytes: [0x80, midiNote, 0])
            } else {
                samplers[trackID]?.stopNote(midiNote, onChannel: 0)
            }
        }
    }

    private func sendMIDI(to unit: AVAudioUnit, bytes: [UInt8]) {
        let au = unit.auAudioUnit
        if let legacyBlock = au.scheduleMIDIEventBlock {
            bytes.withUnsafeBytes { ptr in
                guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
                legacyBlock(AUEventSampleTimeImmediate, 0, bytes.count, base)
            }
        } else if #available(iOS 15.0, *), let listBlock = au.scheduleMIDIEventListBlock {
            sendMIDIList(to: listBlock, bytes: bytes)
        } else {
            print("[FWD] No MIDI block available for \(au.audioUnitName ?? "unknown")")
        }
    }

    @available(iOS 15.0, *)
    private func sendMIDIList(to block: AUMIDIEventListBlock, bytes: [UInt8]) {
        let status = bytes[0]
        let d1 = bytes.count > 1 ? bytes[1] : 0
        let d2 = bytes.count > 2 ? bytes[2] : 0
        // Encode as MIDI 1.0 Universal MIDI Packet:
        // bits[31-28] = 0x2 (MIDI 1.0 channel voice), [23-16] = status, [15-8] = data1, [7-0] = data2
        var word = (UInt32(0x2) << 28) | (UInt32(status) << 16) | (UInt32(d1) << 8) | UInt32(d2)
        // Allocate a raw buffer large enough for MIDIEventList + one packet
        let bufSize = 256
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }
        let listPtr = buf.bindMemory(to: MIDIEventList.self, capacity: 1)
        let pktPtr = MIDIEventListInit(listPtr, MIDIProtocolID._1_0)
        _ = MIDIEventListAdd(listPtr, bufSize, pktPtr, 0, 1, &word)
        _ = block(AUEventSampleTimeImmediate, 0, listPtr)
    }

    func allNotesOff() {
        withLock {
            // Only settled AUv3s are addressed — an unsettled one has no ringing notes
            // (its MIDI was gated) and would crash on the flush. See settledInstruments.
            // Release only notes we started; a 0...127 sweep is 129 events per plugin.
            for (id, notes) in activeNotes {
                guard !notes.isEmpty else { continue }
                if let unit = auv3Units[id] {
                    guard settledInstruments.contains(id) else { continue }
                    for n in notes { sendMIDI(to: unit, bytes: [0x80, n, 0]) }
                } else if let sampler = samplers[id] {
                    for n in notes { sampler.stopNote(n, onChannel: 0) }
                }
            }
            activeNotes.removeAll()
            // CC123 as a genuine panic broadcast, to settled units only.
            for (id, unit) in auv3Units where settledInstruments.contains(id) {
                sendMIDI(to: unit, bytes: [0xB0, 123, 0])
            }
        }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        withLock { trackMixers[id]?.volume = volume }
    }

    func setPan(_ pan: Float, for id: UUID) {
        withLock { trackMixers[id]?.pan = pan }
    }
}
