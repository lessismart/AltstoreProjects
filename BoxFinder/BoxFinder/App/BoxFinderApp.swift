import SwiftUI

@main
struct BoxFinderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(appState)
                .task {
                    await appState.startup()
                }
        }
    }
}
