import Foundation

struct AskGemmaResult: Sendable {
    let matches: [BoxRecord]
    let searchedCount: Int
    let totalCount: Int
}

final class PhotoAiCoordinator: Sendable {
    private let settings: PhotoAiSettingsStore
    private let secrets: SecretStore
    private let fileStore: PhotoFileStore
    private let annotationStore: PhotoAnnotationStore
    private let modelStore: ModelStore
    private let onlineClient: OnlineVisionClient
    private let localRuntime: LocalInferenceBackend

    init(
        settings: PhotoAiSettingsStore,
        secrets: SecretStore,
        fileStore: PhotoFileStore,
        annotationStore: PhotoAnnotationStore,
        modelStore: ModelStore,
        onlineClient: OnlineVisionClient,
        localRuntime: LocalInferenceBackend
    ) {
        self.settings = settings
        self.secrets = secrets
        self.fileStore = fileStore
        self.annotationStore = annotationStore
        self.modelStore = modelStore
        self.onlineClient = onlineClient
        self.localRuntime = localRuntime
    }

    var currentProvider: PhotoAiProvider { settings.provider }

    func currentSummary() -> String {
        let p = settings.provider
        switch p {
        case .offline:
            return "\(settings.offlineModel.displayName) · offline"
        case .openrouter, .gemini:
            return "\(p.displayName) (\(settings.selectedOnlineModel(for: p))) · online"
        }
    }

    func isCurrentProviderReady() -> Bool {
        switch settings.provider {
        case .offline:
            return modelStore.isModelPresent(for: settings.offlineModel)
        case .openrouter, .gemini:
            return secrets.hasSecret(account: KeychainAccount.visionKey(for: settings.provider.rawValue))
        }
    }

    func identifyBoxPhotos(_ photoURLs: [URL]) async throws -> (items: [SuggestedItem], sourceTag: String) {
        let provider = settings.provider
        let maxDim: CGFloat = (!provider.isOnline && ModelStore.isLowMemoryDevice) ? 384 : 1024
        var tempFiles: [URL] = []
        defer {
            for tempURL in tempFiles {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        for url in photoURLs.prefix(4) {
            let prepared = try fileStore.makeBoundedCopy(from: url, maxDimension: maxDim, quality: provider.isOnline ? 0.78 : 0.85)
            tempFiles.append(prepared)
        }

        switch provider {
        case .offline:
            let slot = settings.offlineModel
            let items = try await localRuntime.identifyItems(
                modelURL: modelStore.modelURL(for: slot),
                useCPU: settings.useCPUForOffline,
                imageURLs: tempFiles
            )
            return (items, "offline_\(slot.rawValue)")
        case .openrouter, .gemini:
            let key = try secrets.read(account: KeychainAccount.visionKey(for: provider.rawValue))
            let model = settings.selectedOnlineModel(for: provider)
            let b64s = try tempFiles.map { try Data(contentsOf: $0).base64EncodedString() }
            let items = try await onlineClient.identifyItems(
                provider: provider,
                model: model,
                apiKey: key,
                jpegBase64Images: b64s
            )
            return (items, "vision_\(provider.rawValue)")
        }
    }

    func detectPhotoObjects(photoURL: URL) async throws -> PhotoOverlayMetadata {
        let provider = settings.provider
        let originalHash = try PhotoFileStore.sha256Hex(ofFileAt: photoURL)
        let maxDim: CGFloat = (!provider.isOnline && ModelStore.isLowMemoryDevice) ? 384 : 1024
        let tempURL = try fileStore.makeBoundedCopy(from: photoURL, maxDimension: maxDim, quality: 0.85)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let objects: [DetectedObject]
        let modelName: String
        switch provider {
        case .offline:
            let slot = settings.offlineModel
            modelName = slot.displayName
            objects = try await localRuntime.detectObjects(
                modelURL: modelStore.modelURL(for: slot),
                useCPU: settings.useCPUForOffline,
                imageURL: tempURL
            )
        case .openrouter, .gemini:
            let key = try secrets.read(account: KeychainAccount.visionKey(for: provider.rawValue))
            modelName = settings.selectedOnlineModel(for: provider)
            let b64 = try Data(contentsOf: tempURL).base64EncodedString()
            objects = try await onlineClient.detectObjects(
                provider: provider,
                model: modelName,
                apiKey: key,
                jpegBase64Image: b64
            )
        }

        let currentHash = try PhotoFileStore.sha256Hex(ofFileAt: photoURL)
        guard currentHash == originalHash else {
            throw PhotoFileStoreError.missingPhoto
        }

        return try annotationStore.save(
            objects: objects,
            forPhotoAt: photoURL,
            provider: provider.rawValue,
            model: modelName
        )
    }

    /// Always runs against the local offline Gemma model (never sends inventory online).
    func askGemma(
        question: String,
        boxes: [BoxRecord],
        itemsByBox: [Int64: [ItemRecord]]
    ) async throws -> AskGemmaResult {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else {
            throw BoxDatabaseError.invalidInput("Enter a question up to 500 characters.")
        }

        let charLimit = ModelStore.isLowMemoryDevice ? 1200 : 16_000
        var includedEntries: [[String: Any]] = []
        var includedBoxes: [BoxRecord] = []
        var usedChars = 0

        for box in boxes {
            let boxItems = (itemsByBox[box.id] ?? []).map { item -> [String: Any] in
                [
                    "name": item.name,
                    "category": item.category,
                    "quantity": item.quantity,
                    "notes": item.notes
                ]
            }
            let entry: [String: Any] = [
                "code": box.code,
                "name": box.name,
                "location": box.location,
                "notes": box.notes,
                "items": boxItems
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: entry)
            let size = jsonData.count
            if usedChars + size > charLimit {
                break
            }
            usedChars += size
            includedEntries.append(entry)
            includedBoxes.append(box)
        }

        guard !includedBoxes.isEmpty else {
            throw BoxDatabaseError.invalidInput("Add boxes and items first. A single box with a very large item list can exceed Gemma's search context.")
        }

        let inventoryData = try JSONSerialization.data(withJSONObject: includedEntries, options: [.withoutEscapingSlashes])
        let inventoryJSON = String(data: inventoryData, encoding: .utf8) ?? "[]"
        let questionData = try JSONSerialization.data(withJSONObject: ["question": trimmed], options: [.withoutEscapingSlashes])
        let questionJSON = String(data: questionData, encoding: .utf8) ?? "{}"

        let prompt = """
            Select up to 10 boxes containing recorded items useful for the user's question. Only use this inventory, and return an empty array if no recorded item is relevant. Return ONLY {"boxCodes":["BX-0001"]}.
            Inventory data:
            \(inventoryJSON)
            Question data:
            \(questionJSON)
            """
        let schema = #"{"type":"object","properties":{"boxCodes":{"type":"array","maxItems":10,"items":{"type":"string"}}},"required":["boxCodes"],"additionalProperties":false}"#
        let modelURL = modelStore.modelURL(for: .gemma4)
        let response = try await localRuntime.generateText(
            modelURL: modelURL,
            useCPU: settings.useCPUForOffline,
            prompt: prompt,
            schema: schema
        )
        let matches = try AiJsonParser.parseBoxCodes(from: response, inventory: includedBoxes)
        return AskGemmaResult(matches: matches, searchedCount: includedBoxes.count, totalCount: boxes.count)
    }
}
