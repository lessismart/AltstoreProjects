import CryptoKit
import XCTest
@testable import BoxFinder

final class DatabaseAndModelStoreTests: XCTestCase {
    func testDatabaseMigrationCRUDCascadeDeleteAndAutoincrementSequence() async throws {
        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try SQLiteBoxDatabase(databaseURL: tempDir.appendingPathComponent("boxes.db"))
        let box = try await db.saveBox(id: 0, name: "Electronics", location: "Closet", notes: "Small bin")
        XCTAssertEqual(box.code, "BX-0001")

        let item = try await db.saveItem(id: 0, boxId: box.id, name: "HDMI Cable", category: "Cables", quantity: 3, notes: "", source: "manual")
        XCTAssertEqual(item.boxId, box.id)

        _ = try await db.addPhoto(boxId: box.id, filename: "photo-1.jpg")
        let removedPhotos = try await db.deleteBox(id: box.id)
        XCTAssertEqual(removedPhotos, ["photo-1.jpg"])
        XCTAssertEqual(try await db.allItems().count, 0)
        XCTAssertEqual(try await db.allBoxes().count, 0)

        // Restore explicit ID 42 and ensure next auto-inserted box receives ID 43
        try await db.replaceAll(
            boxes: [BoxRecord(id: 42, code: "BX-0042", name: "Restored", location: "Shelf", notes: "", updated: 123)],
            items: [],
            photos: []
        )
        let nextBox = try await db.saveBox(id: 0, name: "After Restore", location: "Shelf", notes: "")
        XCTAssertEqual(nextBox.id, 43)
        XCTAssertEqual(nextBox.code, "BX-0043")
    }

    func testModelStoreImportChecksumValidationAndDeletion() async throws {
        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try ModelStore(baseDirectory: tempDir, minimumModelBytes: 10, maximumModelBytes: 100_000)

        let badExtURL = tempDir.appendingPathComponent("not-litertlm.gguf")
        try Data("0123456789ABCDEF".utf8).write(to: badExtURL)
        do {
            _ = try await store.importModel(from: badExtURL, slot: .gemma4) { _ in }
            XCTFail("Expected invalid extension error")
        } catch ModelStoreError.invalidExtension {
            // expected
        }

        let goodURL = tempDir.appendingPathComponent("gemma-4-E2B.litertlm")
        let bytes = Data("fake-litertlm-payload-for-import-test".utf8)
        try bytes.write(to: goodURL)
        let expectedSha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let imported = try await store.importModel(from: goodURL, slot: .gemma4, expectedSHA256: expectedSha) { _ in }
        XCTAssertEqual(imported.sha256, expectedSha)
        XCTAssertTrue(store.isModelPresent(for: .gemma4))

        do {
            _ = try await store.importModel(from: goodURL, slot: .gemma4, expectedSHA256: String(repeating: "0", count: 64)) { _ in }
            XCTFail("Expected checksum mismatch")
        } catch ModelStoreError.checksumMismatch {
            // expected; prior valid file remains intact
            XCTAssertTrue(store.isModelPresent(for: .gemma4))
        }

        try store.removeModel(for: .gemma4)
        XCTAssertFalse(store.isModelPresent(for: .gemma4))
    }
}
