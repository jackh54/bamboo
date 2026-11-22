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
}
