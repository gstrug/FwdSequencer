import AVFoundation
import AudioToolbox
import Combine
import UIKit

/// Scans the device for installed AUv3 instrument plugins.
class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published var instruments: [PluginInfo] = []
    /// Effects, scanned alongside instruments. `aufx` is the plain audio effect;
    /// `aumf` is a music effect, which also takes MIDI — both sit in a track's chain
    /// the same way, so they are listed together.
    @Published var effects: [PluginInfo] = []
    @Published var isScanning = false
    /// Each plugin's icon (its app's icon, as iPadOS provides it), by
    /// `componentIdentifier`. Kept here rather than in PluginInfo, which is saved in
    /// songs. A plugin without one shows a plain symbol (see PluginIcon).
    @Published private(set) var icons: [String: UIImage] = [:]
    @Published private(set) var favoriteIdentifiers: Set<String>

    private var observer: NSObjectProtocol?
    private let favoritesKey = "FavoritePluginIdentifiers"

    init() {
        favoriteIdentifiers = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioUnitComponentTagsDidChange,
            object: AVAudioUnitComponentManager.shared(),
            queue: .main
        ) { [weak self] _ in
            // Off the main thread: components(matching:) enumerates every installed
            // audio-unit extension, and this notification fires whenever one is
            // installed, removed or re-tagged. performScan publishes back on main.
            DispatchQueue.global(qos: .userInitiated).async { self?.performScan() }
        }
        _ = AVAudioUnitComponentManager.shared()
    }

    func isFavorite(_ plugin: PluginInfo) -> Bool {
        favoriteIdentifiers.contains(plugin.componentIdentifier)
    }

    func toggleFavorite(_ plugin: PluginInfo) {
        let identifier = plugin.componentIdentifier
        if favoriteIdentifiers.contains(identifier) { favoriteIdentifiers.remove(identifier) }
        else { favoriteIdentifiers.insert(identifier) }
        UserDefaults.standard.set(Array(favoriteIdentifiers).sorted(), forKey: favoritesKey)
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
        // Apple's own instruments (MIDI Synth, Sampler, DLS Synth) make no sound until
        // a host loads a sound bank into them, and would only duplicate the built-in
        // General MIDI sounds, which are chosen in Select Instrument. Not listed.
        // 'dls ' is the DLS Synth, written as its code: its named constant is Mac-only.
        let appleSilent: Set<OSType> = [kAudioUnitSubType_MIDISynth, kAudioUnitSubType_Sampler,
                                        0x646C_7320]
        let foundInstruments = scan(type: kAudioUnitType_MusicDevice).filter {
            !($0.componentManufacturer == kAudioUnitManufacturer_Apple && appleSilent.contains($0.componentSubType))
        }
        let foundEffects = (scan(type: kAudioUnitType_Effect) + scan(type: kAudioUnitType_MusicEffect))
            .sorted { $0.name < $1.name }
        // Icons are fetched here, off the main thread, as each comes from the
        // plugin's app bundle.
        var foundIcons: [String: UIImage] = [:]
        for type in [kAudioUnitType_MusicDevice, kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            for c in components(type: type) {
                if let icon = c.icon { foundIcons[makeKey(c.audioComponentDescription)] = icon }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.instruments = foundInstruments
            self?.effects = foundEffects
            self?.icons = foundIcons
            self?.isScanning = false
        }
    }

    private func components(type: OSType) -> [AVAudioUnitComponent] {
        let desc = AudioComponentDescription(
            componentType: type, componentSubType: 0, componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0
        )
        return AVAudioUnitComponentManager.shared().components(matching: desc)
    }

    private func scan(type: OSType) -> [PluginInfo] {
        var seen = Set<String>()
        var results: [PluginInfo] = []
        for c in components(type: type) {
            guard seen.insert(makeKey(c.audioComponentDescription)).inserted else { continue }
            results.append(makeInfo(c))
        }
        return results.sorted { $0.name < $1.name }
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
