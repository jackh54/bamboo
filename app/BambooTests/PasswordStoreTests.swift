import Security
import XCTest
@testable import Bamboo

/// Runs against the real login keychain with a description and server name no real item
/// uses, and deletes everything it created.
@MainActor
final class PasswordStoreTests: XCTestCase {
    private let itemDescription = "Bamboo test password \(UUID().uuidString)"
    private let server = "bamboo-test-\(UUID().uuidString.lowercased()).invalid"
    private var store: PasswordStore!

    override func setUp() async throws {
        store = PasswordStore(itemDescription: itemDescription)
    }

    override func tearDown() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: itemDescription,
        ]
        let status = SecItemDelete(query as CFDictionary)
        XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound, "Cleanup failed: \(status)")
    }

    private func login(_ username: String, secure: Bool = true, port: Int? = nil) -> SavedLogin {
        SavedLogin(host: server, isSecure: secure, port: port, username: username, modified: nil)
    }

    func testSaveListAndReadBack() throws {
        try store.save(login("jack"), password: "correct horse")
        try store.save(login("amy"), password: "battery staple")

        XCTAssertEqual(store.logins.map(\.username), ["amy", "jack"])
        XCTAssertEqual(try store.password(for: login("jack")), "correct horse")
        XCTAssertEqual(try store.logins(forHost: server, isSecure: true).count, 2)
        XCTAssertEqual(try store.logins(forHost: server, isSecure: false).count, 0)
    }

    func testSavingAgainReplacesThePassword() throws {
        try store.save(login("jack"), password: "old")
        try store.save(login("jack"), password: "new")

        XCTAssertEqual(store.logins.count, 1)
        XCTAssertEqual(try store.password(for: login("jack")), "new")
    }

    func testSchemeAndPortKeepLoginsApart() throws {
        try store.save(login("jack"), password: "https")
        try store.save(login("jack", secure: false), password: "http")
        try store.save(login("jack", port: 8443), password: "port")

        XCTAssertEqual(store.logins.count, 3)
        XCTAssertEqual(try store.password(for: login("jack", secure: false)), "http")
        XCTAssertEqual(try store.password(for: login("jack", port: 8443)), "port")
        XCTAssertEqual(store.logins.first { $0.port == 8443 }?.origin, "https://\(server):8443")
    }

    func testUpdateChangesUsernameAndPassword() throws {
        try store.save(login("jack"), password: "one")
        try store.update(login("jack"), username: "jack.h", password: "two")

        XCTAssertEqual(store.logins.map(\.username), ["jack.h"])
        XCTAssertEqual(try store.password(for: login("jack.h")), "two")
        XCTAssertThrowsError(try store.password(for: login("jack")))
    }

    func testDelete() throws {
        try store.save(login("jack"), password: "secret")
        try store.delete(login("jack"))

        XCTAssertTrue(store.logins.isEmpty)
        XCTAssertThrowsError(try store.password(for: login("jack"))) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecItemNotFound)
        }
    }

    func testOnlyItemsWithThisDescriptionAreListed() throws {
        try store.save(login("jack"), password: "secret")
        let other = PasswordStore(itemDescription: "\(itemDescription) other")
        try other.reload()
        XCTAssertTrue(other.logins.isEmpty)
    }

    func testAnotherAppsItemForTheSameAccountDoesNotBlockSaving() throws {
        let foreign: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrDescription as String: "\(itemDescription) other app",
            kSecAttrServer as String: server,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrAccount as String: "jack",
        ]
        var item = foreign
        item[kSecValueData as String] = Data("theirs".utf8)
        XCTAssertEqual(SecItemAdd(item as CFDictionary, nil), errSecSuccess)
        defer { SecItemDelete(foreign as CFDictionary) }

        try store.save(login("jack"), password: "mine")
        XCTAssertEqual(try store.password(for: login("jack")), "mine")
        XCTAssertEqual(store.logins.count, 1)
    }

    func testExportQuotesFieldsThatNeedIt() throws {
        try store.save(login("jack, the second"), password: #"say "hi""#)
        try store.save(login("amy"), password: "plain")

        let lines = try store.exportCSV().split(separator: "\n")
        XCTAssertEqual(lines[0], "name,url,username,password")
        XCTAssertEqual(lines[1], "\(server),https://\(server),amy,plain")
        XCTAssertEqual(lines[2], #"\#(server),https://\#(server),"jack, the second","say ""hi""""#)
    }

    func testExportFileIsPrivateAndReplacesAnOldOne() throws {
        try store.save(login("amy"), password: "plain")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bamboo-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old".utf8).write(to: url)

        try store.exportCSV(to: url)

        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), try store.exportCSV())
    }

    func testSaveNewAddsMissingLogins() throws {
        let added = try store.saveNew([(login("a"), "1"), (login("b"), "2"), (login("c"), "3")])
        XCTAssertEqual(added, 3)
        XCTAssertEqual(store.logins.map(\.username), ["a", "b", "c"])
        XCTAssertEqual(try store.password(for: login("b")), "2")
    }

    /// Importing must not replace a password the user saved since with the other browser's older one.
    func testSaveNewKeepsExistingLogins() throws {
        try store.save(login("jack"), password: "newer")
        let added = try store.saveNew([(login("jack"), "older"), (login("jack", secure: false), "http"), (login("amy"), "x")])

        XCTAssertEqual(added, 2)
        XCTAssertEqual(try store.password(for: login("jack")), "newer")
        XCTAssertEqual(try store.password(for: login("jack", secure: false)), "http")
        XCTAssertEqual(store.logins.count, 3)
    }
}
