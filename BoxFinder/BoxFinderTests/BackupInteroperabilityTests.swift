import XCTest
@testable import BoxFinder

final class BackupInteroperabilityTests: XCTestCase {
    func testBackupRoundTripPreservesIDsCodesTimestampsJPEGAndDetections() async throws {
        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try SQLiteBoxDatabase(databaseURL: tempDir.appendingPathComponent("boxes.db"))
        let fileStore = try PhotoFileStore(baseDirectory: tempDir)
        let annotations = PhotoAnnotationStore(fileStore: fileStore)
        let backup = BackupService(repository: db, fileStore: fileStore, annotationStore: annotations)

        let jpegData = TestFixtures.makeSolidJPEGData(color: .systemIndigo)
        let filename = "fixture-1.jpg"
        let photoURL = try fileStore.photoURL(for: filename)
        try jpegData.write(to: photoURL)

        let box = BoxRecord(id: 7, code: "BX-0007", name: "Camp Gear", location: "Attic", notes: "Bin 3", updated: 1_760_000_000_000)
        let item = ItemRecord(id: 22, boxId: 7, name: "Headlamp", category: "Outdoors", quantity: 2, notes: "AAA", source: "manual")
        let photo = PhotoRecord(id: 14, boxId: 7, filename: filename)
        try await db.replaceAll(boxes: [box], items: [item], photos: [photo])

        let expectedObjects = [DetectedObject(label: "Headlamp", box2d: [100, 150, 480, 520], uncertain: false)]
        _ = try annotations.save(objects: expectedObjects, forPhotoAt: photoURL, provider: "openrouter", model: "google/gemini-2.5-flash")

        let exportedData = try await backup.exportBackup()
        let exportedString = String(data: exportedData, encoding: .utf8)!
        XCTAssertTrue(exportedString.contains("\"format\":\"box-finder-android-v1\""))
        XCTAssertFalse(exportedString.contains("sync_token"))

        // Import into a clean instance
        let tempDir2 = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir2) }
        let db2 = try SQLiteBoxDatabase(databaseURL: tempDir2.appendingPathComponent("boxes.db"))
        let fileStore2 = try PhotoFileStore(baseDirectory: tempDir2)
        let annotations2 = PhotoAnnotationStore(fileStore: fileStore2)
        let backup2 = BackupService(repository: db2, fileStore: fileStore2, annotationStore: annotations2)

        let preview = try backup2.previewImport(data: exportedData)
        XCTAssertEqual(preview.boxes.count, 1)
        XCTAssertEqual(preview.items.count, 1)
        XCTAssertEqual(preview.photos.count, 1)
        try await backup2.commitImport(preview)

        let restoredBoxes = try await db2.allBoxes()
        let restoredItems = try await db2.allItems()
        let restoredPhotos = try await db2.allPhotos()
        XCTAssertEqual(restoredBoxes.first?.id, 7)
        XCTAssertEqual(restoredBoxes.first?.code, "BX-0007")
        XCTAssertEqual(restoredBoxes.first?.updated, 1_760_000_000_000)
        XCTAssertEqual(restoredItems.first?.id, 22)
        XCTAssertEqual(restoredPhotos.first?.id, 14)

        let restoredURL = try fileStore2.photoURL(for: filename)
        XCTAssertEqual(try Data(contentsOf: restoredURL), jpegData)
        let loadedOverlay = annotations2.load(forPhotoAt: restoredURL)
        XCTAssertEqual(loadedOverlay?.objects.first?.label, "Headlamp")
        XCTAssertEqual(loadedOverlay?.objects.first?.uncertain, false)
    }

    func testOldBackupWithoutDetectionsAndMalformedDetectionsSucceedGracefully() async throws {
        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try SQLiteBoxDatabase(databaseURL: tempDir.appendingPathComponent("boxes.db"))
        let fileStore = try PhotoFileStore(baseDirectory: tempDir)
        let annotations = PhotoAnnotationStore(fileStore: fileStore)
        let backup = BackupService(repository: db, fileStore: fileStore, annotationStore: annotations)

        let b64 = TestFixtures.makeSolidJPEGData().base64EncodedString()
        let payload: [String: Any] = [
            "format": "box-finder-android-v1",
            "boxes": [
                ["id": 1, "code": "BX-0001", "name": "Legacy", "location": "Closet", "notes": "", "updated": 1_750_000_000_000],
                ["id": 2, "code": "BX-0002", "name": "With Bad Overlay", "location": "Garage", "notes": "", "updated": 1_750_000_000_000]
            ],
            "items": [],
            "photos": [
                ["id": 1, "box_id": 1, "filename": "legacy.jpg", "jpegBase64": b64],
                ["id": 2, "box_id": 2, "filename": "bad-overlay.jpg", "jpegBase64": b64, "detections": ["unsupported": true]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let preview = try backup.previewImport(data: data)
        try await backup.commitImport(preview)

        let boxes = try await db.allBoxes()
        XCTAssertEqual(boxes.count, 2)
        XCTAssertNil(annotations.load(forPhotoAt: try fileStore.photoURL(for: "bad-overlay.jpg")))
    }

    func testRejectsPathTraversalBadForeignKeyAndLeavesExistingDataIntact() async throws {
        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try SQLiteBoxDatabase(databaseURL: tempDir.appendingPathComponent("boxes.db"))
        let fileStore = try PhotoFileStore(baseDirectory: tempDir)
        let annotations = PhotoAnnotationStore(fileStore: fileStore)
        let backup = BackupService(repository: db, fileStore: fileStore, annotationStore: annotations)

        _ = try await db.saveBox(id: 0, name: "Keep Me", location: "Office", notes: "")
        let b64 = TestFixtures.makeSolidJPEGData().base64EncodedString()

        let traversalBackup: [String: Any] = [
            "format": "box-finder-android-v1",
            "boxes": [["id": 1, "code": "BX-0001", "name": "X", "location": "Y"]],
            "items": [],
            "photos": [["id": 1, "box_id": 1, "filename": "../escape.jpg", "jpegBase64": b64]]
        ]
        XCTAssertThrowsError(try backup.previewImport(data: try JSONSerialization.data(withJSONObject: traversalBackup)))

        let orphanItemBackup: [String: Any] = [
            "format": "box-finder-android-v1",
            "boxes": [["id": 1, "code": "BX-0001", "name": "X", "location": "Y"]],
            "items": [["id": 1, "box_id": 999, "name": "Orphan", "quantity": 1]],
            "photos": []
        ]
        XCTAssertThrowsError(try backup.previewImport(data: try JSONSerialization.data(withJSONObject: orphanItemBackup)))

        let existing = try await db.allBoxes()
        XCTAssertEqual(existing.count, 1)
        XCTAssertEqual(existing.first?.name, "Keep Me")
    }
}
