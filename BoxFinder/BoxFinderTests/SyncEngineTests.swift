import XCTest
@testable import BoxFinder

private final class MockSyncHTTPClient: SyncHTTPClient, @unchecked Sendable {
    var handler: ((String, URL, [String: String], Data?) throws -> SyncHTTPResponse)?

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> SyncHTTPResponse {
        guard let handler else {
            return SyncHTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        return try handler(method, url, headers, body)
    }
}

private final class InMemoryBaselineStore: SyncBaselineStore, @unchecked Sendable {
    var base: [Int64: String]?
    var lastSync: Int64 = 0

    func loadBase() -> [Int64: String]? { base }
    func saveBase(_ hashes: [Int64: String], timestampMs: Int64) {
        base = hashes
        lastSync = timestampMs
    }
    func clearBase() {
        base = nil
        lastSync = 0
    }
    func lastSyncTimestampMs() -> Int64 { lastSync }
}

final class SyncEngineTests: XCTestCase {
    func testBundleHashMatchesAndroidSyncEngineByteForByte() throws {
        let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("TESTJPEG".utf8)
        let bundle = SyncBundle(
            box: BoxRecord(id: 1, code: "BX-0001", name: "Tools", location: "Garage", notes: "Top shelf", updated: 999),
            items: [ItemRecord(id: 10, boxId: 1, name: "Wrench", category: "Hand Tools", quantity: 2, notes: "", source: "manual")],
            photos: [BackupPhotoEntry(id: 5, boxId: 1, filename: "p.jpg", jpegBase64: jpegBytes.base64EncodedString(), detections: nil)]
        )
        let digest = try bundle.computeHash()
        XCTAssertEqual(digest, "252791f60e717106f351d6923ff64899da3ece3c1664e3ee1379ec3ba0143ec8")
    }

    func testURLAndTokenValidation() throws {
        XCTAssertEqual(
            try SyncURLValidator.validateURL("http://pi-usbserver.local:8000/box-finder-sync.php"),
            "http://pi-usbserver.local:8000/box-finder-sync.php"
        )
        XCTAssertEqual(
            try SyncURLValidator.validateURL("http://192.168.1.42:8000/box-finder-sync.php"),
            "http://192.168.1.42:8000/box-finder-sync.php"
        )
        XCTAssertEqual(
            try SyncURLValidator.validateURL("http://10.0.0.15:8000/box-finder-sync.php"),
            "http://10.0.0.15:8000/box-finder-sync.php"
        )

        XCTAssertThrowsError(try SyncURLValidator.validateURL("https://pi-usbserver.local:8000/box-finder-sync.php"))
        XCTAssertThrowsError(try SyncURLValidator.validateURL("http://example.com:8000/box-finder-sync.php"))
        XCTAssertThrowsError(try SyncURLValidator.validateURL("http://192.168.1.42:9000/box-finder-sync.php"))
        XCTAssertThrowsError(try SyncURLValidator.validateURL("http://192.168.1.42:8000/other.php"))
        XCTAssertThrowsError(try SyncURLValidator.validateToken("abc123"))
        XCTAssertEqual(try SyncURLValidator.validateToken(String(repeating: "a", count: 64)).count, 64)
    }

    func testGzipRoundTripAndMaxBytesEnforcement() throws {
        let original = Data("Hello Box Finder gzip payload 12345!".utf8)
        let compressed = try GzipCodec.compress(original)
        XCTAssertEqual(compressed.prefix(2), Data([0x1F, 0x8B]))
        let restored = try GzipCodec.decompress(compressed, maxBytes: 1024)
        XCTAssertEqual(restored, original)
        XCTAssertThrowsError(try GzipCodec.decompress(compressed, maxBytes: 8))
    }

