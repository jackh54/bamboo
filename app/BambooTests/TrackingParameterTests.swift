import XCTest
@testable import Bamboo

final class TrackingParameterTests: XCTestCase {
    private func strip(_ address: String) -> String? {
        TrackingParameters.strip(URL(string: address)!)?.absoluteString
    }

    func testRemovesClickIdsAndCampaignTags() {
        XCTAssertEqual(strip("https://shop.example/item?id=7&utm_source=news&utm_medium=email&fbclid=abc"),
                       "https://shop.example/item?id=7")
        XCTAssertEqual(strip("https://example.com/?gclid=1&msclkid=2&_hsenc=3&mc_eid=4"), "https://example.com/")
    }

    func testKeepsOrderAndEncodingOfOtherParameters() {
        XCTAssertEqual(strip("https://example.com/search?q=a%26b%20c&igshid=x&page=2"),
                       "https://example.com/search?q=a%26b%20c&page=2")
    }

    func testKeepsFragment() {
        XCTAssertEqual(strip("https://example.com/post?ttclid=9#comments"), "https://example.com/post#comments")
    }

    func testReturnsNilWhenNothingToRemove() {
        XCTAssertNil(strip("https://example.com/?id=1&ref=home"))
        XCTAssertNil(strip("https://example.com/path"))
        // Only exact names and the utm_ prefix count.
        XCTAssertNil(strip("https://example.com/?gclid_like=1&xutm_source=2"))
    }

    func testMatchesNamesCaseSensitively() {
        XCTAssertEqual(strip("https://example.com/?hsCtaTracking=1&a=b"), "https://example.com/?a=b")
        XCTAssertNil(strip("https://example.com/?FBCLID=1"))
    }
}
