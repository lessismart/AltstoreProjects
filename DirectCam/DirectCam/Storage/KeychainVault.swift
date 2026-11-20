import Foundation
import Security

enum CredentialStorageBackend: Equatable, Sendable {
    case keychain
    case localProtectedFile(OSStatus)
}

enum KeychainVault {
    private static let service = "com.lessy.directcam.ios.credentials"

    private static var defaultVaultURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = appSupport.appendingPathComponent("DirectCam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".credentials.vault.json")
    }

    @discardableResult
    static func savePassword(
        _ password: String,
        forCameraID id: UUID,
        fallbackVaultURL: URL? = nil,
        skipKeychain: Bool = false
    ) throws -> CredentialStorageBackend {
        let vaultURL = fallbackVaultURL ?? self.defaultVaultURL
        let account = "camera.\(id.uuidString)"

        if !skipKeychain {
            let status = self.writeToKeychain(password: password, account: account)
            if status == errSecSuccess && self.readFromKeychain(account: account) == password {
                self.removeFromFallbackVault(account: account, url: vaultURL)
                return .keychain
            }
            // Fallback gracefully on sideloaded builds where Keychain returns -34018 or access errors.
            try self.writeToFallbackVault(password: password, account: account, url: vaultURL)
            return .localProtectedFile(status)
        } else {
            try self.writeToFallbackVault(password: password, account: account, url: vaultURL)
            return .localProtectedFile(0)
        }
    }

    static func loadPassword(forCameraID id: UUID, fallbackVaultURL: URL? = nil, skipKeychain: Bool = false) -> String {
        let account = "camera.\(id.uuidString)"
        if !skipKeychain, let kc = self.readFromKeychain(account: account), !kc.isEmpty {
            return kc
        }
        return self.readFromFallbackVault(account: account, url: fallbackVaultURL ?? self.defaultVaultURL) ?? ""
    }

    static func deletePassword(forCameraID id: UUID, fallbackVaultURL: URL? = nil) {
        let account = "camera.\(id.uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        self.removeFromFallbackVault(account: account, url: fallbackVaultURL ?? self.defaultVaultURL)
    }

    // MARK: - Apple Keychain

    private static func writeToKeychain(password: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account
        ]
        if password.isEmpty {
            let del = SecItemDelete(query as CFDictionary)
            return (del == errSecSuccess || del == errSecItemNotFound) ? errSecSuccess : del
        }

        let data = Data(password.utf8)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return errSecSuccess
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil)
        }
        return updateStatus
    }

    private static func readFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Device-Local Protected Fallback Vault (Never Exported)

    private static func writeToFallbackVault(password: String, account: String, url: URL) throws {
        var dict = self.loadFallbackDictionary(url: url)
        if password.isEmpty {
            dict.removeValue(forKey: account)
        } else {
            dict[account] = password
        }
        let encoded = try JSONEncoder().encode(dict)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }

    private static func readFromFallbackVault(account: String, url: URL) -> String? {
        self.loadFallbackDictionary(url: url)[account]
    }

    private static func removeFromFallbackVault(account: String, url: URL) {
        var dict = self.loadFallbackDictionary(url: url)
        guard dict.removeValue(forKey: account) != nil else { return }
        if let encoded = try? JSONEncoder().encode(dict) {
            try? encoded.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private static func loadFallbackDictionary(url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }
}
