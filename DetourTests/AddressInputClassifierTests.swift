import XCTest
@testable import Detour

/// Typed palette input read as a URL or a search (TASK-83).
final class AddressInputClassifierTests: XCTestCase {

    private func url(_ input: String) -> String? {
        AddressInputClassifier.directURL(from: input)?.absoluteString
    }

    // MARK: - localhost

    func testLocalhostNavigatesOverHTTP() {
        XCTAssertEqual(url("localhost"), "http://localhost")
        XCTAssertEqual(url("localhost:4000"), "http://localhost:4000")
        XCTAssertEqual(url("localhost:4000/path?q=a:b#frag"), "http://localhost:4000/path?q=a:b#frag")
        XCTAssertEqual(url("localhost/path"), "http://localhost/path")
        XCTAssertEqual(url("app.localhost:3000"), "http://app.localhost:3000")
        XCTAssertEqual(url("LOCALHOST:4000"), "http://LOCALHOST:4000")
    }

    // MARK: - Explicit ports

    func testDotlessHostWithPortNavigatesOverHTTP() {
        XCTAssertEqual(url("myhost:8080"), "http://myhost:8080")
        XCTAssertEqual(url("intranet:8080/dashboard"), "http://intranet:8080/dashboard")
    }

    func testDottedHostWithNonStandardPortNavigatesOverHTTP() {
        XCTAssertEqual(url("example.com:8443"), "http://example.com:8443")
    }

    func testPort443KeepsHTTPS() {
        XCTAssertEqual(url("example.com:443"), "https://example.com:443")
        XCTAssertEqual(url("myhost:443"), "https://myhost:443")
    }

    func testInvalidPortsSearch() {
        XCTAssertNil(url("localhost:0"))
        XCTAssertNil(url("myhost:65536"))
        XCTAssertNil(url("myhost:99999"))
        XCTAssertNil(url("example.com:abc"))
        XCTAssertNil(url("myhost:"))
        XCTAssertNil(url(":8080"))
    }

    // MARK: - IP literals

    func testIPv4LiteralsNavigateOverHTTP() {
        XCTAssertEqual(url("127.0.0.1:3000"), "http://127.0.0.1:3000")
        XCTAssertEqual(url("192.168.1.10"), "http://192.168.1.10")
        XCTAssertEqual(url("10.0.0.2/admin"), "http://10.0.0.2/admin")
    }

    func testIPv6LiteralsNavigateOverHTTP() {
        XCTAssertEqual(url("[::1]:8080"), "http://[::1]:8080")
        XCTAssertEqual(url("[::1]"), "http://[::1]")
    }

    // MARK: - Dotted hosts and explicit schemes (unchanged)

    func testDottedHostWithoutPortDefaultsToHTTPS() {
        XCTAssertEqual(url("example.com"), "https://example.com")
        XCTAssertEqual(url("example.com/a/b?c=d:e"), "https://example.com/a/b?c=d:e")
    }

    func testExplicitSchemesAreKept() {
        XCTAssertEqual(url("http://example.com"), "http://example.com")
        XCTAssertEqual(url("https://localhost:4000"), "https://localhost:4000")
        XCTAssertEqual(url("HTTPS://example.com"), "HTTPS://example.com")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(url("  localhost:4000 "), "http://localhost:4000")
    }

    // MARK: - Searches

    func testPlainWordsAndPhrasesSearch() {
        XCTAssertNil(url("swift"))
        XCTAssertNil(url("foo bar"))
        XCTAssertNil(url("localhost 4000"))
        XCTAssertNil(url("example.com is down"))
        XCTAssertNil(url(""))
        XCTAssertNil(url("   "))
    }

    func testColonWithoutAPortSearches() {
        XCTAssertNil(url("note:todo"))
        XCTAssertNil(url("foo:bar"))
        XCTAssertNil(url("a:b:c"))
    }

    func testNumbersWithAColonSearch() {
        XCTAssertNil(url("10:30"))
        XCTAssertNil(url("16:9"))
    }
}
