import XCTest
import WebKit
@testable import Detour

final class ContentBlockerTests: XCTestCase {

    private let parser = EasyListParser()
    /// The test data directory's own rule list store, never the production
    /// app's `~/Library/WebKit/<bundle id>/ContentRuleLists/` (TASK-36).
    private let ruleListStore = ContentBlockerStorage.current.ruleListStore

    /// Downloaded filter list text, read only: the test data directory's cache,
    /// or else the production app's.
    private func cachedFilterListFile(_ identifier: String) -> URL {
        let own = ContentBlockerStorage.current.filterListCacheDirectory.appendingPathComponent("\(identifier).txt")
        if FileManager.default.fileExists(atPath: own.path) { return own }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(defaultDetourDataDirectoryName)/ContentBlocker/\(identifier).txt")
    }

    // MARK: - Storage per data directory (TASK-36)

    /// The default data directory keeps WebKit's default rule list store, the
    /// standard defaults and Detour/ContentBlocker, exactly as before.
    func testTheDefaultDataDirectoryKeepsTheSharedContentBlockerStorage() {
        let storage = ContentBlockerStorage.forDataDirectory(named: defaultDetourDataDirectoryName)
        XCTAssertTrue(storage.ruleListStore === WKContentRuleListStore.default())
        XCTAssertTrue(storage.defaults === UserDefaults.standard)
        XCTAssertEqual(storage.filterListCacheDirectory.standardizedFileURL.path,
                       FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                           .appendingPathComponent("Detour/ContentBlocker").standardizedFileURL.path)
    }

