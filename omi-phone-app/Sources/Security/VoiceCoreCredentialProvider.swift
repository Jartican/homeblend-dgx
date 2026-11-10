import Foundation
import OmiPhoneCore
import Security

protocol VoiceCoreCredentialProviding: Sendable {
    func bearerToken() throws -> String
}

enum VoiceCoreCredentialError: LocalizedError {
    case missing
    case invalidEncoding
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "No Voice Core credential is saved."
        case .invalidEncoding:
            return "The saved Voice Core credential is invalid."
        case .keychain:
            return "The secure credential store could not complete the request."
        }
    }
}

/// Stores a single, non-synchronizing credential in this device's Keychain.
/// After-first-unlock access allows planned background audio reconnects while
/// keeping the credential unavailable after a reboot until the phone unlocks.
final class KeychainVoiceCoreCredentialProvider: VoiceCoreCredentialProviding, @unchecked Sendable {
    static let shared = KeychainVoiceCoreCredentialProvider()

    private let service: String
    private let account: String

    init(
        service: String = "com.homeblend.companion.voice-core",
        account: String = "bearer-token"
    ) {
        self.service = service
        self.account = account
    }

    func bearerToken() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw VoiceCoreCredentialError.missing }
        guard status == errSecSuccess else { throw VoiceCoreCredentialError.keychain(status) }
        guard let data = result as? Data,
              let rawToken = String(data: data, encoding: .utf8) else {
            throw VoiceCoreCredentialError.invalidEncoding
        }
        do {
            return try VoiceClientCredential.validate(rawToken)
        } catch {
            throw VoiceCoreCredentialError.invalidEncoding
        }
    }

    func save(_ token: String) throws {
        guard let normalized = try? VoiceClientCredential.validate(token),
              let data = normalized.data(using: .utf8) else {
            throw VoiceCoreCredentialError.invalidEncoding
        }

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        guard addStatus == errSecDuplicateItem else {
            throw VoiceCoreCredentialError.keychain(addStatus)
        }

        let updates = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updates)
        guard updateStatus == errSecSuccess else {
            throw VoiceCoreCredentialError.keychain(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceCoreCredentialError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
