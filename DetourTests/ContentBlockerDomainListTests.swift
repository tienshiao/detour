import XCTest
import WebKit
@testable import Detour

/// A rule's domain list with both included and excluded domains
/// (`a.example,~sub.a.example##.sel`, `$domain=a.example|~sub.a.example`)
/// used to compile to a trigger with an `if-domain` **and** an
/// `unless-domain`. WebKit takes one page condition per trigger and rejects
/// the rule ("more than one condition"), so the bad-rule search stripped it
/// and it never applied (TASK-201).
///
/// The parser follows Adblock Plus: for a page, the most specific listed
/// domain decides. An exclusion outside every included domain changes
/// nothing and is dropped; an exclusion under an included domain makes the
/// condition `if-top-url`, with patterns for the included domains less the
/// excluded subtrees.
@MainActor
final class ContentBlockerDomainListTests: XCTestCase {

    private let parser = EasyListParser()

    private func condition(_ included: [String], _ excluded: [String]) -> EasyListParser.DomainCondition {
        EasyListParser.domainCondition(included: included, excluded: excluded)
    }

    private func topURLPatterns(_ included: [String], _ excluded: [String],
                                file: StaticString = #filePath, line: UInt = #line) -> [NSRegularExpression] {
        guard case .ifTopURL(let patterns) = condition(included, excluded) else {
            XCTFail("expected if-top-url, got \(condition(included, excluded))", file: file, line: line)
            return []
        }
        return patterns.compactMap {
            let regex = try? NSRegularExpression(pattern: $0)
            XCTAssertNotNil(regex, "invalid pattern \($0)", file: file, line: line)
            return regex
        }
    }

    private func matches(_ patterns: [NSRegularExpression], _ url: String) -> Bool {
        patterns.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
    }

    private func trigger(_ rule: [String: Any]) -> [String: Any] {
        rule["trigger"] as? [String: Any] ?? [:]
    }

    private static let conditionKeys = ["if-domain", "unless-domain", "if-top-url", "unless-top-url",
                                        "if-frame-url", "unless-frame-url"]

    // MARK: - The condition

    func testOnlyIncludedOrOnlyExcludedDomainsKeepTheirCondition() {
        XCTAssertEqual(condition([], []), .everyPage)
        XCTAssertEqual(condition(["a.example", "b.example"], []), .ifDomain(["*a.example", "*b.example"]))
        XCTAssertEqual(condition([], ["a.example"]), .unlessDomain(["*a.example"]))
    }

    /// `a.example,~b.example`: b.example is no page of a.example, so the
    /// exclusion changes nothing.
    func testAnExclusionOutsideEveryIncludedDomainIsDropped() {
        XCTAssertEqual(condition(["a.example"], ["b.example"]), .ifDomain(["*a.example"]))
        // Excluding a parent: the included domain is more specific and wins.
        XCTAssertEqual(condition(["sub.a.example"], ["a.example"]), .ifDomain(["*sub.a.example"]))
        // Not a subdomain, only the same suffix.
        XCTAssertEqual(condition(["a.example"], ["notua.example"]), .ifDomain(["*a.example"]))
    }

    func testAnIncludedDomainThatIsAlsoExcludedIsDropped() {
        XCTAssertEqual(condition(["a.example", "b.example"], ["a.example"]), .ifDomain(["*b.example"]))
        XCTAssertEqual(condition(["a.example"], ["a.example"]), .noPage)
    }

    func testASubdomainExclusionLeavesTheRestOfTheDomain() {
        let patterns = topURLPatterns(["a.example"], ["sub.a.example"])
        for url in ["http://a.example/", "https://a.example:8443/x", "https://www.a.example/",
                    "https://deep.www.a.example/p?q", "http://s.a.example/", "http://su.a.example/",
                    "http://subway.a.example/", "http://asub.a.example/", "http://sab.a.example/",
                    "http://sub-x.a.example/", "http://sub.www.a.example/",
                    "http://user@www.a.example/", "http://user:pw@a.example/"] {
            XCTAssertTrue(matches(patterns, url), url)
        }
        for url in ["http://sub.a.example/", "https://sub.a.example:8080/", "https://x.sub.a.example/",
                    "https://y.x.sub.a.example/a.example/", "http://b.example/", "http://nota.example/",
                    "http://a.example.evil.example/", "http://evil.example/?u=http://a.example/",
                    "http://evil.example/http://a.example/",
                    // User info is no label: `x@sub` is not a label other than `sub`.
                    "http://x@sub.a.example/", "http://u:p@x.sub.a.example/"] {
            XCTAssertFalse(matches(patterns, url), url)
        }
    }

