import XCTest
@testable import BoxFinder

final class PhotoGeometryAndAnnotationsTests: XCTestCase {
    func testValidatesBoxesAndDefaultsToUncertain() throws {
        let raw = "```json\n{\"objects\":[{\"label\":\"Cable\",\"box_2d\":[100,200,500,800]}]}\n```"
        let objects = try PhotoAnnotationStore.parse(text: raw)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects[0].label, "Cable")
        XCTAssertTrue(objects[0].uncertain)
        XCTAssertEqual(objects[0].box2d, [100, 200, 500, 800])
    }

    func testRejectsReversedOutsideBooleanStringAndMissingCoordinates() throws {
        let raw = """
            {"objects":[
              {"label":"Reversed","box_2d":[500,100,100,500]},
              {"label":"Outside","box_2d":[-1,100,500,500]},
              {"label":"Missing"},
              {"label":"String","box_2d":["100",100,500,500]},
              {"label":"Boolean","box_2d":[true,100,500,500]}
            ]}
            """
        let objects = try PhotoAnnotationStore.parse(text: raw)
        XCTAssertEqual(objects.count, 0)
    }

    func testDoesNotFabricateLocationsFromItemNames() {
        XCTAssertThrowsError(try PhotoAnnotationStore.parse(text: "{\"items\":[{\"name\":\"Cable\"}]}"))
    }

    func testMapsCoordinatesWithLetterboxingZoomAndHitTesting() {
        let fit = PhotoGeometry.fit(imageSize: CGSize(width: 1000, height: 500), viewSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(fit.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(fit.left, 0.0, accuracy: 0.001)
        XCTAssertEqual(fit.top, 250.0, accuracy: 0.001)

        let rect = PhotoGeometry.screenBox(box2d: [100, 200, 800, 900], imageSize: CGSize(width: 1000, height: 500), transform: fit)
        XCTAssertEqual(rect.minX, 200, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 300, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 900, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 650, accuracy: 0.001)

        let zoom = PhotoGeometry.zoom(current: fit, newScale: 2.0, focus: CGPoint(x: 200, y: 300))
        XCTAssertEqual(zoom.scale, 2.0, accuracy: 0.001)
        XCTAssertEqual(zoom.left, -200.0, accuracy: 0.001)
        XCTAssertEqual(zoom.top, 200.0, accuracy: 0.001)

        let largeObj = DetectedObject(label: "Bin", box2d: [0, 0, 1000, 1000], uncertain: false)
        let smallObj = DetectedObject(label: "Screwdriver", box2d: [200, 200, 400, 400], uncertain: false)
        let hitIdx = PhotoGeometry.hitTest(
            point: CGPoint(x: 300, y: 400),
            objects: [largeObj, smallObj],
            imageSize: CGSize(width: 1000, height: 500),
            transform: fit
        )
        XCTAssertEqual(hitIdx, 1)
    }

    func testSidecarFingerprintReloadsOnlyForMatchingBytesAndNormalizesOrientation() throws {
        let tempDir = try TestFixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileStore = try PhotoFileStore(baseDirectory: tempDir)
        let annotations = PhotoAnnotationStore(fileStore: fileStore)

        // Create a rotated fixture UIImage (.right) and ensure normalization outputs upright pixels
        let rawImage = UIImage(data: TestFixtures.makeSolidJPEGData(size: CGSize(width: 300, height: 150)))!
        let rotated = UIImage(cgImage: rawImage.cgImage!, scale: 1.0, orientation: .right)
        let saved = try fileStore.saveNormalizedPhoto(rotated)
        let normalizedImage = UIImage(data: saved.data)!
        XCTAssertEqual(normalizedImage.imageOrientation, .up)
        XCTAssertEqual(normalizedImage.size.width, 150, accuracy: 1.0)
        XCTAssertEqual(normalizedImage.size.height, 300, accuracy: 1.0)

        let objs = [DetectedObject(label: "Test Object", box2d: [100, 100, 500, 500], uncertain: false)]
        _ = try annotations.save(objects: objs, forPhotoAt: saved.url, provider: "gemini", model: "gemini-2.5-flash")
        XCTAssertEqual(annotations.load(forPhotoAt: saved.url)?.objects.count, 1)

        // Mutate JPEG bytes -> sidecar must NOT reload for mismatched SHA-256
        let altered = TestFixtures.makeSolidJPEGData(color: .systemRed)
        try altered.write(to: saved.url)
        XCTAssertNil(annotations.load(forPhotoAt: saved.url))
    }
}
