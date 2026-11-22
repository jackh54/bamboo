import XCTest
@testable import Bamboo

final class ImportMappingTests: XCTestCase {
    // Foundation caps cookie lifetimes at 400 days from the real current time, so the
    // expiry under test is a month from now, in whole seconds.
    private static let now = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down))
    private static let inAMonthMs = Int64(now.addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
    private var now: Date { Self.now }

    private func cookie(
        domain: String = ".example.com", path: String = "/", expiresMs: Int64? = ImportMappingTests.inAMonthMs,
        secure: Bool = true, httpOnly: Bool = true, sameSite: CookieSameSite = .lax
    ) -> ImportedCookie {
        ImportedCookie(name: "session", value: "abc123", domain: domain, path: path, expiresMs: expiresMs,
                       secure: secure, httpOnly: httpOnly, sameSite: sameSite)
    }

    func testBookmarkTreeKeepsStructure() {
        let items = [
            ImportedBookmark(localId: 1, parentLocalId: nil, title: "Bookmarks Bar", url: nil, createdMs: nil),
            ImportedBookmark(localId: 2, parentLocalId: 1, title: "Docs", url: "https://docs.example", createdMs: 1_700_000_000_000),
        ]
        XCTAssertEqual(ImportMapping.bookmarks(items), [
            BookmarkImport(localId: 1, parentLocalId: nil, title: "Bookmarks Bar", url: nil, createdMs: nil),
            BookmarkImport(localId: 2, parentLocalId: 1, title: "Docs", url: "https://docs.example", createdMs: 1_700_000_000_000),
        ])
    }

    func testHistoryKeepsVisitData() {
        let items = [ImportedHistory(url: "https://a.example", title: "A", lastVisitMs: 42, visitCount: 3)]
        XCTAssertEqual(ImportMapping.history(items), [HistoryImport(url: "https://a.example", title: "A", lastVisitMs: 42, visitCount: 3)])
    }

    func testFolderTitleNamesTheBrowser() {
        let source = SourceProfile(browser: .brave, browserName: "Brave", profileName: "Personal",
                                   profileDir: "/tmp/brave", kinds: [.bookmarks], accessError: nil)
        XCTAssertEqual(ImportMapping.bookmarksFolderTitle(for: source, namingProfile: false), "Imported from Brave")
        XCTAssertEqual(ImportMapping.bookmarksFolderTitle(for: source, namingProfile: true), "Imported from Brave (Personal)")
    }

    func testCookieCarriesEveryAttribute() throws {
        let result = try XCTUnwrap(ImportMapping.cookie(cookie(), now: now))
        XCTAssertEqual(result.name, "session")
        XCTAssertEqual(result.value, "abc123")
        XCTAssertEqual(result.domain, ".example.com")
        XCTAssertEqual(result.path, "/")
        XCTAssertEqual(result.expiresDate, Date(timeIntervalSince1970: Double(Self.inAMonthMs) / 1000))
        XCTAssertTrue(result.isSecure)
        XCTAssertTrue(result.isHTTPOnly)
        XCTAssertFalse(result.isSessionOnly)
        XCTAssertEqual(result.sameSitePolicy, .sameSiteLax)
    }

    func testCookieSameSitePolicies() throws {
        XCTAssertEqual(try XCTUnwrap(ImportMapping.cookie(cookie(sameSite: .strict), now: now)).sameSitePolicy, .sameSiteStrict)
        XCTAssertNil(try XCTUnwrap(ImportMapping.cookie(cookie(sameSite: .noRestriction), now: now)).sameSitePolicy)
        XCTAssertNil(try XCTUnwrap(ImportMapping.cookie(cookie(sameSite: .unspecified), now: now)).sameSitePolicy)
    }

    func testHostOnlyAndSessionCookies() throws {
        let result = try XCTUnwrap(ImportMapping.cookie(
            cookie(domain: "app.example.com", path: "/account", expiresMs: nil, secure: false, httpOnly: false), now: now))
        XCTAssertEqual(result.domain, "app.example.com")
        XCTAssertEqual(result.path, "/account")
        XCTAssertTrue(result.isSessionOnly)
        XCTAssertFalse(result.isSecure)
        XCTAssertFalse(result.isHTTPOnly)
    }

    func testExpiredCookieIsSkipped() {
        let yesterdayMs = Int64(now.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970 * 1000)
        XCTAssertNil(ImportMapping.cookie(cookie(expiresMs: yesterdayMs), now: now))
    }

    func testWebLoginsMapToSavedLogins() throws {
        let mapped = try XCTUnwrap(ImportMapping.login(
            ImportedLogin(origin: "https://accounts.example.com", username: "jack", password: "hunter2", createdMs: nil)))
        XCTAssertEqual(mapped.login.host, "accounts.example.com")
        XCTAssertTrue(mapped.login.isSecure)
        XCTAssertNil(mapped.login.port)
        XCTAssertEqual(mapped.login.username, "jack")
        XCTAssertEqual(mapped.password, "hunter2")

        let local = try XCTUnwrap(ImportMapping.login(
            ImportedLogin(origin: "http://router.local:8080", username: "admin", password: "pw", createdMs: nil)))
        XCTAssertFalse(local.login.isSecure)
        XCTAssertEqual(local.login.port, 8080)
        XCTAssertEqual(local.login.origin, "http://router.local:8080")
    }

    func testDefaultPortIsDropped() throws {
        let mapped = try XCTUnwrap(ImportMapping.login(
            ImportedLogin(origin: "https://example.com:443", username: "a", password: "b", createdMs: nil)))
        XCTAssertNil(mapped.login.port)
        XCTAssertEqual(mapped.login.origin, "https://example.com")
    }

    func testAppAndEmptyLoginsAreSkipped() {
        XCTAssertNil(ImportMapping.login(ImportedLogin(origin: "android://hash@com.example.app/", username: "a", password: "b", createdMs: nil)))
        XCTAssertNil(ImportMapping.login(ImportedLogin(origin: "https://example.com", username: "a", password: "", createdMs: nil)))
    }

    func testDefaultSearchEngineMatchesBuiltIn() {
        let engines = [
            ImportedSearchEngine(name: "Google", keyword: "g", urlTemplate: "https://www.google.com/search?q={searchTerms}", isDefault: false),
            ImportedSearchEngine(name: "Brave", keyword: ":br", urlTemplate: "https://search.brave.com/search?q={searchTerms}&source=desktop", isDefault: true),
        ]
        XCTAssertEqual(ImportMapping.builtInEngine(matching: engines), .brave)
    }

    func testUnknownOrMissingDefaultEngineMatchesNothing() {
        XCTAssertNil(ImportMapping.builtInEngine(matching: [
            ImportedSearchEngine(name: "Intranet", keyword: "i", urlTemplate: "https://search.corp.example/?q={searchTerms}", isDefault: true),
        ]))
        XCTAssertNil(ImportMapping.builtInEngine(matching: [
            ImportedSearchEngine(name: "DuckDuckGo", keyword: "d", urlTemplate: "https://duckduckgo.com/?q={searchTerms}", isDefault: false),
        ]))
    }
}
