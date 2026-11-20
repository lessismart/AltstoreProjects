import Foundation

enum RTSPVideoCodec: String, Equatable, Sendable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"
}

enum RTSPAudioCodec: String, Equatable, Sendable {
    case pcma = "PCMA"
    case pcmu = "PCMU"
    case aac = "AAC"
}

struct RTSPTrackInfo: Equatable, Sendable {
    var mediaType: String // "video" or "audio"
    var controlURI: String
    var payloadType: Int
    var encodingName: String
    var clockRate: Int
    var vps: Data?
    var sps: Data?
    var pps: Data?
}

struct RTSPSDPInfo: Equatable, Sendable {
    var videoTrack: RTSPTrackInfo?
    var audioTrack: RTSPTrackInfo?
}

enum RTSPProtocol {
    static func buildRTSPURL(profile: CameraProfile, password: String, quality: StreamQuality) -> String {
        let userEnc = Self.percentEncodeUserInfo(profile.username)
        let passEnc = Self.percentEncodeUserInfo(password)
        let auth = profile.username.isEmpty ? "" : "\(userEnc):\(passEnc)@"

        switch profile.rtspPathStyle {
        case .onvifAuto:
            let discovered = quality == .main ? profile.discoveredMainURI : profile.discoveredSubURI
            if !discovered.isEmpty, var comps = URLComponents(string: discovered) {
                if !profile.username.isEmpty {
                    comps.user = profile.username
                    comps.password = password
                }
                if let url = comps.string { return url }
            }
            fallthrough
        case .xiongmaiAmp:
            let path = "/user=\(userEnc)&password=\(passEnc)&channel=\(profile.channel)&stream=\(quality.streamIndex).sdp?real_stream"
            return "rtsp://\(auth)\(profile.host):\(profile.rtspPort)\(path)"
        case .xiongmaiUnderscore:
            let path = "/user=\(userEnc)_password=\(passEnc)_channel=\(profile.channel)_stream=\(quality.streamIndex).sdp?real_stream"
            return "rtsp://\(auth)\(profile.host):\(profile.rtspPort)\(path)"
        case .custom:
            let rawPath = quality == .main ? profile.customMainPath : profile.customSubPath
            let normalized = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
            return "rtsp://\(auth)\(profile.host):\(profile.rtspPort)\(normalized)"
        }
    }

    /// RTSP wire Request-URI without embedded `user:pass@` authority; authentication uses Basic/Digest headers.
    static func buildWireRequestURI(profile: CameraProfile, password: String, quality: StreamQuality) -> String {
        let userEnc = Self.percentEncodeUserInfo(profile.username)
        let passEnc = Self.percentEncodeUserInfo(password)

        switch profile.rtspPathStyle {
        case .onvifAuto:
            let discovered = quality == .main ? profile.discoveredMainURI : profile.discoveredSubURI
            if !discovered.isEmpty, var comps = URLComponents(string: discovered) {
                comps.user = nil
                comps.password = nil
                if let url = comps.string { return url }
            }
            fallthrough
        case .xiongmaiAmp:
            let path = "/user=\(userEnc)&password=\(passEnc)&channel=\(profile.channel)&stream=\(quality.streamIndex).sdp?real_stream"
            return "rtsp://\(profile.host):\(profile.rtspPort)\(path)"
        case .xiongmaiUnderscore:
            let path = "/user=\(userEnc)_password=\(passEnc)_channel=\(profile.channel)_stream=\(quality.streamIndex).sdp?real_stream"
            return "rtsp://\(profile.host):\(profile.rtspPort)\(path)"
        case .custom:
            let rawPath = quality == .main ? profile.customMainPath : profile.customSubPath
            let normalized = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
            return "rtsp://\(profile.host):\(profile.rtspPort)\(normalized)"
        }
    }

