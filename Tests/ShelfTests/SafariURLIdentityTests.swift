import XCTest
@testable import Shelf

final class SafariURLIdentityTests: XCTestCase {
    func testCanonicalURLIgnoresSchemeWWWFragmentAndTrackingParameters() throws {
        let first = try XCTUnwrap(URL(string: "https://www.Example.com/articles/swift/?utm_source=newsletter&b=2&a=1#comments"))
        let second = try XCTUnwrap(URL(string: "http://example.com/articles/swift?a=1&b=2"))

        XCTAssertEqual(
            SafariURLIdentity(url: first).canonical,
            SafariURLIdentity(url: second).canonical
        )
    }

    func testCanonicalURLRemovesTrailingSlashAndClickIdentifiers() throws {
        let first = try XCTUnwrap(URL(string: "https://example.com/story/?fbclid=123"))
        let second = try XCTUnwrap(URL(string: "https://example.com/story"))

        XCTAssertEqual(
            SafariURLIdentity(url: first).canonical,
            SafariURLIdentity(url: second).canonical
        )
    }

    func testRegistrableDomainHandlesCommonMultipartSuffixes() throws {
        let url = try XCTUnwrap(URL(string: "https://news.research.example.co.uk/article"))

        XCTAssertEqual(SafariURLIdentity(url: url).registrableDomain, "example.co.uk")
    }

    func testPathTermsDiscardGenericSegments() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/index/swift-async-history.html"))

        XCTAssertEqual(
            SafariURLIdentity(url: url).pathTerms,
            Set(["swift", "async", "history"])
        )
    }
}
