import CryptoKit
import Foundation

enum SyncEngineError: LocalizedError, Sendable {
    case pairingRequired
    case missingLocalPhoto(Int64)
    case orphanRecord(String)
    case unsafeRemotePhoto(String)
    case photoTooLarge
    case serverRejectedPairing
    case serverRevisionConflict
    case invalidServerResponse(String)
    case serverError(String)
    case localApplyFailedAfterRemoteCommit(originalError: String, recoveryPath: String)

    var errorDescription: String? {
        switch self {
        case .pairingRequired:
            return "Pair the app with your Pi in Settings before syncing."
        case .missingLocalPhoto(let id):
            return "A photo on this device is missing (ID \(id))."
        case .orphanRecord(let msg):
            return msg
        case .unsafeRemotePhoto(let name):
            return "Unsafe photo filename from Pi: \(name)"
        case .photoTooLarge:
            return "Photo from Pi exceeds the 5 MB limit."
        case .serverRejectedPairing:
            return "Pi sync pairing was rejected (HTTP 403). Re-import the pairing file."
        case .serverRevisionConflict:
            return "The Pi changed during sync. Tap Sync again."
        case .invalidServerResponse(let detail):
            return "Unexpected response from Pi: \(detail)"
        case .serverError(let detail):
            return detail
        case .localApplyFailedAfterRemoteCommit(let originalError, let recoveryPath):
            return "Remote Pi sync succeeded, but applying changes locally failed (\(originalError)). A pre-sync backup was kept at \(recoveryPath)."
        }
    }
}

struct SyncHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

protocol SyncHTTPClient: Sendable {
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse
}

final class URLSessionSyncHTTPClient: NSObject, SyncHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 120)
        request.httpMethod = method
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body

        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw SyncEngineError.serverError("Pi sync timed out. Check Wi-Fi and verify the Pi server is running.")
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                throw SyncEngineError.serverError("Could not reach the Pi on your local network. Check local-network permission and Wi-Fi.")
            default:
                throw SyncEngineError.serverError("Pi connection error: \(urlError.localizedDescription)")
            }
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw SyncEngineError.invalidServerResponse("Pi did not answer.")
        }
        var lowerHeaders: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            lowerHeaders[String(describing: k).lowercased()] = String(describing: v)
        }
        return SyncHTTPResponse(statusCode: http.statusCode, headers: lowerHeaders, body: data)
    }
}

struct SyncBundle: Sendable {
    var box: BoxRecord
    var items: [ItemRecord] = []
    var photos: [BackupPhotoEntry] = []

    var id: Int64 { box.id }
    var code: String { box.code }

    /// Produces the exact SHA-256 hex digest computed by Android `SyncEngine.Bundle.hash()`.
    func computeHash() throws -> String {
        var buffer = ""
        Self.appendField(&buffer, String(box.id))
        Self.appendField(&buffer, box.code)
        Self.appendField(&buffer, box.name)
        Self.appendField(&buffer, box.location)
        Self.appendField(&buffer, box.notes)

        let sortedItems = items.sorted { $0.id < $1.id }
        for item in sortedItems {
            Self.appendField(&buffer, String(item.id))
            Self.appendField(&buffer, String(item.boxId))
            Self.appendField(&buffer, item.name)
            Self.appendField(&buffer, item.category)
            Self.appendField(&buffer, String(item.quantity))
            Self.appendField(&buffer, item.notes)
            Self.appendField(&buffer, item.source)
        }

        let sortedPhotos = photos.sorted { $0.id < $1.id }
        for photo in sortedPhotos {
            Self.appendField(&buffer, String(photo.id))
            Self.appendField(&buffer, String(photo.boxId))
            guard let jpegBytes = Data(base64Encoded: photo.jpegBase64, options: .ignoreUnknownCharacters) else {
                throw SyncEngineError.invalidServerResponse("Invalid base64 photo during hash.")
            }
            buffer.append(PhotoFileStore.sha256Hex(of: jpegBytes))
        }

        return PhotoFileStore.sha256Hex(of: Data(buffer.utf8))
    }

    private static func appendField(_ buffer: inout String, _ value: String) {
        buffer.append(String(value.utf16.count))
        buffer.append(":")
        buffer.append(value)
        buffer.append(";")
    }
}

struct SyncPlan: Sendable {
    let serverRevision: String
    let remoteSnapshot: InventorySnapshot
    let localSnapshot: InventorySnapshot
    let remoteBoxes: [Int64: SyncBundle]
    let localBoxes: [Int64: SyncBundle]
    let baseHashes: [Int64: String]
    let isInitial: Bool
    let conflicts: [String]
    let localChanges: Int
    let piChanges: Int
}

