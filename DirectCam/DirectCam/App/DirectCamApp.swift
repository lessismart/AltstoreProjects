import SwiftUI

@main
struct DirectCamApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(self.appState)
                .preferredColorScheme(.dark)
        }
        .onChange(of: self.scenePhase) { phase in
            self.appState.setSceneActive(phase == .active)
        }
    }
}