    /// Any other data directory, like the test host's, gets its own rule list
    /// store, defaults suite and filter list cache inside the data directory.
    func testAnIsolatedDataDirectoryGetsItsOwnContentBlockerStorage() throws {
        let name = WebKitStorageScope.currentDataDirectoryName
        guard name != defaultDetourDataDirectoryName else {
            throw XCTSkip("DETOUR_DATA_DIR is unset or \"Detour\"")
        }
        let storage = ContentBlockerStorage.current
        XCTAssertFalse(storage.ruleListStore === WKContentRuleListStore.default())
        XCTAssertFalse(storage.defaults === UserDefaults.standard)
        XCTAssertEqual(storage.filterListCacheDirectory.standardizedFileURL.path,
                       detourDataDirectory().appendingPathComponent("ContentBlocker").standardizedFileURL.path)

        // A list compiled here lands in the data directory, not in WebKit's
        // shared ContentRuleLists directory.
        let identifier = "task36-probe-\(UUID().uuidString.prefix(8))"
        let compiled = expectation(description: "compile")
        storage.ruleListStore.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: #"[{"trigger":{"url-filter":"task36"},"action":{"type":"block"}}]"#
        ) { list, error in
            XCTAssertNotNil(list, "\(String(describing: error))")
            compiled.fulfill()
        }
        wait(for: [compiled], timeout: 30)
        let ownDirectory = detourDataDirectory().appendingPathComponent("ContentRuleLists")
        let sharedDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebKit/\(Bundle.main.bundleIdentifier ?? "")/ContentRuleLists")
        let fileName = "ContentRuleList-\(identifier)"
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownDirectory.appendingPathComponent(fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedDirectory.appendingPathComponent(fileName).path))

        let removed = expectation(description: "remove")
        storage.ruleListStore.removeContentRuleList(forIdentifier: identifier) { _ in removed.fulfill() }
        wait(for: [removed], timeout: 30)
    }

    // MARK: - Parser unit tests

    func testEscapeDollarSign() {
        // $ in a URL pattern should not produce an invalid regex
        let result = parser.parse(text: "example.com/hit$value\n")
        XCTAssertFalse(result.rules.isEmpty)
        let urlFilter = (result.rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
        XCTAssertTrue(urlFilter.contains("\\$"), "Dollar sign should be escaped: \(urlFilter)")
    }

    func testBackslashEscaped() {
        // A literal backslash in a pattern must be escaped to \\ so the regex stays
        // valid and matches the backslash literally (interior + trailing cases).

        // Interior backslash: "example.com\path" — the \ must not form an escape
        // sequence with the following 'p'.
        let interior = parser.parse(text: "example.com\\path\n")
        XCTAssertFalse(interior.rules.isEmpty, "Interior backslash rule should compile")
        let interiorFilter = (interior.rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
        XCTAssertTrue(interiorFilter.contains("\\\\"), "Backslash should be escaped to \\\\: \(interiorFilter)")
        XCTAssertNotNil(try? NSRegularExpression(pattern: interiorFilter), "Produced regex must be valid: \(interiorFilter)")
        // The escaped backslash must match a literal backslash in the URL.
        let subject = "http://example.com\\path"
        let regex = try? NSRegularExpression(pattern: interiorFilter)
        let range = NSRange(subject.startIndex..., in: subject)
        XCTAssertNotNil(regex?.firstMatch(in: subject, range: range),
                        "Regex should match a URL containing a literal backslash: \(interiorFilter)")

        // Trailing backslash: "example.com\" would produce a dangling escape (invalid
        // regex) without the fix, causing the rule to be dropped.
        let trailing = parser.parse(text: "example.com\\\n")
        XCTAssertFalse(trailing.rules.isEmpty, "Trailing backslash rule should compile")
        let trailingFilter = (trailing.rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
        XCTAssertTrue(trailingFilter.hasSuffix("\\\\"), "Trailing backslash should be escaped: \(trailingFilter)")
        XCTAssertNotNil(try? NSRegularExpression(pattern: trailingFilter), "Produced regex must be valid: \(trailingFilter)")
    }

    func testCaretSeparatorNoBackslashW() {
        // ^ separator should expand without \w which WebKit doesn't support in character classes
        let result = parser.parse(text: "||example.com^\n")
        XCTAssertFalse(result.rules.isEmpty)
        let urlFilter = (result.rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
        XCTAssertFalse(urlFilter.contains("\\w"), "Should not contain \\w: \(urlFilter)")
        XCTAssertTrue(urlFilter.contains("a-zA-Z0-9_"), "Should use expanded character class: \(urlFilter)")
    }

    func testPingOptionRecognized() {
        // $ping should be recognized as an option and the rule skipped (unsupported)
        let result = parser.parse(text: "||example.com^$ping\n")
        XCTAssertTrue(result.rules.isEmpty, "Rules with $ping should be skipped")
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testAllOptionRecognized() {
        // $all should be recognized as an option (not become part of the URL pattern)
        let result = parser.parse(text: "||malware.com^$all\n")
        XCTAssertFalse(result.rules.isEmpty, "Rules with $all should compile")
        let urlFilter = (result.rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
        XCTAssertFalse(urlFilter.contains("all"), "Option should not leak into url-filter: \(urlFilter)")
    }

    // MARK: - Compile real filter lists

    /// Parses and compiles each cached filter list through WebKit to verify all generated rules are valid.
    func testCompileEasyList() throws {
        try compileFilterList(identifier: "easylist", name: "EasyList")
    }

    func testCompileEasyPrivacy() throws {
        try compileFilterList(identifier: "easyprivacy", name: "EasyPrivacy")
    }

    func testCompileEasyListCookie() throws {
        try compileFilterList(identifier: "easylist-cookie", name: "EasyList Cookie")
    }

    func testCompileUrlhausFilter() throws {
        try compileFilterList(identifier: "urlhaus-filter", name: "URLhaus Filter")
    }

    // MARK: - Helpers

    private func compileFilterList(identifier: String, name: String) throws {
        let textFile = cachedFilterListFile(identifier)
        guard FileManager.default.fileExists(atPath: textFile.path) else {
            throw XCTSkip("\(name) not cached at \(textFile.path) — run the app first to download it")
        }

        let text = try String(contentsOf: textFile, encoding: .utf8)
        let result = parser.parse(text: text)
        XCTAssertFalse(result.rules.isEmpty, "\(name) should produce rules")
        print("[\(name)] Parsed \(result.rules.count) rules (\(result.skippedCount) skipped)")

        // WebKit has a limit of ~150k rules per list; compile in chunks if needed
        let maxRules = 150_000
        let chunks = stride(from: 0, to: result.rules.count, by: maxRules).map {
            Array(result.rules[$0..<min($0 + maxRules, result.rules.count)])
        }

        for (index, chunk) in chunks.enumerated() {
            let chunkID = chunks.count == 1 ? identifier : "\(identifier)-test-\(index)"

            if let error = tryCompile(rules: chunk, identifier: "test-\(chunkID)") {
                // Verify that ContentRuleStore's fallback compilation handles this
                let ruleStore = ContentRuleStore()
                let compileExp = expectation(description: "Fallback compile \(name) chunk \(index)")
                var fallbackList: WKContentRuleList?

                ruleStore.compile(identifier: "fallback-\(chunkID)", rules: chunk) { list in
                    fallbackList = list
                    compileExp.fulfill()
                }

                wait(for: [compileExp], timeout: 120)
                XCTAssertNotNil(fallbackList, "\(name) chunk \(index) failed even with fallback: \(error.localizedDescription)")
                let removeExp = expectation(description: "Remove fallback \(name) chunk \(index)")
                ruleListStore.removeContentRuleList(forIdentifier: "fallback-\(chunkID)") { _ in removeExp.fulfill() }
                wait(for: [removeExp], timeout: 30)
            }
        }
    }

    private func tryCompile(rules: [[String: Any]], identifier: String) -> Error? {
        let jsonData = try! JSONSerialization.data(withJSONObject: rules)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        let exp = expectation(description: "Compile \(identifier)")
        var compileError: Error?

        ruleListStore.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: jsonString) { list, error in
            compileError = error
            if list != nil {
                self.ruleListStore.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 60)
        return compileError
    }
}