struct SyncOutcome: Sendable {
    let syncedBoxCount: Int
    let newRevision: String
    let uploadedToPi: Bool
}

protocol SyncBaselineStore: Sendable {
    func loadBase() -> [Int64: String]?
    func saveBase(_ hashes: [Int64: String], timestampMs: Int64)
    func clearBase()
    func lastSyncTimestampMs() -> Int64
}

final class UserDefaultsSyncBaselineStore: SyncBaselineStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let baseKey = "sync_base_hashes_v1"
    private let lastSyncKey = "sync_last_sync_ms"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadBase() -> [Int64: String]? {
        guard let raw = defaults.string(forKey: baseKey),
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        var out: [Int64: String] = [:]
        for (k, v) in dict {
            if let id = Int64(k) {
                out[id] = v
            }
        }
        return out
    }

    func saveBase(_ hashes: [Int64: String], timestampMs: Int64) {
        var dict: [String: String] = [:]
        for (id, hash) in hashes {
            dict[String(id)] = hash
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) {
            defaults.set(str, forKey: baseKey)
        }
        defaults.set(timestampMs, forKey: lastSyncKey)
    }

    func clearBase() {
        defaults.removeObject(forKey: baseKey)
        defaults.removeObject(forKey: lastSyncKey)
    }

    func lastSyncTimestampMs() -> Int64 {
        Int64(defaults.integer(forKey: lastSyncKey))
    }
}

final class SyncEngine: Sendable {
    static let maxPayloadBytes = 70_000_000

    private let repository: BoxRepository
    private let fileStore: PhotoFileStore
    private let baselineStore: SyncBaselineStore
    private let httpClient: SyncHTTPClient
    private let url: URL
    private let token: String

    init(
        repository: BoxRepository,
        fileStore: PhotoFileStore,
        baselineStore: SyncBaselineStore,
        httpClient: SyncHTTPClient = URLSessionSyncHTTPClient(),
        urlString: String,
        token: String
    ) throws {
        let validatedURL = try SyncURLValidator.validateURL(urlString)
        guard let parsed = URL(string: validatedURL) else {
            throw SyncPairingError.invalidURL("Invalid Pi sync URL.")
        }
        self.url = parsed
        self.token = try SyncURLValidator.validateToken(token)
        self.repository = repository
        self.fileStore = fileStore
        self.baselineStore = baselineStore
        self.httpClient = httpClient
    }

    func plan() async throws -> SyncPlan {
        let getResponse = try await requestJSON(method: "GET", jsonObject: nil)
        guard let serverRevision = getResponse["revision"] as? String,
              let remoteSnapshotDict = getResponse["snapshot"] as? [String: Any] else {
            throw SyncEngineError.invalidServerResponse("Missing revision or snapshot.")
        }
        let remoteData = try JSONSerialization.data(withJSONObject: remoteSnapshotDict)
        let remoteSnapshot = try JSONDecoder().decode(InventorySnapshot.self, from: remoteData)
        let localSnapshot = try await buildLocalSnapshot()

        return try Self.computePlan(
            serverRevision: serverRevision,
            remote: remoteSnapshot,
            local: localSnapshot,
            savedBase: baselineStore.loadBase()
        )
    }

    func execute(plan: SyncPlan, preferLocal: Bool) async throws -> SyncOutcome {
        let merged = try Self.merge(plan: plan, preferLocal: preferLocal)
        let needsRemoteUpload = try !Self.sameState(merged, plan.remoteSnapshot)
        var finalRevision = plan.serverRevision

        if needsRemoteUpload {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let snapshotData = try encoder.encode(merged)
            guard let snapshotObj = try JSONSerialization.jsonObject(with: snapshotData) as? [String: Any] else {
                throw SyncEngineError.invalidServerResponse("Failed to prepare sync payload.")
            }
            let bodyObj: [String: Any] = [
                "baseRevision": plan.serverRevision,
                "snapshot": snapshotObj
            ]
            let postResponse = try await requestJSON(method: "POST", jsonObject: bodyObj)
            if let rev = postResponse["revision"] as? String {
                finalRevision = rev
            }
        }

        // Persist recoverable pre-sync backup before modifying local DB/photos if remote was updated.
        let recoveryURL = fileStore.baseDirectory.appendingPathComponent("sync-recovery.json")
        if needsRemoteUpload {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let recoveryData = try encoder.encode(plan.localSnapshot)
            try recoveryData.write(to: recoveryURL, options: .atomic)
        }

        do {
            try await applyLocal(merged)
        } catch {
            // Attempt automatic rollback to pre-sync local state.
            try? await applyLocal(plan.localSnapshot)
            if needsRemoteUpload {
                throw SyncEngineError.localApplyFailedAfterRemoteCommit(
                    originalError: error.localizedDescription,
                    recoveryPath: recoveryURL.path
                )
            }
            throw error
        }

        let newBase = try Self.bundleHashes(for: merged)
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        baselineStore.saveBase(newBase, timestampMs: nowMs)
        try? FileManager.default.removeItem(at: recoveryURL)

        return SyncOutcome(
            syncedBoxCount: merged.boxes.count,
            newRevision: finalRevision,
            uploadedToPi: needsRemoteUpload
        )
    }

