import XCTest
@testable import Bamboo

final class AddressInputTests: XCTestCase {
    func testBareDomainBecomesHTTPS() {
        XCTAssertEqual(AddressInput.parse("github.com"), .url(URL(string: "https://github.com")!))
        XCTAssertEqual(AddressInput.parse("  news.ycombinator.com/item?id=1 "),
                       .url(URL(string: "https://news.ycombinator.com/item?id=1")!))
    }

    func testExplicitSchemeIsKept() {
        XCTAssertEqual(AddressInput.parse("http://example.com"), .url(URL(string: "http://example.com")!))
        XCTAssertEqual(AddressInput.parse("about:blank"), .url(URL(string: "about:blank")!))
    }

    func testLocalhostAndIPUseHTTP() {
        XCTAssertEqual(AddressInput.parse("localhost:3000"), .url(URL(string: "http://localhost:3000")!))
        XCTAssertEqual(AddressInput.parse("192.168.1.1"), .url(URL(string: "http://192.168.1.1")!))
    }

    func testTextIsSearch() {
        XCTAssertEqual(AddressInput.parse("rust ownership rules"), .search("rust ownership rules"))
        XCTAssertEqual(AddressInput.parse("swift"), .search("swift"))
        XCTAssertNil(AddressInput.parse("   "))
    }

    func testSearchURLEncodesQuery() {
        let url = SearchEngine.engine(.duckDuckGo).searchURL(for: "a&b c")
        XCTAssertEqual(url.absoluteString, "https://duckduckgo.com/?q=a%26b%20c")
    }
}