    func testSeveralExclusionsAndIncludedDomains() {
        let patterns = topURLPatterns(["example.com", "other.org"], ["sub.example.com", "ads.example.com", "s.example.com"])
        for url in ["https://example.com/", "https://www.example.com/", "https://su.example.com/",
                    "https://ad.example.com/", "https://adsx.example.com/", "https://other.org/",
                    "https://sub.other.org/"] {
            XCTAssertTrue(matches(patterns, url), url)
        }
        for url in ["https://sub.example.com/", "https://ads.example.com/", "https://s.example.com/",
                    "https://x.ads.example.com/"] {
            XCTAssertFalse(matches(patterns, url), url)
        }
    }

    func testAnExclusionDeeperDownLeavesItsParent() {
        let patterns = topURLPatterns(["a.example"], ["x.sub.a.example"])
        for url in ["https://a.example/", "https://sub.a.example/", "https://y.sub.a.example/",
                    "https://x.a.example/", "https://xx.sub.a.example/"] {
            XCTAssertTrue(matches(patterns, url), url)
        }
        for url in ["https://x.sub.a.example/", "https://z.x.sub.a.example/"] {
            XCTAssertFalse(matches(patterns, url), url)
        }
    }

    /// `a.example,~sub.a.example,in.sub.a.example`: the most specific listed
    /// domain decides, so in.sub.a.example is back in.
    func testAnIncludedDomainUnderAnExclusionIsIncludedAgain() {
        let patterns = topURLPatterns(["a.example", "in.sub.a.example"], ["sub.a.example"])
        for url in ["https://a.example/", "https://in.sub.a.example/", "https://x.in.sub.a.example/"] {
            XCTAssertTrue(matches(patterns, url), url)
        }
        for url in ["https://sub.a.example/", "https://out.sub.a.example/"] {
            XCTAssertFalse(matches(patterns, url), url)
        }
    }

    // MARK: - Parser output

    func testAMixedElementHidingRuleHasOneCondition() {
        let dropped = parser.parse(text: "a.example,~b.example##.sel\n").rules
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(trigger(dropped[0])["if-domain"] as? [String], ["*a.example"])
        XCTAssertNil(trigger(dropped[0])["unless-domain"])

        let excluded = parser.parse(text: "a.example,~sub.a.example##.sel\n").rules
        XCTAssertEqual(excluded.count, 1)
        XCTAssertNotNil(trigger(excluded[0])["if-top-url"])
        XCTAssertEqual(Set(trigger(excluded[0]).keys).intersection(Self.conditionKeys), ["if-top-url"])
    }

    func testAMixedDomainOptionHasOneCondition() {
        let dropped = parser.parse(text: "||ads.example^$script,domain=a.example|~b.example\n").rules
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(trigger(dropped[0])["if-domain"] as? [String], ["*a.example"])
        XCTAssertNil(trigger(dropped[0])["unless-domain"])

        for line in ["||ads.example^$domain=a.example|~sub.a.example", "@@||ads.example^$domain=a.example|~sub.a.example"] {
            let rules = parser.parse(text: line + "\n").rules
            XCTAssertEqual(rules.count, 1, line)
            XCTAssertEqual(Set(trigger(rules[0]).keys).intersection(Self.conditionKeys), ["if-top-url"], line)
        }
    }

    func testARuleWhoseOnlyDomainIsExcludedAgainIsSkipped() {
        let result = parser.parse(text: "a.example,~a.example##.sel\n||ads.example^$domain=a.example|~a.example\n")
        XCTAssertTrue(result.rules.isEmpty, "\(result.rules)")
        XCTAssertEqual(result.skippedCount, 2)
    }

    /// The rules hide, block and except on the included domain and not on
    /// the excluded subdomain, evaluated the way WebKit evaluates a list.
    func testMixedRulesApplyOnTheIncludedDomainOnly() {
        let evaluator = RuleListEvaluator(parser.parse(text: """
        a.example,~sub.a.example##.sel
        /ad.js$domain=a.example|~sub.a.example
        /ok.js
        @@/ok.js$domain=a.example|~sub.a.example
        """).rules)

        for page in ["http://a.example/", "http://www.a.example/"] {
            XCTAssertEqual(evaluator.hiddenSelectors("http://cdn.example/x.png", on: page, type: "image"), [".sel"], page)
            XCTAssertTrue(evaluator.blocks("http://cdn.example/ad.js", on: page, type: "script"), page)
            XCTAssertFalse(evaluator.blocks("http://cdn.example/ok.js", on: page, type: "script"), page)
        }
        for page in ["http://sub.a.example/", "http://x.sub.a.example/"] {
            XCTAssertEqual(evaluator.hiddenSelectors("http://cdn.example/x.png", on: page, type: "image"), [], page)
            XCTAssertFalse(evaluator.blocks("http://cdn.example/ad.js", on: page, type: "script"), page)
            XCTAssertTrue(evaluator.blocks("http://cdn.example/ok.js", on: page, type: "script"), page)
        }
    }

