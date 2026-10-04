import XCTest
@testable import Detour

/// TASK-132.4: the pure half of Detour's `declarativeNetRequest` header rules —
/// parsing what an extension passed to `updateSessionRules`, matching a request
/// against a rule's condition, and combining the changes of every matching rule
/// (`ExtensionHeaderRule`, `ExtensionHeaderRuleSet`). The rules in real contexts
/// against a fixture server are `ExtensionDeclarativeNetRequestTests`.
final class ExtensionHeaderRulesTests: XCTestCase {

    // MARK: - Fixtures

    /// The Claude extension's start-up rule (1.0.98), with the API host a parameter.
    private func claudeRule(host: String = "https://api.anthropic.com") -> [String: Any] {
        [
            "id": 1, "priority": 1,
            "action": [
                "type": "modifyHeaders",
                "requestHeaders": [
                    ["header": "User-Agent", "operation": "set", "value": "claude-browser-extension/1.0.98 (external) Mozilla/5.0"],
                    ["header": "anthropic-client-platform", "operation": "set", "value": "claude_browser_extension"],
                    ["header": "anthropic-client-version", "operation": "set", "value": "1.0.98"],
                ],
            ],
            "condition": ["urlFilter": "\(host)/*", "resourceTypes": ["xmlhttprequest", "other"]],
        ]
    }

    private func rule(id: Int = 1, priority: Int? = nil,
                      headers: [[String: Any]] = [["header": "x-test", "operation": "set", "value": "1"]],
                      condition: [String: Any] = [:]) -> [String: Any] {
        var rule: [String: Any] = [
            "id": id,
            "action": ["type": "modifyHeaders", "requestHeaders": headers],
            "condition": condition,
        ]
        if let priority { rule["priority"] = priority }
        return rule
    }

    private func parsed(_ raw: [String: Any], acceptedByWebKit: Bool = false,
                        file: StaticString = #filePath, line: UInt = #line) throws -> ExtensionHeaderRule {
        switch ExtensionHeaderRule.parse(raw, acceptedByWebKit: acceptedByWebKit) {
        case .success(let rule): return rule
        case .failure(let error):
            XCTFail("expected the rule to parse, got \(error)", file: file, line: line)
            throw error
        }
    }

    private func failure(_ raw: [String: Any], acceptedByWebKit: Bool = false) -> ExtensionHeaderRule.ParseError? {
        if case .failure(let error) = ExtensionHeaderRule.parse(raw, acceptedByWebKit: acceptedByWebKit) { return error }
        return nil
    }

    private func matches(_ condition: [String: Any], _ url: String, method: String = "GET",
                         file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        let rule = try parsed(self.rule(condition: condition), file: file, line: line)
        return rule.condition.matches(url: try XCTUnwrap(URL(string: url)), method: method)
    }

    private func set(_ rules: [ExtensionHeaderRule]) throws -> ExtensionHeaderRuleSet {
        try ExtensionHeaderRuleSet().updated(removing: [], adding: rules)
    }

    private func summary(_ changes: [ExtensionHeaderRule.HeaderChange]) -> [String] {
        changes.map { "\($0.operation.rawValue) \($0.header)\($0.value.map { "=\($0)" } ?? "")" }
    }

    // MARK: - Parsing (positive)

    func testParsesTheClaudeExtensionsRule() throws {
        let rule = try parsed(claudeRule())
        XCTAssertEqual(rule.id, 1)
        XCTAssertEqual(rule.priority, 1)
        XCTAssertFalse(rule.acceptedByWebKit)
        XCTAssertEqual(summary(rule.changes), [
            "set User-Agent=claude-browser-extension/1.0.98 (external) Mozilla/5.0",
            "set anthropic-client-platform=claude_browser_extension",
            "set anthropic-client-version=1.0.98",
        ])
        XCTAssertTrue(rule.condition.coversScriptRequests)
        XCTAssertTrue(rule.condition.matches(url: URL(string: "https://api.anthropic.com/v1/messages")!, method: "POST"))
        XCTAssertFalse(rule.condition.matches(url: URL(string: "https://claude.ai/api/organizations")!, method: "GET"))
        // What getSessionRules answers is the rule as the extension passed it.
        XCTAssertEqual(rule.original as NSDictionary, claudeRule() as NSDictionary)
    }

