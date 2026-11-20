import CryptoKit
import Foundation
import Network

// MARK: - DVRIP (:34567) Wire Codec & Parsers (Pure & Unit-Testable)

struct DVRIPPacketHeader: Equatable, Sendable {
    var headFlag: UInt8
    var version: UInt8
    var sessionId: UInt32
    var sequence: UInt32
    var totalPackets: UInt8
    var currentPacket: UInt8
    var messageId: UInt16
    var payloadLength: UInt32
}

enum DVRIPMessageID {
    static let loginRequest: UInt16 = 1000
    static let logoutRequest: UInt16 = 1002
    static let keepAliveRequest: UInt16 = 1006
    static let sysInfoRequest: UInt16 = 1020
    static let configSetRequest: UInt16 = 1040
    static let configGetRequest: UInt16 = 1042
    static let playRequest: UInt16 = 1420
    static let fileSearchRequest: UInt16 = 1440
    static let sysManagerRequest: UInt16 = 1450
    static let timeQueryRequest: UInt16 = 1452
    static let diskManagerRequest: UInt16 = 1460
    static let modifyPasswordRequest: UInt16 = 1476
}

enum DVRIPProtocol {
    static let headerLength = 20
    private static let sofiaAlphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Xiongmai Sofia 8-char Base62 MD5 password transformation.
    static func sofiaHash(_ password: String) -> String {
        let digest = Array(Insecure.MD5.hash(data: Data(password.utf8)))
        var out = ""
        out.reserveCapacity(8)
        for i in 0..<8 {
            let sum = Int(digest[2 * i]) + Int(digest[2 * i + 1])
            out.append(self.sofiaAlphabet[sum % 62])
        }
        return out
    }

    static func encodePacket(
        sessionId: UInt32,
        sequence: UInt32,
        messageId: UInt16,
        jsonObject: [String: Any],
        totalPackets: UInt8 = 0,
        currentPacket: UInt8 = 0
    ) throws -> Data {
        let rawJson = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
        var payload = Data(rawJson)
        payload.append(contentsOf: [0x0A, 0x00])
        return self.encodePacket(
            sessionId: sessionId,
            sequence: sequence,
            messageId: messageId,
            payloadData: payload,
            totalPackets: totalPackets,
            currentPacket: currentPacket
        )
    }

    static func encodePacket(
        sessionId: UInt32,
        sequence: UInt32,
        messageId: UInt16,
        payloadData: Data,
        totalPackets: UInt8 = 0,
        currentPacket: UInt8 = 0
    ) -> Data {
        var packet = Data(capacity: self.headerLength + payloadData.count)
        packet.append(0xFF)
        packet.append(0x00)
        packet.append(0x00)
        packet.append(0x00)

        var sid = sessionId.littleEndian
        withUnsafeBytes(of: &sid) { packet.append(contentsOf: $0) }

        var seq = sequence.littleEndian
        withUnsafeBytes(of: &seq) { packet.append(contentsOf: $0) }

        packet.append(totalPackets)
        packet.append(currentPacket)

        var msg = messageId.littleEndian
        withUnsafeBytes(of: &msg) { packet.append(contentsOf: $0) }

        var len = UInt32(payloadData.count).littleEndian
        withUnsafeBytes(of: &len) { packet.append(contentsOf: $0) }

        packet.append(payloadData)
        return packet
    }

    static func decodeHeader(_ data: Data) -> DVRIPPacketHeader? {
        guard data.count >= self.headerLength else { return nil }
        let b = [UInt8](data.prefix(self.headerLength))
        guard b[0] == 0xFF else { return nil }
        let sid = UInt32(b[4]) | (UInt32(b[5]) << 8) | (UInt32(b[6]) << 16) | (UInt32(b[7]) << 24)
        let seq = UInt32(b[8]) | (UInt32(b[9]) << 8) | (UInt32(b[10]) << 16) | (UInt32(b[11]) << 24)
        let msg = UInt16(b[14]) | (UInt16(b[15]) << 8)
        let len = UInt32(b[16]) | (UInt32(b[17]) << 8) | (UInt32(b[18]) << 16) | (UInt32(b[19]) << 24)
        return DVRIPPacketHeader(
            headFlag: b[0],
            version: b[1],
            sessionId: sid,
            sequence: seq,
            totalPackets: b[12],
            currentPacket: b[13],
            messageId: msg,
            payloadLength: len
        )
    }

