import CryptoKit
import Foundation

enum ModelStoreError: LocalizedError, Sendable {
    case invalidExtension
    case invalidDownloadURL
    case cannotOpenSource
    case fileTooSmall
    case fileTooLarge
    case insufficientStorage(requiredMB: Int64, availableMB: Int64)
    case checksumMismatch(expected: String, actual: String)
    case busyDeleting

    var errorDescription: String? {
        switch self {
        case .invalidExtension:
            return "Choose a .litertlm model file built for LiteRT-LM vision."
        case .invalidDownloadURL:
            return "Enter an HTTPS download URL for a .litertlm model file."
        case .cannotOpenSource:
            return "Cannot open the selected model file."
        case .fileTooSmall:
            return "This model file is too small. Select a complete vision-capable .litertlm file."
        case .fileTooLarge:
            return "Model exceeds the 5 GB limit. Choose a smaller LiteRT-LM model."
        case .insufficientStorage(let requiredMB, let availableMB):
            return "Not enough free storage (\(availableMB) MB available; need at least \(requiredMB) MB with safety headroom)."
        case .checksumMismatch(let expected, let actual):
            return "SHA-256 checksum mismatch.\nExpected: \(expected)\nActual: \(actual)"
        case .busyDeleting:
            return "Wait for the current offline AI request to finish before removing this model."
        }
    }
}

final class ModelStore: @unchecked Sendable {
    static let defaultMinimumBytes: Int64 = 100_000_000
    static let defaultMaximumBytes: Int64 = 5_000_000_000
    static let requiredHeadroomBytes: Int64 = 512_000_000
    static let lowMemoryThresholdBytes: UInt64 = 6_000_000_000

    let modelsDirectory: URL
    private let minimumModelBytes: Int64
    private let maximumModelBytes: Int64

    init(
        baseDirectory: URL? = nil,
        minimumModelBytes: Int64 = ModelStore.defaultMinimumBytes,
        maximumModelBytes: Int64 = ModelStore.defaultMaximumBytes
    ) throws {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            base = appSupport.appendingPathComponent("BoxFinder", isDirectory: true)
        }
        self.modelsDirectory = base.appendingPathComponent("models", isDirectory: true)
        self.minimumModelBytes = minimumModelBytes
        self.maximumModelBytes = maximumModelBytes
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    static var isLowMemoryDevice: Bool {
        ProcessInfo.processInfo.physicalMemory < lowMemoryThresholdBytes
    }

    static var deviceRAMDescription: String {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return String(format: "%.1f GB RAM", gb)
    }

    func modelURL(for slot: OfflineModelSlot) -> URL {
        modelsDirectory.appendingPathComponent(slot.filenameOnDisk)
    }

    func isModelPresent(for slot: OfflineModelSlot) -> Bool {
        FileManager.default.isReadableFile(atPath: modelURL(for: slot).path)
    }

    func modelSizeBytes(for slot: OfflineModelSlot) -> Int64? {
        let url = modelURL(for: slot)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    func availableDiskBytes() -> Int64 {
        let values = try? modelsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        if let standard = values?.volumeAvailableCapacity {
            return Int64(standard)
        }
        return 0
    }

    func importModel(
        from sourceURL: URL,
        slot: OfflineModelSlot,
        expectedSHA256: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (displayName: String, byteCount: Int64, sha256: String) {
        let filename = sourceURL.lastPathComponent
        guard filename.lowercased().hasSuffix(".litertlm") else {
            throw ModelStoreError.invalidExtension
        }

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceAttrs = try? FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let expectedTotal = (sourceAttrs?[.size] as? NSNumber)?.int64Value ?? 0
        let available = availableDiskBytes()
        if expectedTotal > 0 && expectedTotal + Self.requiredHeadroomBytes > available {
            throw ModelStoreError.insufficientStorage(
                requiredMB: (expectedTotal + Self.requiredHeadroomBytes) / 1_000_000,
                availableMB: available / 1_000_000
            )
        }

        let stagingURL = modelsDirectory.appendingPathComponent("import-\(UUID().uuidString.lowercased()).part")
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        guard let input = InputStream(url: sourceURL) else {
            throw ModelStoreError.cannotOpenSource
        }
        input.open()
        defer { input.close() }

        FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: stagingURL)
        defer { try? outputHandle.close() }

        var hasher = SHA256()
        var totalWritten: Int64 = 0
        let bufferSize = 1_048_576
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            try Task.checkCancellation()
            let readCount = input.read(&buffer, maxLength: bufferSize)
            if readCount < 0 {
                throw ModelStoreError.cannotOpenSource
            }
            if readCount == 0 {
                break
            }

            totalWritten += Int64(readCount)
            if totalWritten > maximumModelBytes {
                throw ModelStoreError.fileTooLarge
            }
            if totalWritten > availableDiskBytes() - (Self.requiredHeadroomBytes / 2) {
                throw ModelStoreError.insufficientStorage(
                    requiredMB: (totalWritten + Self.requiredHeadroomBytes) / 1_000_000,
                    availableMB: availableDiskBytes() / 1_000_000
                )
            }

            let slice = Data(bytes: buffer, count: readCount)
            hasher.update(data: slice)
            try outputHandle.write(contentsOf: slice)

            if expectedTotal > 0 {
                progress(min(1.0, Double(totalWritten) / Double(expectedTotal)))
            }
        }

        try outputHandle.synchronize()
        try outputHandle.close()

        return try finalizeStagingFile(
            stagingURL: stagingURL,
            targetSlot: slot,
            displayName: filename,
            totalBytes: totalWritten,
            hasher: hasher,
            expectedSHA256: expectedSHA256
        )
    }

