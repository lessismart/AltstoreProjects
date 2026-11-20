import XCTest
@testable import DirectCam

final class RTSPAndRTPTests: XCTestCase {
    func testBuildsXiongmaiRTSPURLsAndRedactsPasswords() {
        let profile = CameraProfile(
            name: "Yard",
            host: "192.168.2.46",
            rtspPort: 554,
            username: "admin",
            channel: 1,
            rtspPathStyle: .xiongmaiAmp
        )
        let ampURL = RTSPProtocol.buildRTSPURL(profile: profile, password: "s3cr3t&pw", quality: .main)
        XCTAssertEqual(
            ampURL,
            "rtsp://admin:s3cr3t%26pw@192.168.2.46:554/user=admin&password=s3cr3t%26pw&channel=1&stream=0.sdp?real_stream"
        )
        let redacted = RTSPProtocol.redactedURL(ampURL)
        XCTAssertFalse(redacted.contains("s3cr3t"))
        XCTAssertTrue(redacted.contains("password=***"))

        var underscore = profile
        underscore.rtspPathStyle = .xiongmaiUnderscore
        let subURL = RTSPProtocol.buildRTSPURL(profile: underscore, password: "pass", quality: .sub)
        XCTAssertTrue(subURL.contains("/user=admin_password=pass_channel=1_stream=1.sdp?real_stream"))
    }

    func testParsesSDPWithHEVCParametersAndPCMAudio() {
        let vps = Data([0x40, 0x01, 0x0C, 0x01]).base64EncodedString()
        let sps = Data([0x42, 0x01, 0x01, 0x01]).base64EncodedString()
        let pps = Data([0x44, 0x01, 0xC1, 0x73]).base64EncodedString()
        let sdp = """
        v=0
        o=- 0 0 IN IP4 192.168.2.46
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H265/90000
        a=fmtp:96 packetization-mode=1;sprop-vps=\(vps);sprop-sps=\(sps);sprop-pps=\(pps)
        a=control:trackID=0
        m=audio 0 RTP/AVP 8
        a=rtpmap:8 PCMA/8000
        a=control:trackID=1
        """
        let info = RTSPProtocol.parseSDP(sdp)
        XCTAssertEqual(info.videoTrack?.encodingName, "H265")
        XCTAssertEqual(info.videoTrack?.controlURI, "trackID=0")
        XCTAssertEqual(info.videoTrack?.vps, Data([0x40, 0x01, 0x0C, 0x01]))
        XCTAssertEqual(info.videoTrack?.sps, Data([0x42, 0x01, 0x01, 0x01]))
        XCTAssertEqual(info.videoTrack?.pps, Data([0x44, 0x01, 0xC1, 0x73]))
        XCTAssertEqual(info.audioTrack?.encodingName, "PCMA")
        XCTAssertEqual(info.audioTrack?.clockRate, 8000)
    }

    func testHEVCRTPFragmentationAndAggregationPackets() {
        let depacketizer = RTPVideoDepacketizer(codec: .hevc)

        // 1) RFC 7798 Fragmentation Unit (Type 49) reassembling an IDR_W_RADL frame (NAL type 19)
        // Orig NAL header for type 19, LayerId 0, TID 1 -> h0 = (19 << 1) = 0x26, h1 = 0x01
        let fuHeader1 = Data([0x80, 0x02, 0x62, 0x01, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x01])
        var pkt1 = fuHeader1
        // PayloadHdr (type 49 -> (49<<1)=0x62, 0x01) + FU header (S=1, E=0, type=19 -> 0x93) + slice bytes
        pkt1.append(contentsOf: [0x62, 0x01, 0x93, 0xAA, 0xBB])
        XCTAssertNil(depacketizer.processRTPPacket(pkt1))

        var pkt2 = fuHeader1
        // E=1, type=19 -> 0x53 + trailing slice bytes
        pkt2.append(contentsOf: [0x62, 0x01, 0x53, 0xCC, 0xDD])
        let assembled = depacketizer.processRTPPacket(pkt2)
        XCTAssertNotNil(assembled)
        XCTAssertEqual(assembled?.isKeyFrame, true)
        XCTAssertEqual(assembled?.nalUnits, [Data([0x26, 0x01, 0xAA, 0xBB, 0xCC, 0xDD])])

        // 2) RFC 7798 Aggregation Packet (Type 48 -> h0 = 0x60) containing VPS(32) + SPS(33)
        var apPkt = fuHeader1
        let vpsNalu = Data([0x40, 0x01, 0x11, 0x22]) // type 32 -> 0x40
        let spsNalu = Data([0x42, 0x01, 0x33])       // type 33 -> 0x42
        apPkt.append(contentsOf: [0x60, 0x01])       // PayloadHdr Type 48
        apPkt.append(contentsOf: [0x00, UInt8(vpsNalu.count)])
        apPkt.append(vpsNalu)
        apPkt.append(contentsOf: [0x00, UInt8(spsNalu.count)])
        apPkt.append(spsNalu)

        let apResult = depacketizer.processRTPPacket(apPkt)
        XCTAssertEqual(apResult?.vps, vpsNalu)
        XCTAssertEqual(apResult?.sps, spsNalu)
    }

