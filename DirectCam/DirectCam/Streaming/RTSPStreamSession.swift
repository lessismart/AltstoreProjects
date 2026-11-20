import AVFoundation
import CoreMedia
import Foundation
import Network
import UIKit

@MainActor
final class RTSPStreamSession: ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var statusText = "Idle"
    @Published var codecLabel = "--"
    @Published var resolutionText = "--"
    @Published var fps: Int = 0
    @Published var kbps: Int = 0
    @Published var isMuted = true {
        didSet { self.audioPlayer.isMuted = self.isMuted }
    }
    @Published var isRecording = false
    @Published var activeQuality: StreamQuality = .main
    @Published var latestImage: UIImage?
    @Published var detections: [VisionDetectionBox] = []
    @Published var lastError: String?

    let displayLayer: AVSampleBufferDisplayLayer
    private let workerQueue = DispatchQueue(label: "com.lessy.directcam.rtsp.worker")
    private let audioPlayer = AudioStreamPlayer()
    private let recorder = LocalMP4Recorder()
    private let visionEngine = VisionAlertEngine()
    private var activeRecorderURL: URL?
    private var activeRecorderKind: LocalMediaKind = .recording

    private var connection: NWConnection?
    private var recvBuffer = Data()
    private var cseq = 1
    private var rtspURLString = ""
    private var sessionId = ""
    private var videoDepacketizer: RTPVideoDepacketizer?
    private var videoDecoder: VideoToolboxDecoder?
    private var audioCodec: RTSPAudioCodec?
    private var videoPayloadType = 96
    private var audioPayloadType = 8
    private var lastAuthHeader: String?
    private var currentProfile: CameraProfile?
    private var currentPassword = ""
    private var monitorSettings = MonitorSettings()
    private var mediaStore: LocalMediaStore?
    private var monitoringEnabled = false
    private var onAlertTriggered: ((VisionAlertEvent) -> Void)?

    private var frameCountWindow = 0
    private var bytesWindow = 0
    private var metricsTimer: Timer?
    private var keepAliveTimer: Timer?
    private var autoClipStopTask: Task<Void, Never>?
    private var currentDimensions = CGSize(width: 1280, height: 720)
    private var stoppedByUser = true

    init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        self.displayLayer = layer
        self.audioPlayer.isMuted = true
    }

    func updateMonitoring(
        enabled: Bool,
        settings: MonitorSettings,
        mediaStore: LocalMediaStore?,
        onAlert: @escaping (VisionAlertEvent) -> Void
    ) {
        self.monitoringEnabled = enabled
        self.monitorSettings = settings
        self.mediaStore = mediaStore
        self.onAlertTriggered = onAlert
        if !enabled {
            self.detections = []
        }
    }

    func start(profile: CameraProfile, password: String, quality: StreamQuality? = nil) {
        self.stop()
        self.stoppedByUser = false
        let chosenQuality = quality ?? profile.preferredStream
        self.activeQuality = chosenQuality
        self.currentProfile = profile
        self.currentPassword = password
        self.lastError = nil
        self.isConnecting = true
        self.statusText = "Connecting to \(profile.host):\(profile.rtspPort)..."

        let rtspURL = RTSPProtocol.buildRTSPURL(profile: profile, password: password, quality: chosenQuality)
        self.rtspURLString = rtspURL
        self.cseq = 1
        self.sessionId = ""
        self.lastAuthHeader = nil
        self.recvBuffer.removeAll()

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: profile.rtspPort)) else {
            self.lastError = "Invalid RTSP port \(profile.rtspPort)."
            self.isConnecting = false
            return
        }

        let conn = NWConnection(host: NWEndpoint.Host(profile.host), port: nwPort, using: .tcp)
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.performRTSPHandshake()
                case .failed(let err):
                    self.handleDisconnect(reason: err.localizedDescription)
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        conn.start(queue: self.workerQueue)
    }

    func switchQuality(_ quality: StreamQuality) {
        guard let profile = self.currentProfile else { return }
        self.start(profile: profile, password: self.currentPassword, quality: quality)
    }

    func stop() {
        self.stoppedByUser = true
        self.metricsTimer?.invalidate()
        self.metricsTimer = nil
        self.keepAliveTimer?.invalidate()
        self.keepAliveTimer = nil
        self.autoClipStopTask?.cancel()
        self.autoClipStopTask = nil
        if self.isRecording {
            Task { _ = await self.stopRecording() }
        }
        self.connection?.cancel()
        self.connection = nil
        self.audioPlayer.stop()
        self.displayLayer.flushAndRemoveImage()
        self.isConnected = false
        self.isConnecting = false
        self.fps = 0
        self.kbps = 0
        self.statusText = "Stopped"
    }

    func captureSnapshot(to store: LocalMediaStore) -> LocalMediaItem? {
        guard let img = self.latestImage, let jpeg = img.jpegData(compressionQuality: 0.92), let profile = self.currentProfile else {
            return nil
        }
        return try? store.saveSnapshot(
            jpegData: jpeg,
            cameraID: profile.id,
            cameraName: profile.name,
            caption: "\(self.activeQuality.label) Snapshot",
            maxStorageMB: self.monitorSettings.maxStorageMB
        )
    }

    func toggleManualRecording(store: LocalMediaStore) async -> LocalMediaItem? {
        self.mediaStore = store
        if self.isRecording {
            return await self.stopRecording()
        } else {
            self.beginRecording(kind: .recording, store: store)
            return nil
        }
    }

    private func beginRecording(kind: LocalMediaKind, store: LocalMediaStore) {
        guard !self.isRecording else { return }
        let (_, url) = store.newRecordingURL(prefix: kind == .alertClip ? "alert" : "rec")
        let w = max(128, Int(self.currentDimensions.width))
        let h = max(128, Int(self.currentDimensions.height))
        do {
            try self.recorder.start(outputURL: url, width: w, height: h, realTime: true)
            self.activeRecorderURL = url
            self.activeRecorderKind = kind
            self.isRecording = true
        } catch {
            self.lastError = "Recorder start failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func stopRecording() async -> LocalMediaItem? {
        guard self.isRecording else { return nil }
        self.isRecording = false
        guard let finished = await self.recorder.finish(),
              let store = self.mediaStore,
              let profile = self.currentProfile else {
            return nil
        }
        return try? store.registerVideoFile(
            relativePath: finished.lastPathComponent,
            cameraID: profile.id,
            cameraName: profile.name,
            kind: self.activeRecorderKind,
            caption: "\(profile.name) \(self.activeRecorderKind.badge)",
            maxStorageMB: self.monitorSettings.maxStorageMB
        )
    }

    // MARK: - RTSP Control Plane

    private func performRTSPHandshake() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.statusText = "RTSP Handshake..."
                _ = try await self.sendRTSPRequest(method: "OPTIONS", url: self.rtspURLString)

                var describeResp = try await self.sendRTSPRequest(
                    method: "DESCRIBE",
                    url: self.rtspURLString,
                    extraHeaders: ["Accept": "application/sdp"]
                )
                if describeResp.statusCode == 401, let authHdr = describeResp.headers["www-authenticate"] {
                    self.applyAuthChallenge(authHdr, method: "DESCRIBE", uri: self.rtspURLString)
                    describeResp = try await self.sendRTSPRequest(
                        method: "DESCRIBE",
                        url: self.rtspURLString,
                        extraHeaders: ["Accept": "application/sdp"]
                    )
                }
                guard describeResp.statusCode == 200 else {
                    throw NSError(domain: "DirectCam.RTSP", code: describeResp.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Camera rejected RTSP DESCRIBE (status \(describeResp.statusCode)). Check username, password, or stream path."
                    ])
                }

                let sdpInfo = RTSPProtocol.parseSDP(describeResp.bodyText)
                guard let videoTrack = sdpInfo.videoTrack else {
                    throw NSError(domain: "DirectCam.RTSP", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "No video track advertised in camera SDP."
                    ])
                }

                let isHEVC = videoTrack.encodingName.contains("265") || videoTrack.encodingName.contains("HEVC")
                let codec: RTSPVideoCodec = isHEVC ? .hevc : .h264
                self.codecLabel = codec.rawValue
                self.videoPayloadType = videoTrack.payloadType
                self.videoDepacketizer = RTPVideoDepacketizer(codec: codec)
                self.videoDecoder = VideoToolboxDecoder(
                    codec: codec,
                    vps: videoTrack.vps,
                    sps: videoTrack.sps,
                    pps: videoTrack.pps
                )

                let videoSetupURL = RTSPProtocol.resolveControlURI(control: videoTrack.controlURI, baseURL: self.rtspURLString)
                let setupVid = try await self.sendRTSPRequest(
                    method: "SETUP",
                    url: videoSetupURL,
                    extraHeaders: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
                )
                if let sessHdr = setupVid.headers["session"] {
                    self.sessionId = sessHdr.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                }

                if let audioTrack = sdpInfo.audioTrack {
                    let upper = audioTrack.encodingName.uppercased()
                    if upper == "PCMA" || upper == "PCMU" {
                        self.audioCodec = upper == "PCMA" ? .pcma : .pcmu
                        self.audioPayloadType = audioTrack.payloadType
                        self.audioPlayer.configure(sampleRate: Double(max(8000, audioTrack.clockRate)))
                        let audioSetupURL = RTSPProtocol.resolveControlURI(control: audioTrack.controlURI, baseURL: self.rtspURLString)
                        _ = try? await self.sendRTSPRequest(
                            method: "SETUP",
                            url: audioSetupURL,
                            extraHeaders: ["Transport": "RTP/AVP/TCP;unicast;interleaved=2-3"]
                        )
                    }
                }

                var playHeaders: [String: String] = ["Range": "npt=0.000-"]
                if !self.sessionId.isEmpty { playHeaders["Session"] = self.sessionId }
                let playResp = try await self.sendRTSPRequest(method: "PLAY", url: self.rtspURLString, extraHeaders: playHeaders)
                guard (200...299).contains(playResp.statusCode) else {
                    throw NSError(domain: "DirectCam.RTSP", code: playResp.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "RTSP PLAY failed (status \(playResp.statusCode))."
                    ])
                }

                self.isConnected = true
                self.isConnecting = false
                self.statusText = "Live (\(self.activeQuality.label))"
                self.startTimers()
                self.receiveInterleavedLoop()
            } catch {
                self.handleDisconnect(reason: error.localizedDescription)
            }
        }
    }

    private func applyAuthChallenge(_ header: String, method: String, uri: String) {
        let user = self.currentProfile?.username ?? "admin"
        if let challenge = HTTPDigestHelper.parseChallenge(header) {
            self.lastAuthHeader = HTTPDigestHelper.authorizationHeader(
                method: method,
                uri: uri,
                username: user,
                password: self.currentPassword,
                realm: challenge.realm,
                nonce: challenge.nonce,
                qop: challenge.qop
            )
        } else {
            let b64 = Data("\(user):\(self.currentPassword)".utf8).base64EncodedString()
            self.lastAuthHeader = "Basic \(b64)"
        }
    }

    private func sendRTSPRequest(method: String, url: String, extraHeaders: [String: String] = [:]) async throws -> (statusCode: Int, headers: [String: String], bodyText: String) {
        guard let conn = self.connection else {
            throw NSError(domain: "DirectCam.RTSP", code: 10, userInfo: [NSLocalizedDescriptionKey: "RTSP socket disconnected."])
        }
        var msg = "\(method) \(url) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nUser-Agent: DirectCam/1.0\r\n"
        self.cseq += 1
        if !self.sessionId.isEmpty && method != "OPTIONS" && method != "DESCRIBE" {
            msg += "Session: \(self.sessionId)\r\n"
        }
        if let auth = self.lastAuthHeader {
            msg += "Authorization: \(auth)\r\n"
        }
        for (k, v) in extraHeaders where k != "Session" {
            msg += "\(k): \(v)\r\n"
        }
        msg += "\r\n"

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(msg.utf8), completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }

        // Wait for header terminator `\r\n\r\n`
        while true {
            if let range = self.recvBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let hdrData = self.recvBuffer.subdata(in: 0..<range.lowerBound)
                self.recvBuffer.removeSubrange(0..<range.upperBound)
                let hdrString = String(decoding: hdrData, as: UTF8.self)
                guard let parsed = RTSPProtocol.parseResponseHeader(hdrString) else {
                    continue
                }
                let contentLen = Int(parsed.headers["content-length"] ?? "0") ?? 0
                if contentLen > 0 {
                    while self.recvBuffer.count < contentLen {
                        try await self.readNextChunk()
                    }
                    let body = self.recvBuffer.subdata(in: 0..<contentLen)
                    self.recvBuffer.removeFirst(contentLen)
                    return (parsed.statusCode, parsed.headers, String(decoding: body, as: UTF8.self))
                }
                return (parsed.statusCode, parsed.headers, "")
            }
            try await self.readNextChunk()
        }
    }

    private func receiveInterleavedLoop() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.stoppedByUser && self.connection != nil {
                do {
                    try await self.processAvailableInterleavedFrames()
                    try await self.readNextChunk()
                } catch {
                    if !self.stoppedByUser {
                        self.handleDisconnect(reason: error.localizedDescription)
                    }
                    break
                }
            }
        }
    }

    private func processAvailableInterleavedFrames() async throws {
        while true {
            // Skip any unexpected RTSP text response bytes until `$` interleaved framing marker
            while let first = self.recvBuffer.first, first != 0x24 {
                if let dollar = self.recvBuffer.firstIndex(of: 0x24) {
                    self.recvBuffer.removeFirst(dollar)
                } else {
                    self.recvBuffer.removeAll(keepingCapacity: true)
                    return
                }
            }
            guard self.recvBuffer.count >= 4 else { return }
            let channel = self.recvBuffer[self.recvBuffer.startIndex + 1]
            let b2 = Int(self.recvBuffer[self.recvBuffer.startIndex + 2])
            let b3 = Int(self.recvBuffer[self.recvBuffer.startIndex + 3])
            let frameLen = (b2 << 8) | b3
            guard self.recvBuffer.count >= 4 + frameLen else { return }

            let payload = self.recvBuffer.subdata(in: 4..<(4 + frameLen))
            self.recvBuffer.removeFirst(4 + frameLen)
            self.bytesWindow += frameLen

            if channel == 0, let depacketizer = self.videoDepacketizer, let decoder = self.videoDecoder {
                if let unit = depacketizer.processRTPPacket(payload),
                   let frame = decoder.decode(unit: unit) {
                    self.handleDecodedVideoFrame(frame, decoder: decoder)
                }
            } else if channel == 2, let audioCodec = self.audioCodec, !self.isMuted {
                let pcm = G711Decoder.decodeRTPPayload(payload, codec: audioCodec)
                if !pcm.isEmpty {
                    self.audioPlayer.enqueueSamples(pcm)
                }
            }
        }
    }

    private func handleDecodedVideoFrame(_ frame: DecodedVideoFrame, decoder: VideoToolboxDecoder) {
        self.frameCountWindow += 1
        self.currentDimensions = frame.dimensions
        self.resolutionText = "\(Int(frame.dimensions.width))×\(Int(frame.dimensions.height))"

        if self.displayLayer.status == .failed {
            self.displayLayer.flush()
        }
        self.displayLayer.enqueue(frame.sampleBuffer)

        if let pixelBuffer = frame.pixelBuffer {
            if frame.isKeyFrame || self.latestImage == nil,
               let jpeg = decoder.jpegData(from: pixelBuffer),
               let img = UIImage(data: jpeg) {
                self.latestImage = img
            }
            if self.isRecording {
                self.recorder.append(pixelBuffer: pixelBuffer, fps: max(10, self.fps))
            }
            if self.monitoringEnabled, let profile = self.currentProfile {
                self.runVisionOnFrame(pixelBuffer: pixelBuffer, decoder: decoder, profile: profile)
            }
        }
    }

    private func runVisionOnFrame(pixelBuffer: CVPixelBuffer, decoder: VideoToolboxDecoder, profile: CameraProfile) {
        let settings = self.monitorSettings
        self.visionEngine.analyzeIfDue(
            pixelBuffer: pixelBuffer,
            settings: settings
        ) { [weak self] boxes, shouldFireAlert, primaryKind, bestConfidence in
            Task { @MainActor [weak self] in
                guard let self, self.monitoringEnabled else { return }
                self.detections = boxes
                guard shouldFireAlert, let kind = primaryKind else { return }

                var snapRelPath: String?
                if let jpeg = decoder.jpegData(from: pixelBuffer), let store = self.mediaStore {
                    if let savedSnap = try? store.saveSnapshot(
                        jpegData: jpeg,
                        cameraID: profile.id,
                        cameraName: profile.name,
                        caption: "\(kind.label) Alert (\(Int(bestConfidence * 100))%)",
                        maxStorageMB: settings.maxStorageMB
                    ) {
                        snapRelPath = savedSnap.relativePath
                    }
                }

                if settings.playChime {
                    VisionAlertEngine.playAlertChime()
                }
                if settings.sendNotification {
                    VisionAlertEngine.postLocalNotification(
                        cameraName: profile.name,
                        kind: kind,
                        confidence: bestConfidence
                    )
                }

                let event = VisionAlertEvent(
                    id: UUID(),
                    cameraID: profile.id,
                    cameraName: profile.name,
                    kind: kind,
                    confidence: bestConfidence,
                    timestamp: Date(),
                    snapshotRelativePath: snapRelPath,
                    clipRelativePath: nil
                )
                self.onAlertTriggered?(event)

                if settings.autoRecordClip, !self.isRecording, let store = self.mediaStore {
                    self.beginRecording(kind: .alertClip, store: store)
                    let duration = max(5, settings.clipDurationSeconds)
                    self.autoClipStopTask?.cancel()
                    self.autoClipStopTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
                        _ = await self?.stopRecording()
                    }
                }
            }
        }
    }

    private func readNextChunk() async throws {
        guard let conn = self.connection else {
            throw NSError(domain: "DirectCam.RTSP", code: 11, userInfo: [NSLocalizedDescriptionKey: "RTSP connection closed."])
        }
        let chunk: Data = try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: err)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: NSError(domain: "DirectCam.RTSP", code: 12, userInfo: [NSLocalizedDescriptionKey: "Stream ended by camera."]))
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
        if !chunk.isEmpty {
            self.recvBuffer.append(chunk)
        }
    }

    private func startTimers() {
        self.metricsTimer?.invalidate()
        self.metricsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fps = self.frameCountWindow
                self.kbps = (self.bytesWindow * 8) / 1000
                self.frameCountWindow = 0
                self.bytesWindow = 0
            }
        }
        self.keepAliveTimer?.invalidate()
        self.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let conn = self.connection, !self.sessionId.isEmpty else { return }
                let msg = "GET_PARAMETER \(self.rtspURLString) RTSP/1.0\r\nCSeq: \(self.cseq)\r\nSession: \(self.sessionId)\r\n\r\n"
                self.cseq += 1
                conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in })
            }
        }
    }

    private func handleDisconnect(reason: String) {
        self.isConnected = false
        self.isConnecting = false
        self.statusText = "Disconnected"
        self.lastError = reason
    }
}
