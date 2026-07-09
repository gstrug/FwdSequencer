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
        // Start manager early and observe when its registry updates
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioUnitComponentTagsDidChange,
            object: AVAudioUnitComponentManager.shared(),
            queue: .main
        ) { [weak self] _ in
            self?.performScan()
        }
        // Warm up the shared manager so discovery starts immediately
        _ = AVAudioUnitComponentManager.shared()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func scan() {
        isScanning = true
        // Small delay to let the async registry populate before we read it
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.performScan()
        }
    }

    private func performScan() {
        // Try both AVAudioUnitComponentManager and CoreAudio low-level enumeration
        // and merge results so we catch everything regardless of how it is registered
        var seen = Set<String>()
        var results: [PluginInfo] = []

        // Method 1: AVAudioUnitComponentManager (handles AUv3 extensions)
        let managed = AVAudioUnitComponentManager.shared().components { _, _ in true }
        for c in managed {
            let key = "\(c.audioComponentDescription.componentType)-\(c.audioComponentDescription.componentSubType)-\(c.audioComponentDescription.componentManufacturer)"
            guard seen.insert(key).inserted else { continue }
            results.append(PluginInfo(
                name: c.name,
                manufacturerName: "\(c.manufacturerName) [mgr]",
                componentType: c.audioComponentDescription.componentType,
                componentSubType: c.audioComponentDescription.componentSubType,
                componentManufacturer: c.audioComponentDescription.componentManufacturer
            ))
        }

        // Method 2: CoreAudio AudioComponentFindNext (catches v1/v2 and some v3)
        var desc = AudioComponentDescription(
            componentType: 0, componentSubType: 0,
            componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0
        )
        var comp = AudioComponentFindNext(nil, &desc)
        while let c = comp {
            var cd = AudioComponentDescription()
            AudioComponentGetDescription(c, &cd)
            let key = "\(cd.componentType)-\(cd.componentSubType)-\(cd.componentManufacturer)"
            if seen.insert(key).inserted {
                var nameRef: Unmanaged<CFString>?
                AudioComponentCopyName(c, &nameRef)
                let name = nameRef?.takeRetainedValue() as String? ?? "Unknown"
                results.append(PluginInfo(
                    name: name,
                    manufacturerName: "type: \(String(format: "0x%08X", cd.componentType)) [ca]",
                    componentType: cd.componentType,
                    componentSubType: cd.componentSubType,
                    componentManufacturer: cd.componentManufacturer
                ))
            }
            comp = AudioComponentFindNext(c, &desc)
        }

        instruments = results.sorted { $0.name < $1.name }
        isScanning = false
    }
}
