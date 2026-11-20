import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                LiveDashboardView()
                    .tabItem {
                        Label("Live", systemImage: "video.fill")
                    }

                KioskMonitorView()
                    .tabItem {
                        Label("Monitor", systemImage: "shield.checkerboard")
                    }

                RecordingsView()
                    .tabItem {
                        Label("Recordings", systemImage: "film.stack")
                    }

                CameraAdminView()
                    .tabItem {
                        Label("Admin", systemImage: "gearshape.2.fill")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
            }
            .tint(Theme.teal)

            if let toast = self.appState.bannerMessage {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceAlt.opacity(0.96))
                    .overlay(Capsule().stroke(Theme.teal, lineWidth: 1))
                    .clipShape(Capsule())
                    .shadow(radius: 12)
                    .padding(.top, 54)
                    .transition(.opacity)
            }
        }
    }
}
