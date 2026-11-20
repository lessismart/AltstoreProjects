import CryptoKit
import Foundation

// MARK: - XML Tree Parser (Namespace-Stripping)

final class ONVIFXMLNode {
    let name: String
    var attributes: [String: String]
    var text: String = ""
    var children: [ONVIFXMLNode] = []

    init(name: String, attributes: [String: String] = [:]) {
        self.name = Self.stripPrefix(name)
        self.attributes = attributes
    }

    static func stripPrefix(_ qName: String) -> String {
        if let idx = qName.firstIndex(of: ":") {
            return String(qName[qName.index(after: idx)...])
        }
        return qName
    }

    func firstChild(named target: String) -> ONVIFXMLNode? {
        if self.name.caseInsensitiveCompare(target) == .orderedSame { return self }
        for child in self.children {
            if let hit = child.firstChild(named: target) { return hit }
        }
        return nil
    }

    func allChildren(named target: String) -> [ONVIFXMLNode] {
        var matches: [ONVIFXMLNode] = []
        if self.name.caseInsensitiveCompare(target) == .orderedSame {
            matches.append(self)
        }
        for child in self.children {
            matches.append(contentsOf: child.allChildren(named: target))
        }
        return matches
    }

    func value(forChild named: String) -> String? {
        self.firstChild(named: named)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ONVIFTreeParserDelegate: NSObject, XMLParserDelegate {
    private var stack: [ONVIFXMLNode] = []
    private(set) var root: ONVIFXMLNode?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let node = ONVIFXMLNode(name: elementName, attributes: attributeDict)
        if let parent = self.stack.last {
            parent.children.append(node)
        } else {
            self.root = node
        }
        self.stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        self.stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = self.stack.popLast()
    }
}

enum ONVIFXMLParser {
    static func parse(_ data: Data) -> ONVIFXMLNode? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        let delegate = ONVIFTreeParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.root
    }

    static func parseProbeMatch(_ data: Data, fallbackHost: String) -> DiscoveredCamera? {
        guard let root = self.parse(data) else { return nil }
        let xAddrsRaw = root.value(forChild: "XAddrs") ?? ""
        let scopesRaw = root.value(forChild: "Scopes") ?? ""
        let xAddrs = xAddrsRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let firstURL = xAddrs.compactMap { URL(string: $0) }.first
        let host = firstURL?.host ?? fallbackHost
        guard !host.isEmpty else { return nil }
        let port = firstURL?.port ?? 8899

        let scopes = scopesRaw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var name = "ONVIF Camera"
        var hardware = ""
        for scope in scopes {
            if let range = scope.range(of: "onvif://www.onvif.org/name/") {
                let rawName = String(scope[range.upperBound...])
                name = rawName.removingPercentEncoding ?? rawName
            } else if let range = scope.range(of: "onvif://www.onvif.org/hardware/") {
                let rawHw = String(scope[range.upperBound...])
                hardware = rawHw.removingPercentEncoding ?? rawHw
            }
        }
        return DiscoveredCamera(host: host, onvifPort: port, xAddrs: xAddrs, name: name, hardware: hardware)
    }

    static func parseDeviceInfo(_ data: Data) -> ONVIFDeviceInfo? {
        guard let root = self.parse(data),
              let resp = root.firstChild(named: "GetDeviceInformationResponse") else {
            return nil
        }
        return ONVIFDeviceInfo(
            manufacturer: resp.value(forChild: "Manufacturer") ?? "",
            model: resp.value(forChild: "Model") ?? "",
            firmwareVersion: resp.value(forChild: "FirmwareVersion") ?? "",
            serialNumber: resp.value(forChild: "SerialNumber") ?? "",
            hardwareId: resp.value(forChild: "HardwareId") ?? ""
        )
    }