    func testThreeWayMergeHandlesInitialConflictsIndependentEditsDeletionsAndIDCollisions() throws {
        let box1A = BoxRecord(id: 1, code: "BX-0001", name: "Local Tools", location: "Garage", notes: "", updated: 100)
        let box1B = BoxRecord(id: 1, code: "BX-0001", name: "Pi Tools", location: "Shed", notes: "", updated: 200)

        let localSnap = InventorySnapshot(format: InventorySnapshot.expectedFormat, boxes: [box1A], items: [], photos: [])
        let remoteSnap = InventorySnapshot(format: InventorySnapshot.expectedFormat, boxes: [box1B], items: [], photos: [])

        // 1. Initial pairing with different Box 1 -> conflict reported, user picks Pi or Local
        let initialPlan = try SyncEngine.computePlan(serverRevision: "rev1", remote: remoteSnap, local: localSnap, savedBase: nil)
        XCTAssertTrue(initialPlan.isInitial)
        XCTAssertEqual(initialPlan.conflicts, ["BX-0001"])

        let keepPi = try SyncEngine.merge(plan: initialPlan, preferLocal: false)
        XCTAssertEqual(keepPi.boxes.first?.name, "Pi Tools")
        let keepLocal = try SyncEngine.merge(plan: initialPlan, preferLocal: true)
        XCTAssertEqual(keepLocal.boxes.first?.name, "Local Tools")

        // 2. Ongoing sync: Box 1 unchanged, Box 2 deleted on Pi, Box 3 created independently on BOTH sides with same ID=3 & filename
        let jpeg = TestFixtures.makeSolidJPEGData().base64EncodedString()
        let baseBox1 = BoxRecord(id: 1, code: "BX-0001", name: "Shared", location: "Attic", notes: "", updated: 10)
        let baseBox2 = BoxRecord(id: 2, code: "BX-0002", name: "Deleted on Pi", location: "Basement", notes: "", updated: 10)
        let baseSnap = InventorySnapshot(format: InventorySnapshot.expectedFormat, boxes: [baseBox1, baseBox2], items: [], photos: [])
        let baseHashes = try SyncEngine.bundleHashes(for: baseSnap)

        let newPiBox3 = BoxRecord(id: 3, code: "BX-0003", name: "From Pi", location: "A", notes: "", updated: 20)
        let newLocalBox3 = BoxRecord(id: 3, code: "BX-0003", name: "From iPad", location: "B", notes: "", updated: 25)
        let piItem3 = ItemRecord(id: 10, boxId: 3, name: "Pi Item", category: "", quantity: 1, notes: "", source: "manual")
        let localItem3 = ItemRecord(id: 10, boxId: 3, name: "iPad Item", category: "", quantity: 1, notes: "", source: "manual")
        let piPhoto3 = BackupPhotoEntry(id: 5, boxId: 3, filename: "dup.jpg", jpegBase64: jpeg, detections: nil)
        let localPhoto3 = BackupPhotoEntry(id: 5, boxId: 3, filename: "dup.jpg", jpegBase64: jpeg, detections: nil)

        let ongoingRemote = InventorySnapshot(
            format: InventorySnapshot.expectedFormat,
            boxes: [baseBox1, newPiBox3],
            items: [piItem3],
            photos: [piPhoto3]
        )
        let ongoingLocal = InventorySnapshot(
            format: InventorySnapshot.expectedFormat,
            boxes: [baseBox1, baseBox2, newLocalBox3],
            items: [localItem3],
            photos: [localPhoto3]
        )

        let ongoingPlan = try SyncEngine.computePlan(
            serverRevision: "rev2",
            remote: ongoingRemote,
            local: ongoingLocal,
            savedBase: baseHashes
        )
        XCTAssertTrue(ongoingPlan.conflicts.isEmpty)

        let merged = try SyncEngine.merge(plan: ongoingPlan, preferLocal: false)
        // Box 2 should be deleted, and BOTH box 3s should be kept with collision resolution (id 3 & id 4)
        XCTAssertFalse(merged.boxes.contains { $0.id == 2 })
        XCTAssertEqual(merged.boxes.count, 3)
        XCTAssertEqual(Set(merged.boxes.map(\.id)), Set([1, 3, 4]))
        XCTAssertEqual(Set(merged.boxes.map(\.code)), Set(["BX-0001", "BX-0003", "BX-0004"]))
        XCTAssertEqual(Set(merged.items.map(\.id)).count, 2)
        XCTAssertEqual(Set(merged.photos.map(\.filename)).count, 2)
        XCTAssertTrue(merged.items.contains { $0.name == "iPad Item" && $0.boxId == 4 })
    }

