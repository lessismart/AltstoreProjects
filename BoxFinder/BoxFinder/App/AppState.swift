import Foundation
import SwiftUI
import UIKit

struct AlertNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PendingSyncConflict: Identifiable {
    let id = UUID()
    let engine: SyncEngine
    let plan: SyncPlan
}

struct PendingBackupImport: Identifiable {
    let id = UUID()
    let preview: BackupPreview
}

struct ReviewSuggestionSession: Identifiable {
    let id = UUID()
    let boxId: Int64
    let sourceTag: String
    var items: [SuggestedItem]
}

@MainActor
final class AppState: ObservableObject {
    let repository: BoxRepository
    let fileStore: PhotoFileStore
    let annotationStore: PhotoAnnotationStore
    let secrets: SecretStore
    let settings: PhotoAiSettingsStore
    let baselineStore: SyncBaselineStore
    let modelStore: ModelStore
    let onlineVision: OnlineVisionClient
    let localRuntime: LocalInferenceBackend
    let photoAi: PhotoAiCoordinator
    let backupService: BackupService

    @Published var boxSummaries: [BoxSummary] = []
    @Published var searchText = ""
    @Published var selectedBoxId: Int64?
    @Published var busyMessage: String?
    @Published var notice: AlertNotice?
    @Published var pendingSyncConflict: PendingSyncConflict?
    @Published var pendingBackupImport: PendingBackupImport?
    @Published var reviewSession: ReviewSuggestionSession?
    @Published var showPhotoAiSetupSheet = false

    @Published private(set) var lastSyncTimestampMs: Int64 = 0
    @Published private(set) var isSyncPaired = false

    init(
        repository: BoxRepository? = nil,
        fileStore: PhotoFileStore? = nil,
        secrets: SecretStore = KeychainVault(),
        settings: PhotoAiSettingsStore = PhotoAiSettingsStore(),
        baselineStore: SyncBaselineStore = UserDefaultsSyncBaselineStore(),
        modelStore: ModelStore? = nil,
        onlineVision: OnlineVisionClient = OnlineVisionClient(),
        localRuntime: LocalInferenceBackend = LiteRTLMRuntime()
    ) {
        let resolvedFileStore = (try? fileStore ?? PhotoFileStore()) ?? (try! PhotoFileStore(baseDirectory: FileManager.default.temporaryDirectory))
        let resolvedRepo = (try? repository ?? SQLiteBoxDatabase()) ?? (try! SQLiteBoxDatabase(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("fallback.db")))
        let resolvedModelStore = (try? modelStore ?? ModelStore()) ?? (try! ModelStore(baseDirectory: FileManager.default.temporaryDirectory))
        let resolvedAnnotations = PhotoAnnotationStore(fileStore: resolvedFileStore)

        self.repository = resolvedRepo
        self.fileStore = resolvedFileStore
        self.annotationStore = resolvedAnnotations
        self.secrets = secrets
        self.settings = settings
        self.baselineStore = baselineStore
        self.modelStore = resolvedModelStore
        self.onlineVision = onlineVision
        self.localRuntime = localRuntime
        self.photoAi = PhotoAiCoordinator(
            settings: settings,
            secrets: secrets,
            fileStore: resolvedFileStore,
            annotationStore: resolvedAnnotations,
            modelStore: resolvedModelStore,
            onlineClient: onlineVision,
            localRuntime: localRuntime
        )
        self.backupService = BackupService(
            repository: resolvedRepo,
            fileStore: resolvedFileStore,
            annotationStore: resolvedAnnotations
        )
    }

    var totalItemTypesCount: Int {
        boxSummaries.reduce(0) { $0 + $1.itemTypeCount }
    }

