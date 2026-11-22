import WebKit
import XCTest
@testable import Bamboo

@MainActor
final class ShieldsTests: XCTestCase {
    private func site(shields: Bool = true, javascript: Bool = true, lockdown: Bool = false,
                      camera: PermissionState = .ask, microphone: PermissionState = .ask) -> SiteSettings {
        SiteSettings(host: "example.com", shieldsEnabled: shields, javascriptEnabled: javascript, popups: .ask,
                     camera: camera, microphone: microphone, location: .ask, zoom: 1, lockdownMode: lockdown)
    }

    private func defaults(blockAds: Bool = true, blockScripts: Bool = false) -> AppSettings {
        let suite = "dev.pandascript.Bamboo.tests.\(UUID().uuidString)"
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!)
        settings.blockTrackersAndAds = blockAds
        settings.blockScripts = blockScripts
        UserDefaults().removePersistentDomain(forName: suite)
        return settings
    }

    // MARK: - Cosmetic script

    func testCosmeticSourceHidesSelectorsThenRunsScriptlets() throws {
        let resources = CosmeticResources(hideSelectors: [".ad", "#banner"], injectedScript: "window.scriptlet = 1;",
                                          generichide: false, exceptions: [])
        let source = try XCTUnwrap(ShieldsTabExtension.cosmeticSource(resources))
        XCTAssertTrue(source.contains(#"".ad { display: none !important; }\n#banner { display: none !important; }""#))
        XCTAssertTrue(source.hasSuffix("window.scriptlet = 1;"))
    }

    func testCosmeticSourceEscapesSelectors() throws {
        let resources = CosmeticResources(hideSelectors: [#"a[href="x"]"#], injectedScript: "", generichide: false, exceptions: [])
        let source = try XCTUnwrap(ShieldsTabExtension.cosmeticSource(resources))
        XCTAssertTrue(source.contains(#"a[href=\"x\"]"#))
    }

    func testNoCosmeticScriptWhenNothingApplies() {
        let resources = CosmeticResources(hideSelectors: [], injectedScript: "", generichide: true, exceptions: [])
        XCTAssertNil(ShieldsTabExtension.cosmeticSource(resources))
    }

    /// `setCosmeticScript` swaps one script by identity, which relies on WebKit handing back
    /// the same objects it was given.
    func testUserContentControllerReturnsTheScriptsAdded() {
        let controller = WKUserContentController()
        let script = WKUserScript(source: "1", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(script)
        XCTAssertTrue(controller.userScripts.first === script)
    }

    // MARK: - Compiling rule lists

    func testCompileReusesListsAndRemovesStaleOnes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bamboo-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let rule = #"[{"trigger":{"url-filter":"ads\\.example"},"action":{"type":"block"}}]"#
        let first = ContentRuleSet(identifier: "\(ShieldsManager.ruleListPrefix)one", json: rule)
        let second = ContentRuleSet(identifier: "\(ShieldsManager.ruleListPrefix)two", json: rule)
        let unrelated = ContentRuleSet(identifier: "someone-else", json: rule)
        _ = try await ShieldsManager.compile([unrelated], in: store)

        let compiled = try await ShieldsManager.compile([first, second], in: store)
        XCTAssertEqual(compiled.map(\.identifier), [first.identifier, second.identifier])

        let reused = try await ShieldsManager.compile([second], in: store)
        XCTAssertEqual(reused.map(\.identifier), [second.identifier])
        let remaining = Set(await store.availableIdentifiers() ?? [])
        XCTAssertEqual(remaining, [second.identifier, unrelated.identifier])
    }

    func testCompileFailsOnInvalidRules() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bamboo-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let broken = ContentRuleSet(identifier: "\(ShieldsManager.ruleListPrefix)broken", json: "not json")
        do {
            _ = try await ShieldsManager.compile([broken], in: store)
            XCTFail("Compiling invalid rules should throw")
        } catch {}
    }

    // MARK: - Site shields

    func testDefaultsApplyToSitesWithoutSettings() {
        let shields = SiteShields(site(), defaults: defaults())
        XCTAssertTrue(shields.blocksTrackersAndAds)
        XCTAssertFalse(shields.blocksScripts)
        XCTAssertFalse(shields.lockdownMode)

        XCTAssertTrue(SiteShields(nil, defaults: defaults(blockScripts: true)).blocksScripts)
        XCTAssertFalse(SiteShields(nil, defaults: defaults(blockAds: false)).blocksTrackersAndAds)
    }

    func testShieldsDownTurnsEverythingOff() {
        let down = site(shields: false)
        XCTAssertFalse(down.shieldsUp)
        let shields = SiteShields(down, defaults: defaults(blockScripts: true))
        XCTAssertFalse(shields.blocksTrackersAndAds)
        XCTAssertFalse(shields.blocksScripts)
    }

    func testSiteControlsCombineWithDefaults() {
        let scriptsOnly = site(shields: false, javascript: false)
        XCTAssertTrue(scriptsOnly.shieldsUp)
        XCTAssertFalse(SiteShields(scriptsOnly, defaults: defaults()).blocksTrackersAndAds)
        XCTAssertTrue(SiteShields(scriptsOnly, defaults: defaults()).blocksScripts)

        XCTAssertTrue(SiteShields(site(lockdown: true), defaults: defaults()).lockdownMode)
        XCTAssertFalse(SiteShields(site(), defaults: defaults(blockAds: false)).blocksTrackersAndAds)
    }

    // MARK: - Site permissions and HTTPS-Only

    func testCameraAndMicrophoneDecisions() {
        XCTAssertNil(SiteSettingsTabExtension.decision(for: .camera, site: site()))
        XCTAssertEqual(SiteSettingsTabExtension.decision(for: .camera, site: site(camera: .allow)), .grant)
        XCTAssertEqual(SiteSettingsTabExtension.decision(for: .microphone, site: site(microphone: .deny)), .deny)
        XCTAssertEqual(SiteSettingsTabExtension.decision(for: .cameraAndMicrophone, site: site(camera: .allow, microphone: .allow)), .grant)
        XCTAssertNil(SiteSettingsTabExtension.decision(for: .cameraAndMicrophone, site: site(camera: .allow)))
        XCTAssertEqual(SiteSettingsTabExtension.decision(for: .cameraAndMicrophone, site: site(camera: .allow, microphone: .deny)), .deny)
    }

    func testHTTPSOnlyLeavesLocalAddressesAlone() {
        for host in ["localhost", "app.localhost", "printer.local", "192.168.1.1", "::1"] {
            XCTAssertTrue(PrivacyTabExtension.isLocal(host), host)
        }
        for host in ["example.com", "1password.com", "localhost.example.com"] {
            XCTAssertFalse(PrivacyTabExtension.isLocal(host), host)
        }
    }
}
