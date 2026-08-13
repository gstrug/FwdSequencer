// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FwdSequencerCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FwdSequencerCore", targets: ["FwdSequencerCore"])
    ],
    targets: [
        .target(
            name: "FwdSequencerCore",
            path: "FwdSequencer",
            exclude: [
                "Assets.xcassets",
                "Bridge",
                "FwdSequencer.entitlements",
                "Info.plist",
                "PrivacyInfo.xcprivacy",
                "FwdSequencerApp.swift",
                "Store/PlaybackMonitor.swift",
                "Store/SongStore.swift",
                "Views",
                "Engine/AudioEngineManager.swift",
                "Engine/PluginManager.swift"
            ],
            sources: [
                "Models/Models.swift",
                "Models/SongValidation.swift",
                "Models/SongTemplates.swift",
                "Engine/SequencerRandom.swift",
                "Engine/SequencerEngine.swift",
                "Engine/PluginLoadTracker.swift",
                "Engine/SongMIDIExporter.swift",
                "Store/SongPersistence.swift"
            ]
        ),
        .testTarget(
            name: "FwdSequencerCoreTests",
            dependencies: ["FwdSequencerCore"],
            path: "Tests/FwdSequencerCoreTests"
        )
    ]
)
