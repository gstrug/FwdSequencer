// One-off diagnostic (not part of the app): renders General MIDI sounds from
// GeneralUser GS through AVAudioUnitSampler offline, with note patterns like the
// parts of a dense imported song, and reports moments where notes are held but the
// sampler is silent (dropped voices), plus render cost.
import AVFoundation
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let sf2 = URL(fileURLWithPath: CommandLine.arguments[1])
let sampleRate = 44_100.0
let tempo = 100.0
let beat = 60.0 / tempo

struct Note { var start: Double; var end: Double; var pitch: UInt8; var velocity: UInt8 }

func chords(_ voicing: [UInt8], every: Double, length: Double, bars: Int) -> [Note] {
    var notes: [Note] = []
    var t = 0.0
    let roots: [UInt8] = [0, 5, 7, 3]
    var i = 0
    while t < Double(bars) * 4 * beat {
        let shift = roots[(i / max(1, Int(4 / every))) % roots.count]
        for p in voicing { notes.append(Note(start: t, end: t + length * beat, pitch: p + shift, velocity: 96)) }
        t += every * beat; i += 1
    }
    return notes
}

let scenarios: [(String, Int, [Note])] = [
    ("Grand Piano: ONE note, C4, velocity 64, 2 s", 0, [Note(start: 0, end: 2, pitch: 60, velocity: 64)]),
    ("Pad 7 (halo): 6-note chords held a bar", 94, chords([48, 55, 60, 64, 67, 72], every: 4, length: 4, bars: 16)),
    ("Pad 3 (polysynth): 6-note chords on quarters", 90, chords([48, 55, 60, 64, 67, 72], every: 1, length: 1, bars: 16)),
    ("String Ensemble 1: 4-note chords held a bar", 48, chords([48, 55, 64, 67], every: 4, length: 4, bars: 16)),
    ("Choir Aahs: 4-note chords on halves", 52, chords([52, 55, 60, 64], every: 2, length: 2, bars: 16)),
    ("Banjo: 5-note chords on every 16th", 105, chords([55, 62, 67, 71, 74], every: 0.25, length: 0.25, bars: 16)),
    ("Bright Piano: 4-note chords on 8ths", 1, chords([60, 64, 67, 72], every: 0.5, length: 0.5, bars: 16)),
    ("Electric Bass (finger): single 8ths", 33, chords([36], every: 0.5, length: 0.45, bars: 16)),
    ("BASELINE Grand Piano: 6-note chords held a bar", 0, chords([48, 55, 60, 64, 67, 72], every: 4, length: 4, bars: 16)),
    ("BASELINE Grand Piano: 5-note chords on every 16th", 0, chords([55, 62, 67, 71, 74], every: 0.25, length: 0.25, bars: 16)),
]