    static func decodeSessionIdHex(_ string: String?) -> UInt32 {
        guard let string else { return 0 }
        let cleaned = string.lowercased().replacingOccurrences(of: "0x", with: "")
        return UInt32(cleaned, radix: 16) ?? 0
    }

    static func formatSessionIdHex(_ sid: UInt32) -> String {
        String(format: "0x%08X", sid)
    }

    static func parseJSONObject(fromPayload data: Data) -> [String: AnyCodableJSON]? {
        var trimmed = data
        while let last = trimmed.last, last == 0x00 || last == 0x0A || last == 0x0D {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty,
              let root = try? JSONDecoder().decode([String: AnyCodableJSON].self, from: trimmed) else {
            return nil
        }
        return root
    }

    static func parseSystemInfo(_ root: [String: AnyCodableJSON]) -> DVRIPSystemInfo? {
        guard let info = root["SystemInfo"]?.objectValue else { return nil }
        return DVRIPSystemInfo(
            hardWare: info["HardWare"]?.stringValue ?? "",
            softWareVersion: info["SoftWareVersion"]?.stringValue ?? "",
            serialNo: info["SerialNo"]?.stringValue ?? "",
            buildTime: info["BuildTime"]?.stringValue ?? "",
            deviceRunTime: info["DeviceRunTime"]?.stringValue ?? "",
            videoInChannel: info["VideoInChannel"]?.intValue ?? 1,
            talkInChannel: info["TalkInChannel"]?.intValue ?? 0
        )
    }

    static func parseStorageInfo(_ root: [String: AnyCodableJSON]) -> DVRIPStorageInfo {
        guard let diskList = root["StorageInfo"]?.arrayValue else {
            return DVRIPStorageInfo(diskCount: 0, partitions: [])
        }
        var parts: [DVRIPStoragePartition] = []
        for disk in diskList {
            guard let obj = disk.objectValue,
                  let arr = obj["Partition"]?.arrayValue else { continue }
            for (idx, item) in arr.enumerated() {
                guard let p = item.objectValue else { continue }
                let totalHex = (p["TotalSpace"]?.stringValue ?? "0").replacingOccurrences(of: "0x", with: "")
                let remainHex = (p["RemainSpace"]?.stringValue ?? "0").replacingOccurrences(of: "0x", with: "")
                let totalMB = Int64(totalHex, radix: 16) ?? Int64(p["TotalSpace"]?.intValue ?? 0)
                let remainMB = Int64(remainHex, radix: 16) ?? Int64(p["RemainSpace"]?.intValue ?? 0)
                let driver = p["DirverType"]?.intValue ?? p["DriverType"]?.intValue ?? 0
                let status = p["Status"]?.intValue ?? 0
                parts.append(DVRIPStoragePartition(
                    partIndex: idx,
                    driverType: driver,
                    isCurrent: p["IsCurrent"]?.boolValue ?? false,
                    totalMB: totalMB,
                    remainMB: remainMB,
                    statusText: status == 0 ? "Normal" : "Status \(status)"
                ))
            }
        }
        return DVRIPStorageInfo(diskCount: diskList.count, partitions: parts)
    }

    static func parseEncodeConfig(_ root: [String: AnyCodableJSON]) -> DVRIPEncodeConfig? {
        guard let arr = root["Simplify.Encode"]?.arrayValue,
              let ch0 = arr.first?.objectValue else {
            return nil
        }
        func parseStream(_ obj: [String: AnyCodableJSON]?, fallbackRes: String) -> DVRIPEncodeStream {
            let vid = obj?["Video"]?.objectValue
            return DVRIPEncodeStream(
                compression: vid?["Compression"]?.stringValue ?? "H.265",
                resolution: vid?["Resolution"]?.stringValue ?? fallbackRes,
                fps: vid?["FPS"]?.intValue ?? 15,
                bitRate: vid?["BitRate"]?.intValue ?? 1024,
                quality: vid?["Quality"]?.intValue ?? 4,
                audioEnable: obj?["AudioEnable"]?.boolValue ?? false,
                videoEnable: obj?["VideoEnable"]?.boolValue ?? true
            )
        }
        return DVRIPEncodeConfig(
            mainStream: parseStream(ch0["MainFormat"]?.objectValue, fallbackRes: "1080P"),
            extraStream: parseStream(ch0["ExtraFormat"]?.objectValue, fallbackRes: "D1"),
            rawPayload: root
        )
    }

    static func parseDetectionConfig(motionRoot: [String: AnyCodableJSON], humanRoot: [String: AnyCodableJSON]?) -> DVRIPDetectionConfig {
        let motionObj = motionRoot["Detect.MotionDetect"]?.arrayValue?.first?.objectValue ?? [:]
        let humanObj = humanRoot?["Detect.HumanDection"]?.arrayValue?.first?.objectValue ?? [:]
        return DVRIPDetectionConfig(
            motionEnabled: motionObj["Enable"]?.boolValue ?? false,
            motionLevel: motionObj["Level"]?.intValue ?? 3,
            humanEnabled: humanObj["Enable"]?.boolValue ?? false,
            humanSensitivity: humanObj["Sensitivity"]?.intValue ?? 50,
            humanShowRule: humanObj["ShowRule"]?.boolValue ?? false,
            motionRaw: motionRoot,
            humanRaw: humanRoot ?? [:]
        )
    }

    static func parseWhiteLightConfig(_ root: [String: AnyCodableJSON]) -> DVRIPWhiteLightConfig {
        let obj = root["Camera.WhiteLight"]?.objectValue ?? [:]
        let modeStr = obj["WorkMode"]?.stringValue ?? "Auto"
        return DVRIPWhiteLightConfig(
            workMode: DVRIPWhiteLightMode(rawValue: modeStr) ?? .auto,
            rawPayload: root
        )
    }

    static func parseOSDConfig(titleRoot: [String: AnyCodableJSON], widgetRoot: [String: AnyCodableJSON]) -> DVRIPOSDConfig {
        let titles = titleRoot["AVEnc.ChannelTitle"]?.arrayValue
        let title = titles?.first?.stringValue ?? ""
        let widgets = widgetRoot["AVEnc.VideoWidget"]?.arrayValue?.first?.objectValue ?? [:]
        let showTitle = widgets["ChannelTitleAttribute"]?.objectValue?["EncodeBlend"]?.boolValue ?? true
        let showTime = widgets["TimeTitleAttribute"]?.objectValue?["EncodeBlend"]?.boolValue ?? true
        return DVRIPOSDConfig(
            title: title,
            showTitle: showTitle,
            showTimestamp: showTime,
            rawChannelTitle: titleRoot,
            rawVideoWidget: widgetRoot
        )
    }

    static func parsePrivacyConfig(_ root: [String: AnyCodableJSON]) -> DVRIPPrivacyConfig {
        let obj = root["NetWork.Nat"]?.objectValue ?? [:]
        return DVRIPPrivacyConfig(
            natEnabled: obj["NatEnable"]?.boolValue ?? true,
            natStatus: obj["NatInfoCode"]?.stringValue ?? "Unknown",
            rawNatPayload: root
        )
    }

    static func parseNetworkInfo(_ root: [String: AnyCodableJSON]) -> DVRIPNetworkInfo {
        let obj = root["NetWork.NetCommon"]?.objectValue ?? [:]
        return DVRIPNetworkInfo(
            hostIP: obj["HostIP"]?.stringValue ?? "",
            gateway: obj["GateWay"]?.stringValue ?? "",
            submask: obj["Submask"]?.stringValue ?? "",
            mac: obj["MAC"]?.stringValue ?? "",
            dns: obj["PrimaryDNS"]?.stringValue ?? "",
            dhcp: obj["DHCP"]?.boolValue ?? true
        )
    }

    static func parseRecordingFiles(_ root: [String: AnyCodableJSON]) -> [DVRIPRecordingFile] {
        guard let arr = root["OPFileQuery"]?.arrayValue else { return [] }
        return arr.compactMap { entry -> DVRIPRecordingFile? in
            guard let obj = entry.objectValue,
                  let fileName = obj["FileName"]?.stringValue else { return nil }
            let hexLen = (obj["FileLength"]?.stringValue ?? "0").replacingOccurrences(of: "0x", with: "")
            let bytes = Int64(hexLen, radix: 16) ?? Int64(obj["FileLength"]?.intValue ?? 0)
            return DVRIPRecordingFile(
                fileName: fileName,
                beginTime: obj["BeginTime"]?.stringValue ?? "",
                endTime: obj["EndTime"]?.stringValue ?? "",
                diskNo: obj["DiskNo"]?.intValue ?? 0,
                serialNo: obj["SerialNo"]?.intValue ?? 0,
                fileLengthHex: obj["FileLength"]?.stringValue ?? "0x0",
                sizeBytes: bytes
            )
        }
    }

    /// Strips Xiongmai raw stream container headers (`00 00 01 FC` I-frame, `00 00 01 FD` P-frame)
    /// into raw Annex-B elementary bitstream bytes ready for decoding/muxing.
    static func extractAnnexBVideoFrames(from rawData: Data) -> (annexBData: Data, detectedHEVC: Bool) {
        let bytes = [UInt8](rawData)
        var out = Data()
        var idx = 0
        var detectedHEVC = false

        while idx + 8 <= bytes.count {
            if bytes[idx] == 0x00 && bytes[idx + 1] == 0x00 && bytes[idx + 2] == 0x01 {
                let marker = bytes[idx + 3]
                if marker == 0xFC || marker == 0xFE {
                    // I-frame or special frame: 16-byte XM header total (including 4-byte sync)
                    guard idx + 16 <= bytes.count else { break }
                    let codecByte = bytes[idx + 4]
                    if codecByte == 0x03 { detectedHEVC = true } // HEVC tag in XM private frame
                    let length = Int(bytes[idx + 12]) | (Int(bytes[idx + 13]) << 8) | (Int(bytes[idx + 14]) << 16) | (Int(bytes[idx + 15]) << 24)
                    let payloadStart = idx + 16
                    if length > 0 && payloadStart + length <= bytes.count {
                        out.append(contentsOf: bytes[payloadStart..<(payloadStart + length)])
                        idx = payloadStart + length
                        continue
                    }
                } else if marker == 0xFD {
                    // P-frame: 8-byte XM header total (including 4-byte sync)
                    let length = Int(bytes[idx + 4]) | (Int(bytes[idx + 5]) << 8) | (Int(bytes[idx + 6]) << 16) | (Int(bytes[idx + 7]) << 24)
                    let payloadStart = idx + 8
                    if length > 0 && payloadStart + length <= bytes.count {
                        out.append(contentsOf: bytes[payloadStart..<(payloadStart + length)])
                        idx = payloadStart + length
                        continue
                    }
                } else if marker == 0xFA || marker == 0xF9 {
                    // Audio / Info frame: skip safely
                    let length = Int(bytes[idx + 6]) | (Int(bytes[idx + 7]) << 8)
                    let payloadStart = idx + 8
                    if length > 0 && payloadStart + length <= bytes.count {
                        idx = payloadStart + length
                        continue
                    }
                }
            }
            idx += 1
        }

        // Fallback if camera already returned plain Annex-B stream
        if out.isEmpty {
            return (rawData, false)
        }
        return (out, detectedHEVC)
    }
}

// MARK: - Live Asynchronous DVRIP TCP Session

actor DVRIPSession {
    private let host: String
    private let port: Int
    private var connection: NWConnection?
    private var buffer = ByteBuffer()
    private var sessionId: UInt32 = 0
    private var sequence: UInt32 = 0

    init(host: String, port: Int = 34567) {
        self.host = host
        self.port = port
    }

    func connectAndLogin(username: String, password: String) async throws -> UInt32 {
        self.close()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: self.port)) else {
            throw NSError(domain: "DirectCam.DVRIP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid DVRIP port \(self.port)."])
        }
        let conn = NWConnection(host: NWEndpoint.Host(self.host), port: nwPort, using: .tcp)
        self.connection = conn

        let gate = ContinuationGate()
        let queue = DispatchQueue(label: "com.lessy.directcam.dvrip.\(UUID().uuidString.prefix(6))")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.tryAcquire() { cont.resume() }
                case .failed(let err):
                    if gate.tryAcquire() { cont.resume(throwing: err) }
                case .cancelled:
                    if gate.tryAcquire() {
                        cont.resume(throwing: NSError(domain: "DirectCam.DVRIP", code: 2, userInfo: [NSLocalizedDescriptionKey: "DVRIP connection cancelled."]))
                    }
                default:
                    break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 6.0) {
                if gate.tryAcquire() {
                    conn.cancel()
                    cont.resume(throwing: NSError(domain: "DirectCam.DVRIP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timed out connecting to port \(self.port)."]))
                }
            }
        }

        let loginObj: [String: Any] = [
            "EncryptType": "MD5",
            "LoginType": "DVRIP-Web",
            "PassWord": DVRIPProtocol.sofiaHash(password),
            "UserName": username
        ]
        let response = try await self.sendCommand(messageId: DVRIPMessageID.loginRequest, jsonObject: loginObj)
        let ret = response["Ret"]?.intValue ?? -1
        guard ret == 100 || ret == 200 else {
            throw NSError(domain: "DirectCam.DVRIP", code: ret, userInfo: [
                NSLocalizedDescriptionKey: "DVRIP login rejected (code \(ret)). Verify device password."
            ])
        }
        let sidHex = response["SessionID"]?.stringValue
        let sid = DVRIPProtocol.decodeSessionIdHex(sidHex)
        self.sessionId = sid
        return sid
    }

    func close() {
        self.connection?.cancel()
        self.connection = nil
        self.buffer.removeAll()
        self.sessionId = 0
        self.sequence = 0
    }

    func getSystemInfo() async throws -> DVRIPSystemInfo {
        let obj: [String: Any] = ["Name": "SystemInfo", "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)]
        let resp = try await self.sendCommand(messageId: DVRIPMessageID.sysInfoRequest, jsonObject: obj)
        guard let parsed = DVRIPProtocol.parseSystemInfo(resp) else {
            throw NSError(domain: "DirectCam.DVRIP", code: 10, userInfo: [NSLocalizedDescriptionKey: "Missing SystemInfo payload."])
        }
        return parsed
    }

    func getStorageInfo() async throws -> DVRIPStorageInfo {
        let obj: [String: Any] = ["Name": "StorageInfo", "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)]
        let resp = try await self.sendCommand(messageId: DVRIPMessageID.sysInfoRequest, jsonObject: obj)
        return DVRIPProtocol.parseStorageInfo(resp)
    }

    func getConfig(name: String) async throws -> [String: AnyCodableJSON] {
        let obj: [String: Any] = ["Name": name, "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)]
        return try await self.sendCommand(messageId: DVRIPMessageID.configGetRequest, jsonObject: obj)
    }

    func setConfig(name: String, rawJsonObject: Any) async throws {
        let obj: [String: Any] = [
            "Name": name,
            "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId),
            name: rawJsonObject
        ]
        let resp = try await self.sendCommand(messageId: DVRIPMessageID.configSetRequest, jsonObject: obj)
        let ret = resp["Ret"]?.intValue ?? 100
        guard ret == 100 || ret == 102 else {
            throw NSError(domain: "DirectCam.DVRIP", code: ret, userInfo: [
                NSLocalizedDescriptionKey: "Failed saving \(name) (Ret \(ret))."
            ])
        }
    }

    func syncClockToNow() async throws {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let obj: [String: Any] = [
            "Name": "OPTimeSetting",
            "OPTimeSetting": fmt.string(from: Date()),
            "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)
        ]
        _ = try await self.sendCommand(messageId: DVRIPMessageID.sysManagerRequest, jsonObject: obj)
    }

    func rebootCamera() async throws {
        let obj: [String: Any] = [
            "Name": "OPMachine",
            "OPMachine": ["Action": "Reboot"],
            "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)
        ]
        _ = try await self.sendCommand(messageId: DVRIPMessageID.sysManagerRequest, jsonObject: obj)
    }

    func formatMicroSD(serialNo: Int = 0, partNo: Int = 0) async throws {
        let obj: [String: Any] = [
            "Name": "OPStorageManager",
            "OPStorageManager": [
                "Action": "Clear",
                "SerialNo": serialNo,
                "Type": "Data",
                "PartNo": partNo
            ],
            "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)
        ]
        let resp = try await self.sendCommand(messageId: DVRIPMessageID.diskManagerRequest, jsonObject: obj)
        let ret = resp["Ret"]?.intValue ?? 100
        guard ret == 100 else {
            throw NSError(domain: "DirectCam.DVRIP", code: ret, userInfo: [
                NSLocalizedDescriptionKey: "SD format rejected (Ret \(ret))."
            ])
        }
    }

    func modifyPassword(username: String, oldPassword: String, newPassword: String) async throws {
        let obj: [String: Any] = [
            "EncryptType": "MD5",
            "NewPassWord": DVRIPProtocol.sofiaHash(newPassword),
            "PassWord": DVRIPProtocol.sofiaHash(oldPassword),
            "UserName": username,
            "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)
        ]
        let resp = try await self.sendCommand(messageId: DVRIPMessageID.modifyPasswordRequest, jsonObject: obj)
        let ret = resp["Ret"]?.intValue ?? 100
        guard ret == 100 else {
            throw NSError(domain: "DirectCam.DVRIP", code: ret, userInfo: [
                NSLocalizedDescriptionKey: "Password update rejected (Ret \(ret))."
            ])
        }
    }

    func queryRecordings(channel: Int, day: Date, alarmOnly: Bool) async throws -> [DVRIPRecordingFile] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: day)
        let endOfDay = cal.date(byAdding: DateComponents(hour: 23, minute: 59, second: 59), to: startOfDay) ?? day
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        let obj: [String: Any] = [
            "Name": "OPFileQuery",
            "OPFileQuery": [
                "BeginTime": fmt.string(from: startOfDay),
                "EndTime": fmt.string(from: endOfDay),
                "Channel": channel,
                "DriverTypeMask": "0x0000FFFF",
                "Event": alarmOnly ? "A" : "*",
                "Type": "h264"
            ],
            "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)
        ]
        let resp = try await self.sendCommand(messageId: DVRIPMessageID.fileSearchRequest, jsonObject: obj)
        return DVRIPProtocol.parseRecordingFiles(resp)
    }

    func downloadRecording(file: DVRIPRecordingFile) async throws -> (annexBData: Data, detectedHEVC: Bool) {
        let obj: [String: Any] = [
            "Name": "OPPlayBack",
            "OPPlayBack": [
                "Action": "DownloadStart",
                "Parameter": [
                    "FileName": file.fileName,
                    "PlayMode": "ByName",
                    "TransMode": "TCP",
                    "Value": 0
                ],
                "StartTime": file.beginTime,
                "EndTime": file.endTime
            ],
            "SessionID": DVRIPProtocol.formatSessionIdHex(self.sessionId)
        ]

        let packet = try DVRIPProtocol.encodePacket(
            sessionId: self.sessionId,
            sequence: self.nextSeq(),
            messageId: DVRIPMessageID.playRequest,
            jsonObject: obj
        )
        try await self.writeAll(packet)

        var collectedMedia = Data()
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            guard let (hdr, body) = try? await self.readPacket(timeout: 3.0) else { break }
            if hdr.messageId == 1421 {
                // PlayBack JSON response or EOF indicator
                if let json = DVRIPProtocol.parseJSONObject(fromPayload: body),
                   let ret = json["Ret"]?.intValue, ret != 100 && ret != 102 {
                    break
                }
            } else {
                collectedMedia.append(body)
                if file.sizeBytes > 0 && Int64(collectedMedia.count) >= file.sizeBytes {
                    break
                }
            }
        }
        return DVRIPProtocol.extractAnnexBVideoFrames(from: collectedMedia)
    }

    // MARK: - Low-Level Packet IO

    private func nextSeq() -> UInt32 {
        let current = self.sequence
        self.sequence &+= 1
        return current
    }

    private func sendCommand(messageId: UInt16, jsonObject: [String: Any]) async throws -> [String: AnyCodableJSON] {
        let packet = try DVRIPProtocol.encodePacket(
            sessionId: self.sessionId,
            sequence: self.nextSeq(),
            messageId: messageId,
            jsonObject: jsonObject
        )
        try await self.writeAll(packet)

        var combinedPayload = Data()
        while true {
            let (hdr, body) = try await self.readPacket(timeout: 6.0)
            combinedPayload.append(body)
            let total = Int(hdr.totalPackets)
            let cur = Int(hdr.currentPacket)
            if total <= 1 || cur + 1 >= total {
                break
            }
        }
        guard let parsed = DVRIPProtocol.parseJSONObject(fromPayload: combinedPayload) else {
            throw NSError(domain: "DirectCam.DVRIP", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON response from camera DVRIP port."
            ])
        }
        return parsed
    }

    private func writeAll(_ data: Data) async throws {
        guard let conn = self.connection else {
            throw NSError(domain: "DirectCam.DVRIP", code: 21, userInfo: [NSLocalizedDescriptionKey: "DVRIP socket is closed."])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    private func readPacket(timeout: TimeInterval) async throws -> (DVRIPPacketHeader, Data) {
        try await self.fillBuffer(minBytes: DVRIPProtocol.headerLength, timeout: timeout)
        guard let hdrData = self.buffer.slice(0..<DVRIPProtocol.headerLength),
              let hdr = DVRIPProtocol.decodeHeader(hdrData) else {
            throw NSError(domain: "DirectCam.DVRIP", code: 22, userInfo: [NSLocalizedDescriptionKey: "Invalid DVRIP packet header."])
        }
        let bodyLen = Int(hdr.payloadLength)
        guard bodyLen >= 0 && bodyLen <= 8_388_608 else {
            throw NSError(domain: "DirectCam.DVRIP", code: 23, userInfo: [NSLocalizedDescriptionKey: "Unexpected DVRIP payload size \(bodyLen)."])
        }
        let frameTotal = DVRIPProtocol.headerLength + bodyLen
        try await self.fillBuffer(minBytes: frameTotal, timeout: timeout)
        self.buffer.dropFirst(DVRIPProtocol.headerLength)
        let body = self.buffer.read(bodyLen) ?? Data()
        return (hdr, body)
    }

    private func fillBuffer(minBytes: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while self.buffer.count < minBytes {
            guard Date() < deadline else {
                throw NSError(domain: "DirectCam.DVRIP", code: 24, userInfo: [NSLocalizedDescriptionKey: "DVRIP read timed out."])
            }
            guard let conn = self.connection else {
                throw NSError(domain: "DirectCam.DVRIP", code: 25, userInfo: [NSLocalizedDescriptionKey: "DVRIP connection lost."])
            }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, err in
                    if let err {
                        cont.resume(throwing: err)
                    } else if let content, !content.isEmpty {
                        cont.resume(returning: content)
                    } else if isComplete {
                        cont.resume(throwing: NSError(domain: "DirectCam.DVRIP", code: 26, userInfo: [NSLocalizedDescriptionKey: "Camera closed DVRIP connection."]))
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            if !chunk.isEmpty {
                self.buffer.append(chunk)
            }
        }
    }
}
