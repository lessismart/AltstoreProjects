import XCTest
@testable import BoxFinder

final class AiJsonAndQRTests: XCTestCase {
    func testCombinesMultiViewItemsWithoutAddingRepeatedQuantities() throws {
        let batch1 = try AiJsonParser.parseItems(from: #"{"items":[{"name":"Cable","category":"electronics","quantity":2,"uncertain":false}]}"#)
        let batch2 = try AiJsonParser.parseItems(from: #"{"items":[{"name":" cable ","quantity":1,"uncertain":true}]}"#)
        let merged = AiJsonParser.mergeItemBatches([batch1, batch2])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].quantity, 2)
        XCTAssertTrue(merged[0].uncertain)
    }

    func testNormalizesUntrustedItemsAndRejectsInventedBoxCodes() throws {
        let items = try AiJsonParser.parseItems(from: "```json\n{\"items\":[{\"name\":\"Hammer\",\"quantity\":-4},{\"name\":\"\"}]}\n```")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].quantity, 1)
        XCTAssertTrue(items[0].uncertain)

        let inventory = [BoxRecord(id: 1, code: "BX-0001", name: "Tools", location: "Garage", notes: "", updated: 0)]
        let boxes = try AiJsonParser.parseBoxCodes(from: #"{"boxCodes":["BX-9999","BX-0001","BX-0001"]}"#, inventory: inventory)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].location, "Garage")
    }

    func testQRParsingAndRoundTripImageGeneration() throws {
        XCTAssertEqual(QRCodeService.parsePayload("BX-0001"), .boxCode("BX-0001"))
        XCTAssertEqual(QRCodeService.parsePayload(" bx-0042 "), .boxCode("BX-0042"))
        XCTAssertEqual(QRCodeService.parsePayload("http://pi-usbserver.local:8000/box-finder.php?box=7"), .boxID(7))
        XCTAssertEqual(QRCodeService.parsePayload("https://example.org/box-finder-plus.php?box=12"), .boxID(12))
        XCTAssertNil(QRCodeService.parsePayload("https://example.org/unknown"))

        let box = BoxRecord(id: 5, code: "BX-0005", name: "Cables", location: "Office", notes: "", updated: 0)
        let resolvedFromPi = QRCodeService.resolveBox(from: "http://pi-usbserver.local:8000/box-finder-plus.php?box=5", in: [box])
        XCTAssertEqual(resolvedFromPi?.id, 5)

        let qrImage = try XCTUnwrap(QRCodeService.generateQRImage(for: "BX-0005", size: 500))
        let decodedPayload = try QRCodeService.decodeQRPayload(from: qrImage)
        XCTAssertEqual(decodedPayload, "BX-0005")

        let labelCard = try XCTUnwrap(QRCodeService.renderPrintableLabelCard(for: box))
        XCTAssertEqual(labelCard.size, CGSize(width: 760, height: 920))
    }
}