    func testPriorityDefaultsToOneAndAcceptsWholeDoubles() throws {
        XCTAssertEqual(try parsed(rule()).priority, 1)
        // A JS bridge delivers every number as a double.
        var raw = rule()
        raw["id"] = NSNumber(value: 7.0)
        raw["priority"] = NSNumber(value: 3.0)
        let rule = try parsed(raw)
        XCTAssertEqual(rule.id, 7)
        XCTAssertEqual(rule.priority, 3)
    }

    func testRemoveNeedsNoValue() throws {
        let rule = try parsed(self.rule(headers: [["header": "X-Gone", "operation": "remove"]]))
        XCTAssertEqual(summary(rule.changes), ["remove X-Gone"])
        XCTAssertEqual(rule.changes[0].payload as NSDictionary, ["header": "X-Gone", "operation": "remove"] as NSDictionary)
    }

    func testResponseHeadersAreAllowedOnARuleWebKitHolds() throws {
        var raw = rule()
        var action = raw["action"] as! [String: Any]
        action["responseHeaders"] = [["header": "x-frame-options", "operation": "remove"]]
        raw["action"] = action
        XCTAssertNoThrow(try parsed(raw, acceptedByWebKit: true))
    }

    // MARK: - Parsing (negative)

    func testOtherActionsAreNotHeaderRules() {
        XCTAssertEqual(failure(["id": 1, "action": ["type": "block"], "condition": [:] as [String: Any]]), .notAHeaderRule)
        // modifyHeaders with response headers only is WebKit's business alone.
        XCTAssertEqual(failure(["id": 1, "action": ["type": "modifyHeaders",
                                                    "responseHeaders": [["header": "x", "operation": "remove"]]],
                                "condition": [:] as [String: Any]]), .notAHeaderRule)
        XCTAssertEqual(failure(["id": 1]), .notAHeaderRule)
        XCTAssertFalse(ExtensionHeaderRule.isHeaderRule(["action": "modifyHeaders"]))
    }

    func testMalformedRulesAreInvalid() {
        func assertInvalid(_ raw: [String: Any], _ what: String, line: UInt = #line) {
            guard case .invalid = failure(raw) else {
                XCTFail("\(what) should be invalid, got \(String(describing: failure(raw)))", line: line)
                return
            }
        }
        var noID = rule(); noID["id"] = nil
        assertInvalid(noID, "a rule with no id")
        var zeroID = rule(); zeroID["id"] = 0
        assertInvalid(zeroID, "id 0")
        var fractionalID = rule(); fractionalID["id"] = 1.5
        assertInvalid(fractionalID, "a fractional id")
        var booleanID = rule(); booleanID["id"] = true
        assertInvalid(booleanID, "a boolean id")
        var badPriority = rule(); badPriority["priority"] = 0
        assertInvalid(badPriority, "priority 0")
        var noCondition = rule(); noCondition["condition"] = nil
        assertInvalid(noCondition, "a rule with no condition")

        assertInvalid(rule(headers: []), "an empty requestHeaders list")
        assertInvalid(rule(headers: [["operation": "set", "value": "1"]]), "an entry with no header")
        assertInvalid(rule(headers: [["header": "bad name", "operation": "set", "value": "1"]]), "a header name with a space")
        assertInvalid(rule(headers: [["header": "x:y", "operation": "set", "value": "1"]]), "a header name with a colon")
        assertInvalid(rule(headers: [["header": "x", "operation": "replace", "value": "1"]]), "an unknown operation")
        assertInvalid(rule(headers: [["header": "x", "operation": "set"]]), "set without a value")
        assertInvalid(rule(headers: [["header": "x", "operation": "append", "value": 3]]), "a numeric value")
        assertInvalid(rule(headers: [["header": "x", "operation": "remove", "value": "1"]]), "remove with a value")
        assertInvalid(rule(headers: [["header": "x", "operation": "set", "value": "a\r\nInjected: 1"]]),
                      "a value carrying a line break")

        assertInvalid(rule(condition: ["urlFilter": ""]), "an empty urlFilter")
        assertInvalid(rule(condition: ["urlFilter": "a", "regexFilter": "b"]), "both filters")
        assertInvalid(rule(condition: ["resourceTypes": [String]()]), "an empty resourceTypes list")
        assertInvalid(rule(condition: ["resourceTypes": ["script"], "excludedResourceTypes": ["image"]]),
                      "both resource type lists")
        assertInvalid(rule(condition: ["requestMethods": "get"]), "requestMethods that is not a list")
        assertInvalid(rule(condition: ["requestDomains": [String]()]), "an empty requestDomains list")
    }

