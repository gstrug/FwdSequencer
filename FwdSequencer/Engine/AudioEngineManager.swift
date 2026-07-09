import Foundation
import AVFoundation

class AudioEngineManager {
    private let engine = AVAudioEngine()
    private var samplers: [UUID: AVAudioUnitSampler] = [:]
    private var trackMixers: [UUID: AVAudioMixerNode] = [:]
    private var levelTimestamps: [UUID: Double] = [:]

    var onLevelUpdate: ((UUID, Float) -> Void)?
    var onMasterLevelUpdate: ((Float) -> Void)?
    private var masterLevelTimestamp: Double = 0

    init() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
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

    func addTrack(id: UUID) {
        guard samplers[id] == nil else { return }
        let sampler = AVAudioUnitSampler()
        let mixerNode = AVAudioMixerNode()
        engine.attach(sampler)
        engine.attach(mixerNode)
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

    func removeTrack(id: UUID) {
        if let mixer = trackMixers.removeValue(forKey: id) {
            mixer.removeTap(onBus: 0)
            engine.detach(mixer)
        }
        if let sampler = samplers.removeValue(forKey: id) {
            engine.detach(sampler)
        }
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
        samplers[trackID]?.startNote(midiNote, withVelocity: velocity, onChannel: 0)
    }

    func stopNote(trackID: UUID, midiNote: UInt8) {
        samplers[trackID]?.stopNote(midiNote, onChannel: 0)
    }

    func setVolume(_ volume: Float, for id: UUID) {
        trackMixers[id]?.volume = volume
    }

    func setPan(_ pan: Float, for id: UUID) {
        trackMixers[id]?.pan = pan
    }
}
