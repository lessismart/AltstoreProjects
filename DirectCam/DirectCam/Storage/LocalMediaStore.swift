import Foundation
import Photos
import UIKit

final class LocalMediaStore {
    let mediaRoot: URL
    private let indexURL: URL
    private let alertsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseDirectory: URL? = nil) {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            root = appSupport.appendingPathComponent("DirectCam", isDirectory: true)
        }
        self.mediaRoot = root.appendingPathComponent("Media", isDirectory: true)
        self.indexURL = root.appendingPathComponent("media-index.json")
        self.alertsURL = root.appendingPathComponent("vision-alerts.json")
        try? FileManager.default.createDirectory(at: self.mediaRoot, withIntermediateDirectories: true)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    func loadMediaItems() -> [LocalMediaItem] {
        guard let data = try? Data(contentsOf: self.indexURL),
              let items = try? self.decoder.decode([LocalMediaItem].self, from: data) else {
            return []
        }
        return items.filter { FileManager.default.fileExists(atPath: self.fileURL(forRelativePath: $0.relativePath).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func saveMediaItems(_ items: [LocalMediaItem]) throws {
        let data = try self.encoder.encode(items)
        try data.write(to: self.indexURL, options: [.atomic])
    }

    func loadAlerts() -> [VisionAlertEvent] {
        guard let data = try? Data(contentsOf: self.alertsURL),
              let events = try? self.decoder.decode([VisionAlertEvent].self, from: data) else {
            return []
        }
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    func saveAlerts(_ events: [VisionAlertEvent]) throws {
        let trimmed = Array(events.sorted { $0.timestamp > $1.timestamp }.prefix(200))
        let data = try self.encoder.encode(trimmed)
        try data.write(to: self.alertsURL, options: [.atomic])
    }

    func fileURL(forRelativePath relPath: String) -> URL {
        let safeName = (relPath as NSString).lastPathComponent
        return self.mediaRoot.appendingPathComponent(safeName)
    }

    func saveSnapshot(
        jpegData: Data,
        cameraID: UUID,
        cameraName: String,
        caption: String = "",
        maxStorageMB: Int = 2048
    ) throws -> LocalMediaItem {
        let id = UUID()
        let filename = "snap-\(Int(Date().timeIntervalSince1970))-\(id.uuidString.prefix(8)).jpg"
        let dest = self.mediaRoot.appendingPathComponent(filename)
        try jpegData.write(to: dest, options: [.atomic])

        let item = LocalMediaItem(
            id: id,
            cameraID: cameraID,
            cameraName: cameraName,
            kind: .snapshot,
            relativePath: filename,
            createdAt: Date(),
            fileSizeBytes: Int64(jpegData.count),
            caption: caption
        )
        var all = self.loadMediaItems()
        all.insert(item, at: 0)
        all = try self.enforceStorageQuota(items: all, maxStorageMB: maxStorageMB)
        try self.saveMediaItems(all)
        return item
    }

    func newRecordingURL(prefix: String = "clip", ext: String = "mp4") -> (relativePath: String, url: URL) {
        let id = UUID().uuidString.prefix(8)
        let filename = "\(prefix)-\(Int(Date().timeIntervalSince1970))-\(id).\(ext)"
        return (filename, self.mediaRoot.appendingPathComponent(filename))
    }

    func registerVideoFile(
        relativePath: String,
        cameraID: UUID,
        cameraName: String,
        kind: LocalMediaKind,
        caption: String = "",
        maxStorageMB: Int = 2048
    ) throws -> LocalMediaItem {
        let url = self.fileURL(forRelativePath: relativePath)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let item = LocalMediaItem(
            id: UUID(),
            cameraID: cameraID,
            cameraName: cameraName,
            kind: kind,
            relativePath: relativePath,
            createdAt: Date(),
            fileSizeBytes: size,
            caption: caption
        )
        var all = self.loadMediaItems()
        all.insert(item, at: 0)
        all = try self.enforceStorageQuota(items: all, maxStorageMB: maxStorageMB)
        try self.saveMediaItems(all)
        return item
    }

    func deleteItem(_ item: LocalMediaItem) throws {
        let url = self.fileURL(forRelativePath: item.relativePath)
        try? FileManager.default.removeItem(at: url)
        let remaining = self.loadMediaItems().filter { $0.id != item.id }
        try self.saveMediaItems(remaining)
    }

    func totalUsedBytes(for items: [LocalMediaItem]? = nil) -> Int64 {
        let list = items ?? self.loadMediaItems()
        return list.reduce(0) { $0 + max(0, $1.fileSizeBytes) }
    }

    @discardableResult
    func enforceStorageQuota(items: [LocalMediaItem], maxStorageMB: Int) throws -> [LocalMediaItem] {
        let budget = Int64(max(50, maxStorageMB)) * 1024 * 1024
        var sorted = items.sorted { $0.createdAt > $1.createdAt }
        var total = sorted.reduce(Int64(0)) { $0 + max(0, $1.fileSizeBytes) }
        while total > budget, sorted.count > 1, let oldest = sorted.popLast() {
            try? FileManager.default.removeItem(at: self.fileURL(forRelativePath: oldest.relativePath))
            total -= max(0, oldest.fileSizeBytes)
        }
        return sorted
    }

    static func exportImageToPhotos(_ image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func exportVideoToPhotos(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