    /// A condition Detour's matching does not implement is never guessed at:
    /// ignoring it could put a header on a request the rule excluded.
    func testConditionsDetourDoesNotMatchAreUnsupported() {
        for key in ["initiatorDomains", "excludedInitiatorDomains", "domainType", "tabIds", "excludedTabIds",
                    "domains", "excludedDomains", "responseHeaders", "somethingNew"] {
            guard case .unsupported(let reason) = failure(rule(condition: [key: ["example.com"]])) else {
                XCTFail("a condition with `\(key)` should be unsupported")
                continue
            }
            XCTAssertTrue(reason.contains(key), "the reason should name the key: \(reason)")
        }
        guard case .unsupported = failure(rule(condition: ["regexFilter": "(unclosed"])) else {
            return XCTFail("a regexFilter that does not compile should be unsupported")
        }
    }

    func testResponseHeadersAreUnsupportedOnARuleOnlyDetourHolds() {
        var raw = rule()
        var action = raw["action"] as! [String: Any]
        action["responseHeaders"] = [["header": "x-frame-options", "operation": "remove"]]
        raw["action"] = action
        guard case .unsupported = failure(raw, acceptedByWebKit: false) else {
            return XCTFail("Detour cannot change a response header, so it must not keep such a rule alone")
        }
    }

    func testIntegerRejectsWhatIsNotAWholeNumber() {
        XCTAssertEqual(ExtensionHeaderRule.integer(3), 3)
        XCTAssertEqual(ExtensionHeaderRule.integer(NSNumber(value: 3.0)), 3)
        XCTAssertNil(ExtensionHeaderRule.integer(3.5))
        XCTAssertNil(ExtensionHeaderRule.integer(true))
        XCTAssertNil(ExtensionHeaderRule.integer("3"))
        XCTAssertNil(ExtensionHeaderRule.integer(Double.infinity))
        XCTAssertNil(ExtensionHeaderRule.integer(nil))
    }

    // MARK: - urlFilter

    func testURLFilterIsASubstringMatchWithWildcards() throws {
        XCTAssertTrue(try matches(["urlFilter": "api.example.com/v1"], "https://api.example.com/v1/messages"))
        XCTAssertFalse(try matches(["urlFilter": "api.example.com/v2"], "https://api.example.com/v1/messages"))
        XCTAssertTrue(try matches(["urlFilter": "https://api.example.com/*"], "https://api.example.com/"))
        XCTAssertTrue(try matches(["urlFilter": "example*messages"], "https://api.example.com/v1/messages"))
        // Regex metacharacters in a filter are literal text.
        XCTAssertFalse(try matches(["urlFilter": "api.example.com"], "https://apiXexample.com/"))
        XCTAssertTrue(try matches(["urlFilter": "/a?b=(1)"], "https://example.com/a?b=(1)"))
    }