    // MARK: - Pure Sync Algorithms (Testable without network)

    static func computePlan(
        serverRevision: String,
        remote: InventorySnapshot,
        local: InventorySnapshot,
        savedBase: [Int64: String]?
    ) throws -> SyncPlan {
        let isInitial = (savedBase == nil)
        let base = savedBase ?? [:]
        let rb = try bundles(from: remote)
        let lb = try bundles(from: local)

        let allIds = Set(rb.keys).union(lb.keys).union(base.keys).sorted()
        var conflicts: [String] = []
        var localChanges = 0
        var piChanges = 0

        for id in allIds {
            let l = lb[id]
            let r = rb[id]
            let lh = try l?.computeHash()
            let rh = try r?.computeHash()
            let bh = base[id]

            if bh == nil {
                if l != nil && r == nil {
                    localChanges += 1
                } else if r != nil && l == nil {
                    piChanges += 1
                } else if let l, let r, lh != rh {
                    localChanges += 1
                    piChanges += 1
                    if isInitial {
                        conflicts.append(r.code)
                    }
                    _ = l
                }
            } else {
                if lh != bh { localChanges += 1 }
                if rh != bh { piChanges += 1 }
                if lh != rh && lh != bh && rh != bh {
                    if let code = r?.code ?? l?.code {
                        conflicts.append(code)
                    }
                }
            }
        }

        return SyncPlan(
            serverRevision: serverRevision,
            remoteSnapshot: remote,
            localSnapshot: local,
            remoteBoxes: rb,
            localBoxes: lb,
            baseHashes: base,
            isInitial: isInitial,
            conflicts: conflicts,
            localChanges: localChanges,
            piChanges: piChanges
        )
    }

    static func merge(plan: SyncPlan, preferLocal: Bool) throws -> InventorySnapshot {
        var selected: [SyncBundle] = []
        let allIds = Set(plan.localBoxes.keys).union(plan.remoteBoxes.keys).union(plan.baseHashes.keys).sorted()

        for id in allIds {
            let l = plan.localBoxes[id]
            let r = plan.remoteBoxes[id]
            let lh = try l?.computeHash()
            let rh = try r?.computeHash()
            let bh = plan.baseHashes[id]

            if lh == rh {
                if let r { selected.append(r) }
            } else if bh == nil, let l, let r {
                if plan.isInitial {
                    selected.append(preferLocal ? l : r)
                } else {
                    selected.append(r)
                    selected.append(l)
                }
            } else if lh == bh {
                if let r { selected.append(r) }
            } else if rh == bh {
                if let l { selected.append(l) }
            } else {
                if let chosen = (preferLocal ? l : r) {
                    selected.append(chosen)
                }
            }
        }

        var nextBox: Int64 = 1
        var nextItem: Int64 = 1
        var nextPhoto: Int64 = 1
        for bundle in selected {
            nextBox = max(nextBox, bundle.id + 1)
            for item in bundle.items {
                nextItem = max(nextItem, item.id + 1)
            }
            for photo in bundle.photos {
                nextPhoto = max(nextPhoto, photo.id + 1)
            }
        }

        var usedBoxIds = Set<Int64>()
        var usedBoxCodes = Set<String>()
        var usedItemIds = Set<Int64>()
        var usedPhotoIds = Set<Int64>()
        var usedFilenames = Set<String>()

        var outBoxes: [BoxRecord] = []
        var outItems: [ItemRecord] = []
        var outPhotos: [BackupPhotoEntry] = []

        for bundle in selected {
            var box = bundle.box
            if usedBoxIds.contains(box.id) || usedBoxCodes.contains(box.code) {
                let newId = nextBox
                nextBox += 1
                box.id = newId
                box.code = SQLiteBoxDatabase.formatBoxCode(for: newId)
            }
            usedBoxIds.insert(box.id)
            usedBoxCodes.insert(box.code)
            outBoxes.append(box)

            for var item in bundle.items {
                if usedItemIds.contains(item.id) {
                    item.id = nextItem
                    nextItem += 1
                }
                usedItemIds.insert(item.id)
                item.boxId = box.id
                outItems.append(item)
            }

            for var photo in bundle.photos {
                if usedPhotoIds.contains(photo.id) {
                    photo.id = nextPhoto
                    nextPhoto += 1
                }
                usedPhotoIds.insert(photo.id)
                photo.boxId = box.id
                if !isSafeFilename(photo.filename) || usedFilenames.contains(photo.filename) {
                    photo.filename = UUID().uuidString.lowercased() + ".jpg"
                }
                usedFilenames.insert(photo.filename)
                outPhotos.append(photo)
            }
        }

        return InventorySnapshot(
            format: InventorySnapshot.expectedFormat,
            boxes: outBoxes,
            items: outItems,
            photos: outPhotos
        )
    }

