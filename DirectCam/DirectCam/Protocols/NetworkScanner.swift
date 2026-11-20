import Darwin
import Foundation
import Network

final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func tryAcquire() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.completed { return false }
        self.completed = true
        return true
    }
}

enum NetworkScanner {
    static func checkTCPPort(host: String, port: Int, timeout: TimeInterval = 1.4) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)),
              port > 0, port <= 65535 else {
            return false
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let gate = ContinuationGate()

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.lessy.directcam.probe.\(port)")
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.tryAcquire() {
                        connection.cancel()
                        continuation.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if gate.tryAcquire() {
                        continuation.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if gate.tryAcquire() {
                    connection.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    static func probeCameraPorts(
        host: String,
        rtspPort: Int = 554,
        onvifPort: Int = 8899,
        dvripPort: Int = 34567,
        httpPort: Int = 80
    ) async -> PortProbeResult {
        async let rtsp = self.checkTCPPort(host: host, port: rtspPort)
        async let onvif = self.checkTCPPort(host: host, port: onvifPort)
        async let dvrip = self.checkTCPPort(host: host, port: dvripPort)
        async let http = self.checkTCPPort(host: host, port: httpPort)

        return await PortProbeResult(
            host: host,
            rtspOpen: rtsp,
            onvifOpen: onvif,
            dvripOpen: dvrip,
            httpOpen: http,
            checkedAt: Date()
        )
    }

    /// Sends an ONVIF WS-Discovery multicast UDP probe to 239.255.255.250:3702 over BSD socket
    /// (does not require Apple's restricted multicast entitlement) and collects responses.
    static func discoverONVIFCameras(timeout: TimeInterval = 2.4) async -> [DiscoveredCamera] {
        await Task.detached(priority: .userInitiated) {
            let sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard sock >= 0 else { return [] }
            defer { Darwin.close(sock) }

            var reuse: Int32 = 1
            Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var ttl: UInt8 = 2
            Darwin.setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

            var flags = Darwin.fcntl(sock, F_GETFL, 0)
            if flags >= 0 {
                _ = Darwin.fcntl(sock, F_SETFL, flags | O_NONBLOCK)
            }

            let messageID = UUID().uuidString.lowercased()
            let probeSOAP = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
              <s:Header>
                <a:Action s:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action>
                <a:MessageID>urn:uuid:\(messageID)</a:MessageID>
                <a:To s:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To>
              </s:Header>
              <s:Body>
                <d:Probe>
                  <d:Types>dn:NetworkVideoTransmitter</d:Types>
                </d:Probe>
              </s:Body>
            </s:Envelope>
            """

            var destAddr = sockaddr_in()
            destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destAddr.sin_family = sa_family_t(AF_INET)
            destAddr.sin_port = CFSwapInt16HostToBig(3702)
            inet_pton(AF_INET, "239.255.255.250", &destAddr.sin_addr)

            let payloadData = Data(probeSOAP.utf8)
            _ = payloadData.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &destAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.sendto(sock, rawBuf.baseAddress, payloadData.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            var foundByHost: [String: DiscoveredCamera] = [:]
            let deadline = Date().addingTimeInterval(timeout)
            var buffer = [UInt8](repeating: 0, count: 16384)

            while Date() < deadline {
                var senderAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bytesRead = withUnsafeMutablePointer(to: &senderAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.recvfrom(sock, &buffer, buffer.count, 0, sa, &addrLen)
                    }
                }
                if bytesRead > 0 {
                    var ipChars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    var addrCopy = senderAddr.sin_addr
                    inet_ntop(AF_INET, &addrCopy, &ipChars, socklen_t(INET_ADDRSTRLEN))
                    let senderIP = String(cString: ipChars)
                    let xmlData = Data(buffer[0..<bytesRead])
                    if let parsed = ONVIFXMLParser.parseProbeMatch(xmlData, fallbackHost: senderIP) {
                        foundByHost[parsed.host] = parsed
                    }
                } else {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            return foundByHost.values.sorted { $0.host < $1.host }
        }.value
    }
}
