import WebKit
import XCTest
@testable import Bamboo

/// The save offer records the exact origin the page submitted from and goes away when the
/// tab moves to another origin. Runs the autofill script in a real tab of the test host.
@MainActor
final class PasswordSaveOfferTests: XCTestCase {
    private var tab: Tab!
    private var offeredBefore = true

    private static let form = """
        <html><body><form action="javascript:void 0">
        <input id="user" type="email" autocomplete="username" value="jack@example.com">
        <input id="pass" type="password" value="hunter2"><button id="go" type="submit">Sign in</button>
        </form></body></html>
        """

    override func setUp() async throws {
        let settings = AppServices.shared.settings
        offeredBefore = settings.offerToSavePasswords
        settings.offerToSavePasswords = true
        tab = AppServices.shared.windows.openAgentTab(url: nil)
    }

    override func tearDown() async throws {
        AppServices.shared.settings.offerToSavePasswords = offeredBefore
        AppServices.shared.windows.close(tab)
        // The test host is a real Bamboo; save now so this tab isn't restored next launch.
        AppServices.shared.windows.saveSession()
    }

    private func load(_ html: String, at address: String) async throws {
        tab.ensureWebView().loadHTMLString(html, baseURL: URL(string: address)!)
        try await waitUntil { self.tab.webView?.url?.absoluteString == address && !self.tab.isLoading }
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<100 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out")
    }

    func testOfferKeepsTheSubmittingOriginAndClearsOnOriginChange() async throws {
        try await load(Self.form, at: "https://login.bamboo.test/")
        _ = try await tab.webView?.callAsyncJavaScript("document.getElementById('go').click()", contentWorld: .page)
        try await waitUntil { self.tab.passwordSaveOffer != nil }

        let offer = try XCTUnwrap(tab.passwordSaveOffer)
        XCTAssertEqual(offer.login.origin, "https://login.bamboo.test")
        XCTAssertEqual(offer.login.username, "jack@example.com")
        XCTAssertEqual(offer.password, "hunter2")

        try await load("<p>Welcome</p>", at: "https://login.bamboo.test/welcome")
        XCTAssertEqual(tab.passwordSaveOffer, offer, "same origin keeps the offer")

        try await load("<p>Elsewhere</p>", at: "https://login.bamboo.test:8443/")
        XCTAssertNil(tab.passwordSaveOffer, "another origin clears it")
    }

    func testOnlyTheSameSchemeHostAndPortKeepAnOffer() {
        let offer = PasswordSaveOffer(
            login: SavedLogin(host: "example.com", isSecure: true, port: nil, username: "jack", modified: nil),
            password: "pw")
        func survives(_ address: String?) -> Bool {
            AutofillTabExtension.offer(offer, survivesCommitOf: address.flatMap(URL.init(string:)))
        }
        XCTAssertTrue(survives("https://example.com/account"))
        XCTAssertTrue(survives("https://example.com:443/"))
        XCTAssertFalse(survives("http://example.com/"))
        XCTAssertFalse(survives("https://example.com:8443/"))
        XCTAssertFalse(survives("https://www.example.com/"))
        XCTAssertFalse(survives("about:blank"))
        XCTAssertFalse(survives(nil))
    }
}
