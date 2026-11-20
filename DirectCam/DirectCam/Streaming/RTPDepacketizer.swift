import Foundation

struct RTPVideoUnit: Equatable, Sendable {
    var nalUnits: [Data]
    var vps: Data?
    var sps: Data?
    var pps: Data?
    var isKeyFrame: Bool
    var timestamp: UInt32
}

final class RTPVideoDepacketizer {
    private let codec: RTSPVideoCodec
    private var fuBuffer = Data()
    private var assemblingFU = false
    private var fuTimestamp: UInt32 = 0

    init(codec: RTSPVideoCodec) {
        self.codec = codec
    }

    func reset() {
        self.fuBuffer.removeAll(keepingCapacity: false)
        self.assemblingFU = false
    }

    /// Processes one complete RTP packet (12-byte fixed RTP header + extensions + payload)
    /// and returns extracted complete NAL units when available.
    func processRTPPacket(_ packet: Data) -> RTPVideoUnit? {
        guard packet.count >= 12 else { return nil }
        let bytes = [UInt8](packet)
        let firstByte = bytes[0]
        let version = (firstByte >> 6) & 0x03
        guard version == 2 else { return nil }

        let hasPadding = (firstByte & 0x20) != 0
        let hasExtension = (firstByte & 0x10) != 0
        let csrcCount = Int(firstByte & 0x0F)

        let timestamp = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16) | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        var offset = 12 + csrcCount * 4
        guard offset <= bytes.count else { return nil }

        if hasExtension {
            guard offset + 4 <= bytes.count else { return nil }
            let extWords = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4 + extWords * 4
            guard offset <= bytes.count else { return nil }
        }

        var end = bytes.count
        if hasPadding, end > offset {
            let padLen = Int(bytes[end - 1])
            if padLen > 0 && end - padLen >= offset {
                end -= padLen
            }
        }
        guard end > offset else { return nil }
        let payload = Array(bytes[offset..<end])

        switch self.codec {
        case .hevc:
            return self.processHEVCPayload(payload, timestamp: timestamp)
        case .h264:
            return self.processH264Payload(payload, timestamp: timestamp)
        }
    }

    // MARK: - RFC 7798 (HEVC / H.265)

    private func processHEVCPayload(_ payload: [UInt8], timestamp: UInt32) -> RTPVideoUnit? {
        guard payload.count >= 2 else { return nil }
        let h0 = payload[0]
        let h1 = payload[1]
        let nalType = (h0 >> 1) & 0x3F

        if nalType < 48 {
            self.reset()
            return self.classifyHEVCUnits([Data(payload)], timestamp: timestamp)
        } else if nalType == 48 {
            // Aggregation Packet (AP)
            self.reset()
            var units: [Data] = []
            var pos = 2
            while pos + 2 <= payload.count {
                let unitLen = (Int(payload[pos]) << 8) | Int(payload[pos + 1])
                pos += 2
                guard unitLen > 0 && pos + unitLen <= payload.count else { break }
                units.append(Data(payload[pos..<(pos + unitLen)]))
                pos += unitLen
            }
            guard !units.isEmpty else { return nil }
            return self.classifyHEVCUnits(units, timestamp: timestamp)
        } else if nalType == 49 {
            // Fragmentation Unit (FU)
            guard payload.count >= 3 else { return nil }
            let fuHeader = payload[2]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            let origType = fuHeader & 0x3F
            let fragment = payload[3...]

            if isStart {
                self.fuBuffer.removeAll(keepingCapacity: true)
                let newH0 = (h0 & 0x81) | (origType << 1)
                let newH1 = h1
                self.fuBuffer.append(contentsOf: [newH0, newH1])
                self.fuBuffer.append(contentsOf: fragment)
                self.assemblingFU = true
                self.fuTimestamp = timestamp
            } else if self.assemblingFU {
                self.fuBuffer.append(contentsOf: fragment)
            } else {
                return nil
            }

            if isEnd && self.assemblingFU {
                let completed = self.fuBuffer
                self.reset()
                return self.classifyHEVCUnits([completed], timestamp: timestamp)
            }
            return nil
        }
        return nil
    }

    private func classifyHEVCUnits(_ units: [Data], timestamp: UInt32) -> RTPVideoUnit {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        var key = false
        var sliceOrConfigUnits: [Data] = []

        for u in units where u.count >= 2 {
            let nalType = (u[u.startIndex] >> 1) & 0x3F
            switch nalType {
            case 32: vps = u
            case 33: sps = u
            case 34: pps = u
            case 16...21:
                key = true
                sliceOrConfigUnits.append(u)
            default:
                sliceOrConfigUnits.append(u)
            }
        }
        return RTPVideoUnit(nalUnits: sliceOrConfigUnits, vps: vps, sps: sps, pps: pps, isKeyFrame: key, timestamp: timestamp)
    }

    // MARK: - RFC 6184 (H.264)

    private func processH264Payload(_ payload: [UInt8], timestamp: UInt32) -> RTPVideoUnit? {
        guard !payload.isEmpty else { return nil }
        let headerByte = payload[0]
        let nalType = headerByte & 0x1F

        if (1...23).contains(nalType) {
            self.reset()
            return self.classifyH264Units([Data(payload)], timestamp: timestamp)
        } else if nalType == 24 {
            // STAP-A
            self.reset()
            var units: [Data] = []
            var pos = 1
            while pos + 2 <= payload.count {
                let unitLen = (Int(payload[pos]) << 8) | Int(payload[pos + 1])
                pos += 2
                guard unitLen > 0 && pos + unitLen <= payload.count else { break }
                units.append(Data(payload[pos..<(pos + unitLen)]))
                pos += unitLen
            }
            guard !units.isEmpty else { return nil }
            return self.classifyH264Units(units, timestamp: timestamp)
        } else if nalType == 28 {
            // FU-A
            guard payload.count >= 2 else { return nil }
            let fuHeader = payload[1]
            let isStart = (fuHeader & 0x80) != 0
            let isEnd = (fuHeader & 0x40) != 0
            let origType = fuHeader & 0x1F
            let fragment = payload[2...]

            if isStart {
                self.fuBuffer.removeAll(keepingCapacity: true)
                let reconstructed = (headerByte & 0xE0) | origType
                self.fuBuffer.append(reconstructed)
                self.fuBuffer.append(contentsOf: fragment)
                self.assemblingFU = true
                self.fuTimestamp = timestamp
            } else if self.assemblingFU {
                self.fuBuffer.append(contentsOf: fragment)
            } else {
                return nil
            }

            if isEnd && self.assemblingFU {
                let completed = self.fuBuffer
                self.reset()
                return self.classifyH264Units([completed], timestamp: timestamp)
            }
            return nil
        }
        return nil
    }

    private func classifyH264Units(_ units: [Data], timestamp: UInt32) -> RTPVideoUnit {
        var sps: Data?
        var pps: Data?
        var key = false
        var slices: [Data] = []

        for u in units where !u.isEmpty {
            let nalType = u[u.startIndex] & 0x1F
            switch nalType {
            case 7: sps = u
            case 8: pps = u
            case 5:
                key = true
                slices.append(u)
            default:
                slices.append(u)
            }
        }
        return RTPVideoUnit(nalUnits: slices, vps: nil, sps: sps, pps: pps, isKeyFrame: key, timestamp: timestamp)
    }

    // MARK: - Helpers

    static func avccLengthPrefixedData(from nalUnits: [Data]) -> Data {
        let total = nalUnits.reduce(0) { $0 + 4 + $1.count }
        var out = Data(capacity: total)
        for nalu in nalUnits where !nalu.isEmpty {
            var lenBE = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
            out.append(nalu)
        }
        return out
    }

    static func splitAnnexBNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var i = 0
        var nalStart = -1

        while i + 2 < bytes.count {
            let is4Byte = i + 3 < bytes.count && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1
            let is3Byte = bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1
            if is4Byte || is3Byte {
                if nalStart >= 0 && i > nalStart {
                    units.append(Data(bytes[nalStart..<i]))
                }
                i += is4Byte ? 4 : 3
                nalStart = i
            } else {
                i += 1
            }
        }
        if nalStart >= 0 && nalStart < bytes.count {
            units.append(Data(bytes[nalStart..<bytes.count]))
        }
        return units
    }
}