    static func parseInterleavedChannels(fromTransportHeader transport: String) -> (rtp: UInt8, rtcp: UInt8)? {
        for part in transport.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed.hasPrefix("interleaved=") {
                let value = trimmed.dropFirst("interleaved=".count)
                let pair = value.split(separator: "-")
                if let first = pair.first, let rtp = UInt8(first) {
                    let rtcp = pair.count > 1 ? (UInt8(pair[1]) ?? rtp &+ 1) : (rtp &+ 1)
                    return (rtp, rtcp)
                }
            }
        }
        return nil
    }

    static func redactedURL(_ raw: String) -> String {
        guard var comps = URLComponents(string: raw) else {
            return raw.replacingOccurrences(of: "password=[^&\\s]+", with: "password=***", options: .regularExpression)
        }
        if comps.password != nil {
            comps.password = "***"
        }
        let result = comps.string ?? raw
        return result.replacingOccurrences(of: "password=[^&\\s]+", with: "password=***", options: .regularExpression)
    }

    static func resolveControlURI(control: String, baseURL: String) -> String {
        if control.lowercased().hasPrefix("rtsp://") { return control }
        let baseTrimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let ctrlTrimmed = control.hasPrefix("/") ? String(control.dropFirst()) : control
        if control.isEmpty { return baseURL }
        return "\(baseTrimmed)/\(ctrlTrimmed)"
    }

    static func parseResponseHeader(_ raw: String) -> (statusCode: Int, headers: [String: String])? {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.uppercased().hasPrefix("RTSP/") else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let code = Int(parts[1]) else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }
        return (code, headers)
    }

    static func parseSDP(_ sdp: String) -> RTSPSDPInfo {
        let lines = sdp.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init)
        var currentMedia: String?
        var tracks: [String: RTSPTrackInfo] = [:]

        for line in lines {
            if line.hasPrefix("m=") {
                let comps = line.dropFirst(2).split(separator: " ").map(String.init)
                if comps.count >= 4 {
                    let media = comps[0].lowercased()
                    let pt = Int(comps[3]) ?? (media == "video" ? 96 : 8)
                    currentMedia = media
                    tracks[media] = RTSPTrackInfo(
                        mediaType: media,
                        controlURI: "",
                        payloadType: pt,
                        encodingName: "",
                        clockRate: media == "video" ? 90000 : 8000,
                        vps: nil,
                        sps: nil,
                        pps: nil
                    )
                }
            } else if let media = currentMedia, var track = tracks[media] {
                if line.hasPrefix("a=control:") {
                    track.controlURI = String(line.dropFirst("a=control:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("a=rtpmap:") {
                    let body = String(line.dropFirst("a=rtpmap:".count))
                    let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
                    if parts.count == 2 {
                        let codecParts = parts[1].split(separator: "/").map(String.init)
                        track.encodingName = codecParts.first?.uppercased() ?? ""
                        if codecParts.count >= 2, let clk = Int(codecParts[1]) {
                            track.clockRate = clk
                        }
                    }
                } else if line.hasPrefix("a=fmtp:") {
                    let params = String(line.dropFirst("a=fmtp:".count))
                    if let spropVps = Self.extractFmtpValue(named: "sprop-vps", from: params) {
                        track.vps = Data(base64Encoded: spropVps)
                    }
                    if let spropSps = Self.extractFmtpValue(named: "sprop-sps", from: params) {
                        track.sps = Data(base64Encoded: spropSps)
                    }
                    if let spropPps = Self.extractFmtpValue(named: "sprop-pps", from: params) {
                        track.pps = Data(base64Encoded: spropPps)
                    }
                    if let sets = Self.extractFmtpValue(named: "sprop-parameter-sets", from: params) {
                        let items = sets.split(separator: ",").map(String.init)
                        if items.count >= 1, track.sps == nil { track.sps = Data(base64Encoded: items[0]) }
                        if items.count >= 2, track.pps == nil { track.pps = Data(base64Encoded: items[1]) }
                    }
                }
                tracks[media] = track
            }
        }
        return RTSPSDPInfo(videoTrack: tracks["video"], audioTrack: tracks["audio"])
    }

    private static func extractFmtpValue(named key: String, from params: String) -> String? {
        for part in params.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let targetPrefix = "\(key)="
            if trimmed.lowercased().hasPrefix(targetPrefix) {
                return String(trimmed.dropFirst(targetPrefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func percentEncodeUserInfo(_ str: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return str.addingPercentEncoding(withAllowedCharacters: allowed) ?? str
    }
}