    static func bundles(from snapshot: InventorySnapshot) throws -> [Int64: SyncBundle] {
        var map: [Int64: SyncBundle] = [:]
        for box in snapshot.boxes {
            map[box.id] = SyncBundle(box: box)
        }
        for item in snapshot.items {
            guard var bundle = map[item.boxId] else {
                throw SyncEngineError.orphanRecord("Item \(item.id) references missing box \(item.boxId).")
            }
            bundle.items.append(item)
            map[item.boxId] = bundle
        }
        for photo in snapshot.photos {
            guard var bundle = map[photo.boxId] else {
                throw SyncEngineError.orphanRecord("Photo \(photo.id) references missing box \(photo.boxId).")
            }
            bundle.photos.append(photo)
            map[photo.boxId] = bundle
        }
        return map
    }

    static func sameState(_ a: InventorySnapshot, _ b: InventorySnapshot) throws -> Bool {
        let hashesA = try bundleHashes(for: a)
        let hashesB = try bundleHashes(for: b)
        return hashesA == hashesB
    }

    static func bundleHashes(for snapshot: InventorySnapshot) throws -> [Int64: String] {
        let map = try bundles(from: snapshot)
        var hashes: [Int64: String] = [:]
        for (id, bundle) in map {
            hashes[id] = try bundle.computeHash()
        }
        return hashes
    }

    /// Computes a deterministic SHA-256 snapshot revision matching `box-finder-sync.php`.
    static func serverRevision(for snapshot: InventorySnapshot) throws -> String {
        let boxesArr: [[Any]] = snapshot.boxes
            .sorted { $0.id < $1.id }
            .map { [$0.id, $0.code, $0.name, $0.location, $0.notes] }
        let itemsArr: [[Any]] = snapshot.items
            .sorted { $0.id < $1.id }
            .map { [$0.id, $0.boxId, $0.name, $0.category, $0.quantity, $0.notes, $0.source] }
        let photosArr: [[Any]] = try snapshot.photos
            .sorted { $0.id < $1.id }
            .map { photo in
                guard let raw = Data(base64Encoded: photo.jpegBase64, options: .ignoreUnknownCharacters) else {
                    throw SyncEngineError.invalidServerResponse("Invalid base64 photo.")
                }
                return [photo.id, photo.boxId, PhotoFileStore.sha256Hex(of: raw)]
            }
        let data = try JSONSerialization.data(withJSONObject: [boxesArr, itemsArr, photosArr], options: [.withoutEscapingSlashes])
        return PhotoFileStore.sha256Hex(of: data)
    }

    // MARK: - Private I/O & HTTP

    private func buildLocalSnapshot() async throws -> InventorySnapshot {
        let boxes = try await repository.allBoxes()
        let items = try await repository.allItems()
        let photoRows = try await repository.allPhotos()

        var entries: [BackupPhotoEntry] = []
        entries.reserveCapacity(photoRows.count)
        for row in photoRows {
            let bytes: Data
            do {
                bytes = try fileStore.readPhotoData(filename: row.filename, maxBytes: PhotoFileStore.maxSyncBytes)
            } catch PhotoFileStoreError.missingPhoto {
                throw SyncEngineError.missingLocalPhoto(row.id)
            }
            entries.append(BackupPhotoEntry(
                id: row.id,
                boxId: row.boxId,
                filename: row.filename,
                jpegBase64: bytes.base64EncodedString(),
                detections: nil
            ))
        }
        return InventorySnapshot(
            format: InventorySnapshot.expectedFormat,
            boxes: boxes,
            items: items,
            photos: entries
        )
    }

