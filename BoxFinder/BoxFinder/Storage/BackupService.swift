import Foundation

enum BackupError: LocalizedError, Sendable {
    case fileTooLarge
    case invalidFormat(String)
    case missingPhoto(Int64)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return "Backup file exceeds the 70 MB limit."
        case .invalidFormat(let detail):
            return detail
        case .missingPhoto(let id):
            return "A stored photo is missing (ID \(id))."
        }
    }
}

struct StagedPhoto: Sendable {
    let record: PhotoRecord
    let jpegData: Data
    let detections: PhotoOverlayMetadata?
}

struct BackupPreview: Sendable {
    let boxes: [BoxRecord]
    let items: [ItemRecord]
    let photos: [StagedPhoto]
}

final class BackupService: Sendable {
    static let maxBackupBytes = 70_000_000
    static let maxTotalPhotoBytes = 50_000_000
    static let maxBoxes = 1000
    static let maxItems = 10000
    static let maxPhotos = 4000
    static let maxPhotosPerBox = 4

    private let repository: BoxRepository
    private let fileStore: PhotoFileStore
    private let annotationStore: PhotoAnnotationStore

    init(repository: BoxRepository, fileStore: PhotoFileStore, annotationStore: PhotoAnnotationStore) {
        self.repository = repository
        self.fileStore = fileStore
        self.annotationStore = annotationStore
    }

    func exportBackup() async throws -> Data {
        let boxes = try await repository.allBoxes()
        let items = try await repository.allItems()
        let photoRecords = try await repository.allPhotos()

        var packedPhotos: [BackupPhotoEntry] = []
        packedPhotos.reserveCapacity(photoRecords.count)

        for row in photoRecords {
            let url = try fileStore.photoURL(for: row.filename)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw BackupError.missingPhoto(row.id)
            }
            let bytes = try fileStore.readPhotoData(filename: row.filename)
            let detections = annotationStore.load(forPhotoAt: url)
            packedPhotos.append(BackupPhotoEntry(
                id: row.id,
                boxId: row.boxId,
                filename: row.filename,
                jpegBase64: bytes.base64EncodedString(),
                detections: detections
            ))
        }

