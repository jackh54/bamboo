import Foundation
import Observation
import Security

/// The user's Anthropic API key, kept in the Keychain as a generic password.
/// The UI only ever sees a masked form; the key itself is read when a request
/// is sent and is never logged.
@MainActor
@Observable
final class AnthropicKeyStore {
    static let shared = AnthropicKeyStore()

    private static let service = "dev.pandascript.Bamboo.anthropic"
    private static let account = "api-key"

    /// "sk-ant-…a1b2" when a key is saved.
    private(set) var maskedKey: String?
    /// Why the saved key couldn't be read (for example, the user denied Keychain access).
    private(set) var readError: String?
    var hasKey: Bool { maskedKey != nil }

    private init() {
        do {
            maskedKey = try Self.read().map(Self.mask)
        } catch {
            readError = error.localizedDescription
        }
    }

    func key() throws -> String? {
        try Self.read()
    }

    func save(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(Self.query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = Self.query
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Bamboo — Anthropic API key"
            try Self.check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try Self.check(update)
        }
        maskedKey = Self.mask(trimmed)
        readError = nil
    }

    func delete() throws {
        let status = SecItemDelete(Self.query as CFDictionary)
        if status != errSecItemNotFound {
            try Self.check(status)
        }
        maskedKey = nil
        readError = nil
    }

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private static func read() throws -> String? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
        return String(decoding: data, as: UTF8.self)
    }

    private static func mask(_ key: String) -> String {
        "\(key.hasPrefix("sk-ant-") ? "sk-ant-" : "")…\(key.suffix(4))"
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain: \(reason)"
        }
    }
}
