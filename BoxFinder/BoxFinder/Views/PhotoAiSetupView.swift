import SwiftUI
import UniformTypeIdentifiers

struct PhotoAiSetupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: PhotoAiProvider = .offline
    @State private var selectedOfflineSlot: OfflineModelSlot = .gemma4
    @State private var selectedOnlineModel = ""
    @State private var confirmUpload = true
    @State private var useCPU = false

    @State private var hasSavedKey = false
    @State private var modelPresent = false
    @State private var modelSizeText = "Import needed"
    @State private var importedFilename: String?
    @State private var availableStorageText = ""

    @State private var showKeySheet = false
    @State private var keyInput = ""
    @State private var showRemoveKeyConfirm = false

    @State private var showModelIdSheet = false
    @State private var manualModelIdInput = ""

    @State private var showModelBrowser = false
    @State private var browsedModels: [VisionModelOption] = []
    @State private var modelSearchQuery = ""

    @State private var showModelImporter = false
    @State private var showDownloadSheet = false
    @State private var downloadURLInput = ""
    @State private var expectedSHA256Input = ""
    @State private var downloadProgress: Double?
    @State private var activeTask: Task<Void, Never>?
    @State private var showRemoveModelConfirm = false

    @State private var busyLabel: String?
    @State private var localNotice: AlertNotice?

    private var filteredModels: [VisionModelOption] {
        let q = modelSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return browsedModels }
        return browsedModels.filter {
            $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(PhotoAiProvider.allCases) { provider in
                        Text(provider.pickerLabel).tag(provider)
                    }
                }
                .onChange(of: selectedProvider) { newProvider in
                    appState.settings.provider = newProvider
                    reloadState()
                }

                Text(selectedProvider.isOnline
                     ? "Online: only photos from the box you choose are uploaded to \(selectedProvider.displayName). Internet is required and API charges or rate limits may apply. Your Pi pairing is separate."
                     : "Private: photos stay on this device. No internet or API credit is needed after importing or downloading a compatible LiteRT-LM vision model.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } header: {
                Text("1. Choose Where Photos Are Analyzed")
            }

            if selectedProvider == .offline {
                offlineSection
            } else {
                onlineSection
            }

            Section {
                Text("Return to a box → Take or choose photos → Identify items (or open any photo and tap Identify objects). You always review suggestions before anything is saved.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if selectedProvider.isOnline {
                    Toggle("Confirm before uploading photos", isOn: $confirmUpload)
                        .onChange(of: confirmUpload) { newValue in
                            appState.settings.confirmUpload = newValue
                        }
                    Text("The app never silently falls back from offline to online.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("3. Identify a Box")
            }

            Section("Troubleshooting") {
                Text("• If an offline model fails to load on GPU, turn on Use CPU.\n• If object locations return empty or misplaced boxes, location quality depends on the model — try a Gemini vision model online.\n• Check free storage and device RAM (\(ModelStore.deviceRAMDescription)) before importing multi-gigabyte models.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Photo AI Setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear { reloadState() }
        .onDisappear { activeTask?.cancel() }
        .overlay {
            if let busyLabel {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 14) {
                        if let downloadProgress {
                            ProgressView(value: downloadProgress)
                                .frame(width: 220)
                            Text("\(busyLabel) (\(Int(downloadProgress * 100))%)")
                                .font(.subheadline.weight(.medium))
                        } else {
                            ProgressView()
                            Text(busyLabel)
                                .font(.subheadline.weight(.medium))
                        }
                        Button("Cancel", role: .cancel) {
                            activeTask?.cancel()
                            activeTask = nil
                            self.busyLabel = nil
                            self.downloadProgress = nil
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(22)
                    .background(BoxFinderTheme.cardBackground)
                    .cornerRadius(16)
                }
            }
        }
        .fileImporter(
            isPresented: $showModelImporter,
            allowedContentTypes: [.item, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                startModelImport(from: url)
            case .failure(let error):
                localNotice = AlertNotice(title: "Import failed", message: error.localizedDescription)
            }
        }
        .sheet(isPresented: $showKeySheet) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Paste your \(selectedProvider.displayName) API key", text: $keyInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("Your saved key is stored in Apple Keychain, never displayed again, and excluded from backups.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .navigationTitle("\(selectedProvider.displayName) Key")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            keyInput = ""
                            showKeySheet = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.contains(" "), (12...512).contains(trimmed.count) else {
                                localNotice = AlertNotice(title: "Invalid API key", message: "Paste a complete API key without spaces.")
                                return
                            }
                            do {
                                try appState.secrets.save(account: KeychainAccount.visionKey(for: selectedProvider.rawValue), value: trimmed)
                                keyInput = ""
                                showKeySheet = false
                                reloadState()
                            } catch {
                                localNotice = AlertNotice(title: "Keychain error", message: error.localizedDescription)
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showModelIdSheet) {
            NavigationStack {
                Form {
                    Section("Model ID") {
                        TextField("e.g. google/gemini-2.5-flash", text: $manualModelIdInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .navigationTitle("Enter Model ID")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showModelIdSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                let valid = try OnlineVisionClient.validateModelID(manualModelIdInput, provider: selectedProvider)
                                appState.settings.setSelectedOnlineModel(valid, for: selectedProvider)
                                showModelIdSheet = false
                                reloadState()
                            } catch {
                                localNotice = AlertNotice(title: "Invalid model ID", message: error.localizedDescription)
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showModelBrowser) {
            NavigationStack {
                List(filteredModels) { option in
                    Button {
                        appState.settings.setSelectedOnlineModel(option.id, for: selectedProvider)
                        showModelBrowser = false
                        reloadState()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.name)
                                .font(.body.weight(.medium))
                                .foregroundColor(.primary)
                            Text(option.id)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .searchable(text: $modelSearchQuery, prompt: "Filter vision models")
                .navigationTitle("Choose Vision Model")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { showModelBrowser = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showDownloadSheet) {
            NavigationStack {
                Form {
                    Section("Direct HTTPS Model URL") {
                        TextField("https://.../model.litertlm", text: $downloadURLInput)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Expected SHA-256 checksum (optional)", text: $expectedSHA256Input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Section {
                        Text("Downloads stream directly to app storage with available-space checks (\(availableStorageText) free). Leave SHA-256 blank if none is published.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .navigationTitle("Download .litertlm")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showDownloadSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Download") {
                            guard let url = URL(string: downloadURLInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                localNotice = AlertNotice(title: "Invalid URL", message: "Enter a valid HTTPS URL ending in .litertlm.")
                                return
                            }
                            let sha = expectedSHA256Input
                            showDownloadSheet = false
                            startModelDownload(from: url, expectedSHA256: sha)
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("Remove API key?", isPresented: $showRemoveKeyConfirm, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                try? appState.secrets.delete(account: KeychainAccount.visionKey(for: selectedProvider.rawValue))
                reloadState()
            }
            Button("Keep", role: .cancel) {}
        }
        .confirmationDialog("Remove this model?", isPresented: $showRemoveModelConfirm, titleVisibility: .visible) {
            Button("Remove Model File", role: .destructive) {
                if busyLabel != nil {
                    localNotice = AlertNotice(title: "Model busy", message: ModelStoreError.busyDeleting.localizedDescription)
                    return
                }
                try? appState.modelStore.removeModel(for: selectedOfflineSlot)
                appState.settings.setImportedFilename(nil, for: selectedOfflineSlot)
                appState.settings.setLastTestedStamp(nil, for: selectedOfflineSlot)
                reloadState()
            }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Only this model file is removed. Your boxes, items, photos and Pi pairing are kept.")
        }
        .alert(item: $localNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var offlineSection: some View {
        Section {
            Picker("Offline Model", selection: $selectedOfflineSlot) {
                ForEach(OfflineModelSlot.allCases) { slot in
                    Text(slot.displayName).tag(slot)
                }
            }
            .onChange(of: selectedOfflineSlot) { newSlot in
                appState.settings.offlineModel = newSlot
                reloadState()
            }

            HStack {
                Text("Status")
                Spacer()
                Text(modelSizeText)
                    .foregroundColor(modelPresent ? .green : .secondary)
            }

            if let importedFilename {
                Text("File: \(importedFilename)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Device Memory & Storage")
                Spacer()
                Text("\(ModelStore.deviceRAMDescription) · \(availableStorageText) free")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Link("Open \(selectedOfflineSlot.displayName) download page", destination: selectedOfflineSlot.downloadPageURL)

            Button(modelPresent ? "Replace model from Files (.litertlm)" : "Import model from Files (.litertlm)") {
                showModelImporter = true
            }

            Button("Download .litertlm from HTTPS URL") {
                downloadURLInput = ""
                expectedSHA256Input = ""
                showDownloadSheet = true
            }

            Toggle("Use CPU (try if GPU loading fails)", isOn: $useCPU)
                .onChange(of: useCPU) { newVal in
                    appState.settings.useCPUForOffline = newVal
                }

            Button("Test selected model") {
                testOfflineModel()
            }
            .disabled(!modelPresent)

            if modelPresent {
                Button("Remove this model", role: .destructive) {
                    showRemoveModelConfirm = true
                }
            }

            Text("Requires a LiteRT-LM vision .litertlm model (GGUF, .task and text-only models will not work for photos). Even if a model loads, large photo inference depends on device RAM; iOS devices with under 6 GB RAM automatically cap image dimensions and tokens.")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("2. Set Up Offline LiteRT-LM Model")
        }
    }

    private var onlineSection: some View {
        Section {
            Text(selectedProvider == .openrouter
                 ? "1) Create an API key on OpenRouter and add credit if your chosen model requires it.\n2) Save your key below, then browse image-capable models.\n3) Check the connection without uploading any box photos."
                 : "1) Create a Gemini API key in Google AI Studio.\n2) Save your key below and choose a Gemini model.\n3) Check the connection without uploading any box photos.")
                .font(.caption)
                .foregroundColor(.secondary)

            Link(
                selectedProvider == .openrouter ? "Open OpenRouter API Keys" : "Open Google AI Studio Keys",
                destination: URL(string: selectedProvider == .openrouter ? "https://openrouter.ai/keys" : "https://aistudio.google.com/apikey")!
            )

            HStack {
                Text("API Key")
                Spacer()
                Text(hasSavedKey ? "Saved securely in Keychain" : "Not set")
                    .foregroundColor(hasSavedKey ? .green : .secondary)
            }

            Button(hasSavedKey ? "Replace API key" : "Paste API key") {
                keyInput = ""
                showKeySheet = true
            }

            HStack {
                Text("Selected Model")
                Spacer()
                Text(selectedOnlineModel)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            if selectedProvider == .openrouter {
                HStack(spacing: 8) {
                    Button("Use Gemini 2.5 Flash") {
                        appState.settings.setSelectedOnlineModel(PhotoAiSettingsStore.defaultOpenRouterModel, for: .openrouter)
                        reloadState()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Use Qwen 3.7 Flash") {
                        appState.settings.setSelectedOnlineModel(PhotoAiSettingsStore.piPresetOpenRouterModel, for: .openrouter)
                        reloadState()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Button("Browse vision models") {
                browseOnlineModels()
            }

            Button("Enter model ID manually") {
                manualModelIdInput = selectedOnlineModel
                showModelIdSheet = true
            }

            Button("Check key and model") {
                checkOnlineConnection()
            }
            .disabled(!hasSavedKey)

            if hasSavedKey {
                Button("Remove saved key", role: .destructive) {
                    showRemoveKeyConfirm = true
                }
            }
        } header: {
            Text("2. Connect \(selectedProvider.displayName)")
        }
    }

    private func reloadState() {
        selectedProvider = appState.settings.provider
        selectedOfflineSlot = appState.settings.offlineModel
        selectedOnlineModel = appState.settings.selectedOnlineModel(for: selectedProvider)
        confirmUpload = appState.settings.confirmUpload
        useCPU = appState.settings.useCPUForOffline

        hasSavedKey = appState.secrets.hasSecret(account: KeychainAccount.visionKey(for: selectedProvider.rawValue))
        modelPresent = appState.modelStore.isModelPresent(for: selectedOfflineSlot)
        if let bytes = appState.modelStore.modelSizeBytes(for: selectedOfflineSlot) {
            modelSizeText = String(format: "Imported (%.2f GB)", Double(bytes) / 1_000_000_000.0)
        } else {
            modelSizeText = "Import needed"
        }
        importedFilename = appState.settings.importedFilename(for: selectedOfflineSlot)
        let freeGB = Double(appState.modelStore.availableDiskBytes()) / 1_000_000_000.0
        availableStorageText = String(format: "%.1f GB", freeGB)
    }

    private func startModelImport(from url: URL) {
        let slot = selectedOfflineSlot
        busyLabel = "Importing \(slot.displayName)"
        downloadProgress = 0
        activeTask = Task {
            do {
                let imported = try await appState.modelStore.importModel(from: url, slot: slot) { fraction in
                    Task { @MainActor in
                        self.downloadProgress = fraction
                    }
                }
                appState.settings.setImportedFilename(imported.displayName, for: slot)
                appState.settings.setLastTestedStamp(nil, for: slot)
                busyLabel = nil
                downloadProgress = nil
                reloadState()
                localNotice = AlertNotice(title: "Model imported", message: "Tap Test selected model to verify LiteRT-LM execution on this device.")
            } catch is CancellationError {
                busyLabel = nil
                downloadProgress = nil
            } catch {
                busyLabel = nil
                downloadProgress = nil
                localNotice = AlertNotice(title: "Import failed", message: error.localizedDescription)
            }
        }
    }

    private func startModelDownload(from url: URL, expectedSHA256: String) {
        let slot = selectedOfflineSlot
        busyLabel = "Downloading \(slot.displayName)"
        downloadProgress = 0
        activeTask = Task {
            do {
                let downloaded = try await appState.modelStore.downloadModel(
                    from: url,
                    slot: slot,
                    expectedSHA256: expectedSHA256.isEmpty ? nil : expectedSHA256
                ) { fraction in
                    Task { @MainActor in
                        self.downloadProgress = fraction
                    }
                }
                appState.settings.setImportedFilename(downloaded.displayName, for: slot)
                appState.settings.setLastTestedStamp(nil, for: slot)
                busyLabel = nil
                downloadProgress = nil
                reloadState()
                localNotice = AlertNotice(title: "Model downloaded", message: "Tap Test selected model to verify LiteRT-LM execution on this device.")
            } catch is CancellationError {
                busyLabel = nil
                downloadProgress = nil
            } catch {
                busyLabel = nil
                downloadProgress = nil
                localNotice = AlertNotice(title: "Download failed", message: error.localizedDescription)
            }
        }
    }

    private func testOfflineModel() {
        let slot = selectedOfflineSlot
        let modelURL = appState.modelStore.modelURL(for: slot)
        let cpu = appState.settings.useCPUForOffline
        busyLabel = "Testing \(slot.displayName)…"
        downloadProgress = nil
        activeTask = Task {
            do {
                let msg = try await appState.localRuntime.testModel(modelURL: modelURL, useCPU: cpu)
                appState.settings.setLastTestedStamp("\(Date().timeIntervalSince1970)", for: slot)
                busyLabel = nil
                localNotice = AlertNotice(title: "Model responded", message: msg)
            } catch is CancellationError {
                busyLabel = nil
            } catch {
                busyLabel = nil
                localNotice = AlertNotice(title: "Model test failed", message: error.localizedDescription)
            }
        }
    }

    private func browseOnlineModels() {
        let provider = selectedProvider
        let key = (try? appState.secrets.read(account: KeychainAccount.visionKey(for: provider.rawValue))) ?? ""
        busyLabel = "Loading \(provider.displayName) vision models…"
        downloadProgress = nil
        activeTask = Task {
            do {
                let options = try await appState.onlineVision.fetchModels(provider: provider, apiKey: key)
                busyLabel = nil
                if options.isEmpty {
                    localNotice = AlertNotice(title: "No vision models found", message: "Try entering a model ID manually.")
                } else {
                    browsedModels = options
                    modelSearchQuery = ""
                    showModelBrowser = true
                }
            } catch {
                busyLabel = nil
                localNotice = AlertNotice(title: "Could not load models", message: error.localizedDescription)
            }
        }
    }

    private func checkOnlineConnection() {
        let provider = selectedProvider
        let key = (try? appState.secrets.read(account: KeychainAccount.visionKey(for: provider.rawValue))) ?? ""
        let model = selectedOnlineModel
        busyLabel = "Checking \(provider.displayName)…"
        downloadProgress = nil
        activeTask = Task {
            do {
                let status = try await appState.onlineVision.checkConnection(provider: provider, model: model, apiKey: key)
                busyLabel = nil
                localNotice = AlertNotice(title: "Connection checked", message: status)
            } catch {
                busyLabel = nil
                localNotice = AlertNotice(title: "Connection check failed", message: error.localizedDescription)
            }
        }
    }
}
