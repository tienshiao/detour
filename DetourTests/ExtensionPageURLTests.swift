import XCTest
@testable import Detour

/// TASK-14: the URL rewrite that moves an open extension page from a dead
/// context origin to the reloaded context's origin. Pure — no WebKit, no store.
final class ExtensionPageURLTests: XCTestCase {

    private let oldBase = URL(string: "webkit-extension://11111111-1111-1111-1111-111111111111/")!
    private let newBase = URL(string: "webkit-extension://22222222-2222-2222-2222-222222222222/")!

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    // MARK: - rewriteExtensionPageURL

    func testRewritePreservesPathQueryAndFragment() throws {
        let page = try url("webkit-extension://11111111-1111-1111-1111-111111111111/options/index.html?tab=general&x=1#privacy")

        let rewritten = try XCTUnwrap(rewriteExtensionPageURL(page, from: oldBase, to: newBase))

        XCTAssertEqual(rewritten.absoluteString,
                       "webkit-extension://22222222-2222-2222-2222-222222222222/options/index.html?tab=general&x=1#privacy")
    }

    func testRewriteKeepsBarePath() throws {
        let page = try url("webkit-extension://11111111-1111-1111-1111-111111111111/popup.html")

        XCTAssertEqual(try XCTUnwrap(rewriteExtensionPageURL(page, from: oldBase, to: newBase)).absoluteString,
                       "webkit-extension://22222222-2222-2222-2222-222222222222/popup.html")
    }

    /// The root page of the old origin, with and without a trailing slash. A
    /// host-only URL has an empty path, which must not produce a nil URL.
    func testRewriteHandlesOriginRoot() throws {
        XCTAssertEqual(try XCTUnwrap(rewriteExtensionPageURL(oldBase, from: oldBase, to: newBase)).absoluteString,
                       "webkit-extension://22222222-2222-2222-2222-222222222222/")

        let hostOnly = try url("webkit-extension://11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(try XCTUnwrap(rewriteExtensionPageURL(hostOnly, from: oldBase, to: newBase)).absoluteString,
                       "webkit-extension://22222222-2222-2222-2222-222222222222/")
    }

    /// An extension page's query routinely carries a URL of its own; the escapes
    /// must survive untouched rather than being decoded and re-encoded.
    func testRewritePreservesPercentEncoding() throws {
        let page = try url("webkit-extension://11111111-1111-1111-1111-111111111111/save.html?url=https%3A%2F%2Fexample.com%2Fa%20b&q=%26")

        XCTAssertEqual(try XCTUnwrap(rewriteExtensionPageURL(page, from: oldBase, to: newBase)).absoluteString,
                       "webkit-extension://22222222-2222-2222-2222-222222222222/save.html?url=https%3A%2F%2Fexample.com%2Fa%20b&q=%26")
    }

    /// WebKit's base URL host is a lowercase UUID, but a URL round-tripped
    /// through persistence or written by a page's own link can carry any case,
    /// and an origin check that missed would leave the page on a dead origin.
    /// (A hex UUID with letters — an all-digit one would make this vacuous.)
    func testRewriteIsCaseInsensitiveInHost() throws {
        let lowerBase = try url("webkit-extension://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/")
        let upperBase = try url("webkit-extension://AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/")
        let lowerPage = try url("webkit-extension://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/p.html")
        let upperPage = try url("webkit-extension://AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/p.html")

        XCTAssertNotNil(rewriteExtensionPageURL(lowerPage, from: upperBase, to: newBase),
                        "a base URL host in another case must still match the page's")
        XCTAssertNotNil(rewriteExtensionPageURL(upperPage, from: lowerBase, to: newBase),
                        "a page URL host in another case must still match the base's")
        XCTAssertEqual(try XCTUnwrap(rewriteExtensionPageURL(upperPage, from: lowerBase, to: newBase)).absoluteString,
                       "webkit-extension://22222222-2222-2222-2222-222222222222/p.html",
                       "the rewritten URL takes its origin verbatim from the new base")
    }

    // MARK: - rewriteExtensionPageURL: what must be left alone

    func testRewriteRejectsAnotherExtensionsOrigin() throws {
        let other = try url("webkit-extension://33333333-3333-3333-3333-333333333333/options.html")

        XCTAssertNil(rewriteExtensionPageURL(other, from: oldBase, to: newBase),
                     "another extension's page must not be moved by this context's reload")
    }

    func testRewriteRejectsOrdinaryWebPage() throws {
        XCTAssertNil(rewriteExtensionPageURL(try url("https://example.com/options.html"),
                                             from: oldBase, to: newBase),
                     "an https page must never be rewritten")
        XCTAssertNil(rewriteExtensionPageURL(try url("about:blank"), from: oldBase, to: newBase))
        XCTAssertNil(rewriteExtensionPageURL(try url("detour-error://x/"), from: oldBase, to: newBase))
    }

    /// A page whose host matches but whose scheme does not is a different origin.
    func testRewriteRejectsMatchingHostUnderAnotherScheme() throws {
        let page = try url("https://11111111-1111-1111-1111-111111111111/options.html")

        XCTAssertNil(rewriteExtensionPageURL(page, from: oldBase, to: newBase))
    }

    // MARK: - isExtensionPage

    func testIsExtensionPageMatchesOriginHost() throws {
        let host = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

        XCTAssertTrue(isExtensionPage(try url("webkit-extension://\(host)/a/b.html?q=1"), ofOriginHost: host))
        XCTAssertTrue(isExtensionPage(try url("webkit-extension://\(host.uppercased())/a.html"), ofOriginHost: host),
                      "host comparison is case-insensitive")
        XCTAssertTrue(isExtensionPage(try url("webkit-extension://\(host)/"), ofOriginHost: host.uppercased()))
    }

    func testIsExtensionPageRejectsOtherOriginsAndSchemes() throws {
        let host = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

        XCTAssertFalse(isExtensionPage(try url("webkit-extension://33333333-3333-3333-3333-333333333333/a.html"),
                                       ofOriginHost: host))
        XCTAssertFalse(isExtensionPage(try url("https://\(host)/a.html"), ofOriginHost: host))
        XCTAssertFalse(isExtensionPage(try url("webkit-extension://\(host)/a.html"), ofOriginHost: ""),
                       "an empty host must never match — an unloaded context has no origin to compare")
        XCTAssertFalse(isExtensionPage(try url("about:blank"), ofOriginHost: host))
    }
}
