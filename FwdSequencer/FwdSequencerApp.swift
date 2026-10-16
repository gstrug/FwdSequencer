import SwiftUI

/// Identifies which copy of the app is running, so device logs are never ambiguous
/// when more than one build is installed side by side.
private func logBuildIdentity() {
    let info = Bundle.main.infoDictionary ?? [:]
    NSLog("[FWD-BUILD] %@ bundle=%@ version=%@ build=%@",
          "MAIN",
          Bundle.main.bundleIdentifier ?? "?",
          info["CFBundleShortVersionString"] as? String ?? "?",
          info["CFBundleVersion"] as? String ?? "?")
}


@main
struct FwdSequencerApp: App {
    init() { logBuildIdentity() }

    @StateObject var songStore = SongStore()

    var body: some Scene {
        WindowGroup {
            ProjectBrowserView()
                .environmentObject(songStore)
                .environmentObject(songStore.levels)
                .environmentObject(songStore.playback)
                .onAppear {
                    // MIDI controllers: listen from launch, so the MIDI page lists them.
                    // What they act on is attached by the song screen while it is open.
                    MIDIControlCenter.shared.start()
                }
        }
    }
}