    var syncURL: String {
        get {
            UserDefaults.standard.string(forKey: "sync_pi_url") ?? SyncURLValidator.defaultURL
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "sync_pi_url")
        }
    }

    func startup() async {
        importPrivatePairingIfPresent()
        refreshSyncStatus()
        await reloadInventory()
    }

    func refreshSyncStatus() {
        lastSyncTimestampMs = baselineStore.lastSyncTimestampMs()
        isSyncPaired = secrets.hasSecret(account: KeychainAccount.syncToken)
    }

    func reloadInventory() async {
        do {
            let boxes = try await repository.allBoxes()
            var summaries: [BoxSummary] = []
            summaries.reserveCapacity(boxes.count)
            for box in boxes {
                let items = try await repository.items(boxId: box.id)
                let photos = try await repository.photos(boxId: box.id)
                summaries.append(BoxSummary(
                    box: box,
                    itemTypeCount: items.count,
                    photoCount: photos.count,
                    items: items
                ))
            }
            self.boxSummaries = summaries
        } catch {
            self.notice = AlertNotice(title: "Inventory error", message: error.localizedDescription)
        }
    }

    func saveBox(id: Int64, name: String, location: String, notes: String) async -> BoxRecord? {
        do {
            let saved = try await repository.saveBox(id: id, name: name, location: location, notes: notes)
            await reloadInventory()
            return saved
        } catch {
            notice = AlertNotice(title: "Could not save box", message: error.localizedDescription)
            return nil
        }
    }

    func deleteBox(id: Int64) async {
        do {
            let filenames = try await repository.deleteBox(id: id)
            fileStore.deletePhotoFiles(filenames)
            if selectedBoxId == id {
                selectedBoxId = nil
            }
            await reloadInventory()
        } catch {
            notice = AlertNotice(title: "Could not delete box", message: error.localizedDescription)
        }
    }

    func saveItem(
        id: Int64,
        boxId: Int64,
        name: String,
        category: String,
        quantity: Int,
        notes: String,
        source: String
    ) async -> Bool {
        do {
            _ = try await repository.saveItem(
                id: id,
                boxId: boxId,
                name: name,
                category: category,
                quantity: quantity,
                notes: notes,
                source: source
            )
            await reloadInventory()
            return true
        } catch {
            notice = AlertNotice(title: "Could not save item", message: error.localizedDescription)
            return false
        }
    }

    func deleteItem(id: Int64) async {
        do {
            try await repository.deleteItem(id: id)
            await reloadInventory()
        } catch {
            notice = AlertNotice(title: "Could not delete item", message: error.localizedDescription)
        }
    }

    func addPhoto(_ image: UIImage, toBox boxId: Int64) async {
        do {
            let existing = try await repository.photos(boxId: boxId)
            guard existing.count < 4 else {
                notice = AlertNotice(title: "Photo limit reached", message: "Each box can hold up to four photos.")
                return
            }
            let saved = try fileStore.saveNormalizedPhoto(image)
            do {
                _ = try await repository.addPhoto(boxId: boxId, filename: saved.filename)
            } catch {
                fileStore.deletePhotoFiles([saved.filename])
                throw error
            }
            await reloadInventory()
        } catch {
            notice = AlertNotice(title: "Could not add photo", message: error.localizedDescription)
        }
    }

    func deletePhoto(_ photo: PhotoRecord) async {
        do {
            if let filename = try await repository.deletePhoto(id: photo.id) {
                fileStore.deletePhotoFiles([filename])
            }
            await reloadInventory()
        } catch {
            notice = AlertNotice(title: "Could not remove photo", message: error.localizedDescription)
        }
    }

    func openScannedQR(_ payload: String) {
        let boxes = boxSummaries.map(\.box)
        if let box = QRCodeService.resolveBox(from: payload, in: boxes) {
            selectedBoxId = box.id
        } else {
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            notice = AlertNotice(
                title: "Box not found",
                message: "QR payload: \(trimmed)\nNo matching box exists in the local inventory."
            )
        }
    }

    // MARK: - Pi Pairing & Sync

    func importPairing(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            try savePairing(data: data)
            notice = AlertNotice(title: "Paired with Pi", message: "Tap Sync now when on your home Wi-Fi.")
        } catch {
            notice = AlertNotice(title: "Pairing failed", message: error.localizedDescription)
        }
    }

    func savePairing(data: Data) throws {
        let config = try SyncURLValidator.parsePairingJSON(data)
        try secrets.save(account: KeychainAccount.syncToken, value: config.token)
        syncURL = config.url
        baselineStore.clearBase()
        refreshSyncStatus()
    }

    func removeSyncPairing() {
        try? secrets.delete(account: KeychainAccount.syncToken)
        baselineStore.clearBase()
        refreshSyncStatus()
    }

    func startSync() async {
        guard busyMessage == nil else { return }
        let token: String
        do {
            token = try secrets.read(account: KeychainAccount.syncToken)
        } catch {
            notice = AlertNotice(title: "Pairing needed", message: "Could not read sync token from Keychain.")
            return
        }
        guard !token.isEmpty else {
            notice = AlertNotice(title: "Pairing needed", message: "Open Settings and import your Pi pairing JSON file first.")
            return
        }

        let engine: SyncEngine
        do {
            engine = try SyncEngine(
                repository: repository,
                fileStore: fileStore,
                baselineStore: baselineStore,
                urlString: syncURL,
                token: token
            )
        } catch {
            notice = AlertNotice(title: "Invalid sync settings", message: error.localizedDescription)
            return
        }

        busyMessage = "Comparing this device and Pi inventory…"
        do {
            let plan = try await engine.plan()
            busyMessage = nil
            if plan.conflicts.isEmpty {
                await executeSync(engine: engine, plan: plan, preferLocal: false)
            } else {
                pendingSyncConflict = PendingSyncConflict(engine: engine, plan: plan)
            }
        } catch {
            busyMessage = nil
            notice = AlertNotice(title: "Sync failed", message: error.localizedDescription)
        }
    }

    func executeSync(engine: SyncEngine, plan: SyncPlan, preferLocal: Bool) async {
        pendingSyncConflict = nil
        busyMessage = "Syncing boxes and photos with Pi…"
        do {
            let outcome = try await engine.execute(plan: plan, preferLocal: preferLocal)
            busyMessage = nil
            refreshSyncStatus()
            await reloadInventory()
            notice = AlertNotice(
                title: "Sync complete",
                message: "\(outcome.syncedBoxCount) boxes are current on this device and the Pi."
            )
        } catch {
            busyMessage = nil
            notice = AlertNotice(title: "Sync failed", message: error.localizedDescription)
        }
    }

    // MARK: - Backups

    func exportBackupData() async throws -> Data {
        try await backupService.exportBackup()
    }

    func previewBackupImport(from url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let data = try Data(contentsOf: url)
            let preview = try backupService.previewImport(data: data)
            pendingBackupImport = PendingBackupImport(preview: preview)
        } catch {
            notice = AlertNotice(title: "Invalid backup", message: error.localizedDescription)
        }
    }

    func commitPendingBackupImport() async {
        guard let pending = pendingBackupImport else { return }
        pendingBackupImport = nil
        busyMessage = "Restoring inventory and photos…"
        do {
            try await backupService.commitImport(pending.preview)
            busyMessage = nil
            selectedBoxId = nil
            await reloadInventory()
            notice = AlertNotice(
                title: "Import complete",
                message: "Restored \(pending.preview.boxes.count) boxes, \(pending.preview.items.count) items, and \(pending.preview.photos.count) photos."
            )
        } catch {
            busyMessage = nil
            notice = AlertNotice(title: "Import failed", message: error.localizedDescription)
        }
    }

    // MARK: - AI Identification

    func identifyItemsInBox(_ boxId: Int64) async {
        guard busyMessage == nil else {
            notice = AlertNotice(title: "Photo AI is busy", message: "Wait for the current request to finish.")
            return
        }
        guard photoAi.isCurrentProviderReady() else {
            showPhotoAiSetupSheet = true
            return
        }

        do {
            let photos = try await repository.photos(boxId: boxId)
            let urls = try photos.map { try fileStore.photoURL(for: $0.filename) }
                .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            guard !urls.isEmpty else {
                notice = AlertNotice(title: "Add a photo", message: "Take or choose a photo of the box contents first.")
                return
            }

            let provider = photoAi.currentProvider
            busyMessage = provider.isOnline
                ? "Identifying items with \(provider.displayName)…"
                : "Analyzing photos privately on this device…"
            let result = try await photoAi.identifyBoxPhotos(urls)
            busyMessage = nil

            if result.items.isEmpty {
                notice = AlertNotice(
                    title: "No clear items found",
                    message: "Try closer photos with better lighting, or add items manually."
                )
            } else {
                reviewSession = ReviewSuggestionSession(
                    boxId: boxId,
                    sourceTag: result.sourceTag,
                    items: result.items
                )
            }
        } catch {
            busyMessage = nil
            notice = AlertNotice(title: "Photo AI needs attention", message: error.localizedDescription)
        }
    }

    func commitSuggestedItems(boxId: Int64, sourceTag: String, items: [SuggestedItem]) async {
        var addedCount = 0
        for item in items where item.selected {
            let ok = await saveItem(
                id: 0,
                boxId: boxId,
                name: item.name,
                category: item.category,
                quantity: max(1, min(9999, item.quantity)),
                notes: item.uncertain ? "Check identification" : "",
                source: sourceTag
            )
            if ok {
                addedCount += 1
            }
        }
        reviewSession = nil
        if addedCount > 0 {
            notice = AlertNotice(title: "Items added", message: "Added \(addedCount) reviewed item(s) to the box.")
        }
    }

    private func importPrivatePairingIfPresent() {
        let candidates = [
            fileStore.baseDirectory.appendingPathComponent("pi-sync-pairing.json"),
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("pi-sync-pairing.json")
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate.path) {
            defer { try? FileManager.default.removeItem(at: candidate) }
            if let data = try? Data(contentsOf: candidate) {
                try? savePairing(data: data)
            }
        }
    }
}