    static func parseCapabilities(_ data: Data, baseDeviceURL: URL) -> ONVIFCapabilities {
        guard let root = self.parse(data) else {
            return ONVIFCapabilities(deviceXAddr: baseDeviceURL.absoluteString, mediaXAddr: "", imagingXAddr: "", ptzXAddr: "", eventsXAddr: "")
        }
        let mediaXAddr = root.firstChild(named: "Media")?.value(forChild: "XAddr") ?? ""
        let imagingXAddr = root.firstChild(named: "Imaging")?.value(forChild: "XAddr") ?? ""
        let ptzXAddr = root.firstChild(named: "PTZ")?.value(forChild: "XAddr") ?? ""
        let eventsXAddr = root.firstChild(named: "Events")?.value(forChild: "XAddr") ?? ""

        // Fallback if camera returns Ver20 GetServices XAddrs
        var fallbackMedia = mediaXAddr
        var fallbackImaging = imagingXAddr
        var fallbackPTZ = ptzXAddr
        var fallbackEvents = eventsXAddr
        for service in root.allChildren(named: "Service") {
            let ns = (service.value(forChild: "Namespace") ?? "").lowercased()
            let xaddr = service.value(forChild: "XAddr") ?? ""
            guard !xaddr.isEmpty else { continue }
            if ns.contains("/media"), fallbackMedia.isEmpty { fallbackMedia = xaddr }
            if ns.contains("/imaging"), fallbackImaging.isEmpty { fallbackImaging = xaddr }
            if ns.contains("/ptz"), fallbackPTZ.isEmpty { fallbackPTZ = xaddr }
            if ns.contains("/events"), fallbackEvents.isEmpty { fallbackEvents = xaddr }
        }

        return ONVIFCapabilities(
            deviceXAddr: baseDeviceURL.absoluteString,
            mediaXAddr: fallbackMedia,
            imagingXAddr: fallbackImaging,
            ptzXAddr: fallbackPTZ,
            eventsXAddr: fallbackEvents
        )
    }

    static func parseMediaProfiles(_ data: Data) -> [ONVIFMediaProfile] {
        guard let root = self.parse(data) else { return [] }
        return root.allChildren(named: "Profiles").map { node in
            let token = node.attributes["token"] ?? ""
            let name = node.value(forChild: "Name") ?? token
            let vec = node.firstChild(named: "VideoEncoderConfiguration")
            let encoding = vec?.value(forChild: "Encoding") ?? ""
            let res = vec?.firstChild(named: "Resolution")
            let width = Int(res?.value(forChild: "Width") ?? "") ?? 0
            let height = Int(res?.value(forChild: "Height") ?? "") ?? 0
            let srcToken = node.firstChild(named: "VideoSourceConfiguration")?.value(forChild: "SourceToken") ?? ""
            let ptzToken = node.firstChild(named: "PTZConfiguration")?.attributes["token"] ?? ""
            return ONVIFMediaProfile(
                token: token,
                name: name,
                videoSourceToken: srcToken,
                ptzToken: ptzToken,
                width: width,
                height: height,
                encoding: encoding
            )
        }.filter { !$0.token.isEmpty }
    }

    static func parseStreamOrSnapshotURI(_ data: Data) -> String? {
        guard let root = self.parse(data),
              let uri = root.value(forChild: "Uri"),
              !uri.isEmpty else {
            return nil
        }
        return uri
    }

    static func parseImagingSettings(_ data: Data) -> ONVIFImagingSettings? {
        guard let root = self.parse(data),
              let img = root.firstChild(named: "ImagingSettings") else {
            return nil
        }
        let brightness = Double(img.value(forChild: "Brightness") ?? "") ?? 50
        let contrast = Double(img.value(forChild: "Contrast") ?? "") ?? 50
        let saturation = Double(img.value(forChild: "ColorSaturation") ?? "") ?? 50
        let sharpness = Double(img.value(forChild: "Sharpness") ?? "") ?? 50
        let irRaw = (img.value(forChild: "IrCutFilter") ?? "AUTO").uppercased()
        let irMode = IRCutFilterMode(rawValue: irRaw) ?? .auto
        return ONVIFImagingSettings(
            brightness: brightness,
            contrast: contrast,
            saturation: saturation,
            sharpness: sharpness,
            irCutFilter: irMode
        )
    }

    static func parsePTZPresets(_ data: Data) -> [ONVIFPTZPreset] {
        guard let root = self.parse(data) else { return [] }
        return root.allChildren(named: "Preset").compactMap { node in
            let token = node.attributes["token"] ?? ""
            guard !token.isEmpty else { return nil }
            let name = node.value(forChild: "Name") ?? "Preset \(token)"
            return ONVIFPTZPreset(token: token, name: name)
        }
    }

    static func parsePullMessages(_ data: Data) -> [ONVIFMotionEvent] {
        guard let root = self.parse(data) else { return [] }
        return root.allChildren(named: "NotificationMessage").map { msg in
            let topic = msg.value(forChild: "Topic") ?? "RuleEngine/Motion"
            let items = msg.allChildren(named: "SimpleItem").compactMap { item -> String? in
                guard let k = item.attributes["Name"], let v = item.attributes["Value"] else { return nil }
                return "\(k)=\(v)"
            }
            return ONVIFMotionEvent(
                timestamp: Date(),
                topic: topic,
                detail: items.isEmpty ? "Camera event triggered" : items.joined(separator: ", ")
            )
        }
    }

