import SwiftUI
import UniformTypeIdentifiers

struct BoxFinderJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var showPairingImporter = false
    @State private var showBackupImporter = false
    @State private var showBackupExporter = false
    @State private var exportDocument = BoxFinderJSONDocument()
    @State private var showPhotoAiSetup = false
    @State private var showRemovePairingConfirm = false

    private var lastSyncedText: String {
        if appState.lastSyncTimestampMs <= 0 {
            return "Never synced"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(appState.lastSyncTimestampMs) / 1000.0)
        return "Last synced: \(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Pi Pairing")
                    Spacer()
                    Text(appState.isSyncPaired ? "Paired (Keychain)" : "Not paired")
                        .foregroundColor(appState.isSyncPaired ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpoint")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(appState.syncURL)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Text(lastSyncedText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button("Sync now") {
                    Task { await appState.startSync() }
                }
                .disabled(!appState.isSyncPaired || appState.busyMessage != nil)

                Button("Import Pi pairing JSON") {
                    showPairingImporter = true
                }

                if appState.isSyncPaired {
                    Button("Clear Pi pairing", role: .destructive) {
                        showRemovePairingConfirm = true
                    }
                }

                Text("Sync is manual on home Wi-Fi. Changes to different boxes merge; conflicting edits let you choose this device's or the Pi's version.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Pi Synchronization")
            }

            Section {
                HStack {
                    Text("Active Provider")
                    Spacer()
                    Text(appState.photoAi.currentSummary())
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                Button("Open Photo AI setup & models") {
                    showPhotoAiSetup = true
                }

                Text("Ask Gemma uses your offline LiteRT-LM Gemma model locally. Inventory and photos are never sent to online providers by Ask Gemma.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Photo AI & Offline Gemma")
            }

            Section {
                Button("Export backup (JSON)") {
                    Task {
                        do {
                            let data = try await appState.exportBackupData()
                            exportDocument = BoxFinderJSONDocument(data: data)
                            showBackupExporter = true
                        } catch {
                            appState.notice = AlertNotice(title: "Export failed", message: error.localizedDescription)
                        }
                    }
                }

                Button("Import backup (JSON)") {
                    showBackupImporter = true
                }

                Text("Backups use format box-finder-android-v1 and contain unencrypted boxes, items, photos and optional overlay detections. API keys, Pi pairing tokens and local AI models are excluded. Importing replaces current local inventory after previewing counts.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } header: {
                Text("Backups & Interoperability")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPhotoAiSetup) {
            NavigationStack {
                PhotoAiSetupView()
            }
        }
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await appState.importPairing(from: url) }
            }
        }
        .fileImporter(
            isPresented: $showBackupImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await appState.previewBackupImport(from: url) }
            }
        }
        .fileExporter(
            isPresented: $showBackupExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "box-finder-backup.json"
        ) { result in
            switch result {
            case .success:
                appState.notice = AlertNotice(
                    title: "Backup exported",
                    message: "Remember: backups contain unencrypted inventory and photos. Store the JSON file securely."
                )
            case .failure(let error):
                appState.notice = AlertNotice(title: "Export failed", message: error.localizedDescription)
            }
        }
        .confirmationDialog(
            "Replace local inventory?",
            isPresented: Binding(
                get: { appState.pendingBackupImport != nil },
                set: { if !$0 { appState.pendingBackupImport = nil } }
            ),
            presenting: appState.pendingBackupImport
        ) { pending in
            Button("Replace & Import (\(pending.preview.boxes.count) boxes)", role: .destructive) {
                Task { await appState.commitPendingBackupImport() }
            }
            Button("Cancel", role: .cancel) {
                appState.pendingBackupImport = nil
            }
        } message: { pending in
            Text("Import \(pending.preview.boxes.count) boxes, \(pending.preview.items.count) items, and \(pending.preview.photos.count) photos? Existing local inventory and photos will be replaced.")
        }
        .confirmationDialog("Remove Pi pairing?", isPresented: $showRemovePairingConfirm, titleVisibility: .visible) {
            Button("Clear Pairing", role: .destructive) {
                appState.removeSyncPairing()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
