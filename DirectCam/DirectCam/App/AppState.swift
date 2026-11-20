import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppState: ObservableObject {
    let cameraStore = CameraStore()
    let mediaStore = LocalMediaStore()
    private let onvif = ONVIFClient()

    @Published var cameras: [CameraProfile] = []
    @Published var selectedCameraID: UUID?
    @Published var sessions: [UUID: RTSPStreamSession] = [:]
    @Published var monitorSettings = MonitorSettings()

    @Published var gridModeEnabled = false
    @Published var kioskMonitoringActive = false
    @Published var mediaItems: [LocalMediaItem] = []
    @Published var alertEvents: [VisionAlertEvent] = []

    // Discovery & Port Probe
    @Published var portProbes: [UUID: PortProbeResult] = [:]
    @Published var discoveredCameras: [DiscoveredCamera] = []
    @Published var isDiscovering = false

    // Selected Camera Admin State (ONVIF + DVRIP)
    @Published var isLoadingAdmin = false
    @Published var adminStatusMessage: String?
    @Published var onvifCapabilities: ONVIFCapabilities?
    @Published var onvifDeviceInfo: ONVIFDeviceInfo?
    @Published var onvifProfiles: [ONVIFMediaProfile] = []
    @Published var imagingSettings: ONVIFImagingSettings?
    @Published var ptzPresets: [ONVIFPTZPreset] = []
    @Published var motionEvents: [ONVIFMotionEvent] = []
    @Published var isPullingEvents = false

    @Published var dvripSystemInfo: DVRIPSystemInfo?
    @Published var dvripStorageInfo: DVRIPStorageInfo?
    @Published var dvripEncodeConfig: DVRIPEncodeConfig?
    @Published var dvripDetectionConfig: DVRIPDetectionConfig?
    @Published var dvripWhiteLightConfig: DVRIPWhiteLightConfig?
    @Published var dvripOSDConfig: DVRIPOSDConfig?
    @Published var dvripPrivacyConfig: DVRIPPrivacyConfig?
    @Published var dvripNetworkInfo: DVRIPNetworkInfo?
    @Published var dvripRecordings: [DVRIPRecordingFile] = []
    @Published var isDownloadingRecording = false

    @Published var diagnosticsLog: [String] = []
    @Published var bannerMessage: String?

    private var pullPointTask: Task<Void, Never>?

    init() {
        let loaded = self.cameraStore.loadCameras()
        if loaded.isEmpty {
            let starter = CameraProfile(name: "Outdoor Camera", host: "192.168.2.46")
            self.cameras = [starter]
            try? self.cameraStore.saveCameras(self.cameras)
            self.selectedCameraID = starter.id
            self.cameraStore.saveSelectedCameraID(starter.id)
        } else {
            self.cameras = loaded
            let savedID = self.cameraStore.loadSelectedCameraID()
            if let savedID, loaded.contains(where: { $0.id == savedID }) {
                self.selectedCameraID = savedID
            } else {
                // Prefer any camera that already has a stored credential if savedID was unset
                self.selectedCameraID = loaded.first(where: { !KeychainVault.loadPassword(forCameraID: $0.id).isEmpty })?.id ?? loaded.first?.id
            }
        }
        self.monitorSettings = self.cameraStore.loadMonitorSettings()
        self.mediaItems = self.mediaStore.loadMediaItems()
        self.alertEvents = self.mediaStore.loadAlerts()
        self.ensureSessionsExist()
    }

    var selectedCamera: CameraProfile? {
        self.cameras.first { $0.id == self.selectedCameraID } ?? self.cameras.first
    }

    func session(for camera: CameraProfile) -> RTSPStreamSession {
        if let existing = self.sessions[camera.id] {
            return existing
        }
        let created = RTSPStreamSession()
        self.sessions[camera.id] = created
        return created
    }

    func password(for camera: CameraProfile) -> String {
        KeychainVault.loadPassword(forCameraID: camera.id)
    }

    func log(_ message: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(message)"
        self.diagnosticsLog.insert(line, at: 0)
        if self.diagnosticsLog.count > 120 {
            self.diagnosticsLog.removeLast(self.diagnosticsLog.count - 120)
        }
    }

    func showBanner(_ message: String) {
        self.bannerMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if self?.bannerMessage == message {
                self?.bannerMessage = nil
            }
        }
    }

    // MARK: - Camera Profile Management

    func upsertCamera(_ profile: CameraProfile, password: String?) {
        if let idx = self.cameras.firstIndex(where: { $0.id == profile.id }) {
            self.cameras[idx] = profile
        } else {
            self.cameras.append(profile)
        }
        self.selectedCameraID = profile.id
        self.cameraStore.saveSelectedCameraID(profile.id)

        if let password {
            do {
                let backend = try KeychainVault.savePassword(password, forCameraID: profile.id)
                switch backend {
                case .keychain:
                    self.log("Saved password for '\(profile.name)' to Apple Keychain.")
                case .localProtectedFile(let status):
                    self.log("Keychain returned \(status); saved password for '\(profile.name)' to protected device vault.")
                }
            } catch {
                self.log("Failed saving password for '\(profile.name)': \(error.localizedDescription)")
                self.showBanner("Password save failed: \(error.localizedDescription)")
            }
        }
        do {
            try self.cameraStore.saveCameras(self.cameras)
        } catch {
            self.showBanner("Failed saving camera list: \(error.localizedDescription)")
        }
        self.ensureSessionsExist()
        self.log("Saved profile '\(profile.name)' (\(profile.host)).")
    }

    func deleteCamera(_ profile: CameraProfile) {
        self.sessions[profile.id]?.stop()
        self.sessions.removeValue(forKey: profile.id)
        KeychainVault.deletePassword(forCameraID: profile.id)
        self.cameras.removeAll { $0.id == profile.id }
        try? self.cameraStore.saveCameras(self.cameras)
        if self.selectedCameraID == profile.id {
            self.selectedCameraID = self.cameras.first?.id
            self.cameraStore.saveSelectedCameraID(self.selectedCameraID)
        }
        self.log("Removed profile '\(profile.name)'.")
    }

    func selectCamera(_ camera: CameraProfile) {
        self.selectedCameraID = camera.id
        self.cameraStore.saveSelectedCameraID(camera.id)
        self.clearAdminState()
    }

    func saveMonitorSettings() {
        try? self.cameraStore.saveMonitorSettings(self.monitorSettings)
        if let cam = self.selectedCamera {
            self.applyMonitoringState(for: cam)
        }
    }

    // MARK: - Live Streaming, Recording & Vision Monitor

    func connectStream(for camera: CameraProfile, quality: StreamQuality? = nil) {
        let sess = self.session(for: camera)
        let pwd = self.password(for: camera)
        self.applyMonitoringState(for: camera)
        let previewURL = RTSPProtocol.redactedURL(RTSPProtocol.buildRTSPURL(profile: camera, password: pwd, quality: quality ?? camera.preferredStream))
        self.log("Starting RTSP session: \(previewURL)")
        sess.start(profile: camera, password: pwd, quality: quality)
    }

    func disconnectStream(for camera: CameraProfile) {
        self.session(for: camera).stop()
        self.log("Stopped RTSP session for '\(camera.name)'.")
    }

    func toggleKioskMonitoring() {
        self.kioskMonitoringActive.toggle()
        if self.kioskMonitoringActive {
            VisionAlertEngine.requestNotificationPermission()
        }
        UIApplication.shared.isIdleTimerDisabled = self.kioskMonitoringActive && self.monitorSettings.keepScreenAwakeInKiosk
        if let cam = self.selectedCamera {
            self.applyMonitoringState(for: cam)
            if self.kioskMonitoringActive && !self.session(for: cam).isConnected {
                self.connectStream(for: cam)
            }
        }
    }

    func setSceneActive(_ isActive: Bool) {
        if !isActive {
            UIApplication.shared.isIdleTimerDisabled = false
        } else {
            UIApplication.shared.isIdleTimerDisabled = self.kioskMonitoringActive && self.monitorSettings.keepScreenAwakeInKiosk
        }
    }

    func captureSnapshot(for camera: CameraProfile) {
        let sess = self.session(for: camera)
        if let saved = sess.captureSnapshot(to: self.mediaStore) {
            self.mediaItems = self.mediaStore.loadMediaItems()
            self.showBanner("Saved snapshot '\(saved.relativePath)'.")
            return
        }
        // Fallback: try direct ONVIF HTTP snapshot URI if RTSP stream is idle
        Task {
            do {
                let pwd = self.password(for: camera)
                var snapURI = camera.discoveredSnapshotURI
                if snapURI.isEmpty {
                    let caps = try await self.onvif.getCapabilities(host: camera.host, port: camera.onvifPort, username: camera.username, password: pwd)
                    let fallbackMediaURL = try self.onvif.baseDeviceURL(host: camera.host, port: camera.onvifPort)
                    let mediaURL = URL(string: caps.mediaXAddr) ?? fallbackMediaURL
                    let profiles = try await self.onvif.getMediaProfiles(mediaURL: mediaURL, username: camera.username, password: pwd)
                    if let tok = profiles.first?.token {
                        snapURI = (try await self.onvif.getSnapshotURI(mediaURL: mediaURL, profileToken: tok, username: camera.username, password: pwd)) ?? ""
                    }
                }
                guard !snapURI.isEmpty else {
                    self.showBanner("Connect live stream first or verify ONVIF snapshot support.")
                    return
                }
                let data = try await self.onvif.fetchSnapshotData(uriString: snapURI, username: camera.username, password: pwd)
                let saved = try self.mediaStore.saveSnapshot(
                    jpegData: data,
                    cameraID: camera.id,
                    cameraName: camera.name,
                    caption: "ONVIF Snapshot",
                    maxStorageMB: self.monitorSettings.maxStorageMB
                )
                self.mediaItems = self.mediaStore.loadMediaItems()
                self.showBanner("Saved ONVIF snapshot '\(saved.relativePath)'.")
            } catch {
                self.showBanner("Snapshot failed: \(error.localizedDescription)")
            }
        }
    }

    func toggleManualRecord(for camera: CameraProfile) async {
        let sess = self.session(for: camera)
        if let saved = await sess.toggleManualRecording(store: self.mediaStore) {
            self.mediaItems = self.mediaStore.loadMediaItems()
            self.showBanner("Saved clip '\(saved.relativePath)'.")
        } else if sess.isRecording {
            self.showBanner("Recording MP4...")
        }
    }

    func deleteMediaItem(_ item: LocalMediaItem) {
        try? self.mediaStore.deleteItem(item)
        self.mediaItems = self.mediaStore.loadMediaItems()
    }

    func clearAlerts() {
        self.alertEvents = []
        try? self.mediaStore.saveAlerts([])
    }

    // MARK: - Discovery & Port Probing

    func discoverLAN() async {
        self.isDiscovering = true
        self.log("Running ONVIF WS-Discovery multicast probe...")
        let found = await NetworkScanner.discoverONVIFCameras()
        self.discoveredCameras = found
        self.isDiscovering = false
        self.log("Discovery finished: found \(found.count) ONVIF camera(s).")
    }

    func probePorts(for camera: CameraProfile) async -> PortProbeResult {
        let result = await NetworkScanner.probeCameraPorts(
            host: camera.host,
            rtspPort: camera.rtspPort,
            onvifPort: camera.onvifPort,
            dvripPort: camera.dvripPort,
            httpPort: camera.httpPort
        )
        self.portProbes[camera.id] = result
        self.log("Ports for \(camera.host): RTSP=\(result.rtspOpen) ONVIF=\(result.onvifOpen) DVRIP=\(result.dvripOpen) HTTP=\(result.httpOpen)")
        return result
    }

    // MARK: - Direct ONVIF & DVRIP Administration

    func refreshAllAdmin(for camera: CameraProfile) async {
        self.isLoadingAdmin = true
        self.adminStatusMessage = nil
        let pwd = self.password(for: camera)
        var errors: [String] = []

        // 1. ONVIF query
        do {
            let caps = try await self.onvif.getCapabilities(host: camera.host, port: camera.onvifPort, username: camera.username, password: pwd)
            self.onvifCapabilities = caps
            self.onvifDeviceInfo = try await self.onvif.getDeviceInformation(host: camera.host, port: camera.onvifPort, username: camera.username, password: pwd)

            if let mediaURL = URL(string: caps.mediaXAddr) {
                let profiles = try await self.onvif.getMediaProfiles(mediaURL: mediaURL, username: camera.username, password: pwd)
                self.onvifProfiles = profiles

                var updated = camera
                if let p0 = profiles.first {
                    if let mainURI = try? await self.onvif.getStreamURI(mediaURL: mediaURL, profileToken: p0.token, username: camera.username, password: pwd) {
                        updated.discoveredMainURI = mainURI
                    }
                    if let snapURI = try? await self.onvif.getSnapshotURI(mediaURL: mediaURL, profileToken: p0.token, username: camera.username, password: pwd) {
                        updated.discoveredSnapshotURI = snapURI
                    }
                    if caps.supportsImaging, let imgURL = URL(string: caps.imagingXAddr), !p0.videoSourceToken.isEmpty {
                        self.imagingSettings = try? await self.onvif.getImagingSettings(imagingURL: imgURL, videoSourceToken: p0.videoSourceToken, username: camera.username, password: pwd)
                    }
                    if caps.supportsPTZ, let ptzURL = URL(string: caps.ptzXAddr) {
                        self.ptzPresets = (try? await self.onvif.getPTZPresets(ptzURL: ptzURL, profileToken: p0.token, username: camera.username, password: pwd)) ?? []
                    }
                }
                if profiles.count > 1,
                   let subURI = try? await self.onvif.getStreamURI(mediaURL: mediaURL, profileToken: profiles[1].token, username: camera.username, password: pwd) {
                    updated.discoveredSubURI = subURI
                }
                if updated != camera {
                    self.upsertCamera(updated, password: nil)
                }
            }
            self.log("ONVIF diagnostics loaded for \(camera.host):\(camera.onvifPort).")
        } catch {
            errors.append("ONVIF: \(error.localizedDescription)")
        }

        // 2. Xiongmai DVRIP (:34567) query
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        do {
            _ = try await dvrip.connectAndLogin(username: camera.username, password: pwd)
            self.dvripSystemInfo = try? await dvrip.getSystemInfo()
            self.dvripStorageInfo = try? await dvrip.getStorageInfo()
            if let encRaw = try? await dvrip.getConfig(name: "Simplify.Encode") {
                self.dvripEncodeConfig = DVRIPProtocol.parseEncodeConfig(encRaw)
            }
            if let motRaw = try? await dvrip.getConfig(name: "Detect.MotionDetect") {
                let humRaw = try? await dvrip.getConfig(name: "Detect.HumanDection")
                self.dvripDetectionConfig = DVRIPProtocol.parseDetectionConfig(motionRoot: motRaw, humanRoot: humRaw)
            }
            if let wlRaw = try? await dvrip.getConfig(name: "Camera.WhiteLight") {
                self.dvripWhiteLightConfig = DVRIPProtocol.parseWhiteLightConfig(wlRaw)
            }
            if let titleRaw = try? await dvrip.getConfig(name: "AVEnc.ChannelTitle"),
               let widgetRaw = try? await dvrip.getConfig(name: "AVEnc.VideoWidget") {
                self.dvripOSDConfig = DVRIPProtocol.parseOSDConfig(titleRoot: titleRaw, widgetRoot: widgetRaw)
            }
            if let natRaw = try? await dvrip.getConfig(name: "NetWork.Nat") {
                self.dvripPrivacyConfig = DVRIPProtocol.parsePrivacyConfig(natRaw)
            }
            if let netRaw = try? await dvrip.getConfig(name: "NetWork.NetCommon") {
                self.dvripNetworkInfo = DVRIPProtocol.parseNetworkInfo(netRaw)
            }
            await dvrip.close()
            self.log("DVRIP (:34567) config loaded for \(camera.host).")
        } catch {
            await dvrip.close()
            errors.append("DVRIP: \(error.localizedDescription)")
        }

        self.isLoadingAdmin = false
        if !errors.isEmpty {
            self.adminStatusMessage = errors.joined(separator: " | ")
            self.log("Admin warning: \(self.adminStatusMessage ?? "")")
        } else {
            self.adminStatusMessage = "Loaded ONVIF & DVRIP configuration."
        }
    }

    func syncCameraClock(for camera: CameraProfile) async {
        let pwd = self.password(for: camera)
        var synced = false
        if (try? await self.onvif.syncClockToNow(host: camera.host, port: camera.onvifPort, username: camera.username, password: pwd)) != nil {
            synced = true
        }
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        if (try? await dvrip.connectAndLogin(username: camera.username, password: pwd)) != nil {
            if (try? await dvrip.syncClockToNow()) != nil { synced = true }
            await dvrip.close()
        }
        self.showBanner(synced ? "Synced camera clock to iPad time." : "Clock sync failed — check camera credentials.")
    }

    func rebootCamera(_ camera: CameraProfile) async {
        let pwd = self.password(for: camera)
        var ok = false
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        if (try? await dvrip.connectAndLogin(username: camera.username, password: pwd)) != nil {
            if (try? await dvrip.rebootCamera()) != nil { ok = true }
            await dvrip.close()
        }
        if !ok {
            if (try? await self.onvif.systemReboot(host: camera.host, port: camera.onvifPort, username: camera.username, password: pwd)) != nil {
                ok = true
            }
        }
        self.showBanner(ok ? "Reboot command sent to camera." : "Failed sending reboot command.")
    }

    func applyImagingSettings(_ settings: ONVIFImagingSettings, for camera: CameraProfile) async {
        guard let caps = self.onvifCapabilities,
              let imgURL = URL(string: caps.imagingXAddr),
              let srcToken = self.onvifProfiles.first?.videoSourceToken,
              !srcToken.isEmpty else {
            self.showBanner("Camera ONVIF imaging endpoint unavailable.")
            return
        }
        let pwd = self.password(for: camera)
        do {
            try await self.onvif.setImagingSettings(imagingURL: imgURL, videoSourceToken: srcToken, settings: settings, username: camera.username, password: pwd)
            self.imagingSettings = settings
            self.showBanner("Applied image & IR filter settings.")
        } catch {
            self.showBanner("Failed updating imaging: \(error.localizedDescription)")
        }
    }

    func movePTZ(camera: CameraProfile, pan: Double, tilt: Double, zoom: Double = 0) async {
        guard let caps = self.onvifCapabilities,
              let ptzURL = URL(string: caps.ptzXAddr),
              let token = self.onvifProfiles.first?.token else { return }
        let pwd = self.password(for: camera)
        try? await self.onvif.ptzContinuousMove(ptzURL: ptzURL, profileToken: token, pan: pan, tilt: tilt, zoom: zoom, username: camera.username, password: pwd)
    }

    func stopPTZ(camera: CameraProfile) async {
        guard let caps = self.onvifCapabilities,
              let ptzURL = URL(string: caps.ptzXAddr),
              let token = self.onvifProfiles.first?.token else { return }
        let pwd = self.password(for: camera)
        try? await self.onvif.ptzStop(ptzURL: ptzURL, profileToken: token, username: camera.username, password: pwd)
    }

    func gotoHomePTZ(camera: CameraProfile) async {
        guard let caps = self.onvifCapabilities,
              let ptzURL = URL(string: caps.ptzXAddr),
              let token = self.onvifProfiles.first?.token else { return }
        let pwd = self.password(for: camera)
        try? await self.onvif.ptzGotoHome(ptzURL: ptzURL, profileToken: token, username: camera.username, password: pwd)
    }

    func recallPTZPreset(_ preset: ONVIFPTZPreset, camera: CameraProfile) async {
        guard let caps = self.onvifCapabilities,
              let ptzURL = URL(string: caps.ptzXAddr),
              let token = self.onvifProfiles.first?.token else { return }
        let pwd = self.password(for: camera)
        try? await self.onvif.gotoPTZPreset(ptzURL: ptzURL, profileToken: token, presetToken: preset.token, username: camera.username, password: pwd)
    }

    func savePTZPreset(named name: String, camera: CameraProfile) async {
        guard let caps = self.onvifCapabilities,
              let ptzURL = URL(string: caps.ptzXAddr),
              let token = self.onvifProfiles.first?.token else { return }
        let pwd = self.password(for: camera)
        try? await self.onvif.setPTZPreset(ptzURL: ptzURL, profileToken: token, presetName: name, username: camera.username, password: pwd)
        self.ptzPresets = (try? await self.onvif.getPTZPresets(ptzURL: ptzURL, profileToken: token, username: camera.username, password: pwd)) ?? self.ptzPresets
    }

    func toggleONVIFEventMonitor(for camera: CameraProfile) {
        if self.isPullingEvents {
            self.pullPointTask?.cancel()
            self.pullPointTask = nil
            self.isPullingEvents = false
            return
        }
        guard let caps = self.onvifCapabilities, let eventsURL = URL(string: caps.eventsXAddr) else {
            self.showBanner("Camera ONVIF Events service unavailable.")
            return
        }
        self.isPullingEvents = true
        let pwd = self.password(for: camera)
        self.pullPointTask = Task { [weak self] in
            guard let self else { return }
            do {
                let subURL = try await self.onvif.createPullPointSubscription(eventsURL: eventsURL, username: camera.username, password: pwd)
                while !Task.isCancelled {
                    let msgs = try await self.onvif.pullMessages(subscriptionURL: subURL, username: camera.username, password: pwd)
                    if !msgs.isEmpty {
                        await MainActor.run {
                            self.motionEvents.insert(contentsOf: msgs, at: 0)
                            if self.motionEvents.count > 100 {
                                self.motionEvents.removeLast(self.motionEvents.count - 100)
                            }
                        }
                    }
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                await MainActor.run {
                    self.isPullingEvents = false
                    self.log("ONVIF PullPoint stopped: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - DVRIP Write Operations

    func saveDVRIPEncoder(mainCodec: String, mainFPS: Int, mainBitrate: Int, audioEnable: Bool, for camera: CameraProfile) async {
        guard var current = self.dvripEncodeConfig,
              var arr = current.rawPayload["Simplify.Encode"]?.arrayValue,
              var ch0 = arr.first?.objectValue else {
            self.showBanner("Load DVRIP settings first.")
            return
        }
        var mainFmt = ch0["MainFormat"]?.objectValue ?? [:]
        var vid = mainFmt["Video"]?.objectValue ?? [:]
        vid["Compression"] = .string(mainCodec)
        vid["FPS"] = .int(mainFPS)
        vid["BitRate"] = .int(mainBitrate)
        mainFmt["Video"] = .object(vid)
        mainFmt["AudioEnable"] = .bool(audioEnable)
        ch0["MainFormat"] = .object(mainFmt)
        arr[0] = .object(ch0)
        current.rawPayload["Simplify.Encode"] = .array(arr)

        let jsonObj = Self.convertToRawDictionary(current.rawPayload["Simplify.Encode"] ?? .array([]))
        await self.pushDVRIPConfig(name: "Simplify.Encode", value: jsonObj, camera: camera, successToast: "Saved encoder settings.")
    }

    func saveDVRIPDetection(motionEnabled: Bool, motionLevel: Int, humanEnabled: Bool, humanSens: Int, for camera: CameraProfile) async {
        guard let det = self.dvripDetectionConfig else {
            self.showBanner("Load DVRIP settings first.")
            return
        }
        if var motArr = det.motionRaw["Detect.MotionDetect"]?.arrayValue, var obj = motArr.first?.objectValue {
            obj["Enable"] = .bool(motionEnabled)
            obj["Level"] = .int(motionLevel)
            motArr[0] = .object(obj)
            let raw = Self.convertToRawDictionary(.array(motArr))
            await self.pushDVRIPConfig(name: "Detect.MotionDetect", value: raw, camera: camera, successToast: nil)
        }
        if var humArr = det.humanRaw["Detect.HumanDection"]?.arrayValue, var obj = humArr.first?.objectValue {
            obj["Enable"] = .bool(humanEnabled)
            obj["Sensitivity"] = .int(humanSens)
            humArr[0] = .object(obj)
            let raw = Self.convertToRawDictionary(.array(humArr))
            await self.pushDVRIPConfig(name: "Detect.HumanDection", value: raw, camera: camera, successToast: nil)
        }
        self.showBanner("Saved camera detection settings.")
    }

    func saveDVRIPWhiteLight(_ mode: DVRIPWhiteLightMode, for camera: CameraProfile) async {
        guard let wl = self.dvripWhiteLightConfig else { return }
        var obj = wl.rawPayload["Camera.WhiteLight"]?.objectValue ?? [:]
        obj["WorkMode"] = .string(mode.rawValue)
        let raw = Self.convertToRawDictionary(.object(obj))
        await self.pushDVRIPConfig(name: "Camera.WhiteLight", value: raw, camera: camera, successToast: "Updated camera spotlight mode.")
    }

    func saveDVRIPOSD(title: String, showTitle: Bool, showTimestamp: Bool, for camera: CameraProfile) async {
        guard let osd = self.dvripOSDConfig else { return }
        var titles = osd.rawChannelTitle["AVEnc.ChannelTitle"]?.arrayValue ?? []
        if titles.isEmpty { titles = [.string(title)] } else { titles[0] = .string(title) }
        await self.pushDVRIPConfig(name: "AVEnc.ChannelTitle", value: Self.convertToRawDictionary(.array(titles)), camera: camera, successToast: nil)

        if var widgets = osd.rawVideoWidget["AVEnc.VideoWidget"]?.arrayValue, var w0 = widgets.first?.objectValue {
            var chAttr = w0["ChannelTitleAttribute"]?.objectValue ?? [:]
            chAttr["EncodeBlend"] = .bool(showTitle)
            var tAttr = w0["TimeTitleAttribute"]?.objectValue ?? [:]
            tAttr["EncodeBlend"] = .bool(showTimestamp)
            w0["ChannelTitleAttribute"] = .object(chAttr)
            w0["TimeTitleAttribute"] = .object(tAttr)
            widgets[0] = .object(w0)
            await self.pushDVRIPConfig(name: "AVEnc.VideoWidget", value: Self.convertToRawDictionary(.array(widgets)), camera: camera, successToast: "Saved OSD overlay settings.")
        }
    }

    func setCloudP2PEnabled(_ enabled: Bool, for camera: CameraProfile) async {
        guard let priv = self.dvripPrivacyConfig else { return }
        var obj = priv.rawNatPayload["NetWork.Nat"]?.objectValue ?? [:]
        obj["NatEnable"] = .bool(enabled)
        let raw = Self.convertToRawDictionary(.object(obj))
        await self.pushDVRIPConfig(
            name: "NetWork.Nat",
            value: raw,
            camera: camera,
            successToast: enabled ? "Cloud P2P enabled." : "Privacy Lockdown active: Cloud P2P disabled."
        )
    }

    func formatMicroSD(for camera: CameraProfile) async {
        let pwd = self.password(for: camera)
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        do {
            _ = try await dvrip.connectAndLogin(username: camera.username, password: pwd)
            let part = self.dvripStorageInfo?.partitions.first
            try await dvrip.formatMicroSD(serialNo: 0, partNo: part?.partIndex ?? 0)
            self.dvripStorageInfo = try? await dvrip.getStorageInfo()
            await dvrip.close()
            self.showBanner("MicroSD card formatted.")
        } catch {
            await dvrip.close()
            self.showBanner("Format failed: \(error.localizedDescription)")
        }
    }

    func changeCameraPassword(for camera: CameraProfile, newPassword: String) async {
        let oldPassword = self.password(for: camera)
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        do {
            _ = try await dvrip.connectAndLogin(username: camera.username, password: oldPassword)
            try await dvrip.modifyPassword(username: camera.username, oldPassword: oldPassword, newPassword: newPassword)
            await dvrip.close()
            try KeychainVault.savePassword(newPassword, forCameraID: camera.id)
            self.showBanner("Camera password updated & saved to Keychain.")
        } catch {
            await dvrip.close()
            self.showBanner("Password change failed: \(error.localizedDescription)")
        }
    }

    func querySDRecordings(camera: CameraProfile, day: Date, alarmOnly: Bool) async {
        let pwd = self.password(for: camera)
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        do {
            _ = try await dvrip.connectAndLogin(username: camera.username, password: pwd)
            let files = try await dvrip.queryRecordings(channel: camera.channel, day: day, alarmOnly: alarmOnly)
            await dvrip.close()
            self.dvripRecordings = files
            self.showBanner("Found \(files.count) SD card clip(s).")
        } catch {
            await dvrip.close()
            self.showBanner("SD query failed: \(error.localizedDescription)")
        }
    }

    func downloadSDRecording(_ file: DVRIPRecordingFile, camera: CameraProfile) async {
        self.isDownloadingRecording = true
        defer { self.isDownloadingRecording = false }
        let pwd = self.password(for: camera)
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        do {
            _ = try await dvrip.connectAndLogin(username: camera.username, password: pwd)
            let extracted = try await dvrip.downloadRecording(file: file)
            await dvrip.close()

            let (relPath, destURL) = self.mediaStore.newRecordingURL(prefix: "sd", ext: "mp4")
            _ = try await LocalMP4Recorder.remuxAnnexBToMP4(annexBData: extracted.annexBData, isHEVC: extracted.detectedHEVC, outputURL: destURL)
            _ = try self.mediaStore.registerVideoFile(
                relativePath: relPath,
                cameraID: camera.id,
                cameraName: camera.name,
                kind: .recording,
                caption: "SD \(file.beginTime)",
                maxStorageMB: self.monitorSettings.maxStorageMB
            )
            self.mediaItems = self.mediaStore.loadMediaItems()
            self.showBanner("Downloaded & saved '\(relPath)' to Local Media.")
        } catch {
            await dvrip.close()
            self.showBanner("Download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func ensureSessionsExist() {
        for cam in self.cameras where self.sessions[cam.id] == nil {
            self.sessions[cam.id] = RTSPStreamSession()
        }
    }

    private func applyMonitoringState(for camera: CameraProfile) {
        let sess = self.session(for: camera)
        sess.updateMonitoring(
            enabled: self.kioskMonitoringActive,
            settings: self.monitorSettings,
            mediaStore: self.mediaStore
        ) { [weak self] event in
            guard let self else { return }
            self.alertEvents.insert(event, at: 0)
            if self.alertEvents.count > 200 {
                self.alertEvents.removeLast(self.alertEvents.count - 200)
            }
            try? self.mediaStore.saveAlerts(self.alertEvents)
            self.mediaItems = self.mediaStore.loadMediaItems()
            self.log("Vision alert: \(event.kind.label) (\(Int(event.confidence * 100))%) on \(event.cameraName)")
        }
    }

    private func pushDVRIPConfig(name: String, value: Any, camera: CameraProfile, successToast: String?) async {
        let pwd = self.password(for: camera)
        let dvrip = DVRIPSession(host: camera.host, port: camera.dvripPort)
        do {
            _ = try await dvrip.connectAndLogin(username: camera.username, password: pwd)
            try await dvrip.setConfig(name: name, rawJsonObject: value)
            await dvrip.close()
            if let successToast { self.showBanner(successToast) }
        } catch {
            await dvrip.close()
            self.showBanner("Save \(name) failed: \(error.localizedDescription)")
        }
    }

    private func clearAdminState() {
        self.onvifCapabilities = nil
        self.onvifDeviceInfo = nil
        self.onvifProfiles = []
        self.imagingSettings = nil
        self.ptzPresets = []
        self.motionEvents = []
        self.pullPointTask?.cancel()
        self.pullPointTask = nil
        self.isPullingEvents = false

        self.dvripSystemInfo = nil
        self.dvripStorageInfo = nil
        self.dvripEncodeConfig = nil
        self.dvripDetectionConfig = nil
        self.dvripWhiteLightConfig = nil
        self.dvripOSDConfig = nil
        self.dvripPrivacyConfig = nil
        self.dvripNetworkInfo = nil
        self.dvripRecordings = []
    }

    private static func convertToRawDictionary(_ value: AnyCodableJSON) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .double(let d): return d
        case .string(let s): return s
        case .array(let arr): return arr.map { self.convertToRawDictionary($0) }
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = self.convertToRawDictionary(v) }
            return out
        }
    }
}
