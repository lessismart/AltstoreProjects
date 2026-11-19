import CryptoKit
import Foundation
import UIKit

enum PhotoFileStoreError: LocalizedError, Sendable {
    case unsafeFilename(String)
    case invalidImage
    case photoTooLarge
    case missingPhoto

    var errorDescription: String? {
        switch self {
        case .unsafeFilename: return "Invalid photo filename."
        case .invalidImage: return "This photo could not be opened as an image."
        case .photoTooLarge: return "Photo is too large. Try a closer crop."
        case .missingPhoto: return "The saved photo file is missing."
        }
    }
}

final class PhotoFileStore: Sendable {
    static let maxStoredBytes = 2_400_000
    static let preferredMaxBytes = 2_000_000
    static let maxSyncBytes = 5_000_000

    let baseDirectory: URL
    let photosDirectory: URL
    let overlaysDirectory: URL

    init(baseDirectory: URL? = nil) throws {
        let resolvedBase: URL
        if let baseDirectory {
            resolvedBase = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            resolvedBase = appSupport.appendingPathComponent("BoxFinder", isDirectory: true)
        }
        self.baseDirectory = resolvedBase
        self.photosDirectory = resolvedBase.appendingPathComponent("photos", isDirectory: true)
        self.overlaysDirectory = resolvedBase.appendingPathComponent("photo-overlays", isDirectory: true)

        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: overlaysDirectory, withIntermediateDirectories: true)
    }

    func validateFilename(_ filename: String) throws -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 255,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains(".."),
              !trimmed.contains("\0"),
              !trimmed.hasPrefix(".") else {
            throw PhotoFileStoreError.unsafeFilename(filename)
        }
        let candidate = photosDirectory.appendingPathComponent(trimmed).standardizedFileURL
        let rootPath = photosDirectory.standardizedFileURL.path
        guard candidate.path.hasPrefix(rootPath + "/") else {
            throw PhotoFileStoreError.unsafeFilename(filename)
        }
        return trimmed
    }

    func photoURL(for filename: String) throws -> URL {
        let safe = try validateFilename(filename)
        return photosDirectory.appendingPathComponent(safe)
    }

    func normalizeAndEncodeJPEG(from image: UIImage, maxDimension: CGFloat = 2048) throws -> Data {
        let upright = renderUprightImage(image, maxDimension: maxDimension)
        guard let initialData = upright.jpegData(compressionQuality: 0.82) else {
            throw PhotoFileStoreError.invalidImage
        }
        if initialData.count <= Self.preferredMaxBytes {
            return initialData
        }
        guard let smallerData = upright.jpegData(compressionQuality: 0.65) else {
            throw PhotoFileStoreError.invalidImage
        }
        guard smallerData.count <= Self.maxStoredBytes else {
            throw PhotoFileStoreError.photoTooLarge
        }
        return smallerData
    }

    func normalizeAndEncodeJPEG(fromRawData rawData: Data, maxDimension: CGFloat = 2048) throws -> Data {
        guard let image = UIImage(data: rawData) else {
            throw PhotoFileStoreError.invalidImage
        }
        return try normalizeAndEncodeJPEG(from: image, maxDimension: maxDimension)
    }

    func saveNormalizedPhoto(_ image: UIImage) throws -> (filename: String, data: Data, url: URL) {
        let data = try normalizeAndEncodeJPEG(from: image)
        let filename = UUID().uuidString.lowercased() + ".jpg"
        let url = try photoURL(for: filename)
        try data.write(to: url, options: .atomic)
        return (filename, data, url)
    }

    func readPhotoData(filename: String, maxBytes: Int = PhotoFileStore.maxSyncBytes) throws -> Data {
        let url = try photoURL(for: filename)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw PhotoFileStoreError.missingPhoto
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else {
            throw PhotoFileStoreError.photoTooLarge
        }
        return data
    }

    func deletePhotoFiles(_ filenames: [String]) {
        for filename in filenames {
            guard let url = try? photoURL(for: filename) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func makeBoundedCopy(from photoURL: URL, maxDimension: CGFloat, quality: CGFloat = 0.85) throws -> URL {
        guard FileManager.default.isReadableFile(atPath: photoURL.path) else {
            throw PhotoFileStoreError.missingPhoto
        }
        let rawData = try Data(contentsOf: photoURL)
        guard let image = UIImage(data: rawData) else {
            throw PhotoFileStoreError.invalidImage
        }
        let scaled = renderUprightImage(image, maxDimension: maxDimension)
        guard let jpegData = scaled.jpegData(compressionQuality: quality) else {
            throw PhotoFileStoreError.invalidImage
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bf-ai-\(UUID().uuidString.lowercased()).jpg")
        try jpegData.write(to: tempURL, options: .atomic)
        return tempURL
    }

    func renderUprightImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return image }
        let longest = max(sourceSize.width, sourceSize.height)
        let scaleFactor = longest > maxDimension ? (maxDimension / longest) : 1.0
        let targetSize = CGSize(
            width: max(1, floor(sourceSize.width * scaleFactor)),
            height: max(1, floor(sourceSize.height * scaleFactor))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256Hex(of: data)
    }

    static func isValidJPEGData(_ data: Data) -> Bool {
        guard data.count >= 100 else { return false }
        let bytes = [UInt8](data.prefix(2))
        guard bytes == [0xFF, 0xD8] else { return false }
        return UIImage(data: data) != nil
    }
}
