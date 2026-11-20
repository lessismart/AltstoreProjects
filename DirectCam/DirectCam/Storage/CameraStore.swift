import Foundation

struct ExportedCameraBundle: Codable, Sendable {
    var format: String
    var exportedAt: Date
    var cameras: [CameraProfile]
    var monitorSettings: MonitorSettings
}

final class CameraStore {
    let baseDirectory: URL
    private let profilesURL: URL
    private let monitorSettingsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(baseDirectory: URL? = nil) {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            root = appSupport.appendingPathComponent("DirectCam", isDirectory: true)
        }
        self.baseDirectory = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.profilesURL = root.appendingPathComponent("cameras.json")
        self.monitorSettingsURL = root.appendingPathComponent("monitor-settings.json")

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    func loadCameras() -> [CameraProfile] {
        guard let data = try? Data(contentsOf: self.profilesURL),
              let list = try? self.decoder.decode([CameraProfile].self, from: data) else {
            return []
        }
        return list
    }

    func saveCameras(_ cameras: [CameraProfile]) throws {
        let data = try self.encoder.encode(cameras)
        try data.write(to: self.profilesURL, options: [.atomic])
    }

    func loadMonitorSettings() -> MonitorSettings {
        guard let data = try? Data(contentsOf: self.monitorSettingsURL),
              let settings = try? self.decoder.decode(MonitorSettings.self, from: data) else {
            return MonitorSettings()
        }
        return settings
    }

    func saveMonitorSettings(_ settings: MonitorSettings) throws {
        let data = try self.encoder.encode(settings)
        try data.write(to: self.monitorSettingsURL, options: [.atomic])
    }

    /// Exports camera profiles without passwords (passwords always remain exclusively in Apple Keychain).
    func exportProfilesData(cameras: [CameraProfile], settings: MonitorSettings) throws -> Data {
        let bundle = ExportedCameraBundle(
            format: "directcam-profiles-v1",
            exportedAt: Date(),
            cameras: cameras,
            monitorSettings: settings
        )
        return try self.encoder.encode(bundle)
    }

    func importProfilesData(_ data: Data) throws -> ExportedCameraBundle {
        let bundle = try self.decoder.decode(ExportedCameraBundle.self, from: data)
        guard bundle.format == "directcam-profiles-v1" else {
            throw NSError(domain: "DirectCam.Import", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported profile backup format '\(bundle.format)'."
            ])
        }
        return bundle
    }
}