    func testURLFilterIsCaseInsensitiveUnlessAskedOtherwise() throws {
        XCTAssertTrue(try matches(["urlFilter": "EXAMPLE.com/Path"], "https://example.com/path"))
        XCTAssertFalse(try matches(["urlFilter": "EXAMPLE.com/Path", "isUrlFilterCaseSensitive": true],
                                   "https://example.com/path"))
        XCTAssertTrue(try matches(["urlFilter": "example.com/path", "isUrlFilterCaseSensitive": true],
                                  "https://example.com/path"))
    }

    func testURLFilterAnchors() throws {
        // `|` at the start and at the end.
        XCTAssertTrue(try matches(["urlFilter": "|https://example.com"], "https://example.com/a"))
        XCTAssertFalse(try matches(["urlFilter": "|example.com"], "https://example.com/a"))
        XCTAssertTrue(try matches(["urlFilter": ".json|"], "https://example.com/a.json"))
        XCTAssertFalse(try matches(["urlFilter": ".json|"], "https://example.com/a.json?x=1"))
        // `||` anchors at a domain boundary: the host or a subdomain of it.
        XCTAssertTrue(try matches(["urlFilter": "||example.com"], "https://example.com/a"))
        XCTAssertTrue(try matches(["urlFilter": "||example.com"], "http://api.example.com/a"))
        XCTAssertFalse(try matches(["urlFilter": "||example.com"], "https://notexample.com/a"))
        XCTAssertFalse(try matches(["urlFilter": "||example.com"], "https://other.test/?next=example.com"))
        // `^` is a separator: not a letter, digit or one of _-.%, or the end.
        XCTAssertTrue(try matches(["urlFilter": "||example.com^"], "https://example.com/a"))
        XCTAssertTrue(try matches(["urlFilter": "||example.com^"], "https://example.com"))
        XCTAssertTrue(try matches(["urlFilter": "||example.com^"], "https://example.com:8080/a"))
        XCTAssertFalse(try matches(["urlFilter": "||example.com^"], "https://example.company/a"))
    }

    func testTheFragmentIsNotMatched() throws {
        XCTAssertFalse(try matches(["urlFilter": "secret"], "https://example.com/a#secret"))
        XCTAssertTrue(try matches(["urlFilter": "/a|"], "https://example.com/a#secret"))
    }

    func testRegexFilter() throws {
        XCTAssertTrue(try matches(["regexFilter": "^https://api\\.example\\.com/v[0-9]+/"], "https://api.example.com/v12/x"))
        XCTAssertFalse(try matches(["regexFilter": "^https://api\\.example\\.com/v[0-9]+/"], "https://api.example.com/vx/x"))
        XCTAssertTrue(try matches(["regexFilter": "EXAMPLE"], "https://example.com/"))
        XCTAssertFalse(try matches(["regexFilter": "EXAMPLE", "isUrlFilterCaseSensitive": true], "https://example.com/"))
    }

    func testNoFilterMatchesEveryURL() throws {
        XCTAssertTrue(try matches([:], "https://anything.test/at/all"))
    }

    // MARK: - Resource types, methods, domains

    /// The wrappers only ever see script-made requests, which Chrome types
    /// `xmlhttprequest`.
    func testResourceTypesDecideWhetherScriptRequestsAreCovered() throws {
        XCTAssertTrue(try matches(["resourceTypes": ["xmlhttprequest", "other"]], "https://example.com/"))
        XCTAssertTrue(try matches(["resourceTypes": ["XMLHttpRequest"]], "https://example.com/"))
        XCTAssertFalse(try matches(["resourceTypes": ["main_frame", "sub_frame", "image"]], "https://example.com/"))
        XCTAssertFalse(try matches(["excludedResourceTypes": ["xmlhttprequest"]], "https://example.com/"))
        XCTAssertTrue(try matches(["excludedResourceTypes": ["image"]], "https://example.com/"))
        XCTAssertTrue(try matches([:], "https://example.com/"), "with neither list a rule covers everything but main_frame")
    }

