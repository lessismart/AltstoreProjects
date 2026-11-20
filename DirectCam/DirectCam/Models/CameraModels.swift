import Foundation

enum StreamQuality: String, Codable, CaseIterable, Sendable {
    case main
    case sub

    var label: String {
        switch self {
        case .main: return "Main (HD)"
        case .sub: return "Sub (Fast)"
        }
    }

    var streamIndex: Int {
        switch self {
        case .main: return 0
        case .sub: return 1
        }
    }
}

enum RTSPPathStyle: String, Codable, CaseIterable, Sendable {
    case xiongmaiAmp = "xiongmai_amp"
    case xiongmaiUnderscore = "xiongmai_underscore"
    case onvifAuto = "onvif_auto"
    case custom = "custom"

    var label: String {
        switch self {
        case .xiongmaiAmp: return "Xiongmai / iCSee (&)"
        case .xiongmaiUnderscore: return "Xiongmai / iCSee (_)"
        case .onvifAuto: return "ONVIF Auto URI"
        case .custom: return "Custom Path"
        }
    }
}

struct CameraProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var rtspPort: Int
    var onvifPort: Int
    var dvripPort: Int
    var httpPort: Int
    var username: String
    var channel: Int
    var preferredStream: StreamQuality
    var rtspPathStyle: RTSPPathStyle
    var customMainPath: String
    var customSubPath: String
    var discoveredMainURI: String
    var discoveredSubURI: String
    var discoveredSnapshotURI: String
    var notes: String

    init(
        id: UUID = UUID(),
        name: String = "Outdoor Camera",
        host: String = "192.168.2.46",
        rtspPort: Int = 554,
        onvifPort: Int = 8899,
        dvripPort: Int = 34567,
        httpPort: Int = 80,
        username: String = "admin",
        channel: Int = 0,
        preferredStream: StreamQuality = .main,
        rtspPathStyle: RTSPPathStyle = .xiongmaiAmp,
        customMainPath: String = "/stream1",
        customSubPath: String = "/stream2",
        discoveredMainURI: String = "",
        discoveredSubURI: String = "",
        discoveredSnapshotURI: String = "",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.rtspPort = rtspPort
        self.onvifPort = onvifPort
        self.dvripPort = dvripPort
        self.httpPort = httpPort
        self.username = username
        self.channel = channel
        self.preferredStream = preferredStream
        self.rtspPathStyle = rtspPathStyle
        self.customMainPath = customMainPath
        self.customSubPath = customSubPath
        self.discoveredMainURI = discoveredMainURI
        self.discoveredSubURI = discoveredSubURI
        self.discoveredSnapshotURI = discoveredSnapshotURI
        self.notes = notes
    }
}

struct PortProbeResult: Equatable, Sendable {
    var host: String
    var rtspOpen: Bool
    var onvifOpen: Bool
    var dvripOpen: Bool
    var httpOpen: Bool
    var checkedAt: Date
}

struct DiscoveredCamera: Identifiable, Equatable, Sendable {
    var id: String { "\(host):\(onvifPort)" }
    var host: String
    var onvifPort: Int
    var xAddrs: [String]
    var name: String
    var hardware: String
}

// MARK: - ONVIF Models

struct ONVIFDeviceInfo: Equatable, Sendable {
    var manufacturer: String
    var model: String
    var firmwareVersion: String
    var serialNumber: String
    var hardwareId: String
}

struct ONVIFCapabilities: Equatable, Sendable {
    var deviceXAddr: String
    var mediaXAddr: String
    var imagingXAddr: String
    var ptzXAddr: String
    var eventsXAddr: String

    var supportsPTZ: Bool { !ptzXAddr.isEmpty }
    var supportsImaging: Bool { !imagingXAddr.isEmpty }
    var supportsEvents: Bool { !eventsXAddr.isEmpty }
}

struct ONVIFMediaProfile: Identifiable, Equatable, Sendable {
    var id: String { token }
    var token: String
    var name: String
    var videoSourceToken: String
    var ptzToken: String
    var width: Int
    var height: Int
    var encoding: String
}

enum IRCutFilterMode: String, CaseIterable, Codable, Sendable {
    case auto = "AUTO"
    case on = "ON"
    case off = "OFF"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .on: return "Night (IR On)"
        case .off: return "Day Color (IR Off)"
        }
    }
}

struct ONVIFImagingSettings: Equatable, Sendable {
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var sharpness: Double
    var irCutFilter: IRCutFilterMode
}

struct ONVIFPTZPreset: Identifiable, Equatable, Sendable {
    var id: String { token }
    var token: String
    var name: String
}

struct ONVIFMotionEvent: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var timestamp: Date
    var topic: String
    var detail: String
}

// MARK: - Xiongmai DVRIP (:34567) Models

struct DVRIPSystemInfo: Equatable, Sendable {
    var hardWare: String
    var softWareVersion: String
    var serialNo: String
    var buildTime: String
    var deviceRunTime: String
    var videoInChannel: Int
    var talkInChannel: Int
}

struct DVRIPStoragePartition: Identifiable, Equatable, Sendable {
    var id: Int { driverType * 100 + partIndex }
    var partIndex: Int
    var driverType: Int
    var isCurrent: Bool
    var totalMB: Int64
    var remainMB: Int64
    var statusText: String
}

