import SwiftUI

struct NavigationMenuSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onAddBox: () -> Void
    let onScanQR: () -> Void
    let onAskGemma: () -> Void
    let onSyncNow: () -> Void
    let onPhotoAiSetup: () -> Void
    let onSettings: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Inventory & Labels") {
                    menuButton(title: "Add box", systemImage: "plus.square.fill", action: onAddBox)
                    menuButton(title: "Scan QR", systemImage: "qrcode.viewfinder", action: onScanQR)
                }

                Section("Assistant & Vision") {
                    menuButton(title: "Ask Gemma", systemImage: "sparkles.rectangle.stack", action: onAskGemma)
                    menuButton(title: "Photo AI setup", systemImage: "camera.metering.center.weighted", action: onPhotoAiSetup)
                }

                Section("Sync & Data") {
                    menuButton(title: "Sync now", systemImage: "arrow.triangle.2.circlepath", action: onSyncNow)
                    menuButton(title: "Settings", systemImage: "gearshape", action: onSettings)
                }
            }
            .navigationTitle("Box Finder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func menuButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                action()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.medium))
                .foregroundColor(.primary)
                .padding(.vertical, 6)
        }
    }
}