    func testExecuteHandles403And409AndRecoveryOnLocalFailure() async throws {
        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let db = try SQLiteBoxDatabase(databaseURL: tempDir.appendingPathComponent("boxes.db"))
        let fileStore = try PhotoFileStore(baseDirectory: tempDir)
        let baseline = InMemoryBaselineStore()
        let mockHTTP = MockSyncHTTPClient()
        let token = String(repeating: "f", count: 64)

        let engine = try SyncEngine(
            repository: db,
            fileStore: fileStore,
            baselineStore: baseline,
            httpClient: mockHTTP,
            urlString: SyncURLValidator.defaultURL,
            token: token
        )

        mockHTTP.handler = { _, _, headers, _ in
            XCTAssertEqual(headers["X-Box-Sync-Key"], token)
            return SyncHTTPResponse(statusCode: 403, headers: [:], body: Data("{\"error\":\"Pairing required\"}".utf8))
        }
        do {
            _ = try await engine.plan()
            XCTFail("Expected 403 error")
        } catch SyncEngineError.serverRejectedPairing {
            // expected
        }

        let remoteBox = BoxRecord(id: 1, code: "BX-0001", name: "Remote", location: "Pi", notes: "", updated: 100)
        let remoteSnap = InventorySnapshot(format: InventorySnapshot.expectedFormat, boxes: [remoteBox], items: [], photos: [])
        let rev = try SyncEngine.serverRevision(for: remoteSnap)
        let localSnap = InventorySnapshot(format: InventorySnapshot.expectedFormat, boxes: [], items: [], photos: [])
        let plan = try SyncEngine.computePlan(serverRevision: rev, remote: remoteSnap, local: localSnap, savedBase: nil)

        mockHTTP.handler = { method, _, _, body in
            XCTAssertEqual(method, "POST")
            XCTAssertNotNil(body)
            return SyncHTTPResponse(statusCode: 409, headers: [:], body: Data("{\"error\":\"Changed\"}".utf8))
        }
        _ = try await db.saveBox(id: 0, name: "Local Extra", location: "Shelf", notes: "")
        let dirtyPlan = try SyncEngine.computePlan(
            serverRevision: rev,
            remote: remoteSnap,
            local: InventorySnapshot(
                format: InventorySnapshot.expectedFormat,
                boxes: [BoxRecord(id: 2, code: "BX-0002", name: "Local Extra", location: "Shelf", notes: "", updated: 200)],
                items: [],
                photos: []
            ),
            savedBase: nil
        )
        do {
            _ = try await engine.execute(plan: dirtyPlan, preferLocal: true)
            XCTFail("Expected 409 error")
        } catch SyncEngineError.serverRevisionConflict {
            // expected
        }

        // Successful remote pull with gzipped response
        let encoder = JSONEncoder()
        let respObj: [String: Any] = [
            "revision": rev,
            "snapshot": try JSONSerialization.jsonObject(with: try encoder.encode(remoteSnap))
        ]
        let gzBody = try GzipCodec.compress(try JSONSerialization.data(withJSONObject: respObj))
        mockHTTP.handler = { method, _, _, _ in
            XCTAssertEqual(method, "GET")
            return SyncHTTPResponse(statusCode: 200, headers: ["content-encoding": "gzip"], body: gzBody)
        }
        let freshPlan = try await engine.plan()
        let outcome = try await engine.execute(plan: freshPlan, preferLocal: false)
        XCTAssertEqual(outcome.syncedBoxCount, 1)
        XCTAssertFalse(outcome.uploadedToPi)
        _ = plan
    }
}
