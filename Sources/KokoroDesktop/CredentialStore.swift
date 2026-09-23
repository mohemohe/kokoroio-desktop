import Foundation
import LocalAuthentication
import Security

struct Credential: Codable, Sendable {
    let baseURL: URL
    let token: String
}

/// The access token and its server are kept together in the user's Keychain.
enum CredentialStore {
    private static let service = "io.kokoro.desktop.credentials"
    private static let account = "current-session"
    private static let imgBBService = "io.kokoro.desktop.imgbb"
    private static let imgBBAccount = "api-key"

    static func load() throws -> Credential? {
        var query = identityQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Automatic restoration must not block the main thread on a system prompt.
        // A new development signature may require the user to sign in again.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    static func save(_ credential: Credential) throws {
        let data = try JSONEncoder().encode(credential)
        let changes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(identityQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identityQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let insertionStatus = SecItemAdd(item as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else {
                throw KeychainError(status: insertionStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func delete() throws {
        let status = SecItemDelete(identityQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    static func loadImgBBAPIKey() throws -> String? {
        var query = imgBBQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return key
    }

    static func saveImgBBAPIKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            let status = SecItemDelete(imgBBQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let changes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(imgBBQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = imgBBQuery
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let insertionStatus = SecItemAdd(item as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else { throw KeychainError(status: insertionStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    private static var identityQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private static var imgBBQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: imgBBService,
            kSecAttrAccount as String: imgBBAccount,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                return "保存したトークンを読み取れません。アクセストークンを入力して接続し直してください。開発用署名が変わった場合は、macOSのKeychain確認が必要になることがあります。"
            }
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "エラー \(status)"
            return "Keychain を操作できませんでした: \(reason)"
        }
    }
}