func render(program: Int, notes: [Note]) throws -> (dropouts: [(Double, Double)], heldSeconds: Double, renderRatio: Double) {
    let engine = AVAudioEngine()
    let sampler = AVAudioUnitSampler()
    engine.attach(sampler)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    engine.connect(sampler, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try engine.start()
    try sampler.loadSoundBankInstrument(at: sf2, program: UInt8(program == 128 ? 0 : program), bankMSB: program == 128 ? 0x78 : 0x79, bankLSB: 0)
    if let cap = ProcessInfo.processInfo.environment["VOICES"].flatMap(Int.init),
       var state = sampler.auAudioUnit.fullState {
        state["voice count"] = cap
        sampler.auAudioUnit.fullState = state
        print("voice count now", sampler.auAudioUnit.fullState?["voice count"] ?? "?")
    }
    if program == 94, let state = sampler.auAudioUnit.fullState {
        func walk(_ value: Any, _ path: String) {
            if let d = value as? [String: Any] { for (k, v) in d { walk(v, path + "/" + k) } }
            else if let a = value as? [Any] { for (i, v) in a.prefix(3).enumerated() { walk(v, path + "[\(i)]") } }
            else if path.lowercased().contains("voice") || path.lowercased().contains("poly") { print("state\(path) = \(value)") }
        }
        walk(state, "")
    }

    struct Event { var time: Double; var on: Bool; var note: Note }
    var events = notes.flatMap { [Event(time: $0.start, on: true, note: $0), Event(time: $0.end, on: false, note: $0)] }
    events.sort { ($0.time, $0.on ? 1 : 0) < ($1.time, $1.on ? 1 : 0) }
    let total = (notes.map(\.end).max() ?? 0) + 2
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    var t = 0.0, next = 0
    var dropouts: [(Double, Double)] = []
    var runStart: Double?
    var held = 0.0
    let clock = Date()
    while t < total {
        let end = t + 512 / sampleRate
        while next < events.count && events[next].time < end {
            let e = events[next]
            if e.on { sampler.startNote(e.note.pitch, withVelocity: e.note.velocity, onChannel: 0) }
            else { sampler.stopNote(e.note.pitch, onChannel: 0) }
            next += 1
        }
        _ = try engine.renderOffline(512, to: buffer)
        var sum: Float = 0
        let n = Int(buffer.frameLength)
        for c in 0..<2 { let d = buffer.floatChannelData![c]; for i in 0..<n { sum += d[i] * d[i] } }
        let rms = sqrt(sum / Float(max(1, n * 2)))
        // Held, past its attack: a note started at least 80 ms ago and not yet released.
        let holding = notes.contains { $0.start + 0.08 <= t && end <= $0.end }
        if holding {
            held += end - t
            if rms < 0.0005 {             // below about -66 dBFS: effectively silent
                if runStart == nil { runStart = t }
            } else if let s = runStart { if t - s >= 0.05 { dropouts.append((s, t)) }; runStart = nil }
        } else if let s = runStart { if t - s >= 0.05 { dropouts.append((s, t)) }; runStart = nil }
        t = end
    }
    let elapsed = Date().timeIntervalSince(clock)
    engine.stop()
    return (dropouts, held, elapsed / total)
}

// "sweep N": program N (128 = drum kit) with 4-note chords on 8ths for 8 bars.
if CommandLine.arguments.count > 3, CommandLine.arguments[2] == "sweep", let n = Int(CommandLine.arguments[3]) {
    let notes = chords([48, 55, 60, 64], every: 0.5, length: 0.5, bars: 8)
    let r = try render(program: n, notes: notes)
    let silent = r.dropouts.reduce(0) { $0 + $1.1 - $1.0 }
    print(String(format: "%3d cost %5.1f%%  silent %4.1f%%", n, r.renderRatio * 100,
                 r.heldSeconds > 0 ? silent / r.heldSeconds * 100 : 0))
    exit(0)
}
// "record N out.caf": a short phrase on program N (128 = drum kit) to an audio file.
if CommandLine.arguments.count > 4, CommandLine.arguments[2] == "record", let n = Int(CommandLine.arguments[3]) {
    let out = URL(fileURLWithPath: CommandLine.arguments[4])
    let engine = AVAudioEngine()
    let sampler = AVAudioUnitSampler()
    engine.attach(sampler)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    engine.connect(sampler, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try engine.start()
    try sampler.loadSoundBankInstrument(at: sf2, program: UInt8(n == 128 ? 0 : n),
                                        bankMSB: n == 128 ? 0x78 : 0x79, bankLSB: 0)
    var phrase: [Note] = []
    if n == 128 {
        let hits: [(Double, UInt8)] = [(0, 36), (0, 42), (0.25, 42), (0.5, 38), (0.5, 42), (0.75, 42),
                                       (1.0, 36), (1.0, 42), (1.25, 36), (1.25, 42), (1.5, 38), (1.5, 42),
                                       (1.75, 46), (2.0, 49), (2.0, 36)]
        phrase = hits.map { Note(start: $0.0 * beat * 2, end: $0.0 * beat * 2 + 0.2, pitch: $0.1, velocity: 100) }
    } else {
        let base: UInt8 = (32...39).contains(n) ? 36 : 60     // basses an octave down
        for (i, step) in [0, 4, 7, 12].enumerated() {
            phrase.append(Note(start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.35, pitch: base + UInt8(step), velocity: 96))
        }
        for step in [0, 4, 7] as [UInt8] {
            phrase.append(Note(start: 1.7, end: 3.0, pitch: base + 12 + step, velocity: 96))
        }
    }
    let file = try AVAudioFile(forWriting: out, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    struct E { var t: Double; var on: Bool; var p: UInt8; var v: UInt8 }
    var events = phrase.flatMap { [E(t: $0.start, on: true, p: $0.pitch, v: $0.velocity), E(t: $0.end, on: false, p: $0.pitch, v: 0)] }
    events.sort { ($0.t, $0.on ? 1 : 0) < ($1.t, $1.on ? 1 : 0) }
    var t = 0.0, next = 0
    while t < 4.2 {
        let end = t + 512 / sampleRate
        while next < events.count && events[next].t < end {
            let e = events[next]
            if e.on { sampler.startNote(e.p, withVelocity: e.v, onChannel: 0) } else { sampler.stopNote(e.p, onChannel: 0) }
            next += 1
        }
        _ = try engine.renderOffline(512, to: buffer)
        try file.write(from: buffer)
        t = end
    }
    exit(0)
}
let only = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : nil
for (index, (name, program, notes)) in scenarios.enumerated() where only == nil || only == index {
    let r = try render(program: program, notes: notes)
    let silent = r.dropouts.reduce(0) { $0 + $1.1 - $1.0 }
    let pct = r.heldSeconds > 0 ? silent / r.heldSeconds * 100 : 0
    print(String(format: "%-52@ notes %4d  silent while held: %5.1f%% (%d gaps)  render cost %.1f%% of real time",
                 name as NSString, notes.count, pct, r.dropouts.count, r.renderRatio * 100))
    for g in r.dropouts.prefix(3) { print(String(format: "      gap %.2fs–%.2fs", g.0, g.1)) }
}
