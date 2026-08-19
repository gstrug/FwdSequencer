import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Formats a master recording can be exported as.
///
/// Recording always captures to CAF at the engine's own 32-bit float format: float
/// cannot clip, so the take is preserved exactly however hot the mix ran. WAV is
/// produced by converting at export time.
nonisolated enum RecordingFormat: String, CaseIterable, Identifiable {
    case wav
    case caf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wav: return "WAV (24-bit)"
        case .caf: return "CAF (32-bit float)"
        }
    }

    var detail: String {
        switch self {
        case .wav: return "Opens anywhere. Levels above 0 dBFS are clipped."
        case .caf: return "Exact capture, no clipping. Fewer apps read it."
        }
    }

    var contentType: UTType {
        switch self {
        case .wav: return .wav
        case .caf: return .coreAudioRecording
        }
    }

    var fileExtension: String { rawValue }
}

/// Result of preparing a recording for export.
struct PreparedRecording {
    let data: Data
    /// True when converting to a fixed-point format had to clamp samples beyond
    /// ±1.0. The float source is unaffected; only the exported file is.
    let didClip: Bool
    /// Loudest sample in the take, in dBFS. Above 0 means the mix exceeded full scale.
    let peakDBFS: Float
}

enum RecordingExporter {

    /// Read a recorded CAF and produce the bytes for the requested export format.
    static func prepare(_ source: URL, as format: RecordingFormat) throws -> PreparedRecording {
        let input = try AVAudioFile(forReading: source)
        let peak = try peakAmplitude(of: input)
        let peakDB = peak > 0 ? 20 * log10(peak) : -Float.infinity

        switch format {
        case .caf:
            // Already the recorded format — hand the bytes over untouched.
            return PreparedRecording(data: try Data(contentsOf: source),
                                     didClip: false,
                                     peakDBFS: peakDB)
        case .wav:
            let data = try convertToWAV(source)
            return PreparedRecording(data: data, didClip: peak > 1.0, peakDBFS: peakDB)
        }
    }

    /// Loudest absolute sample in the file, scanned without loading it all at once.
    private static func peakAmplitude(of file: AVAudioFile) throws -> Float {
        file.framePosition = 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: 8192) else { return 0 }
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channels = buffer.floatChannelData else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for i in 0..<frames { peak = max(peak, abs(channels[channel][i])) }
            }
        }
        file.framePosition = 0
        return peak
    }

    /// 24-bit integer PCM — the usual delivery format, readable by anything.
    private static func convertToWAV(_ source: URL) throws -> Data {
        let input = try AVAudioFile(forReading: source)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("FWD-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: destination) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: input.fileFormat.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: 8192) else {
            throw AudioRecordingError.writeFailed("Could not allocate a conversion buffer.")
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)   // AVAudioFile converts float -> 24-bit here
        }
        return try Data(contentsOf: destination)
    }
}
