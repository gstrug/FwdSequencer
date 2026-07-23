import AVFoundation
import AudioToolbox
import Combine

/// Scans the device for installed AUv3 instrument plugins.
class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published var instruments: [PluginInfo] = []
    @Published var isScanning = false

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioUnitComponentTagsDidChange,
            object: AVAudioUnitComponentManager.shared(),
            queue: .main
        ) { [weak self] _ in
            self?.performScan()
        }
        _ = AVAudioUnitComponentManager.shared()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func scan() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.performScan()
        }
    }

    private func performScan() {
        var seen = Set<String>()
        var results: [PluginInfo] = []

        // Instruments only: kAudioUnitType_MusicDevice = 0x61756D75 ("aumu")
        let instrDesc = AudioComponentDescription(
            componentType: 0x61756D75, componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0
        )
        for c in AVAudioUnitComponentManager.shared().components(matching: instrDesc) {
            let key = makeKey(c.audioComponentDescription)
            guard seen.insert(key).inserted else { continue }
            results.append(makeInfo(c))
        }

        let sorted = results.sorted { $0.name < $1.name }
        DispatchQueue.main.async { [weak self] in
            self?.instruments = sorted
            self?.isScanning = false
        }
    }

    private func makeKey(_ d: AudioComponentDescription) -> String {
        "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)"
    }

    private func makeInfo(_ c: AVAudioUnitComponent) -> PluginInfo {
        PluginInfo(
            name: c.name,
            manufacturerName: c.manufacturerName,
            componentType: c.audioComponentDescription.componentType,
            componentSubType: c.audioComponentDescription.componentSubType,
            componentManufacturer: c.audioComponentDescription.componentManufacturer
        )
    }
}
