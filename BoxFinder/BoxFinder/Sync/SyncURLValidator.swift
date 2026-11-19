import Foundation

enum SyncPairingError: LocalizedError, Sendable {
    case invalidURL(String)
    case invalidToken
    case pairingFileTooLarge
    case invalidPairingFile

    var errorDescription: String? {
        switch self {
        case .invalidURL(let msg): return msg
        case .invalidToken: return "Invalid Pi pairing token. Expected 64 hexadecimal characters."
        case .pairingFileTooLarge: return "Pairing file is too large."
        case .invalidPairingFile: return "This file is not a valid Box Finder Pi pairing JSON."
        }
    }
}

struct PairingConfiguration: Equatable, Sendable {
    let url: String
    let token: String
}

enum SyncURLValidator {
    static let defaultURL = "http://pi-usbserver.local:8000/box-finder-sync.php"
    static let maxPairingFileBytes = 4096

    @discardableResult
    static func validateURL(_ rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              let host = components.host,
              !host.isEmpty,
              components.port == 8000,
              components.path == "/box-finder-sync.php",
              components.query == nil,
              components.fragment == nil,
              components.user == nil,
              components.password == nil else {
            throw SyncPairingError.invalidURL("Invalid Pi sync URL. Expected http://<pi-host>:8000/box-finder-sync.php")
        }

        let lowerHost = host.lowercased()
        let allowed = lowerHost == "pi-usbserver.local" || isAllowedPrivateIPv4(lowerHost)
        guard allowed else {
            throw SyncPairingError.invalidURL("Use the Pi's home-network address (pi-usbserver.local, 192.168.x.x, or 10.x.x.x).")
        }
        return trimmed
    }

    static func validateToken(_ rawToken: String) throws -> String {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 64,
              trimmed.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57) || // 0-9
                  ($0.value >= 65 && $0.value <= 70) || // A-F
                  ($0.value >= 97 && $0.value <= 102)   // a-f
              }) else {
            throw SyncPairingError.invalidToken
        }
        return trimmed
    }

    static func parsePairingJSON(_ data: Data) throws -> PairingConfiguration {
        guard data.count <= maxPairingFileBytes else {
            throw SyncPairingError.pairingFileTooLarge
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = json["url"] as? String,
              let rawToken = json["token"] as? String else {
            throw SyncPairingError.invalidPairingFile
        }
        let validatedURL = try validateURL(rawURL)
        let validatedToken = try validateToken(rawToken)
        return PairingConfiguration(url: validatedURL, token: validatedToken)
    }

    private static func isAllowedPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let val = Int(part), (0...255).contains(val) else {
                return false
            }
            octets.append(val)
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        if octets[0] == 10 {
            return true
        }
        return false
    }
}