    private func applyLocal(_ snapshot: InventorySnapshot) async throws {
        let stagingDir = fileStore.baseDirectory.appendingPathComponent("sync-staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        var validatedFilenames = Set<String>()
        var photoRecords: [PhotoRecord] = []
        photoRecords.reserveCapacity(snapshot.photos.count)

        for entry in snapshot.photos {
            guard Self.isSafeFilename(entry.filename) else {
                throw SyncEngineError.unsafeRemotePhoto(entry.filename)
            }
            let safeName = try fileStore.validateFilename(entry.filename)
            guard let bytes = Data(base64Encoded: entry.jpegBase64, options: .ignoreUnknownCharacters),
                  bytes.count >= 100,
                  bytes.count <= PhotoFileStore.maxSyncBytes,
                  PhotoFileStore.isValidJPEGData(bytes) else {
                throw SyncEngineError.photoTooLarge
            }
            let stagedURL = stagingDir.appendingPathComponent(safeName)
            try bytes.write(to: stagedURL, options: .atomic)
            validatedFilenames.insert(safeName)
            photoRecords.append(PhotoRecord(id: entry.id, boxId: entry.boxId, filename: safeName))
        }

        let oldFilenames = Set(try await repository.allPhotos().map(\.filename))
        var movedToLive: [URL] = []
        var overwrittenBackups: [(filename: String, backupURL: URL)] = []

        do {
            for record in photoRecords {
                let src = stagingDir.appendingPathComponent(record.filename)
                let dst = try fileStore.photoURL(for: record.filename)
                if FileManager.default.fileExists(atPath: dst.path) {
                    let backup = stagingDir.appendingPathComponent("old-\(UUID().uuidString.lowercased())-\(record.filename)")
                    try FileManager.default.moveItem(at: dst, to: backup)
                    overwrittenBackups.append((record.filename, backup))
                }
                try FileManager.default.moveItem(at: src, to: dst)
                movedToLive.append(dst)
            }

            try await repository.replaceAll(
                boxes: snapshot.boxes,
                items: snapshot.items,
                photos: photoRecords
            )
        } catch {
            for url in movedToLive {
                try? FileManager.default.removeItem(at: url)
            }
            for item in overwrittenBackups {
                if let dst = try? fileStore.photoURL(for: item.filename) {
                    try? FileManager.default.moveItem(at: item.backupURL, to: dst)
                }
            }
            throw error
        }

        let obsolete = Array(oldFilenames.subtracting(validatedFilenames))
        fileStore.deletePhotoFiles(obsolete)
    }

    private func requestJSON(method: String, jsonObject: [String: Any]?) async throws -> [String: Any] {
        var headers: [String: String] = [
            "X-Box-Sync-Key": token,
            "Accept-Encoding": "gzip"
        ]
        var bodyData: Data?
        if let jsonObject {
            let rawJSON = try JSONSerialization.data(withJSONObject: jsonObject, options: [.withoutEscapingSlashes])
            bodyData = try GzipCodec.compress(rawJSON)
            headers["Content-Type"] = "application/json"
            headers["Content-Encoding"] = "gzip"
        }

        let response = try await httpClient.send(method: method, url: url, headers: headers, body: bodyData)

        let payloadData: Data
        let hasGzipHeader = response.headers["content-encoding"]?.lowercased().contains("gzip") == true
        let hasGzipMagic = response.body.count >= 2 && response.body[0] == 0x1F && response.body[1] == 0x8B
        if hasGzipHeader && hasGzipMagic || hasGzipMagic {
            payloadData = try GzipCodec.decompress(response.body, maxBytes: Self.maxPayloadBytes)
        } else {
            guard response.body.count <= Self.maxPayloadBytes else {
                throw GzipError.outputTooLarge
            }
            payloadData = response.body
        }

        let json = (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
        if response.statusCode == 403 {
            throw SyncEngineError.serverRejectedPairing
        }
        if response.statusCode == 409 {
            throw SyncEngineError.serverRevisionConflict
        }
        if response.statusCode != 200 {
            let serverMsg = (json["error"] as? String) ?? "Pi sync failed (\(response.statusCode))."
            throw SyncEngineError.serverError(serverMsg)
        }
        guard !json.isEmpty else {
            throw SyncEngineError.invalidServerResponse("Empty response from Pi.")
        }
        return json
    }

    private static func isSafeFilename(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty &&
            !trimmed.contains("/") &&
            !trimmed.contains("\\") &&
            !trimmed.contains("..") &&
            !trimmed.contains("\0") &&
            !trimmed.hasPrefix(".")
    }
}
