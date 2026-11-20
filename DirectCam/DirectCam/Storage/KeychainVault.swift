import Foundation
import Security

enum KeychainVault {
    private static let service = "com.lessy.directcam.ios.credentials"

    static func savePassword(_ password: String, forCameraID id: UUID) throws {
        let account = "camera.\(id.uuidString)"
        let data = Data(password.utf8)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrAccount: account
        ]

        SecItemDelete(query as CFDictionary)
        guard !password.isEmpty else { return }

        var attributes = query
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain save failed (OSStatus \(status))."
            ])
        }
    }

    static func loadPassword(forCameraID id: UUID) -> String {
        let account = "camera.\(id.uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func deletePassword(forCameraID id: UUID) {
        let account = "camera.\(id.uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