    func testH264FUAAndG711AudioDecoders() {
        let depacketizer = RTPVideoDepacketizer(codec: .h264)
        let rtpHdr = Data([0x80, 0x60, 0x00, 0x01, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x02])
        var p1 = rtpHdr
        // FU-A indicator NRI=3, type=28 -> 0x7C; FU header S=1, type=5 (IDR) -> 0x85
        p1.append(contentsOf: [0x7C, 0x85, 0x10, 0x20])
        XCTAssertNil(depacketizer.processRTPPacket(p1))

        var p2 = rtpHdr
        p2.append(contentsOf: [0x7C, 0x45, 0x30])
        let out = depacketizer.processRTPPacket(p2)
        XCTAssertEqual(out?.isKeyFrame, true)
        XCTAssertEqual(out?.nalUnits, [Data([0x65, 0x10, 0x20, 0x30])])

        let annexB = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x01, 0x68, 0xCE])
        let splits = RTPVideoDepacketizer.splitAnnexBNALUnits(annexB)
        XCTAssertEqual(splits, [Data([0x67, 0x42]), Data([0x68, 0xCE])])

        var rtpAudio = rtpHdr
        rtpAudio.append(contentsOf: [0x55, 0xD5, 0xFF, 0x7F])
        let aLawSamples = G711Decoder.decodeRTPPayload(rtpAudio, codec: .pcma)
        let muLawSamples = G711Decoder.decodeRTPPayload(rtpAudio, codec: .pcmu)
        XCTAssertEqual(aLawSamples.count, 4)
        XCTAssertEqual(muLawSamples.count, 4)
        XCTAssertLessThan(abs(muLawSamples[2]), 0.01) // 0xFF mu-law ~ near silence
    }

    func testByteBufferHandlesSequentialReadsDropsAndPatternSearchWithoutIndexCrash() {
        var buf = ByteBuffer()
        let hdr1 = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8)
        let body2 = "v=0\r\nm=video 0 RTP/AVP 96\r\n"
        let hdr2 = Data("RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: \(body2.utf8.count)\r\n\r\n\(body2)".utf8)
        let rtp1Payload = Data([0x80, 0x60, 0x00, 0x01, 0xAA, 0xBB])
        let rtp2Payload = Data([0x80, 0x60, 0x00, 0x02, 0xCC])

        var frame1 = Data([0x24, 0x00, 0x00, UInt8(rtp1Payload.count)])
        frame1.append(rtp1Payload)
        var frame2 = Data([0x24, 0x02, 0x00, UInt8(rtp2Payload.count)])
        frame2.append(rtp2Payload)

        buf.append(hdr1 + hdr2 + frame1 + frame2)

        let term = Data("\r\n\r\n".utf8)
        let r1 = buf.firstRange(of: term)!
        let parsed1 = RTSPProtocol.parseResponseHeader(String(decoding: buf.slice(0..<r1.lowerBound)!, as: UTF8.self))
        XCTAssertEqual(parsed1?.statusCode, 200)
        buf.dropFirst(r1.upperBound)

        // Second message after dropFirst -> previously shifted Data.startIndex and crashed subdata(in: 0..<len)!
        let r2 = buf.firstRange(of: term)!
        let parsed2 = RTSPProtocol.parseResponseHeader(String(decoding: buf.slice(0..<r2.lowerBound)!, as: UTF8.self))
        buf.dropFirst(r2.upperBound)
        let len2 = Int(parsed2!.headers["content-length"]!)!
        let sdpBody = String(decoding: buf.read(len2)!, as: UTF8.self)
        XCTAssertEqual(sdpBody, body2)

        // Interleaved `$` binary frames cleanly read at 0-relative indices
        XCTAssertEqual(buf.byte(at: 0), 0x24)
        XCTAssertEqual(buf.byte(at: 1), 0x00)
        let f1Len = (Int(buf.byte(at: 2)!) << 8) | Int(buf.byte(at: 3)!)
        buf.dropFirst(4)
        XCTAssertEqual(buf.read(f1Len), rtp1Payload)

        XCTAssertEqual(buf.byte(at: 0), 0x24)
        XCTAssertEqual(buf.byte(at: 1), 0x02)
        let f2Len = (Int(buf.byte(at: 2)!) << 8) | Int(buf.byte(at: 3)!)
        buf.dropFirst(4)
        XCTAssertEqual(buf.read(f2Len), rtp2Payload)
        XCTAssertTrue(buf.isEmpty)
    }

    func testRTSPWireRequestURIOmitsCredentialsAndParsesInterleavedTransport() {
        let profile = CameraProfile(name: "Gate", host: "192.168.2.46", rtspPort: 554, username: "admin", channel: 0, rtspPathStyle: .onvifAuto, discoveredMainURI: "rtsp://admin:pass@192.168.2.46:554/stream1")
        let wireURI = RTSPProtocol.buildWireRequestURI(profile: profile, password: "pass", quality: .main)
        XCTAssertEqual(wireURI, "rtsp://192.168.2.46:554/stream1")

        let channels = RTSPProtocol.parseInterleavedChannels(fromTransportHeader: "RTP/AVP/TCP;unicast;interleaved=2-3;ssrc=1234")
        XCTAssertEqual(channels?.rtp, 2)
        XCTAssertEqual(channels?.rtcp, 3)
    }
}