    static func parsePullPointSubscriptionAddress(_ data: Data) -> String? {
        guard let root = self.parse(data) else { return nil }
        return root.firstChild(named: "SubscriptionReference")?.value(forChild: "Address")
    }
}

// MARK: - WS-UsernameToken Security Header

enum ONVIFPasswordDigest {
    private static let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        return fmt
    }()

    static func computeDigest(nonceData: Data, createdISO: String, password: String) -> String {
        var input = Data()
        input.append(nonceData)
        input.append(Data(createdISO.utf8))
        input.append(Data(password.utf8))
        let digest = Insecure.SHA1.hash(data: input)
        return Data(digest).base64EncodedString()
    }

    static func makeSecurityHeader(
        username: String,
        password: String,
        nonceData: Data? = nil,
        createdDate: Date = Date()
    ) -> String {
        let nonce: Data
        if let nonceData {
            nonce = nonceData
        } else {
            var bytes = [UInt8](repeating: 0, count: 16)
            for idx in bytes.indices { bytes[idx] = UInt8.random(in: 0...255) }
            nonce = Data(bytes)
        }
        let created = self.isoFormatter.string(from: createdDate)
        let digestB64 = self.computeDigest(nonceData: nonce, createdISO: created, password: password)
        let nonceB64 = nonce.base64EncodedString()

        return """
        <wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
          <wsse:UsernameToken>
            <wsse:Username>\(self.xmlEscape(username))</wsse:Username>
            <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digestB64)</wsse:Password>
            <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceB64)</wsse:Nonce>
            <wsu:Created>\(created)</wsu:Created>
          </wsse:UsernameToken>
        </wsse:Security>
        """
    }

    static func xmlEscape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - HTTP Digest Helper & Redirect Guard

