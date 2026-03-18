import XCTest
@testable import Detour

final class ContentScriptMatcherTests: XCTestCase {

    // MARK: - <all_urls>

    func testAllURLsMatchesHTTP() {
        let matcher = ContentScriptMatcher(patterns: ["<all_urls>"])
        XCTAssertTrue(matcher.matches(URL(string: "http://example.com")!))
    }

    func testAllURLsMatchesHTTPS() {
        let matcher = ContentScriptMatcher(patterns: ["<all_urls>"])
        XCTAssertTrue(matcher.matches(URL(string: "https://example.com/page")!))
    }

    func testAllURLsRejectsFileScheme() {
        let matcher = ContentScriptMatcher(patterns: ["<all_urls>"])
        XCTAssertFalse(matcher.matches(URL(string: "file:///tmp/test.html")!))
    }

    func testAllURLsRejectsAboutScheme() {
        let matcher = ContentScriptMatcher(patterns: ["<all_urls>"])
        XCTAssertFalse(matcher.matches(URL(string: "about:blank")!))
    }

    // MARK: - Exact host

    func testExactHostMatches() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/*"])
        XCTAssertTrue(matcher.matches(URL(string: "https://example.com/page")!))
    }

    func testExactHostRejectsSubdomain() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/*"])
        XCTAssertFalse(matcher.matches(URL(string: "https://sub.example.com/page")!))
    }

    func testExactHostRejectsDifferentDomain() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/*"])
        XCTAssertFalse(matcher.matches(URL(string: "https://other.com/page")!))
    }

    // MARK: - Wildcard subdomain

    func testWildcardSubdomainMatchesSubdomain() {
        let matcher = ContentScriptMatcher(patterns: ["https://*.example.com/*"])
        XCTAssertTrue(matcher.matches(URL(string: "https://sub.example.com/page")!))
    }

    func testWildcardSubdomainMatchesBareDomain() {
        let matcher = ContentScriptMatcher(patterns: ["https://*.example.com/*"])
        XCTAssertTrue(matcher.matches(URL(string: "https://example.com/page")!))
    }

    func testWildcardSubdomainMatchesDeepSubdomain() {
        let matcher = ContentScriptMatcher(patterns: ["https://*.example.com/*"])
        XCTAssertTrue(matcher.matches(URL(string: "https://a.b.example.com/")!))
    }

    func testWildcardSubdomainRejectsDifferentDomain() {
        let matcher = ContentScriptMatcher(patterns: ["https://*.example.com/*"])
        XCTAssertFalse(matcher.matches(URL(string: "https://notexample.com/")!))
    }

    // MARK: - Wildcard host

    func testWildcardHostMatchesAnyDomain() {
        let matcher = ContentScriptMatcher(patterns: ["https://*/*"])
        XCTAssertTrue(matcher.matches(URL(string: "https://anything.com/page")!))
    }

    // MARK: - Scheme matching

    func testSchemeWildcardMatchesHTTP() {
        let matcher = ContentScriptMatcher(patterns: ["*://example.com/*"])
        XCTAssertTrue(matcher.matches(URL(string: "http://example.com/")!))
    }

    func testSchemeWildcardMatchesHTTPS() {
        let matcher = ContentScriptMatcher(patterns: ["*://example.com/*"])
        XCTAssertTrue(matcher.matches(URL(string: "https://example.com/")!))
    }

    func testSchemeWildcardRejectsFTP() {
        let matcher = ContentScriptMatcher(patterns: ["*://example.com/*"])
        XCTAssertFalse(matcher.matches(URL(string: "ftp://example.com/")!))
    }

    func testHTTPOnlyRejectsHTTPS() {
        let matcher = ContentScriptMatcher(patterns: ["http://example.com/*"])
        XCTAssertFalse(matcher.matches(URL(string: "https://example.com/")!))
    }

    // MARK: - Path matching

    func testSpecificPathMatches() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/foo/*"])
        XCTAssertTrue(matcher.matches(URL(string: "https://example.com/foo/bar")!))
    }

    func testSpecificPathRejectsNonMatching() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/foo/*"])
        XCTAssertFalse(matcher.matches(URL(string: "https://example.com/bar/baz")!))
    }

    func testExactPathMatches() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/page.html"])
        XCTAssertTrue(matcher.matches(URL(string: "https://example.com/page.html")!))
    }

    func testExactPathRejectsOther() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/page.html"])
        XCTAssertFalse(matcher.matches(URL(string: "https://example.com/other.html")!))
    }

    // MARK: - Multiple patterns

    func testMultiplePatternsMatchesEither() {
        let matcher = ContentScriptMatcher(patterns: [
            "https://example.com/*",
            "https://other.com/*"
        ])
        XCTAssertTrue(matcher.matches(URL(string: "https://example.com/page")!))
        XCTAssertTrue(matcher.matches(URL(string: "https://other.com/page")!))
    }

    func testMultiplePatternsRejectsNonMatching() {
        let matcher = ContentScriptMatcher(patterns: [
            "https://example.com/*",
            "https://other.com/*"
        ])
        XCTAssertFalse(matcher.matches(URL(string: "https://third.com/page")!))
    }

    // MARK: - Invalid patterns

    func testInvalidPatternIsIgnored() {
        let matcher = ContentScriptMatcher(patterns: ["not a pattern"])
        XCTAssertFalse(matcher.matches(URL(string: "https://example.com")!))
    }

    func testEmptyPatternsMatchNothing() {
        let matcher = ContentScriptMatcher(patterns: [])
        XCTAssertFalse(matcher.matches(URL(string: "https://example.com")!))
    }

    // MARK: - JS guard condition

    func testJSGuardConditionForAllURLs() {
        let matcher = ContentScriptMatcher(patterns: ["<all_urls>"])
        let js = matcher.jsGuardCondition()
        XCTAssertTrue(js.contains("location.protocol"))
        XCTAssertTrue(js.contains("http:") || js.contains("https:"))
    }

    func testJSGuardConditionForExactHost() {
        let matcher = ContentScriptMatcher(patterns: ["https://example.com/*"])
        let js = matcher.jsGuardCondition()
        XCTAssertTrue(js.contains("example.com"))
        XCTAssertTrue(js.contains("https:"))
    }
}
