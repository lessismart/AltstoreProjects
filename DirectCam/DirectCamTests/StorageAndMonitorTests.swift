import XCTest
@testable import DirectCam

final class StorageAndMonitorTests: XCTestCase {
    func testCameraProfileExportExcludesAllPasswords() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DirectCamTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = CameraStore(baseDirectory: tempDir)
        let profile = CameraProfile(name: "Driveway", host: "192.168.2.46", username: "admin")
        let exported = try store.exportProfilesData(cameras: [profile], settings: MonitorSettings())
        let jsonString = try XCTUnwrap(String(data: exported, encoding: .utf8))
        XCTAssertFalse(jsonString.localizedCaseInsensitiveContains("password"))

        let reimported = try store.importProfilesData(exported)
        XCTAssertEqual(reimported.cameras.count, 1)
        XCTAssertEqual(reimported.cameras[0].host, "192.168.2.46")
    }

    func testLocalMediaStoreEnforcesQuotaEvictingOldestFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DirectCamMedia-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mediaStore = LocalMediaStore(baseDirectory: tempDir)
        let camID = UUID()
        let older = LocalMediaItem(
            id: UUID(),
            cameraID: camID,
            cameraName: "Yard",
            kind: .snapshot,
            relativePath: "old.jpg",
            createdAt: Date(timeIntervalSince1970: 100),
            fileSizeBytes: 40 * 1024 * 1024,
            caption: ""
        )
        let newer = LocalMediaItem(
            id: UUID(),
            cameraID: camID,
            cameraName: "Yard",
            kind: .snapshot,
            relativePath: "new.jpg",
            createdAt: Date(timeIntervalSince1970: 200),
            fileSizeBytes: 25 * 1024 * 1024,
            caption: ""
        )
        try Data([0xFF, 0xD8]).write(to: mediaStore.fileURL(forRelativePath: "old.jpg"))
        try Data([0xFF, 0xD8]).write(to: mediaStore.fileURL(forRelativePath: "new.jpg"))

        let retained = try mediaStore.enforceStorageQuota(items: [older, newer], maxStorageMB: 50)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained[0].relativePath, "new.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaStore.fileURL(forRelativePath: "old.jpg").path))
    }

    func testVisionCoordinateTransformAndCooldownGating() {
        // Vision origin is bottom-left: y=0.2, h=0.3 -> topLeft y = 1.0 - 0.2 - 0.3 = 0.5
        let topLeft = VisionAlertEngine.convertVisionBoundingBoxToTopLeft(CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.3))
        XCTAssertEqual(topLeft.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 0.5, accuracy: 0.001)

        let detections = [
            VisionDetectionBox(kind: .human, confidence: 0.85, normalizedRectTopLeft: (0.1, 0.2, 0.2, 0.4)),
            VisionDetectionBox(kind: .pet, confidence: 0.40, normalizedRectTopLeft: (0.5, 0.5, 0.1, 0.1))
        ]
        let now = Date()
        let blockedByCooldown = VisionAlertEngine.evaluateAlert(
            detections: detections,
            minConfidence: 0.65,
            cooldownSeconds: 20,
            lastAlertDate: now.addingTimeInterval(-5),
            now: now
        )
        XCTAssertFalse(blockedByCooldown.shouldTrigger)

        let allowed = VisionAlertEngine.evaluateAlert(
            detections: detections,
            minConfidence: 0.65,
            cooldownSeconds: 20,
            lastAlertDate: now.addingTimeInterval(-25),
            now: now
        )
        XCTAssertTrue(allowed.shouldTrigger)
        XCTAssertEqual(allowed.primaryKind, .human)
        XCTAssertEqual(allowed.bestConfidence, 0.85, accuracy: 0.001)
    }

    func testCredentialVaultSavesLoadsAndDeletesPasswordAcrossFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DirectCamVault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let vaultURL = tempDir.appendingPathComponent(".credentials.vault.json")
        let camID = UUID()

        let backend = try KeychainVault.savePassword("P@ssw0rd!", forCameraID: camID, fallbackVaultURL: vaultURL, skipKeychain: true)
        XCTAssertEqual(backend, .localProtectedFile(0))
        XCTAssertEqual(KeychainVault.loadPassword(forCameraID: camID, fallbackVaultURL: vaultURL, skipKeychain: true), "P@ssw0rd!")

        // Updating and clearing password removes entry cleanly
        _ = try KeychainVault.savePassword("Updated#2", forCameraID: camID, fallbackVaultURL: vaultURL, skipKeychain: true)
        XCTAssertEqual(KeychainVault.loadPassword(forCameraID: camID, fallbackVaultURL: vaultURL, skipKeychain: true), "Updated#2")

        KeychainVault.deletePassword(forCameraID: camID, fallbackVaultURL: vaultURL)
        XCTAssertEqual(KeychainVault.loadPassword(forCameraID: camID, fallbackVaultURL: vaultURL, skipKeychain: true), "")
    }
}