    func testRequestMethods() throws {
        XCTAssertTrue(try matches(["requestMethods": ["post"]], "https://example.com/", method: "POST"))
        XCTAssertFalse(try matches(["requestMethods": ["post"]], "https://example.com/", method: "GET"))
        XCTAssertFalse(try matches(["excludedRequestMethods": ["get"]], "https://example.com/", method: "get"))
        XCTAssertTrue(try matches(["excludedRequestMethods": ["get"]], "https://example.com/", method: "PUT"))
    }

    func testRequestDomains() throws {
        XCTAssertTrue(try matches(["requestDomains": ["example.com"]], "https://example.com/"))
        XCTAssertTrue(try matches(["requestDomains": ["example.com"]], "https://API.example.com/"))
        XCTAssertFalse(try matches(["requestDomains": ["example.com"]], "https://notexample.com/"))
        XCTAssertFalse(try matches(["excludedRequestDomains": ["example.com"]], "https://api.example.com/"))
        XCTAssertTrue(try matches(["excludedRequestDomains": ["example.com"]], "https://other.test/"))
        XCTAssertFalse(try matches(["requestDomains": ["example.com"], "excludedRequestDomains": ["api.example.com"]],
                                   "https://api.example.com/"))
    }

    // MARK: - Combining rules

    func testOnlyMatchingRulesContribute() throws {
        let rules = try set([
            try parsed(rule(id: 1, headers: [["header": "x-a", "operation": "set", "value": "a"]],
                            condition: ["urlFilter": "||a.test"])),
            try parsed(rule(id: 2, headers: [["header": "x-b", "operation": "set", "value": "b"]],
                            condition: ["urlFilter": "||b.test"])),
        ])
        XCTAssertEqual(summary(rules.changes(for: URL(string: "https://a.test/")!, method: "GET",
                                             includingAcceptedByWebKit: true)), ["set x-a=a"])
        XCTAssertEqual(summary(rules.changes(for: URL(string: "https://c.test/")!, method: "GET",
                                             includingAcceptedByWebKit: true)), [])
    }

    /// Chrome's rule: the higher priority decides, a lower one may only append
    /// to what was set or appended, and nothing follows a remove.
    func testHigherPriorityWinsAndOnlyAppendFollows() throws {
        let url = URL(string: "https://example.com/")!
        let rules = try set([
            try parsed(rule(id: 1, priority: 1, headers: [
                ["header": "X-Set", "operation": "set", "value": "low"],
                ["header": "x-set", "operation": "append", "value": "low-append"],
                ["header": "x-removed", "operation": "set", "value": "low"],
                ["header": "x-removed", "operation": "append", "value": "low"],
                ["header": "x-appended", "operation": "remove"],
                ["header": "x-appended", "operation": "append", "value": "low"],
                ["header": "x-only-low", "operation": "set", "value": "low"],
            ])),
            try parsed(rule(id: 2, priority: 5, headers: [
                ["header": "x-set", "operation": "set", "value": "high"],
                ["header": "x-removed", "operation": "remove"],
                ["header": "x-appended", "operation": "append", "value": "high"],
            ])),
        ])
        XCTAssertEqual(summary(rules.changes(for: url, method: "GET", includingAcceptedByWebKit: true)), [
            "set x-set=high",
            "remove x-removed",
            "append x-appended=high",
            "append x-set=low-append",
            "append x-appended=low",
            "set x-only-low=low",
        ])
    }

    func testEqualPrioritiesGoByID() throws {
        let rules = try set([
            try parsed(rule(id: 9, headers: [["header": "x", "operation": "set", "value": "nine"]])),
            try parsed(rule(id: 3, headers: [["header": "x", "operation": "set", "value": "three"]])),
        ])
        XCTAssertEqual(summary(rules.changes(for: URL(string: "https://example.com/")!, method: "GET",
                                             includingAcceptedByWebKit: true)), ["set x=three"])
    }

