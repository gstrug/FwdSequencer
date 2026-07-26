import SwiftUI

@main
struct FwdSequencerApp: App {
    @StateObject var songStore = SongStore()

    var body: some Scene {
        WindowGroup {
            ProjectBrowserView()
                .environmentObject(songStore)
                .environmentObject(songStore.levels)
                .environmentObject(songStore.playback)
        }
    }
}