private final class RedirectBlockerDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HTTPDigestHelper {
    static func parseChallenge(_ header: String) -> (realm: String, nonce: String, qop: String?)? {
        guard header.lowercased().hasPrefix("digest ") else { return nil }
        func extract(_ key: String) -> String? {
            let pattern = "\(key)=\"([^\"]+)\""
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: header, range: NSRange(location: 0, length: header.utf16.count)),
                  let range = Range(match.range(at: 1), in: header) else {
                return nil
            }
            return String(header[range])
        }
        guard let realm = extract("realm"), let nonce = extract("nonce") else { return nil }
        let qop = extract("qop")
        return (realm, nonce, qop)
    }

    static func authorizationHeader(
        method: String,
        uri: String,
        username: String,
        password: String,
        realm: String,
        nonce: String,
        qop: String?,
        nc: String = "00000001",
        cnonce: String = "0a4f113b"
    ) -> String {
        func md5Hex(_ s: String) -> String {
            Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let ha1 = md5Hex("\(username):\(realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        let responseHash: String
        if let qop, qop.lowercased().contains("auth") {
            responseHash = md5Hex("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            return #"Digest username="\#(username)", realm="\#(realm)", nonce="\#(nonce)", uri="\#(uri)", qop=auth, nc=\#(nc), cnonce="\#(cnonce)", response="\#(responseHash)""#
        } else {
            responseHash = md5Hex("\(ha1):\(nonce):\(ha2)")
            return #"Digest username="\#(username)", realm="\#(realm)", nonce="\#(nonce)", uri="\#(uri)", response="\#(responseHash)""#
        }
    }
}

// MARK: - Live ONVIF SOAP Client

final class ONVIFClient {
    private let session: URLSession
    private let redirectDelegate = RedirectBlockerDelegate()

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: cfg, delegate: self.redirectDelegate, delegateQueue: nil)
    }

    func baseDeviceURL(host: String, port: Int) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = port
        comps.path = "/onvif/device_service"
        guard let url = comps.url else {
            throw NSError(domain: "DirectCam.ONVIF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid ONVIF URL."])
        }
        return url
    }

    private func sendSOAP(
        to url: URL,
        action: String,
        bodyXML: String,
        username: String,
        password: String,
        useAuthHeader: Bool = true
    ) async throws -> Data {
        let headerXML = useAuthHeader && !username.isEmpty
            ? ONVIFPasswordDigest.makeSecurityHeader(username: username, password: password)
            : ""
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" xmlns:timg="http://www.onvif.org/ver20/imaging/wsdl" xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl" xmlns:tev="http://www.onvif.org/ver10/events/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema">
          <s:Header>\(headerXML)</s:Header>
          <s:Body>\(bodyXML)</s:Body>
        </s:Envelope>
        """

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(envelope.utf8)
        req.setValue(#"application/soap+xml; charset=utf-8; action="\#(action)""#, forHTTPHeaderField: "Content-Type")

        var (data, resp) = try await self.session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401,
           let authHdr = http.value(forHTTPHeaderField: "WWW-Authenticate") {
            if let digest = HTTPDigestHelper.parseChallenge(authHdr) {
                let authVal = HTTPDigestHelper.authorizationHeader(
                    method: "POST",
                    uri: url.path.isEmpty ? "/" : url.path,
                    username: username,
                    password: password,
                    realm: digest.realm,
                    nonce: digest.nonce,
                    qop: digest.qop
                )
                req.setValue(authVal, forHTTPHeaderField: "Authorization")
            } else {
                let b64 = Data("\(username):\(password)".utf8).base64EncodedString()
                req.setValue("Basic \(b64)", forHTTPHeaderField: "Authorization")
            }
            (data, resp) = try await self.session.data(for: req)
        }

        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "DirectCam.ONVIF", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "ONVIF HTTP error \(http.statusCode)."
            ])
        }
        return data
    }

    func getCapabilities(host: String, port: Int, username: String, password: String) async throws -> ONVIFCapabilities {
        let deviceURL = try self.baseDeviceURL(host: host, port: port)
        let data = try await self.sendSOAP(
            to: deviceURL,
            action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities",
            bodyXML: "<tds:GetCapabilities><tds:Category>All</tds:Category></tds:GetCapabilities>",
            username: username,
            password: password
        )
        return ONVIFXMLParser.parseCapabilities(data, baseDeviceURL: deviceURL)
    }

    func getDeviceInformation(host: String, port: Int, username: String, password: String) async throws -> ONVIFDeviceInfo {
        let url = try self.baseDeviceURL(host: host, port: port)
        let data = try await self.sendSOAP(
            to: url,
            action: "http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation",
            bodyXML: "<tds:GetDeviceInformation/>",
            username: username,
            password: password
        )
        guard let info = ONVIFXMLParser.parseDeviceInfo(data) else {
            throw NSError(domain: "DirectCam.ONVIF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not parse ONVIF device info."])
        }
        return info
    }

    func getMediaProfiles(mediaURL: URL, username: String, password: String) async throws -> [ONVIFMediaProfile] {
        let data = try await self.sendSOAP(
            to: mediaURL,
            action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles",
            bodyXML: "<trt:GetProfiles/>",
            username: username,
            password: password
        )
        return ONVIFXMLParser.parseMediaProfiles(data)
    }

    func getStreamURI(mediaURL: URL, profileToken: String, username: String, password: String) async throws -> String {
        let body = """
        <trt:GetStreamUri>
          <trt:StreamSetup>
            <tt:Stream>RTP-Unicast</tt:Stream>
            <tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>
          </trt:StreamSetup>
          <trt:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</trt:ProfileToken>
        </trt:GetStreamUri>
        """
        let data = try await self.sendSOAP(
            to: mediaURL,
            action: "http://www.onvif.org/ver10/media/wsdl/GetStreamUri",
            bodyXML: body,
            username: username,
            password: password
        )
        guard let uri = ONVIFXMLParser.parseStreamOrSnapshotURI(data) else {
            throw NSError(domain: "DirectCam.ONVIF", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing ONVIF StreamUri."])
        }
        return uri
    }

    func getSnapshotURI(mediaURL: URL, profileToken: String, username: String, password: String) async throws -> String? {
        let body = "<trt:GetSnapshotUri><trt:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</trt:ProfileToken></trt:GetSnapshotUri>"
        let data = try await self.sendSOAP(
            to: mediaURL,
            action: "http://www.onvif.org/ver10/media/wsdl/GetSnapshotUri",
            bodyXML: body,
            username: username,
            password: password
        )
        return ONVIFXMLParser.parseStreamOrSnapshotURI(data)
    }

    func fetchSnapshotData(uriString: String, username: String, password: String) async throws -> Data {
        guard let url = URL(string: uriString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(domain: "DirectCam.ONVIF", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid snapshot URI."])
        }
        var req = URLRequest(url: url)
        var (data, resp) = try await self.session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 401,
           let authHdr = http.value(forHTTPHeaderField: "WWW-Authenticate") {
            if let digest = HTTPDigestHelper.parseChallenge(authHdr) {
                let authVal = HTTPDigestHelper.authorizationHeader(
                    method: "GET",
                    uri: url.path.isEmpty ? "/" : url.path,
                    username: username,
                    password: password,
                    realm: digest.realm,
                    nonce: digest.nonce,
                    qop: digest.qop
                )
                req.setValue(authVal, forHTTPHeaderField: "Authorization")
            } else {
                let b64 = Data("\(username):\(password)".utf8).base64EncodedString()
                req.setValue("Basic \(b64)", forHTTPHeaderField: "Authorization")
            }
            (data, resp) = try await self.session.data(for: req)
        }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "DirectCam.ONVIF", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Snapshot HTTP error \(http.statusCode)."
            ])
        }
        return data
    }

    func syncClockToNow(host: String, port: Int, username: String, password: String) async throws {
        let url = try self.baseDeviceURL(host: host, port: port)
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: Date())
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0

        let body = """
        <tds:SetSystemDateAndTime>
          <tds:DateTimeType>Manual</tds:DateTimeType>
          <tds:DaylightSavings>false</tds:DaylightSavings>
          <tds:UTCDateTime>
            <tt:Time><tt:Hour>\(hour)</tt:Hour><tt:Minute>\(minute)</tt:Minute><tt:Second>\(second)</tt:Second></tt:Time>
            <tt:Date><tt:Year>\(year)</tt:Year><tt:Month>\(month)</tt:Month><tt:Day>\(day)</tt:Day></tt:Date>
          </tds:UTCDateTime>
        </tds:SetSystemDateAndTime>
        """
        _ = try await self.sendSOAP(
            to: url,
            action: "http://www.onvif.org/ver10/device/wsdl/SetSystemDateAndTime",
            bodyXML: body,
            username: username,
            password: password
        )
    }

    func systemReboot(host: String, port: Int, username: String, password: String) async throws {
        let url = try self.baseDeviceURL(host: host, port: port)
        _ = try await self.sendSOAP(
            to: url,
            action: "http://www.onvif.org/ver10/device/wsdl/SystemReboot",
            bodyXML: "<tds:SystemReboot/>",
            username: username,
            password: password
        )
    }

    func getImagingSettings(imagingURL: URL, videoSourceToken: String, username: String, password: String) async throws -> ONVIFImagingSettings {
        let body = "<timg:GetImagingSettings><timg:VideoSourceToken>\(ONVIFPasswordDigest.xmlEscape(videoSourceToken))</timg:VideoSourceToken></timg:GetImagingSettings>"
        let data = try await self.sendSOAP(
            to: imagingURL,
            action: "http://www.onvif.org/ver20/imaging/wsdl/GetImagingSettings",
            bodyXML: body,
            username: username,
            password: password
        )
        guard let settings = ONVIFXMLParser.parseImagingSettings(data) else {
            throw NSError(domain: "DirectCam.ONVIF", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to parse ONVIF imaging settings."])
        }
        return settings
    }

    func setImagingSettings(
        imagingURL: URL,
        videoSourceToken: String,
        settings: ONVIFImagingSettings,
        username: String,
        password: String
    ) async throws {
        let body = """
        <timg:SetImagingSettings>
          <timg:VideoSourceToken>\(ONVIFPasswordDigest.xmlEscape(videoSourceToken))</timg:VideoSourceToken>
          <timg:ImagingSettings>
            <tt:Brightness>\(Int(settings.brightness))</tt:Brightness>
            <tt:ColorSaturation>\(Int(settings.saturation))</tt:ColorSaturation>
            <tt:Contrast>\(Int(settings.contrast))</tt:Contrast>
            <tt:IrCutFilter>\(settings.irCutFilter.rawValue)</tt:IrCutFilter>
            <tt:Sharpness>\(Int(settings.sharpness))</tt:Sharpness>
          </timg:ImagingSettings>
          <timg:ForcePersistence>true</timg:ForcePersistence>
        </timg:SetImagingSettings>
        """
        _ = try await self.sendSOAP(
            to: imagingURL,
            action: "http://www.onvif.org/ver20/imaging/wsdl/SetImagingSettings",
            bodyXML: body,
            username: username,
            password: password
        )
    }

    // MARK: - PTZ

    func ptzContinuousMove(ptzURL: URL, profileToken: String, pan: Double, tilt: Double, zoom: Double, username: String, password: String) async throws {
        let body = """
        <tptz:ContinuousMove>
          <tptz:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</tptz:ProfileToken>
          <tptz:Velocity>
            <tt:PanTilt x="\(String(format: "%.2f", pan))" y="\(String(format: "%.2f", tilt))"/>
            <tt:Zoom x="\(String(format: "%.2f", zoom))"/>
          </tptz:Velocity>
        </tptz:ContinuousMove>
        """
        _ = try await self.sendSOAP(
            to: ptzURL,
            action: "http://www.onvif.org/ver20/ptz/wsdl/ContinuousMove",
            bodyXML: body,
            username: username,
            password: password
        )
    }

    func ptzStop(ptzURL: URL, profileToken: String, username: String, password: String) async throws {
        let body = "<tptz:Stop><tptz:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>"
        _ = try await self.sendSOAP(
            to: ptzURL,
            action: "http://www.onvif.org/ver20/ptz/wsdl/Stop",
            bodyXML: body,
            username: username,
            password: password
        )
    }

    func ptzGotoHome(ptzURL: URL, profileToken: String, username: String, password: String) async throws {
        let body = "<tptz:GotoHomePosition><tptz:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</tptz:ProfileToken></tptz:GotoHomePosition>"
        _ = try await self.sendSOAP(
            to: ptzURL,
            action: "http://www.onvif.org/ver20/ptz/wsdl/GotoHomePosition",
            bodyXML: body,
            username: username,
            password: password
        )
    }

    func getPTZPresets(ptzURL: URL, profileToken: String, username: String, password: String) async throws -> [ONVIFPTZPreset] {
        let body = "<tptz:GetPresets><tptz:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</tptz:ProfileToken></tptz:GetPresets>"
        let data = try await self.sendSOAP(
            to: ptzURL,
            action: "http://www.onvif.org/ver20/ptz/wsdl/GetPresets",
            bodyXML: body,
            username: username,
            password: password
        )
        return ONVIFXMLParser.parsePTZPresets(data)
    }

    func gotoPTZPreset(ptzURL: URL, profileToken: String, presetToken: String, username: String, password: String) async throws {
        let body = """
        <tptz:GotoPreset>
          <tptz:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</tptz:ProfileToken>
          <tptz:PresetToken>\(ONVIFPasswordDigest.xmlEscape(presetToken))</tptz:PresetToken>
        </tptz:GotoPreset>
        """
        _ = try await self.sendSOAP(
            to: ptzURL,
            action: "http://www.onvif.org/ver20/ptz/wsdl/GotoPreset",
            bodyXML: body,
            username: username,
            password: password
        )
    }

    func setPTZPreset(ptzURL: URL, profileToken: String, presetName: String, username: String, password: String) async throws {
        let body = """
        <tptz:SetPreset>
          <tptz:ProfileToken>\(ONVIFPasswordDigest.xmlEscape(profileToken))</tptz:ProfileToken>
          <tptz:PresetName>\(ONVIFPasswordDigest.xmlEscape(presetName))</tptz:PresetName>
        </tptz:SetPreset>
        """
        _ = try await self.sendSOAP(
            to: ptzURL,
            action: "http://www.onvif.org/ver20/ptz/wsdl/SetPreset",
            bodyXML: body,
            username: username,
            password: password
        )
    }

    // MARK: - PullPoint Events

    func createPullPointSubscription(eventsURL: URL, username: String, password: String) async throws -> URL {
        let body = "<tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT120S</tev:InitialTerminationTime></tev:CreatePullPointSubscription>"
        let data = try await self.sendSOAP(
            to: eventsURL,
            action: "http://www.onvif.org/ver10/events/wsdl/EventPortType/CreatePullPointSubscriptionRequest",
            bodyXML: body,
            username: username,
            password: password
        )
        if let raw = ONVIFXMLParser.parsePullPointSubscriptionAddress(data), let subURL = URL(string: raw) {
            return subURL
        }
        return eventsURL
    }

    func pullMessages(subscriptionURL: URL, username: String, password: String) async throws -> [ONVIFMotionEvent] {
        let body = "<tev:PullMessages><tev:Timeout>PT2S</tev:Timeout><tev:MessageLimit>10</tev:MessageLimit></tev:PullMessages>"
        let data = try await self.sendSOAP(
            to: subscriptionURL,
            action: "http://www.onvif.org/ver10/events/wsdl/PullPointSubscription/PullMessagesRequest",
            bodyXML: body,
            username: username,
            password: password
        )
        return ONVIFXMLParser.parsePullMessages(data)
    }
}
