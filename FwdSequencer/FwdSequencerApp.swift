import SwiftUI

@main
struct FwdSequencerApp: App {
    @StateObject var store = ProjectStore()
    @StateObject var songStore = SongStore()

    var body: some Scene {
        WindowGroup {
            ProjectBrowserView()
                .environmentObject(store)
                .environmentObject(store.levels)
                .environmentObject(store.playback)
                .environmentObject(songStore)
        }
    }
}
