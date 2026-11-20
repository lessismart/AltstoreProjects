import XCTest
@testable import DirectCam

final class DVRIPProtocolTests: XCTestCase {
    func testSofiaMD5PasswordHashMatchesKnownVectors() {
        XCTAssertEqual(DVRIPProtocol.sofiaHash(""), "tlJwpbo6")
        XCTAssertEqual(DVRIPProtocol.sofiaHash("admin"), "6QNMIQGe")
    }

    func testTwentyByteHeaderEncodeDecodeRoundTrip() throws {
        let packet = try DVRIPProtocol.encodePacket(
            sessionId: 0x000001A2,
            sequence: 7,
            messageId: DVRIPMessageID.configGetRequest,
            jsonObject: ["Name": "SystemInfo"],
            totalPackets: 2,
            currentPacket: 1
        )
        let hdr = try XCTUnwrap(DVRIPProtocol.decodeHeader(packet))
        XCTAssertEqual(hdr.headFlag, 0xFF)
        XCTAssertEqual(hdr.sessionId, 0x000001A2)
        XCTAssertEqual(hdr.sequence, 7)
        XCTAssertEqual(hdr.totalPackets, 2)
        XCTAssertEqual(hdr.currentPacket, 1)
        XCTAssertEqual(hdr.messageId, 1042)

        let body = packet.subdata(in: DVRIPProtocol.headerLength..<packet.count)
        let json = try XCTUnwrap(DVRIPProtocol.parseJSONObject(fromPayload: body))
        XCTAssertEqual(json["Name"]?.stringValue, "SystemInfo")
    }

    func testParsesStorageEncodePrivacyAndRecordingsJSON() throws {
        let storageJSON = #"""
        {
          "Ret": 100,
          "StorageInfo": [{
            "Partition": [{
              "DirverType": 0,
              "IsCurrent": true,
              "TotalSpace": "0x00007470",
              "RemainSpace": "0x00003A10",
              "Status": 0
            }]
          }]
        }
        """#
        let storageObj = try XCTUnwrap(DVRIPProtocol.parseJSONObject(fromPayload: Data(storageJSON.utf8)))
        let storage = DVRIPProtocol.parseStorageInfo(storageObj)
        XCTAssertEqual(storage.totalMB, 0x7470)
        XCTAssertEqual(storage.remainMB, 0x3A10)

        let natJSON = #"{"NetWork.Nat":{"NatEnable":false,"NatInfoCode":"Conning"}}"#
        let natObj = try XCTUnwrap(DVRIPProtocol.parseJSONObject(fromPayload: Data(natJSON.utf8)))
        let privacy = DVRIPProtocol.parsePrivacyConfig(natObj)
        XCTAssertFalse(privacy.natEnabled)

        let queryJSON = #"""
        {
          "Ret": 100,
          "OPFileQuery": [{
            "FileName": "/idea0/2026-11-20/001/10.15.00-10.16.00[M][@1].h264",
            "BeginTime": "2026-11-20 10:15:00",
            "EndTime": "2026-11-20 10:16:00",
            "DiskNo": 0,
            "SerialNo": 1,
            "FileLength": "0x00020000"
          }]
        }
        """#
        let queryObj = try XCTUnwrap(DVRIPProtocol.parseJSONObject(fromPayload: Data(queryJSON.utf8)))
        let files = DVRIPProtocol.parseRecordingFiles(queryObj)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isAlarm)
        XCTAssertEqual(files[0].sizeBytes, 0x20000)
    }

    func testExtractsAnnexBFramesFromXiongmaiMediaContainer() {
        var raw = Data()
        let iframeAnnexB = Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x99])
        // 16-byte XM I-frame header: 00 00 01 FC + codec=0x03 (HEVC) + 7 bytes + LE uint32 length
        raw.append(contentsOf: [0x00, 0x00, 0x01, 0xFC, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        raw.append(contentsOf: [UInt8(iframeAnnexB.count), 0x00, 0x00, 0x00])
        raw.append(iframeAnnexB)

        let pframeAnnexB = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x55])
        // 8-byte XM P-frame header: 00 00 01 FD + LE uint32 length
        raw.append(contentsOf: [0x00, 0x00, 0x01, 0xFD, UInt8(pframeAnnexB.count), 0x00, 0x00, 0x00])
        raw.append(pframeAnnexB)

        let extracted = DVRIPProtocol.extractAnnexBVideoFrames(from: raw)
        XCTAssertTrue(extracted.detectedHEVC)
        XCTAssertEqual(extracted.annexBData, iframeAnnexB + pframeAnnexB)
    }
}