struct DVRIPStorageInfo: Equatable, Sendable {
    var diskCount: Int
    var partitions: [DVRIPStoragePartition]

    var totalMB: Int64 { partitions.reduce(0) { $0 + $1.totalMB } }
    var remainMB: Int64 { partitions.reduce(0) { $0 + $1.remainMB } }
}

struct DVRIPEncodeStream: Equatable, Sendable {
    var compression: String
    var resolution: String
    var fps: Int
    var bitRate: Int
    var quality: Int
    var audioEnable: Bool
    var videoEnable: Bool
}

struct DVRIPEncodeConfig: Equatable, Sendable {
    var mainStream: DVRIPEncodeStream
    var extraStream: DVRIPEncodeStream
    var rawPayload: [String: AnyCodableJSON]
}

struct DVRIPDetectionConfig: Equatable, Sendable {
    var motionEnabled: Bool
    var motionLevel: Int
    var humanEnabled: Bool
    var humanSensitivity: Int
    var humanShowRule: Bool
    var motionRaw: [String: AnyCodableJSON]
    var humanRaw: [String: AnyCodableJSON]
}

enum DVRIPWhiteLightMode: String, CaseIterable, Sendable {
    case auto = "Auto"
    case intelligent = "Intelligent"
    case keepOpen = "KeepOpen"
    case close = "Close"

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .intelligent: return "Smart Warm Light"
        case .keepOpen: return "Always On"
        case .close: return "Off (IR Only)"
        }
    }
}

struct DVRIPWhiteLightConfig: Equatable, Sendable {
    var workMode: DVRIPWhiteLightMode
    var rawPayload: [String: AnyCodableJSON]
}

struct DVRIPOSDConfig: Equatable, Sendable {
    var title: String
    var showTitle: Bool
    var showTimestamp: Bool
    var rawChannelTitle: [String: AnyCodableJSON]
    var rawVideoWidget: [String: AnyCodableJSON]
}

struct DVRIPPrivacyConfig: Equatable, Sendable {
    var natEnabled: Bool
    var natStatus: String
    var rawNatPayload: [String: AnyCodableJSON]
}

struct DVRIPNetworkInfo: Equatable, Sendable {
    var hostIP: String
    var gateway: String
    var submask: String
    var mac: String
    var dns: String
    var dhcp: Bool
}

struct DVRIPRecordingFile: Identifiable, Equatable, Sendable {
    var id: String { fileName }
    var fileName: String
    var beginTime: String
    var endTime: String
    var diskNo: Int
    var serialNo: Int
    var fileLengthHex: String
    var sizeBytes: Int64

    var isAlarm: Bool {
        let lower = fileName.lowercased()
        return lower.contains("[a]") || lower.contains("alarm") || lower.contains("[m]")
    }
}

// MARK: - Local Media & On-Device Vision Monitor Models

enum LocalMediaKind: String, Codable, CaseIterable, Sendable {
    case snapshot
    case recording
    case alertClip

    var badge: String {
        switch self {
        case .snapshot: return "Snapshot"
        case .recording: return "Recording"
        case .alertClip: return "Alert Clip"
        }
    }
}

struct LocalMediaItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var cameraID: UUID
    var cameraName: String
    var kind: LocalMediaKind
    var relativePath: String
    var createdAt: Date
    var fileSizeBytes: Int64
    var caption: String
}

enum VisionTargetKind: String, Codable, Equatable, Sendable {
    case human
    case pet

    var label: String {
        switch self {
        case .human: return "Person"
        case .pet: return "Animal / Pet"
        }
    }
}

struct VisionDetectionBox: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var kind: VisionTargetKind
    var confidence: Float
    /// Normalized in image display space (origin top-left, 0...1).
    var normalizedRectTopLeft: (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)

    static func == (lhs: VisionDetectionBox, rhs: VisionDetectionBox) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.confidence == rhs.confidence
    }
}

struct VisionAlertEvent: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var cameraID: UUID
    var cameraName: String
    var kind: VisionTargetKind
    var confidence: Float
    var timestamp: Date
    var snapshotRelativePath: String?
    var clipRelativePath: String?
}

struct MonitorSettings: Codable, Equatable, Sendable {
    var detectHumans: Bool = true
    var detectPets: Bool = false
    var minConfidence: Double = 0.65
    var cooldownSeconds: Int = 20
    var playChime: Bool = true
    var sendNotification: Bool = true
    var autoRecordClip: Bool = true
    var clipDurationSeconds: Int = 10
    var keepScreenAwakeInKiosk: Bool = true
    var maxStorageMB: Int = 2048
}

// MARK: - Lightweight Sendable JSON Value for Raw Round-Trip Updates

enum AnyCodableJSON: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableJSON])
    case object([String: AnyCodableJSON])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let arr = try? container.decode([AnyCodableJSON].self) { self = .array(arr) }
        else if let dict = try? container.decode([String: AnyCodableJSON].self) { self = .object(dict) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let arr): try container.encode(arr)
        case .object(let dict): try container.encode(dict)
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        default: return nil
        }
    }

    var objectValue: [String: AnyCodableJSON]? {
        if case .object(let d) = self { return d }
        return nil
    }

    var arrayValue: [AnyCodableJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }
}