    /// A pattern-less cosmetic exception names its pages with `domain=`;
    /// an exclusion under them makes it an `if-top-url` page-wide exception.
    func testAPatternlessCosmeticExceptionWithAnExcludedSubdomain() {
        let rules = parser.parse(text: """
        ##.generic-ad
        @@$generichide,domain=a.example|~sub.a.example
        """).rules
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(ContentRuleListChunks.isPageWideException(rules[1]))
        let evaluator = RuleListEvaluator(rules)
        XCTAssertTrue(evaluator.genericHiding("http://a.example/", on: "http://a.example/").isEmpty)
        XCTAssertEqual(evaluator.genericHiding("http://sub.a.example/", on: "http://sub.a.example/"), [".generic-ad"])
    }

    /// A mixed element-hiding rule is domain-specific: it goes after the
    /// `$generichide` exceptions, which must not undo it.
    func testAMixedElementHidingRuleIsInTheDomainSpecificSection() {
        let rules = parser.parse(text: """
        a.example,~sub.a.example##.specific
        ##.generic
        @@||a.example^$generichide
        """).rules
        let selectors = rules.compactMap { ($0["action"] as? [String: Any])?["selector"] as? String }
        XCTAssertEqual(selectors, [".generic", ".specific"])
        XCTAssertEqual(RuleListEvaluator(rules).hiddenSelectors("http://a.example/x.png", on: "http://a.example/", type: "image"),
                       [".specific"])
    }

    // MARK: - Internationalised domains

    /// easylist-cookie's two rules the bad-rule search stripped: their
    /// domain lists held `przesył-energii.pl` and `wanderwege-graubünden.ch`,
    /// which became `przesy%C5%82-energii.pl` (percent-encoded, upper-case
    /// hex) where WebKit needs lower-case ASCII, i.e. punycode.
    func testAnInternationalisedDomainBecomesPunycode() {
        let hiding = parser.parse(text: "przesył-energii.pl,wanderwege-graubünden.ch##.cookie\n").rules
        XCTAssertEqual(trigger(hiding[0])["if-domain"] as? [String],
                       ["*xn--przesy-energii-lnc.pl", "*xn--wanderwege-graubnden-4ec.ch"])
        let blocking = parser.parse(text: "||ads.example^$domain=bücher.de\n").rules
        XCTAssertEqual(trigger(blocking[0])["if-domain"] as? [String], ["*xn--bcher-kva.de"])
    }

    /// `xn--ü.de` is no host IDNA can encode: `encodedHost` percent-encodes
    /// it (upper-case hex, which WebKit rejects), so it is left out. A list
    /// whose every included domain is left out applies on no page, not on
    /// every page.
    func testAnIncludedDomainThatDoesNotEncodeIsLeftOut() {
        let kept = parser.parse(text: "bücher.de,xn--ü.de##.cookie\n").rules
        XCTAssertEqual(trigger(kept[0])["if-domain"] as? [String], ["*xn--bcher-kva.de"])

        let result = parser.parse(text: """
        xn--ü.de##.cookie
        xn--ü.de,~b.example##.cookie
        ||ads.example^$domain=xn--ü.de
        @@$generichide,domain=xn--ü.de
        """)
        XCTAssertTrue(result.rules.isEmpty, "\(result.rules)")
        XCTAssertEqual(result.skippedCount, 4)
    }

    // MARK: - WebKit accepts the output

    func testWebKitCompilesEveryMixedRule() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TASK201-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))

        let text = """
        a.example,~b.example##.dropped-exclusion
        a.example,~sub.a.example##.sub-exclusion
        example.com,other.org,~sub.example.com,~ads.example.com,~s.example.com##.several
        a.example,~x.sub.a.example,in.x.sub.a.example##.nested
        ~a.example,~b.example##.only-exclusions
        przesył-energii.pl,~www.przesył-energii.pl##.idn
        ||ads.example^$script,domain=a.example|~b.example
        ||ads.example^$domain=a.example|~sub.a.example
        @@||ads.example^$domain=a.example|~sub.a.example
        @@$generichide,domain=a.example|~sub.a.example
        @@$elemhide,domain=a.example|~sub.a.example
        """
        let rules = parser.parse(text: text).rules
        XCTAssertEqual(rules.count, text.split(separator: "\n").count)
        for rule in rules {
            XCTAssertLessThanOrEqual(Set(trigger(rule).keys).intersection(Self.conditionKeys).count, 1, "\(rule)")
            let json = String(data: try JSONSerialization.data(withJSONObject: [rule]), encoding: .utf8)!
            let error: Error? = await withCheckedContinuation { continuation in
                store.compileContentRuleList(forIdentifier: "task201", encodedContentRuleList: json) { _, error in
                    continuation.resume(returning: error)
                }
            }
            XCTAssertNil(error, "WebKit rejected \(json): \(String(describing: error))")
        }
    }
}
