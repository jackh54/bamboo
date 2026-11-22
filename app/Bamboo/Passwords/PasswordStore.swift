import Foundation
import LocalAuthentication
import Observation
import Security

/// A saved website login, without its password.
struct SavedLogin: Identifiable, Hashable, Sendable {
    var host: String
    var isSecure: Bool
    /// Nil for the scheme's default port.
    var port: Int?
    var username: String
    var modified: Date?

    var id: String { "\(origin) \(username)" }

    /// "https://accounts.example.com", as `location.origin` gives it.
    var origin: String {
        "\(isSecure ? "https" : "http")://\(host)" + (port.map { ":\($0)" } ?? "")
    }
}

extension SavedLogin {
    /// A login for an http(s) origin; nil for anything else (an app's android:// login, say).
    init?(origin: URL, username: String) {
        guard let scheme = origin.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = origin.host(), !host.isEmpty
        else { return nil }
        let isSecure = scheme == "https"
        let defaultPort = isSecure ? 443 : 80
        self.init(host: host, isSecure: isSecure, port: origin.port == defaultPort ? nil : origin.port,
                  username: username, modified: nil)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
}

/// Website passwords, kept as internet-password items in the user's login keychain. Every
/// item carries `itemDescription`, so Bamboo lists only the items it created. (The
/// data-protection keychain would need a signed team identifier.)
@MainActor
@Observable
final class PasswordStore {
    private(set) var logins: [SavedLogin] = []
    @ObservationIgnored private let itemDescription: String

    static let label = "Bamboo"

    init(itemDescription: String = "Bamboo website password") {
        self.itemDescription = itemDescription
    }

    /// Reads the list of saved logins again.
    func reload() throws {
        logins = try fetch([:])
    }

    func logins(forHost host: String, isSecure: Bool) throws -> [SavedLogin] {
        try fetch([
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: isSecure ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
        ])
    }

    func password(for login: SavedLogin) throws -> String {
        var query = itemQuery(login)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return password
    }

    /// Saves a login, replacing the password when the site already has one for this username.
    func save(_ login: SavedLogin, password: String) throws {
        try write(login, password: password)
        try reload()
    }

    /// Saves the logins that aren't saved yet and leaves existing ones alone, so an import
    /// never replaces a newer password with an older one. Returns how many were added.
    func saveNew(_ entries: [(login: SavedLogin, password: String)]) throws -> Int {
        var added = 0
        for entry in entries {
            var item = itemQuery(entry.login)
            item[kSecAttrLabel as String] = Self.label
            item[kSecValueData as String] = Data(entry.password.utf8)
            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecDuplicateItem { continue }
            try check(status)
            added += 1
        }
        try reload()
        return added
    }

    func update(_ login: SavedLogin, username: String, password: String) throws {
        let changes: [String: Any] = [
            kSecAttrAccount as String: username,
            kSecValueData as String: Data(password.utf8),
        ]
        try check(SecItemUpdate(itemQuery(login) as CFDictionary, changes as CFDictionary))
        try reload()
    }

    func delete(_ login: SavedLogin) throws {
        try check(SecItemDelete(itemQuery(login) as CFDictionary))
        try reload()
    }

    /// Every saved login as CSV in the column layout Chrome, Brave and Safari import.
    func exportCSV() throws -> String {
        var lines = ["name,url,username,password"]
        for login in logins {
            let fields = [login.host, login.origin, login.username, try password(for: login)]
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Asks for Touch ID or the user's Mac password. Throws `LAError.userCancel` when they decline.
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }

    // MARK: - Keychain

    private func write(_ login: SavedLogin, password: String) throws {
        let data = Data(password.utf8)
        var query = itemQuery(login)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return try check(status) }
        query[kSecAttrLabel as String] = Self.label
        query[kSecValueData as String] = data
        try check(SecItemAdd(query as CFDictionary, nil))
    }

    private func fetch(_ attributes: [String: Any]) throws -> [SavedLogin] {
        var query = attributes
        query[kSecClass as String] = kSecClassInternetPassword
        query[kSecAttrDescription as String] = itemDescription
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let items = result as? [[String: Any]] else { throw KeychainError(status: errSecDecode) }
        return items.compactMap(Self.login(from:)).sorted {
            ($0.host, $0.username.lowercased()) < ($1.host, $1.username.lowercased())
        }
    }

    /// The description isn't part of an internet password's unique key, so the security
    /// domain carries it too: otherwise another app's item for the same server and account
    /// would block Bamboo from saving its own.
    private func itemQuery(_ login: SavedLogin) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: itemDescription,
            kSecAttrSecurityDomain as String: itemDescription,
            kSecAttrAuthenticationType as String: kSecAttrAuthenticationTypeHTMLForm,
            kSecAttrServer as String: login.host,
            kSecAttrProtocol as String: login.isSecure ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP,
            kSecAttrPort as String: login.port ?? 0,
            kSecAttrAccount as String: login.username,
        ]
    }

    private static func login(from attributes: [String: Any]) -> SavedLogin? {
        guard let host = attributes[kSecAttrServer as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String
        else { return nil }
        let port = attributes[kSecAttrPort as String] as? Int ?? 0
        let protocolCode = attributes[kSecAttrProtocol as String] as? String
        return SavedLogin(
            host: host, isSecure: protocolCode != kSecAttrProtocolHTTP as String, port: port == 0 ? nil : port,
            username: account, modified: attributes[kSecAttrModificationDate as String] as? Date)
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
