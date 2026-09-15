import AVFoundation
import AudioToolbox
import Combine

/// Scans the device for installed AUv3 instrument plugins.
class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published var instruments: [PluginInfo] = []
    /// Effects, scanned alongside instruments. `aufx` is the plain audio effect;
    /// `aumf` is a music effect, which also takes MIDI — both sit in a track's chain
    /// the same way, so they are listed together.
    @Published var effects: [PluginInfo] = []
    @Published var isScanning = false
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
        let foundInstruments = scan(type: kAudioUnitType_MusicDevice)
        let foundEffects = (scan(type: kAudioUnitType_Effect) + scan(type: kAudioUnitType_MusicEffect))
            .sorted { $0.name < $1.name }
        DispatchQueue.main.async { [weak self] in
            self?.instruments = foundInstruments
            self?.effects = foundEffects
            self?.isScanning = false
        }
    }

    private func scan(type: OSType) -> [PluginInfo] {
        var seen = Set<String>()
        var results: [PluginInfo] = []
        let desc = AudioComponentDescription(
            componentType: type, componentSubType: 0, componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0
        )
        for c in AVAudioUnitComponentManager.shared().components(matching: desc) {
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
