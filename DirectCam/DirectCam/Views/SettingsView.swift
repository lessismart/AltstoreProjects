import SwiftUI
import UniformTypeIdentifiers

struct ProfileJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: self.data)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showImporter = false
    @State private var exportDoc: ProfileJSONDocument?
    @State private var showExporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                List {
                    Section("Local Media Storage Quota") {
                        let usedBytes = self.appState.mediaStore.totalUsedBytes(for: self.appState.mediaItems)
                        HStack {
                            Text("Used Storage")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))
                                .monospacedDigit()
                                .foregroundStyle(Theme.teal)
                        }
                        Stepper(
                            "Storage Cap: \(self.appState.monitorSettings.maxStorageMB) MB",
                            value: self.$appState.monitorSettings.maxStorageMB,
                            in: 256...10240,
                            step: 256
                        )
                        .onChange(of: self.appState.monitorSettings.maxStorageMB) { _ in
                            self.appState.saveMonitorSettings()
                        }
                    }

                    Section("Camera Profiles Backup (Passwords Excluded)") {
                        Button {
                            if let data = try? self.appState.cameraStore.exportProfilesData(
                                cameras: self.appState.cameras,
                                settings: self.appState.monitorSettings
                            ) {
                                self.exportDoc = ProfileJSONDocument(data: data)
                                self.showExporter = true
                            }
                        } label: {
                            Label("Export Camera Profiles JSON", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            self.showImporter = true
                        } label: {
                            Label("Import Camera Profiles JSON", systemImage: "square.and.arrow.down")
                        }
                    }

                    Section("Standalone Architecture & Security") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Direct LAN Operation — Zero Raspberry Pi Required")
                                .font(.subheadline.bold())
                            Text("DirectCam connects directly to camera RTSP (:554), ONVIF (:8899), and Xiongmai DVRIP (:34567) endpoints. No credentials leave your local network, and camera passwords remain exclusively in Apple Keychain.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                    }

                    Section("Redacted Connection Diagnostics") {
                        if self.appState.diagnosticsLog.isEmpty {
                            Text("No diagnostic entries yet.")
                                .foregroundStyle(Theme.muted)
                        } else {
                            ForEach(self.appState.diagnosticsLog, id: \.self) { line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .fileExporter(
                isPresented: self.$showExporter,
                document: self.exportDoc,
                contentType: .json,
                defaultFilename: "DirectCam-Profiles.json"
            ) { result in
                switch result {
                case .success:
                    self.appState.showBanner("Exported password-free camera profiles JSON.")
                case .failure(let err):
                    self.appState.showBanner("Export failed: \(err.localizedDescription)")
                }
            }
            .fileImporter(isPresented: self.$showImporter, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    let needsStop = url.startAccessingSecurityScopedResource()
                    defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url),
                       let bundle = try? self.appState.cameraStore.importProfilesData(data) {
                        for cam in bundle.cameras {
                            self.appState.upsertCamera(cam, password: nil)
                        }
                        self.appState.monitorSettings = bundle.monitorSettings
                        self.appState.saveMonitorSettings()
                        self.appState.showBanner("Imported \(bundle.cameras.count) camera profile(s). Re-enter passwords in Edit Camera.")
                    } else {
                        self.appState.showBanner("Invalid DirectCam profiles JSON file.")
                    }
                case .failure(let err):
                    self.appState.showBanner("Import canceled: \(err.localizedDescription)")
                }
            }
        }
    }
}
