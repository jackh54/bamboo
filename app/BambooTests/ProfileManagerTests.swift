import XCTest
@testable import Bamboo

@MainActor
final class ProfileManagerTests: XCTestCase {
    func testProfileNamedCreatesAMissingProfileOnceAndThenReusesIt() async throws {
        let manager = ProfileManager()
        let name = "Imported \(UUID().uuidString)"

        let created = manager.profile(named: name)
        XCTAssertEqual(created.name, name)
        XCTAssertFalse(created.isDefault)
        XCTAssertTrue(manager.profile(named: name) === created)
        XCTAssertEqual(manager.profiles.filter { $0.name == name }.count, 1)

        try await manager.deleteProfile(created)
    }

    func testEachProfileHasItsOwnPasswordsAndDeletingItRemovesThem() async throws {
        let manager = ProfileManager()
        let profile = manager.createProfile(name: "Passwords \(UUID().uuidString)", symbol: "person.crop.circle")
        let server = "bamboo-test-\(UUID().uuidString.lowercased()).invalid"
        let login = SavedLogin(host: server, isSecure: true, port: nil, username: "jack", modified: nil)

        try profile.passwords.save(login, password: "secret")
        XCTAssertEqual(try profile.passwords.logins(forHost: server, isSecure: true).map(\.username), ["jack"])
        XCTAssertTrue(try manager.defaultProfile.passwords.logins(forHost: server, isSecure: true).isEmpty)

        let description = profile.passwords.itemDescription
        try await manager.deleteProfile(profile)
        let leftover = PasswordStore(itemDescription: description)
        try leftover.reload()
        XCTAssertTrue(leftover.logins.isEmpty)
    }
}
