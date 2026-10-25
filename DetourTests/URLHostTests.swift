import XCTest
@testable import Detour

/// URLs rebuilt from a page URL's host keep IPv6 brackets and the port
/// (TASK-198). Navigating to `http://[::1]:3000/` used to crash Detour: the
/// optimistic favicon URL was interpolated from `URL.host`, which Foundation
/// returns without brackets.
final class URLHostTests: XCTestCase {

    private func fallback(_ string: String) -> String? {
        faviconFallbackURL(for: URL(string: string)!)?.absoluteString
    }

    // MARK: - The Foundation behaviour this guards against

    /// `URL.host` drops the brackets, `URLComponents.host` keeps them. Pinned
    /// here so a Foundation change shows up as a failing test, not a crash.
    func testFoundationStripsTheBracketsFromAnIPv6Host() {
        let url = URL(string: "http://[::1]:3000/")!
        XCTAssertEqual(url.host, "::1")
        XCTAssertEqual(url.port, 3000)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.host, "[::1]")
        XCTAssertNil(URL(string: "http://::1/favicon.ico"), "the old interpolation's result does not parse")
    }

    // MARK: - authorityHost

    func testAuthorityHostBracketsAnIPv6Literal() {
        XCTAssertEqual(URL(string: "http://[::1]:3000/")!.authorityHost, "[::1]")
        XCTAssertEqual(URL(string: "https://[2001:db8::1]/a")!.authorityHost, "[2001:db8::1]")
    }

    func testAuthorityHostLeavesOtherHostsAlone() {
        XCTAssertEqual(URL(string: "https://example.com/a")!.authorityHost, "example.com")
        XCTAssertEqual(URL(string: "http://127.0.0.1:8080/")!.authorityHost, "127.0.0.1")
        XCTAssertEqual(URL(string: "http://localhost:3000/")!.authorityHost, "localhost")
    }

    func testAuthorityHostIsNilWithoutAHost() {
        XCTAssertNil(URL(string: "about:blank")!.authorityHost)
        XCTAssertNil(URL(string: "file:///tmp/x")!.authorityHost)
        XCTAssertNil(URL(string: "data:text/html,hi")!.authorityHost)
    }

    // MARK: - faviconFallbackURL

    func testTheFallbackForAnIPv6HostKeepsTheBrackets() {
        XCTAssertEqual(fallback("http://[::1]/"), "http://[::1]/favicon.ico")
        XCTAssertEqual(fallback("https://[2001:db8::1]/a/b"), "https://[2001:db8::1]/favicon.ico")
    }

    func testTheFallbackForAnIPv6HostKeepsThePort() {
        XCTAssertEqual(fallback("http://[::1]:3000/"), "http://[::1]:3000/favicon.ico")
    }

    /// Origin semantics: the server on another port is another origin. The
    /// old code fetched `http://localhost/favicon.ico` for a `localhost:3000`
    /// page — the wrong server, or none.
    func testTheFallbackKeepsThePortOfAnyHost() {
        XCTAssertEqual(fallback("http://localhost:3000/app"), "http://localhost:3000/favicon.ico")
        XCTAssertEqual(fallback("http://127.0.0.1:8080/x"), "http://127.0.0.1:8080/favicon.ico")
    }

    func testTheFallbackForAnIPv4Host() {
        XCTAssertEqual(fallback("http://127.0.0.1/x"), "http://127.0.0.1/favicon.ico")
    }

    func testTheFallbackForANormalHostDropsPathQueryFragmentAndCredentials() {
        XCTAssertEqual(fallback("https://example.com/a/b?q=1#frag"), "https://example.com/favicon.ico")
        XCTAssertEqual(fallback("https://user:secret@example.com/"), "https://example.com/favicon.ico")
    }

    func testThereIsNoFallbackWithoutAHost() {
        XCTAssertNil(fallback("about:blank"))
        XCTAssertNil(fallback("file:///tmp/page.html"))
        XCTAssertNil(fallback("data:text/html,hi"))
    }

    // MARK: - faviconSiteKey

    func testTheSiteKeyIsTheHostForAURLWithoutAPort() {
        XCTAssertEqual(faviconSiteKey(for: URL(string: "https://example.com/a")), "example.com")
        XCTAssertEqual(faviconSiteKey(for: URL(string: "https://Example.COM/a")), "example.com")
    }

    func testTheSiteKeyCarriesANonDefaultPort() {
        XCTAssertEqual(faviconSiteKey(for: URL(string: "http://localhost:3000/")), "localhost:3000")
        XCTAssertEqual(faviconSiteKey(for: URL(string: "http://[::1]:3000/")), "[::1]:3000")
        XCTAssertEqual(faviconSiteKey(for: URL(string: "http://[::1]/")), "[::1]")
    }

    /// WebKit reports `http://localhost:80/` as `http://localhost/`; both are
    /// the same site.
    func testTheSiteKeyDropsTheSchemesDefaultPort() {
        XCTAssertEqual(faviconSiteKey(for: URL(string: "http://localhost:80/")), "localhost")
        XCTAssertEqual(faviconSiteKey(for: URL(string: "https://example.com:443/")), "example.com")
        XCTAssertEqual(faviconSiteKey(for: URL(string: "https://example.com:80/")), "example.com:80")
    }

    func testThereIsNoSiteKeyWithoutAHost() {
        XCTAssertNil(faviconSiteKey(for: nil))
        XCTAssertNil(faviconSiteKey(for: URL(string: "about:blank")))
    }

    // MARK: - The faux address bar

    private func displayHost(_ string: String) -> String {
        BrowserTab(id: UUID(), title: "", url: URL(string: string), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: UUID()).displayHost
    }

    /// The sidebar's address bar read `::1` for `http://[::1]:8898/`.
    func testTheAddressBarShowsAnIPv6HostInBrackets() {
        XCTAssertEqual(displayHost("http://[::1]:8898/"), "[::1]")
    }

    func testTheAddressBarHostIsUnchangedForOtherHosts() {
        XCTAssertEqual(displayHost("https://www.example.com/a"), "example.com")
        XCTAssertEqual(displayHost("http://localhost:3000/"), "localhost")
        XCTAssertEqual(displayHost("http://127.0.0.1/"), "127.0.0.1")
        XCTAssertEqual(displayHost("about:blank"), "")
    }

    // MARK: - securityOriginHost

    /// `WKSecurityOrigin.host` brackets an IPv6 literal (checked against WebKit:
    /// `[::1]` for `http://[::1]:8898/`).
    func testABracketedOriginHostMatchesAnIPv6PageURL() {
        let url = URL(string: "http://[::1]:3000/page")!
        XCTAssertTrue(securityOriginHost("[::1]", isHostOf: url))
        XCTAssertFalse(securityOriginHost("[::2]", isHostOf: url))
    }

    func testAnOriginHostMatchesWithoutCase() {
        let url = URL(string: "https://fav.test/page")!
        XCTAssertTrue(securityOriginHost("FAV.test", isHostOf: url))
        XCTAssertFalse(securityOriginHost("other.test", isHostOf: url))
        XCTAssertFalse(securityOriginHost("", isHostOf: URL(string: "about:blank")!))
    }
}
