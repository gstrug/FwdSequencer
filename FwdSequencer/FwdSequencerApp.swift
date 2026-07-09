import SwiftUI

@main
struct FwdSequencerApp: App {
    @StateObject var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ProjectBrowserView()
                .environmentObject(store)
        }
    }
}
