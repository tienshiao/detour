import XCTest
import WebKit
@testable import Detour

final class ContentBlockerTests: XCTestCase {

    private let parser = EasyListParser()
    private let ruleListStore = WKContentRuleListStore.default()!

    private var cacheDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Detour/ContentBlocker", isDirectory: true)
    }

    // MARK: - Parser unit tests

    func testEscapeDollarSign() {
        // $ in a URL pattern should not produce an invalid regex
        let result = parser.parse(text: "example.com/hit$value\n")
        XCTAssertFalse(result.rules.isEmpty)
        let urlFilter = (result.rules[0]["trigger"] as? [String: Any])?["url-filter"] as? String ?? ""
        XCTAssertTrue(urlFilter.contains("\\$"), "Dollar sign should be escaped: \(urlFilter)")
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
        let textFile = cacheDir.appendingPathComponent("\(identifier).txt")
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

    /// Binary search to find a single rule that causes compilation to fail.
    private func bisectBadRule(rules: [[String: Any]], identifier: String) -> String? {
        if rules.count <= 1 {
            if let data = try? JSONSerialization.data(withJSONObject: rules, options: .prettyPrinted),
               let str = String(data: data, encoding: .utf8) {
                print("[BISECT] Found bad rule: \(str)")
                let urlFilter = (rules.first?["trigger"] as? [String: Any])?["url-filter"] as? String ?? "?"
                print("[BISECT] url-filter: \(urlFilter)")
                return urlFilter
            }
            return nil
        }

        let mid = rules.count / 2
        let left = Array(rules[..<mid])
        let right = Array(rules[mid...])

        if tryCompile(rules: left, identifier: "\(identifier)-L") != nil {
            return bisectBadRule(rules: left, identifier: "\(identifier)-L")
        }
        if tryCompile(rules: right, identifier: "\(identifier)-R") != nil {
            return bisectBadRule(rules: right, identifier: "\(identifier)-R")
        }

        // Neither half fails alone — interaction between rules
        return "Interaction between rules near index \(mid)"
    }
}