        let snapshot = InventorySnapshot(
            format: InventorySnapshot.expectedFormat,
            boxes: boxes,
            items: items,
            photos: packedPhotos
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    func previewImport(data: Data) throws -> BackupPreview {
        guard data.count <= Self.maxBackupBytes else {
            throw BackupError.fileTooLarge
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackupError.invalidFormat("This is not a valid JSON backup file.")
        }
        guard (root["format"] as? String) == InventorySnapshot.expectedFormat else {
            throw BackupError.invalidFormat("This is not a compatible Box Finder backup (expected \(InventorySnapshot.expectedFormat)).")
        }
        guard let rawBoxes = root["boxes"] as? [Any],
              let rawItems = root["items"] as? [Any],
              let rawPhotos = root["photos"] as? [Any] else {
            throw BackupError.invalidFormat("Backup is missing boxes, items, or photos arrays.")
        }
        guard rawBoxes.count <= Self.maxBoxes,
              rawItems.count <= Self.maxItems,
              rawPhotos.count <= Self.maxPhotos else {
            throw BackupError.invalidFormat("Backup contains too many records.")
        }

        let codeRegex = try NSRegularExpression(pattern: "^BX-[0-9]{4,}$")
        var seenBoxIds = Set<Int64>()
        var seenBoxCodes = Set<String>()
        var boxes: [BoxRecord] = []
        boxes.reserveCapacity(rawBoxes.count)

        for entry in rawBoxes {
            guard let dict = entry as? [String: Any] else {
                throw BackupError.invalidFormat("Invalid box entry in backup.")
            }
            let id = try validRecordID(dict["id"], field: "box id")
            let code = try validText(dict["code"], limit: 32, required: true, field: "box code")
            let range = NSRange(location: 0, length: code.utf16.count)
            guard codeRegex.firstMatch(in: code, range: range) != nil else {
                throw BackupError.invalidFormat("Invalid box code '\(code)' in backup.")
            }
            guard seenBoxIds.insert(id).inserted, seenBoxCodes.insert(code).inserted else {
                throw BackupError.invalidFormat("Duplicate box ID or code '\(code)' in backup.")
            }
            let name = try validText(dict["name"], limit: 100, required: true, field: "box name")
            let location = try validText(dict["location"], limit: 100, required: true, field: "box location")
            let notes = try validText(dict["notes"] ?? "", limit: 1000, required: false, field: "box notes")
            let updated: Int64
            if let rawUpdated = dict["updated"] {
                updated = try validOptionalEpoch(rawUpdated)
            } else {
                updated = Int64(Date().timeIntervalSince1970 * 1000)
            }
            boxes.append(BoxRecord(id: id, code: code, name: name, location: location, notes: notes, updated: updated))
        }

        var seenItemIds = Set<Int64>()
        var items: [ItemRecord] = []
        items.reserveCapacity(rawItems.count)

        for entry in rawItems {
            guard let dict = entry as? [String: Any] else {
                throw BackupError.invalidFormat("Invalid item entry in backup.")
            }
            let id = try validRecordID(dict["id"], field: "item id")
            let boxId = try validRecordID(dict["box_id"], field: "item box_id")
            guard seenItemIds.insert(id).inserted, seenBoxIds.contains(boxId) else {
                throw BackupError.invalidFormat("Backup item references an unknown or duplicate ID.")
            }
            let name = try validText(dict["name"], limit: 120, required: true, field: "item name")
            let category = try validText(dict["category"] ?? "", limit: 80, required: false, field: "item category")
            let notes = try validText(dict["notes"] ?? "", limit: 500, required: false, field: "item notes")
            let source = try validText(dict["source"] ?? "manual", limit: 30, required: false, field: "item source")
            let qty = try validQuantity(dict["quantity"] ?? 1)
            items.append(ItemRecord(
                id: id,
                boxId: boxId,
                name: name,
                category: category,
                quantity: qty,
                notes: notes,
                source: source.isEmpty ? "manual" : source
            ))
        }

        var seenPhotoIds = Set<Int64>()
        var seenFilenames = Set<String>()
        var photoCountsByBox: [Int64: Int] = [:]
        var totalPhotoBytes = 0
        var stagedPhotos: [StagedPhoto] = []
        stagedPhotos.reserveCapacity(rawPhotos.count)

        for entry in rawPhotos {
            guard let dict = entry as? [String: Any] else {
                throw BackupError.invalidFormat("Invalid photo entry in backup.")
            }
            let id = try validRecordID(dict["id"], field: "photo id")
            let boxId = try validRecordID(dict["box_id"], field: "photo box_id")
            guard seenPhotoIds.insert(id).inserted, seenBoxIds.contains(boxId) else {
                throw BackupError.invalidFormat("Backup photo references an unknown or duplicate ID.")
            }
            let nextCount = (photoCountsByBox[boxId] ?? 0) + 1
            guard nextCount <= Self.maxPhotosPerBox else {
                throw BackupError.invalidFormat("A box in the backup has more than \(Self.maxPhotosPerBox) photos.")
            }
            photoCountsByBox[boxId] = nextCount

            guard let rawFilename = dict["filename"] as? String else {
                throw BackupError.invalidFormat("Missing photo filename in backup.")
            }
            let filename = try fileStore.validateFilename(rawFilename)
            guard seenFilenames.insert(filename).inserted else {
                throw BackupError.invalidFormat("Duplicate photo filename '\(filename)' in backup.")
            }

            guard let b64 = dict["jpegBase64"] as? String,
                  let decoded = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                  decoded.count >= 100,
                  decoded.count <= PhotoFileStore.maxSyncBytes,
                  PhotoFileStore.isValidJPEGData(decoded) else {
                throw BackupError.invalidFormat("Invalid JPEG photo data in backup.")
            }
            totalPhotoBytes += decoded.count
            guard totalPhotoBytes <= Self.maxTotalPhotoBytes else {
                throw BackupError.invalidFormat("Backup photo set exceeds the 50 MB limit.")
            }

            let optionalDetections = parseLenientDetections(dict["detections"], expectedHash: PhotoFileStore.sha256Hex(of: decoded))
            stagedPhotos.append(StagedPhoto(
                record: PhotoRecord(id: id, boxId: boxId, filename: filename),
                jpegData: decoded,
                detections: optionalDetections
            ))
        }

        return BackupPreview(boxes: boxes, items: items, photos: stagedPhotos)
    }

    func commitImport(_ preview: BackupPreview) async throws {
        let stagingDir = fileStore.baseDirectory.appendingPathComponent("import-staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        // 1. Stage all JPEGs in stagingDir before touching live photos or database.
        for staged in preview.photos {
            let url = stagingDir.appendingPathComponent(staged.record.filename)
            try staged.jpegData.write(to: url, options: .atomic)
        }

        let existingPhotos = try await repository.allPhotos()
        let oldFilenames = Set(existingPhotos.map(\.filename))
        let newFilenames = Set(preview.photos.map(\.record.filename))

        // 2. Move staged files into live photos/ atomically using a temporary backup of overwritten filenames.
        var backedUpOverwrites: [(filename: String, backupURL: URL)] = []
        var installedNewURLs: [URL] = []

        do {
            for staged in preview.photos {
                let src = stagingDir.appendingPathComponent(staged.record.filename)
                let dst = try fileStore.photoURL(for: staged.record.filename)
                if FileManager.default.fileExists(atPath: dst.path) {
                    let tempBackup = stagingDir.appendingPathComponent("old-\(UUID().uuidString.lowercased())-\(staged.record.filename)")
                    try FileManager.default.moveItem(at: dst, to: tempBackup)
                    backedUpOverwrites.append((staged.record.filename, tempBackup))
                }
                try FileManager.default.moveItem(at: src, to: dst)
                installedNewURLs.append(dst)
            }

            try await repository.replaceAll(
                boxes: preview.boxes,
                items: preview.items,
                photos: preview.photos.map(\.record)
            )
        } catch {
            // Roll back any installed new files and restore overwritten originals.
            for url in installedNewURLs {
                try? FileManager.default.removeItem(at: url)
            }
            for item in backedUpOverwrites {
                if let dst = try? fileStore.photoURL(for: item.filename) {
                    try? FileManager.default.moveItem(at: item.backupURL, to: dst)
                }
            }
            throw error
        }

        // 3. Delete superseded photos and restore optional valid detections sidecars.
        let obsolete = Array(oldFilenames.subtracting(newFilenames))
        fileStore.deletePhotoFiles(obsolete)

        for staged in preview.photos {
            if let detections = staged.detections,
               let liveURL = try? fileStore.photoURL(for: staged.record.filename) {
                try? annotationStore.restore(detections, forPhotoAt: liveURL)
            }
        }
    }

    // MARK: - Validation Helpers

    private func parseLenientDetections(_ raw: Any?, expectedHash: String) -> PhotoOverlayMetadata? {
        guard let dict = raw as? [String: Any],
              let objects = try? PhotoAnnotationStore.normalize(jsonObject: dict) else {
            return nil
        }
        let storedHash = (dict["imageSha256"] as? String) ?? expectedHash
        guard storedHash == expectedHash else { return nil }
        let provider = (dict["provider"] as? String) ?? "offline"
        let model = (dict["model"] as? String) ?? ""
        let created = (dict["created"] as? NSNumber)?.int64Value ?? 0
        return PhotoOverlayMetadata(
            objects: objects,
            imageSha256: expectedHash,
            provider: provider,
            model: model,
            created: created
        )
    }

    private func validRecordID(_ raw: Any?, field: String) throws -> Int64 {
        guard let num = raw as? NSNumber,
              CFGetTypeID(num) != CFBooleanGetTypeID(),
              floor(num.doubleValue) == num.doubleValue else {
            throw BackupError.invalidFormat("Invalid \(field) in backup.")
        }
        let value = num.int64Value
        guard value >= 1 && value <= Int64(Int32.max) else {
            throw BackupError.invalidFormat("Out-of-range \(field) in backup.")
        }
        return value
    }

    private func validQuantity(_ raw: Any) throws -> Int {
        guard let num = raw as? NSNumber,
              CFGetTypeID(num) != CFBooleanGetTypeID(),
              floor(num.doubleValue) == num.doubleValue else {
            throw BackupError.invalidFormat("Invalid item quantity in backup.")
        }
        let value = num.intValue
        guard value >= 1 && value <= 9999 else {
            throw BackupError.invalidFormat("Item quantity must be between 1 and 9999.")
        }
        return value
    }

    private func validOptionalEpoch(_ raw: Any) throws -> Int64 {
        guard let num = raw as? NSNumber,
              CFGetTypeID(num) != CFBooleanGetTypeID() else {
            throw BackupError.invalidFormat("Invalid box timestamp in backup.")
        }
        return num.int64Value
    }

    private func validText(_ raw: Any?, limit: Int, required: Bool, field: String) throws -> String {
        guard let str = raw as? String else {
            throw BackupError.invalidFormat("Invalid \(field) in backup.")
        }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= limit else {
            throw BackupError.invalidFormat("\(field.capitalized) exceeds \(limit) characters.")
        }
        if required && trimmed.isEmpty {
            throw BackupError.invalidFormat("Missing required \(field) in backup.")
        }
        return trimmed
    }
}