// MARK: - ITU-T G.711 A-law / u-law Audio Decoder

enum G711Decoder {
    private static let muLawTable: [Float] = (0...255).map { idx -> Float in
        let inv = ~UInt8(idx)
        let sign = (inv & 0x80) != 0 ? -1 : 1
        let exponent = Int((inv >> 4) & 0x07)
        let mantissa = Int(inv & 0x0F)
        let sample = (((mantissa << 3) + 0x84) << exponent) - 0x84
        return Float(sign * sample) / 32768.0
    }

    private static let aLawTable: [Float] = (0...255).map { idx -> Float in
        let val = UInt8(idx) ^ 0x55
        let sign = (val & 0x80) != 0 ? 1 : -1
        let exponent = Int((val >> 4) & 0x07)
        let mantissa = Int(val & 0x0F)
        let sample: Int
        if exponent == 0 {
            sample = (mantissa << 4) + 8
        } else {
            sample = ((mantissa << 4) + 0x108) << (exponent - 1)
        }
        return Float(sign * sample) / 32768.0
    }

    static func decodeMuLaw(_ rtpPayload: Data) -> [Float] {
        rtpPayload.map { self.muLawTable[Int($0)] }
    }

    static func decodeALaw(_ rtpPayload: Data) -> [Float] {
        rtpPayload.map { self.aLawTable[Int($0)] }
    }

    /// Strips the 12-byte RTP header before decoding G.711 audio samples.
    static func decodeRTPPayload(_ packet: Data, codec: RTSPAudioCodec) -> [Float] {
        guard packet.count > 12 else { return [] }
        let firstByte = packet[packet.startIndex]
        let csrcCount = Int(firstByte & 0x0F)
        var offset = 12 + csrcCount * 4
        if (firstByte & 0x10) != 0, offset + 4 <= packet.count {
            let extWords = (Int(packet[offset + 2]) << 8) | Int(packet[offset + 3])
            offset += 4 + extWords * 4
        }
        guard offset < packet.count else { return [] }
        let audioBytes = packet.subdata(in: offset..<packet.count)
        switch codec {
        case .pcma: return self.decodeALaw(audioBytes)
        case .pcmu: return self.decodeMuLaw(audioBytes)
        case .aac: return []
        }
    }
}
