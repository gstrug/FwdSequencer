import Foundation
import AVFoundation
import AudioToolbox
import CoreMIDI

class AudioEngineManager {
    // One shared audio engine / session for the whole app. Pattern playback and
    // song playback both route through it (only one document plays at a time).
    static let shared = AudioEngineManager()

    private let engine = AVAudioEngine()
    private var samplers: [UUID: AVAudioUnitSampler] = [:]
    private var auv3Units: [UUID: AVAudioUnit] = [:]
    private var trackMixers: [UUID: AVAudioMixerNode] = [:]
    private var levelTimestamps: [UUID: Double] = [:]

    var onLevelUpdate: ((UUID, Float) -> Void)?
    var onMasterLevelUpdate: ((Float) -> Void)?
    private var masterLevelTimestamp: Double = 0

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP]
        )
        // Give the render callback more time per buffer. The device default is small,
        // and hosting CPU-heavy sampled instruments (e.g. Ravenscroft piano) can overrun
        // it — producing crackle/dropouts even at low levels (distinct from clipping).
        try? session.setPreferredIOBufferDuration(0.011)
        try? session.setActive(true)
    }

    func setMasterVolume(_ volume: Float) {
        engine.mainMixerNode.outputVolume = volume
    }

    private func installMasterTap() {
        let main = engine.mainMixerNode
        guard main.numberOfInputs > 0 else { return }
        main.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let level = self.rms(buffer)
            let now = CACurrentMediaTime()
            guard now - self.masterLevelTimestamp > 0.05 else { return }
            self.masterLevelTimestamp = now
            self.onMasterLevelUpdate?(level)
        }
    }

    func addTrack(id: UUID, volume: Float = 0.8, pan: Float = 0.0) {
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
        if !engine.isRunning {
            try? engine.start()
            installMasterTap()
        }
        installLevelTap(id: id, node: mixerNode)
    }

    func hasInstrument(for id: UUID) -> Bool {
        auv3Units[id] != nil || samplers[id] != nil
    }

    func removeTrack(id: UUID) {
        if let mixer = trackMixers.removeValue(forKey: id) {
            mixer.removeTap(onBus: 0)
            engine.detach(mixer)
        }
        if let auv3 = auv3Units.removeValue(forKey: id) {
            engine.detach(auv3)
        }
        if let sampler = samplers.removeValue(forKey: id) {
            engine.detach(sampler)
        }
    }

    // Swap the instrument on a track. Pass saved stateData to restore a preset.
    func loadPlugin(_ pluginInfo: PluginInfo?, for trackID: UUID, stateData: Data? = nil) {
        guard let mixer = trackMixers[trackID] else { return }

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
                if let unit = avAudioUnit {
                    DispatchQueue.main.async {
                        self.swapInstrument(unit, for: trackID, mixer: mixer)
                        // Delay state restore slightly — many AUv3 plugins need a run-loop
                        // cycle to finish initialising before they accept fullState/fullStateForDocument.
                        if let data = stateData {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                self.applyPluginState(data, for: trackID)
                            }
                        }
                    }
                } else {
                    print("[FWD] Plugin failed to load: \(pluginInfo.name) error: \(String(describing: error))")
                    DispatchQueue.main.async { self.attachSampler(for: trackID, mixer: mixer) }
                }
            }
        } else {
            attachSampler(for: trackID, mixer: mixer)
        }
    }

    // Return the live AVAudioUnit for a track (nil if using GM sampler).
    func auv3Unit(for id: UUID) -> AVAudioUnit? { auv3Units[id] }

    // Serialise the plugin's current full state (preset + parameters) to Data.
    // Strategy:
    //   1. fullStateForDocument / fullState (non-empty) — standard AUv3 plugins
    //   2. parameterTree values + currentPreset — AudioKit and other plugins that
    //      return nil or an empty dict from fullState
    func getPluginState(for id: UUID) -> Data? {
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

        guard !combined.isEmpty else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: combined,
            format: .binary,
            options: 0
        )
    }

    // Restore a previously serialised plugin state.
    func applyPluginState(_ data: Data, for id: UUID) {
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

    private func swapInstrument(_ newUnit: AVAudioUnit, for trackID: UUID, mixer: AVAudioMixerNode) {
        if let auv3 = auv3Units.removeValue(forKey: trackID) {
            engine.disconnectNodeInput(mixer)
            engine.detach(auv3)
        } else if let sampler = samplers.removeValue(forKey: trackID) {
            engine.disconnectNodeInput(mixer)
            engine.detach(sampler)
        }
        engine.attach(newUnit)
        engine.connect(newUnit, to: mixer, format: nil)
        auv3Units[trackID] = newUnit
        if !engine.isRunning { try? engine.start() }
    }

    private func attachSampler(for trackID: UUID, mixer: AVAudioMixerNode) {
        if let auv3 = auv3Units.removeValue(forKey: trackID) {
            engine.disconnectNodeInput(mixer)
            engine.detach(auv3)
        } else if let sampler = samplers.removeValue(forKey: trackID) {
            engine.disconnectNodeInput(mixer)
            engine.detach(sampler)
        }
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: mixer, format: nil)
        loadGMBank(sampler)
        samplers[trackID] = sampler
        if !engine.isRunning { try? engine.start() }
    }

    private func installLevelTap(id: UUID, node: AVAudioMixerNode) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let level = self.rms(buffer)
            let now = CACurrentMediaTime()
            guard now - (self.levelTimestamps[id] ?? 0) > 0.05 else { return }
            self.levelTimestamps[id] = now
            self.onLevelUpdate?(id, level)
        }
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[0][i] * data[0][i] }
        return min(1.0, sqrt(sum / Float(count)) * 8)
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
        if let unit = auv3Units[trackID] {
            sendMIDI(to: unit, bytes: [0x90, midiNote, velocity])
        } else {
            samplers[trackID]?.startNote(midiNote, withVelocity: velocity, onChannel: 0)
        }
    }

    func stopNote(trackID: UUID, midiNote: UInt8) {
        if let unit = auv3Units[trackID] {
            sendMIDI(to: unit, bytes: [0x80, midiNote, 0])
        } else {
            samplers[trackID]?.stopNote(midiNote, onChannel: 0)
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
        block(AUEventSampleTimeImmediate, 0, listPtr)
    }

    func allNotesOff() {
        for note in 0...127 {
            let midi = UInt8(note)
            for (id, _) in samplers {
                samplers[id]?.stopNote(midi, onChannel: 0)
            }
            for (_, unit) in auv3Units {
                sendMIDI(to: unit, bytes: [0x80, midi, 0])
            }
        }
        // Also send All Notes Off CC (123) to AUv3 units
        for (_, unit) in auv3Units {
            sendMIDI(to: unit, bytes: [0xB0, 123, 0])
        }
    }

    func setVolume(_ volume: Float, for id: UUID) {
        trackMixers[id]?.volume = volume
    }

    func setPan(_ pan: Float, for id: UUID) {
        trackMixers[id]?.pan = pan
    }
}
