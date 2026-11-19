import Foundation
import Security

enum KeychainAccount {
    static let syncToken = "sync_token"
    static let openRouterKey = "vision_openrouter"
    static let geminiKey = "vision_gemini"

    static func visionKey(for provider: String) -> String {
        "vision_\(provider)"
    }
}

enum KeychainError: LocalizedError, Sendable {
    case encodingFailed
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode secret for Keychain storage."
        case .unexpectedStatus(let status):
            return "Keychain access failed (OSStatus \(status))."
        }
    }
}

protocol SecretStore: Sendable {
    func read(account: String) throws -> String
    func save(account: String, value: String) throws
    func delete(account: String) throws
    func hasSecret(account: String) -> Bool
}

final class KeychainVault: SecretStore, Sendable {
    private let service: String

    init(service: String = "com.lessy.boxfinder.secrets") {
        self.service = service
    }

    func read(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    func save(account: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try delete(account: account)
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func hasSecret(account: String) -> Bool {
        guard let value = try? read(account: account) else { return false }
        return !value.isEmpty
    }
}

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    func read(account: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage[account] ?? ""
    }

    func save(account: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storage.removeValue(forKey: account)
        } else {
            storage[account] = value
        }
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }

    func hasSecret(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !(storage[account] ?? "").isEmpty
    }
}
