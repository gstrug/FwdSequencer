// One-off diagnostic (not part of the app): does the built-in sampler keep its General
// MIDI sound when an effect is wired in after it, the way AudioEngineManager does it?
// Renders one note before, with the effect in, with it removed again, and after the
// sound is loaded again, and reports how bright each is. A plain sine tone has almost
// no brightness; a piano has plenty.
import AVFoundation
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let sf2 = URL(fileURLWithPath: CommandLine.arguments[1])
let sampleRate = 44_100.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

func report(_ text: String) { print("::notice::\(text)") }

func run(program: UInt8, reconnectOnly: Bool) throws {
    let engine = AVAudioEngine()
    let sampler = AVAudioUnitSampler()
    let trackMixer = AVAudioMixerNode()
    engine.attach(sampler)
    engine.attach(trackMixer)
    engine.connect(sampler, to: trackMixer, format: nil)
    engine.connect(trackMixer, to: engine.mainMixerNode, format: nil)
    try sampler.loadSoundBankInstrument(at: sf2, program: program, bankMSB: 0x79, bankLSB: 0)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try engine.start()

    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!

    /// Play C4 for a second and return (level, brightness).
    func measure() throws -> (Double, Double) {
        var sum = 0.0, diffSum = 0.0, last: Float = 0
        sampler.startNote(60, withVelocity: 100, onChannel: 0)
        let frames = Int(sampleRate)
        var done = 0
        while done < frames {
            _ = try engine.renderOffline(512, to: buffer)
            let n = Int(buffer.frameLength)
            if let data = buffer.floatChannelData {
                for i in 0..<n {
                    let s = data[0][i]
                    sum += Double(s * s)
                    let d = s - last
                    diffSum += Double(d * d)
                    last = s
                }
            }
            done += max(n, 1)
        }
        sampler.stopNote(60, onChannel: 0)
        // Let the release ring out so the next measurement starts clean.
        for _ in 0..<170 { _ = try engine.renderOffline(512, to: buffer) }
        let level = (sum / Double(frames)).squareRoot()
        return (level, sum > 0 ? diffSum / sum : 0)
    }

    func show(_ label: String) throws {
        let (level, brightness) = try measure()
        report(String(format: "program %d %@ | %@: level %.4f brightness %.5f",
                      Int(program), reconnectOnly ? "(reconnect only)" : "(delay effect)",
                      label, level, brightness))
    }

    try show("1 as loaded")

    let effect = AVAudioUnitDelay()
    effect.wetDryMix = 0          // dry: the effect itself must not colour the result
    if reconnectOnly {
        // Just the unwiring and rewiring, with no effect at all.
        engine.disconnectNodeInput(trackMixer)
        engine.disconnectNodeOutput(sampler)
        engine.connect(sampler, to: trackMixer, format: nil)
    } else {
        engine.attach(effect)
        engine.disconnectNodeInput(trackMixer)
        engine.disconnectNodeInput(effect)
        engine.disconnectNodeOutput(effect)
        engine.disconnectNodeOutput(sampler)
        engine.connect(sampler, to: effect, format: nil)
        let input = effect.inputFormat(forBus: 0)
        engine.connect(effect, to: trackMixer,
                       format: AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 2))
    }
    if !engine.isRunning { report("engine stopped by rewiring; restarting"); try engine.start() }
    try show("2 after wiring")

    if !reconnectOnly {
        engine.disconnectNodeOutput(effect)
        engine.detach(effect)
        engine.disconnectNodeInput(trackMixer)
        engine.disconnectNodeOutput(sampler)
        engine.connect(sampler, to: trackMixer, format: nil)
        if !engine.isRunning { report("engine stopped by removal; restarting"); try engine.start() }
        try show("3 effect removed")
    }

    try sampler.loadSoundBankInstrument(at: sf2, program: program, bankMSB: 0x79, bankLSB: 0)
    try show("4 sound loaded again")
    engine.stop()
}

for program: UInt8 in [0, 48] {
    for reconnectOnly in [false, true] {
        do { try run(program: program, reconnectOnly: reconnectOnly) }
        catch { report("program \(program) failed: \(error)") }
    }
}