    /// In a page WebKit applies the rules it accepted, so Detour answers only
    /// with the ones it holds alone; the worker gets both.
    func testRulesWebKitAcceptedAreLeftToWebKitInAPage() throws {
        let rules = try set([
            try parsed(rule(id: 1, headers: [["header": "user-agent", "operation": "set", "value": "ua"]]),
                       acceptedByWebKit: true),
            try parsed(rule(id: 2, headers: [["header": "x-custom", "operation": "set", "value": "c"]]),
                       acceptedByWebKit: false),
        ])
        let url = URL(string: "https://example.com/")!
        XCTAssertEqual(summary(rules.changes(for: url, method: "GET", includingAcceptedByWebKit: false)),
                       ["set x-custom=c"])
        XCTAssertEqual(summary(rules.changes(for: url, method: "GET", includingAcceptedByWebKit: true)),
                       ["set user-agent=ua", "set x-custom=c"])
    }

    func testOnlyHTTPRequestsAreChanged() throws {
        let rules = try set([try parsed(rule())])
        for url in ["webkit-extension://abc/page.html", "data:text/plain,hi", "blob:https://example.com/1", "file:///etc/hosts"] {
            XCTAssertTrue(rules.changes(for: URL(string: url)!, method: "GET", includingAcceptedByWebKit: true).isEmpty,
                          "\(url) must not be changed")
        }
        XCTAssertEqual(rules.changes(for: URL(string: "HTTP://example.com/")!, method: "GET",
                                     includingAcceptedByWebKit: true).count, 1)
    }

    // MARK: - The rule set

    func testUpdateRemovesThenAddsAndAnIDHasOneKeeper() throws {
        var rules = try set([try parsed(rule(id: 1)), try parsed(rule(id: 2))])
        rules = try rules.updated(removing: [1, 99], adding: [try parsed(rule(id: 3))])
        XCTAssertEqual(rules.rules.keys.sorted(), [2, 3])

        // The same id again, now held by WebKit: it replaces Detour's own copy.
        rules = try rules.updated(removing: [], adding: [try parsed(rule(id: 2), acceptedByWebKit: true)])
        XCTAssertEqual(rules.rules[2]?.acceptedByWebKit, true)
        XCTAssertEqual(rules.originalsKeptByDetourAlone().compactMap { $0["id"] as? Int }, [3])

        rules = try rules.updated(removing: [2, 3], adding: [])
        XCTAssertTrue(rules.isEmpty)
    }

    func testUpdatedLeavesTheReceiverUntouched() throws {
        let rules = try set([try parsed(rule(id: 1))])
        _ = try rules.updated(removing: [1], adding: [try parsed(rule(id: 2))])
        XCTAssertEqual(rules.rules.keys.sorted(), [1], "a dry run must not change anything")
    }

    func testOriginalsAreByIDAndFilterable() throws {
        let rules = try set([try parsed(rule(id: 5)), try parsed(rule(id: 2)),
                             try parsed(rule(id: 8), acceptedByWebKit: true)])
        XCTAssertEqual(rules.originalsKeptByDetourAlone().compactMap { $0["id"] as? Int }, [2, 5])
        XCTAssertEqual(rules.originalsKeptByDetourAlone(ruleIDs: [5, 8]).compactMap { $0["id"] as? Int }, [5])
        XCTAssertEqual(rules.originalsKeptByDetourAlone(ruleIDs: []).count, 0)
    }

    func testTheRuleCountIsCapped() throws {
        let full = try ExtensionHeaderRuleSet().updated(
            removing: [], adding: try (1...ExtensionHeaderRuleSet.maximumRuleCount).map { try parsed(rule(id: $0)) })
        XCTAssertEqual(full.rules.count, ExtensionHeaderRuleSet.maximumRuleCount)
        XCTAssertThrowsError(try full.updated(removing: [], adding: [try parsed(rule(id: 999_999))]))
        // Replacing one, or removing one first, stays within the cap.
        XCTAssertNoThrow(try full.updated(removing: [], adding: [try parsed(rule(id: 1))]))
        XCTAssertNoThrow(try full.updated(removing: [1], adding: [try parsed(rule(id: 999_999))]))
    }
}
