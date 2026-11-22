import XCTest
@testable import Bamboo

@MainActor
final class WindowManagerTests: XCTestCase {
    func testShowWindowOpensAWindowForTheProfileOnceAndThenReusesIt() async throws {
        let services = AppServices.shared
        let profile = services.profiles.createProfile(name: "Window \(UUID().uuidString)", symbol: "person.crop.circle")
        let windowCount = services.windows.controllers.count

        services.windows.showWindow(for: profile)
        XCTAssertEqual(services.windows.controllers.count, windowCount + 1)
        let model = try XCTUnwrap(services.windows.models.last)
        XCTAssertTrue(model.selectedSpace.profile === profile)
        XCTAssertFalse(model.isPrivate)
        XCTAssertEqual(model.selectedSpace.tint, services.profiles.tint(for: profile))
        XCTAssertEqual(services.windows.controller(for: model)?.window?.title, "Bamboo — \(profile.name)")

        services.windows.showWindow(for: profile)
        XCTAssertEqual(services.windows.controllers.count, windowCount + 1)

        services.windows.controller(for: model)?.close()
        XCTAssertEqual(services.windows.controllers.count, windowCount)
        try await services.profiles.deleteProfile(profile)
    }
}