    func downloadModel(
        from remoteURL: URL,
        slot: OfflineModelSlot,
        expectedSHA256: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> (displayName: String, byteCount: Int64, sha256: String) {
        guard remoteURL.scheme?.lowercased() == "https",
              remoteURL.lastPathComponent.lowercased().hasSuffix(".litertlm") else {
            throw ModelStoreError.invalidDownloadURL
        }

        let delegate = ModelDownloadDelegate(progressHandler: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let downloadedTempURL = try await withTaskCancellationHandler {
            try await delegate.download(url: remoteURL, with: session)
        } onCancel: {
            delegate.cancel()
        }
        defer { try? FileManager.default.removeItem(at: downloadedTempURL) }

        let attrs = try FileManager.default.attributesOfItem(atPath: downloadedTempURL.path)
        let byteCount = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount <= maximumModelBytes else {
            throw ModelStoreError.fileTooLarge
        }
        guard byteCount >= minimumModelBytes else {
            throw ModelStoreError.fileTooSmall
        }

        let available = availableDiskBytes()
        if byteCount + Self.requiredHeadroomBytes > available {
            throw ModelStoreError.insufficientStorage(
                requiredMB: (byteCount + Self.requiredHeadroomBytes) / 1_000_000,
                availableMB: available / 1_000_000
            )
        }

        let stagingURL = modelsDirectory.appendingPathComponent("download-\(UUID().uuidString.lowercased()).part")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try FileManager.default.moveItem(at: downloadedTempURL, to: stagingURL)

        let hasher = try computeSHA256Streaming(of: stagingURL)
        return try finalizeStagingFile(
            stagingURL: stagingURL,
            targetSlot: slot,
            displayName: remoteURL.lastPathComponent,
            totalBytes: byteCount,
            hasher: hasher,
            expectedSHA256: expectedSHA256
        )
    }

    func removeModel(for slot: OfflineModelSlot) throws {
        let url = modelURL(for: slot)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func computeSHA256Streaming(of url: URL) throws -> SHA256 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}
        return hasher
    }

    private func finalizeStagingFile(
        stagingURL: URL,
        targetSlot: OfflineModelSlot,
        displayName: String,
        totalBytes: Int64,
        hasher: SHA256,
        expectedSHA256: String?
    ) throws -> (displayName: String, byteCount: Int64, sha256: String) {
        guard totalBytes >= minimumModelBytes else {
            throw ModelStoreError.fileTooSmall
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expected.isEmpty,
           expected != digest {
            throw ModelStoreError.checksumMismatch(expected: expected, actual: digest)
        }

        let destination = modelURL(for: targetSlot)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagingURL)
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destination)
        }
        return (displayName, totalBytes, digest)
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressHandler: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var activeTask: URLSessionDownloadTask?

    init(progressHandler: @escaping @Sendable (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func download(url: URL, with session: URLSession) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            self.activeTask = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        let task = activeTask
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let persistentCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("bf-dl-\(UUID().uuidString.lowercased()).litertlm")
        do {
            if FileManager.default.fileExists(atPath: persistentCopy.path) {
                try FileManager.default.removeItem(at: persistentCopy)
            }
            try FileManager.default.moveItem(at: location, to: persistentCopy)
            resume(with: .success(persistentCopy))
        } catch {
            resume(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resume(with: .failure(error))
        }
    }

    private func resume(with result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        activeTask = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}
