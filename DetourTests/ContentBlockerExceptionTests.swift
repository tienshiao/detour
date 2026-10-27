import XCTest
import WebKit
@testable import Detour

/// EasyList's `@@` rules that only switch element hiding off (`$generichide`,
/// `$elemhide`) must never cancel a network block rule, and `$document` must
/// allowlist a page fully (TASK-199).
///
/// WebKit has no "cancel cosmetic rules only" action: `ignore-previous-rules`
/// undoes every earlier action of its rule list for a load its trigger
/// matches. The parser therefore puts the element-hiding section first
/// (generic hiding, `$generichide` exceptions, domain-specific hiding,
/// `$elemhide` exceptions), and the block rules and network exceptions after
/// it, where a cosmetic exception cannot reach them.
///
/// The pure tests evaluate the parser's output the way WebKit evaluates a rule
/// list (`RuleListEvaluator`); the web view tests compile it for real.
@MainActor
final class ContentBlockerExceptionTests: XCTestCase {

    private let parser = EasyListParser()

    private func rules(_ text: String) -> [[String: Any]] {
        parser.parse(text: text).rules
    }

    // MARK: - Network blocking survives cosmetic exceptions

    /// The task's case: a generic network block rule plus EasyList's
    /// webcompat lines for 127.0.0.1 and an `$elemhide` exception.
    func testAGenericHideOrElemHideExceptionDoesNotCancelANetworkBlockRule() {
        let evaluator = RuleListEvaluator(rules("""
        /jquery.popunder.js
        @@://127.0.0.1$generichide
        @@://localhost:$generichide
        @@||example.com^$elemhide
        """))

        for page in ["http://127.0.0.1:8899/page.html", "http://localhost:8899/page.html",
                     "http://example.com/page.html", "http://www.example.com/", "http://lvh.me:8899/page.html"] {
            let script = popunderScript(onPageOf: page)
            XCTAssertTrue(evaluator.blocks(script, on: page, type: "script"), "\(script) on \(page) must stay blocked")
        }
    }

    /// No `ignore-previous-rules` that could match a load follows a block
    /// rule, unless it is a network exception or a `$document` allowlist.
    func testNoCosmeticExceptionFollowsABlockRule() throws {
        let compiled = rules("""
        ||ads.example^
        @@://127.0.0.1$generichide
        ##.generic-ad
        @@||example.com^$elemhide
        example.com##.specific-ad
        /jquery.popunder.js
        @@||ads.example/ok.js
        """)
        let firstBlock = try XCTUnwrap(compiled.firstIndex { actionType($0) == "block" })
        XCTAssertFalse(compiled[..<firstBlock].contains { actionType($0) == "block" })
        XCTAssertFalse(compiled[firstBlock...].contains { actionType($0) == "css-display-none" },
                       "element hiding comes before every block rule")
        XCTAssertFalse(compiled[firstBlock...].contains(where: ContentRuleListChunks.isPageWideException),
                       "no page-wide exception after the block rules when there is no $document rule")
        XCTAssertTrue(compiled[..<firstBlock].filter { actionType($0) == "ignore-previous-rules" }
                        .allSatisfy(ContentRuleListChunks.isPageWideException),
                      "the only exceptions ahead of the block rules are the cosmetic, page-wide ones")
    }

    // MARK: - Cosmetic behaviour

    private let cosmeticList = """
    ##.generic-ad
    127.0.0.1##.specific-ad
    example.com##.specific-ad
    other.example##.specific-ad
    @@://127.0.0.1$generichide
    @@||example.com^$elemhide
    """

    func testGenericHideTurnsOffOnlyGenericHidingOnItsPages() {
        let evaluator = RuleListEvaluator(rules(cosmeticList))

        // The document load and a third-party subresource load of the page:
        // WebKit adds element hiding from every load of the page.
        for (url, type) in [("http://127.0.0.1:8899/", "document"), ("http://cdn.other.example/x.png", "image")] {
            XCTAssertEqual(evaluator.hiddenSelectors(url, on: "http://127.0.0.1:8899/", type: type), [".specific-ad"],
                           "\(url): generic hiding off, the domain's own rule stays")
        }
        XCTAssertEqual(evaluator.hiddenSelectors("http://other.example/", on: "http://other.example/", type: "document"),
                       [".generic-ad", ".specific-ad"], "a page without the exception keeps both")
    }

    func testElemHideTurnsOffGenericAndSpecificHiding() {
        let evaluator = RuleListEvaluator(rules(cosmeticList))

        for page in ["http://example.com/", "http://www.example.com/a"] {
            XCTAssertEqual(evaluator.hiddenSelectors(page, on: page, type: "document"), [], page)
            XCTAssertEqual(evaluator.hiddenSelectors("http://cdn.other.example/x.png", on: page, type: "image"), [], page)
        }
    }

    /// Patterns that are not a plain domain are applied to the page URL.
    func testANonDomainPatternIsMatchedAgainstThePageURL() {
        let evaluator = RuleListEvaluator(rules("""
        ##.generic-ad
        /jquery.popunder.js
        @@://192.168.$generichide
        @@||www.google.*/search?$generichide
        """))

        XCTAssertEqual(evaluator.hiddenSelectors("http://192.168.1.1/", on: "http://192.168.1.1/", type: "document"), [])
        XCTAssertTrue(evaluator.blocks("http://192.168.1.1/jquery.popunder.js", on: "http://192.168.1.1/", type: "script"))
        XCTAssertEqual(evaluator.hiddenSelectors("https://www.google.com/search?q=a", on: "https://www.google.com/search?q=a",
                                                 type: "document"), [])
        XCTAssertEqual(evaluator.hiddenSelectors("https://www.google.com/maps", on: "https://www.google.com/maps",
                                                 type: "document"), [".generic-ad"])
    }

    /// `@@$generichide,domain=a|b`: no pattern, the pages are the domains.
    func testADomainOptionWithoutAPatternNamesThePages() {
        let evaluator = RuleListEvaluator(rules("""
        ##.generic-ad
        @@$generichide,domain=a.example|b.example
        """))

        XCTAssertEqual(evaluator.hiddenSelectors("https://www.a.example/", on: "https://www.a.example/", type: "document"), [])
        XCTAssertEqual(evaluator.hiddenSelectors("https://b.example/", on: "https://b.example/", type: "document"), [])
        XCTAssertEqual(evaluator.hiddenSelectors("https://c.example/", on: "https://c.example/", type: "document"),
                       [".generic-ad"])
    }

    /// Exceptions WebKit cannot express without also cancelling rules they do
    /// not mean are left out; they must never unblock the network.
    func testGenericBlockAndSpecificHideExceptionsCancelNothing() {
        let evaluator = RuleListEvaluator(rules("""
        ##.generic-ad
        site.example##.specific-ad
        /jquery.popunder.js
        @@||site.example^$genericblock
        @@||site.example^$specifichide
        """))

        XCTAssertTrue(evaluator.blocks("http://site.example/jquery.popunder.js", on: "http://site.example/", type: "script"))
        XCTAssertEqual(evaluator.hiddenSelectors("http://site.example/", on: "http://site.example/", type: "document"),
                       [".generic-ad", ".specific-ad"])
    }

    // MARK: - $document and plain network exceptions

    /// `$popup` maps to no resource type: kept, the exception would undo
    /// every block rule for its URLs. Block rules with these options are
    /// skipped, so there is nothing for it to undo.
    func testAnExceptionOnlyForTypesWithoutBlockRulesIsLeftOut() {
        let evaluator = RuleListEvaluator(rules("""
        /jquery.popunder.js
        ||ads.example^
        @@||accounts.google.com^$popup
        @@||ads.example/ws$websocket
        @@||ads.example/beacon$ping,xmlhttprequest
        """))

        XCTAssertTrue(evaluator.blocks("https://accounts.google.com/jquery.popunder.js", on: "https://accounts.google.com/",
                                       type: "script"))
        XCTAssertTrue(evaluator.blocks("https://ads.example/ws", on: "https://site.example/", type: "script"))
        XCTAssertFalse(evaluator.blocks("https://ads.example/beacon", on: "https://site.example/", type: "raw"),
                       "a mapped type keeps the exception")
        XCTAssertTrue(evaluator.blocks("https://ads.example/beacon", on: "https://site.example/", type: "script"))
    }

    func testADocumentExceptionAllowlistsThePage() {
        let evaluator = RuleListEvaluator(rules("""
        ##.generic-ad
        allowed.example##.specific-ad
        ||ads.example^
        /jquery.popunder.js
        @@||allowed.example^$document
        """))

        let page = "https://allowed.example/a"
        XCTAssertFalse(evaluator.blocks("https://ads.example/x.js", on: page, type: "script"))
        XCTAssertFalse(evaluator.blocks("https://allowed.example/jquery.popunder.js", on: page, type: "script"))
        XCTAssertEqual(evaluator.hiddenSelectors(page, on: page, type: "document"), [])
        XCTAssertTrue(evaluator.blocks("https://ads.example/x.js", on: "https://other.example/", type: "script"),
                      "other pages are not allowlisted")
    }

    /// A network exception now follows every block rule of its list, also one
    /// written after it in the file.
    func testANetworkExceptionAppliesToABlockRuleLaterInTheFile() {
        let evaluator = RuleListEvaluator(rules("""
        @@||ads.example/ok.js
        ||ads.example^
        """))

        XCTAssertFalse(evaluator.blocks("https://ads.example/ok.js", on: "https://site.example/", type: "script"))
        XCTAssertTrue(evaluator.blocks("https://ads.example/other.js", on: "https://site.example/", type: "script"))
    }

    /// `$important` block rules win over every exception, wherever they stand
    /// in the file (EasyPrivacy's `||googletagmanager.com/gtm.js$important,…`
    /// against its later `@@||googletagmanager.com/gtm.js$domain=…`).
    func testAnImportantBlockRuleWinsOverExceptions() {
        let evaluator = RuleListEvaluator(rules("""
        ||tags.example/gtm.js$important,domain=site.example
        @@||tags.example/gtm.js$domain=site.example|other.example
        @@||site.example^$document
        ||tags.example/plain.js
        @@||tags.example/plain.js
        """))

        XCTAssertTrue(evaluator.blocks("https://tags.example/gtm.js", on: "https://site.example/", type: "script"))
        XCTAssertFalse(evaluator.blocks("https://tags.example/gtm.js", on: "https://other.example/", type: "script"))
        XCTAssertFalse(evaluator.blocks("https://tags.example/plain.js", on: "https://site.example/", type: "script"),
                       "a rule without $important is still undone")
    }

    /// `$badfilter` disables the rule it repeats and compiles to nothing;
    /// an exception with it must not unblock anything.
    func testABadFilterRuleDisablesItsTargetAndCompilesToNothing() {
        let evaluator = RuleListEvaluator(rules("""
        ||ads.example^$script
        ||ads.example^$script,badfilter
        ||tracker.example^
        @@||tracker.example^$badfilter
        """))

        XCTAssertFalse(evaluator.blocks("https://ads.example/x.js", on: "https://site.example/", type: "script"))
        XCTAssertTrue(evaluator.blocks("https://tracker.example/x.js", on: "https://site.example/", type: "script"))
    }

    /// `$elemhide` covers `$generichide`; a rule with both turns all hiding off.
    func testElemHideWinsOverGenericHideOnTheSameRule() {
        let evaluator = RuleListEvaluator(rules("""
        ##.generic-ad
        site.example##.specific-ad
        @@||site.example^$generichide,elemhide
        """))

        XCTAssertEqual(evaluator.hiddenSelectors("https://site.example/", on: "https://site.example/", type: "document"), [])
    }

    /// An exception that only lifts a redirect or CSP rule (none is compiled)
    /// must not undo the block rules for its URLs.
    func testARedirectOrCSPExceptionIsLeftOut() {
        let evaluator = RuleListEvaluator(rules("""
        ||ads.example^
        @@||ads.example^$csp=script-src 'none'
        @@||ads.example/x.js$redirect=noop.js
        """))

        XCTAssertTrue(evaluator.blocks("https://ads.example/x.js", on: "https://site.example/", type: "script"))
    }

    // MARK: - The real lists

    /// EasyList as downloaded: a generically blocked script stays blocked on
    /// the hosts its `$generichide` lines name, and generic hiding is off there.
    func testTheRealEasyListBlocksOnItsGenericHideHosts() throws {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(defaultDetourDataDirectoryName)/ContentBlocker/easylist.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            throw XCTSkip("EasyList not cached at \(file.path)")
        }
        let evaluator = RuleListEvaluator(parser.parse(text: text).rules)

        for page in ["http://127.0.0.1:8899/page.html", "http://localhost:8899/page.html",
                     "https://accounts.google.com/", "https://github.com/", "http://lvh.me:8899/page.html"] {
            let script = popunderScript(onPageOf: page)
            XCTAssertTrue(evaluator.blocks(script, on: page, type: "script"), "\(script) on \(page)")
        }
        XCTAssertTrue(evaluator.genericHiding("http://127.0.0.1:8899/", on: "http://127.0.0.1:8899/").isEmpty)
        XCTAssertTrue(evaluator.genericHiding("https://github.com/", on: "https://github.com/").isEmpty)
        XCTAssertFalse(evaluator.genericHiding("http://lvh.me:8899/", on: "http://lvh.me:8899/").isEmpty)
    }

    // MARK: - Split lists (TASK-155)

    /// The cosmetic section is compiled together at the start of the first
    /// chunk; network exceptions and `$document` allowlists follow the block
    /// rules of every chunk; a cosmetic exception never follows a block rule.
    func testASplitListKeepsTheCosmeticSectionTogetherAndCarriesTheNetworkExceptions() {
        let compiled = rules("""
        ##.generic-ad
        @@://127.0.0.1$generichide
        example.com##.specific-ad
        @@||example.com^$elemhide
        ||ads0.example^
        ||ads1.example^
        ||ads2.example^
        @@||ads0.example/ok.js
        @@||site.example^$document
        """)
        let cosmetic = Array(compiled.prefix { actionType($0) != "block" })
        XCTAssertEqual(cosmetic.count, 4)
        let carried = compiled.filter { actionType($0) == "ignore-previous-rules" }.count - 2
        let cap = cosmetic.count + 1 + carried

        let chunks = ContentRuleListChunks.chunks(ofCompiledRules: compiled, maxRulesPerList: cap)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.rules.count <= cap })
        XCTAssertEqual(NSArray(array: Array(chunks[0].rules.prefix(4))), NSArray(array: cosmetic),
                       "the cosmetic section starts the first chunk, in order")
        for (index, chunk) in chunks.enumerated() {
            let firstBlock = chunk.rules.firstIndex { actionType($0) == "block" } ?? chunk.rules.endIndex
            XCTAssertFalse(chunk.rules[firstBlock...].contains { isCosmeticException($0, in: compiled) },
                           "chunk \(index): no cosmetic exception after a block rule")
            let evaluator = RuleListEvaluator(chunk.rules)
            XCTAssertFalse(evaluator.blocks("http://ads0.example/ok.js", on: "http://127.0.0.1/", type: "script"),
                           "chunk \(index) carries the network exception")
            XCTAssertFalse(evaluator.blocks("http://ads1.example/x.js", on: "http://site.example/", type: "script"),
                           "chunk \(index) carries the $document allowlist")
        }
        for host in ["ads0", "ads1", "ads2"] {
            XCTAssertTrue(chunks.contains {
                RuleListEvaluator($0.rules).blocks("http://\(host).example/x.js", on: "http://127.0.0.1/", type: "script")
            }, "\(host) stays blocked on 127.0.0.1 in its chunk")
        }
        XCTAssertEqual(chunks.map(\.countedRuleCount).reduce(0, +), compiled.count, "every rule counted once")
    }

    /// A list within the cap is compiled exactly as parsed.
    func testAListWithinTheCapIsOneChunkAsParsed() {
        let compiled = rules(cosmeticList + "\n/jquery.popunder.js\n")
        let chunks = ContentRuleListChunks.chunks(ofCompiledRules: compiled, maxRulesPerList: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(NSArray(array: chunks[0].rules), NSArray(array: compiled))
    }

    func testWhichRulesArePageWideExceptions() {
        XCTAssertTrue(ContentRuleListChunks.isPageWideException(
            ["trigger": ["url-filter": ".*", "if-domain": ["*a.example"]], "action": ["type": "ignore-previous-rules"]]))
        XCTAssertTrue(ContentRuleListChunks.isPageWideException(
            ["trigger": ["url-filter": ".*", "if-top-url": ["://127"]], "action": ["type": "ignore-previous-rules"]]))
        XCTAssertFalse(ContentRuleListChunks.isPageWideException(
            ["trigger": ["url-filter": "ads\\.example"], "action": ["type": "ignore-previous-rules"]]))
        XCTAssertFalse(ContentRuleListChunks.isPageWideException(
            ["trigger": ["url-filter": ".*", "if-domain": ["*a.example"]], "action": ["type": "block"]]))
    }

    // MARK: - Compiled lists from an older parser are recompiled

    func testACompiledListIsReusedOnlyWhenItsFormatIsCurrent() {
        XCTAssertGreaterThanOrEqual(EasyListParser.rulesFormatVersion, 2, "TASK-199 changed the compiled output")
        XCTAssertGreaterThanOrEqual(EasyListParser.rulesFormatVersion, 3,
                                    "TASK-201 changed mixed domain lists and internationalised domains")
        XCTAssertTrue(ContentBlockerManager.shouldReuseCompiledList(recordedFormat: EasyListParser.rulesFormatVersion))
        XCTAssertFalse(ContentBlockerManager.shouldReuseCompiledList(recordedFormat: nil),
                       "a list compiled before the format was recorded")
        XCTAssertFalse(ContentBlockerManager.shouldReuseCompiledList(recordedFormat: EasyListParser.rulesFormatVersion - 1))
    }

    // MARK: - In a real web view

    private var directory: URL!
    private var defaultsSuiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentBlockerExceptionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuiteName = "ContentBlockerExceptionTests.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private let webViewList = """
    ##.generic-ad
    127.0.0.1##.specific-ad
    site.example##.specific-ad
    /jquery.popunder.js
    @@://127.0.0.1$generichide
    @@||site.example^$elemhide
    @@||allowed.example^$document
    """

    private func compiledLists(_ text: String) async throws -> [WKContentRuleList] {
        try await compiledStore(text).lists
    }

    private func compiledStore(_ text: String) async throws -> (store: ContentRuleStore, lists: [WKContentRuleList]) {
        let storage = ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: directory),
            filterListCacheDirectory: directory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName)))
        let store = ContentRuleStore(storage: storage)
        let lists = await withCheckedContinuation { continuation in
            store.compile(identifier: "easylist", rules: rules(text)) { continuation.resume(returning: $0.lists) }
        }
        XCTAssertEqual(lists.count, 1)
        return (store, lists)
    }

    private struct PageResult {
        let blocked: [URL]
        let genericDisplay: String
        let specificDisplay: String
    }

    /// Loads a page on `pageURL` with a generic and a specific ad element, the
    /// generically blocked script on the page's own host, and an image from
    /// another host (a load the cosmetic exception must cover as well).
    private func load(_ pageURL: URL, lists: [WKContentRuleList], expectHidden: Bool) async throws -> PageResult {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        lists.forEach(configuration.userContentController.add)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
        let delegate = ExceptionRecordingNavigationDelegate()
        defer { webView.navigationDelegate = nil }
        webView.navigationDelegate = delegate
        let script = pageURL.appendingPathComponent("jquery.popunder.js")
        let html = """
        <html><body><div class="generic-ad">g</div><div class="specific-ad">s</div>
        <img src="http://cdn.other.example/pixel.png"><script src="\(script.absoluteString)"></script></body></html>
        """

        webView.loadHTMLString(html, baseURL: pageURL)
        try await waitUntil("the page finished loading") { delegate.finished }
        func display(_ selector: String) async throws -> String {
            try await webView.evaluateJavaScript(
                "getComputedStyle(document.querySelector('\(selector)')).display") as? String ?? "?"
        }
        if expectHidden {
            try await waitUntil("generic hiding applied", timeout: 5) { try await display(".generic-ad") == "none" }
        }
        // Let the subresource loads run out (an unblocked one fails at DNS).
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return PageResult(blocked: delegate.blocked, genericDisplay: try await display(".generic-ad"),
                          specificDisplay: try await display(".specific-ad"))
    }

    func testOn127001TheScriptIsBlockedAndOnlyGenericHidingIsOff() async throws {
        let lists = try await compiledLists(webViewList)
        // Not a port WebKit refuses outright (9 is one): nothing listens, the
        // loads fail after the content blocker has seen them.
        let page = URL(string: "http://127.0.0.1:61999/")!

        let result = try await load(page, lists: lists, expectHidden: false)

        XCTAssertTrue(result.blocked.contains(page.appendingPathComponent("jquery.popunder.js")),
                      "blocked: \(result.blocked)")
        XCTAssertNotEqual(result.genericDisplay, "none", "$generichide: generic hiding is off")
        XCTAssertEqual(result.specificDisplay, "none", "the domain's own hiding rule still applies")
    }

    func testOnAnotherHostBothHidingRulesApplyAndTheScriptIsBlocked() async throws {
        let lists = try await compiledLists(webViewList + "\nother.example##.specific-ad\n")
        let page = URL(string: "http://other.example/")!

        let result = try await load(page, lists: lists, expectHidden: true)

        XCTAssertTrue(result.blocked.contains(page.appendingPathComponent("jquery.popunder.js")),
                      "blocked: \(result.blocked)")
        XCTAssertEqual(result.genericDisplay, "none")
        XCTAssertEqual(result.specificDisplay, "none")
    }

    func testElemHideTurnsAllHidingOffButKeepsTheScriptBlocked() async throws {
        let lists = try await compiledLists(webViewList)
        let page = URL(string: "http://site.example/")!

        let result = try await load(page, lists: lists, expectHidden: false)

        XCTAssertTrue(result.blocked.contains(page.appendingPathComponent("jquery.popunder.js")),
                      "blocked: \(result.blocked)")
        XCTAssertNotEqual(result.genericDisplay, "none")
        XCTAssertNotEqual(result.specificDisplay, "none")
    }

    func testADocumentExceptionAllowlistsThePageInAWebView() async throws {
        let lists = try await compiledLists(webViewList + "\nallowed.example##.specific-ad\n")
        let page = URL(string: "http://allowed.example/")!

        let result = try await load(page, lists: lists, expectHidden: false)

        XCTAssertTrue(result.blocked.isEmpty, "blocked: \(result.blocked)")
        XCTAssertNotEqual(result.genericDisplay, "none")
        XCTAssertNotEqual(result.specificDisplay, "none")
    }

    // MARK: - Mixed included and excluded domains (TASK-201)

    /// `a.example,~sub.a.example##sel` and `$domain=a.example|~sub.a.example`
    /// used to carry two page conditions, which WebKit rejects; the list's
    /// bad-rule search then stripped them. They hide and block on the
    /// included domain and not on the excluded subdomain.
    private let mixedDomainList = """
    ##.generic-ad
    a.example,~sub.a.example,~b.example##.specific-ad
    /jquery.popunder.js$domain=a.example|~sub.a.example|~b.example
    """

    func testAMixedDomainListAppliesOnTheIncludedDomainInAWebView() async throws {
        let (store, lists) = try await compiledStore(mixedDomainList)
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 3, "no rule stripped as bad")

        for page in [URL(string: "http://a.example/")!, URL(string: "http://www.a.example/")!] {
            let result = try await load(page, lists: lists, expectHidden: true)
            XCTAssertEqual(result.specificDisplay, "none", "\(page)")
            XCTAssertTrue(result.blocked.contains(page.appendingPathComponent("jquery.popunder.js")),
                          "\(page) blocked: \(result.blocked)")
        }
    }

    func testAMixedDomainListDoesNotApplyOnTheExcludedSubdomainInAWebView() async throws {
        let lists = try await compiledLists(mixedDomainList)

        for page in [URL(string: "http://sub.a.example/")!, URL(string: "http://x.sub.a.example/")!] {
            let result = try await load(page, lists: lists, expectHidden: true)
            XCTAssertNotEqual(result.specificDisplay, "none", "\(page)")
            XCTAssertTrue(result.blocked.isEmpty, "\(page) blocked: \(result.blocked)")
        }
    }

    // MARK: - Helpers

    /// `/jquery.popunder.js` on the page's own scheme, host and port: a
    /// script EasyList blocks with a generic rule.
    private func popunderScript(onPageOf page: String) -> String {
        var components = URLComponents(string: page)!
        components.path = "/jquery.popunder.js"
        components.query = nil
        return components.string!
    }

    private func actionType(_ rule: [String: Any]) -> String? {
        (rule["action"] as? [String: Any])?["type"] as? String
    }

    /// A page-wide exception of the parser's cosmetic section (they come
    /// before the list's first block rule).
    private func isCosmeticException(_ rule: [String: Any], in list: [[String: Any]]) -> Bool {
        guard ContentRuleListChunks.isPageWideException(rule) else { return false }
        let firstBlock = list.firstIndex { actionType($0) == "block" } ?? list.endIndex
        return list[..<firstBlock].contains { NSDictionary(dictionary: $0).isEqual(to: rule) }
    }
}

/// Evaluates a compiled rule list for one load the way WebKit's content
/// blocker does (`ContentExtensionsBackend::actionsFromContentRuleList`): the
/// rules whose trigger matches, in list order, where an
/// `ignore-previous-rules` drops everything before it. A trigger matches when
/// its `url-filter` matches the load's URL, its resource and load types allow
/// the load, and its page condition (`if-domain` / `unless-domain` on the
/// page's host, `if-top-url` / `unless-top-url` on the page's URL) holds.
struct RuleListEvaluator {
    private struct Rule {
        let action: String
        let selector: String?
        let urlFilter: NSRegularExpression?
        let resourceTypes: [String]?
        let loadTypes: [String]?
        let ifDomains: [String]?
        let unlessDomains: [String]?
        let ifTopURLs: [NSRegularExpression]?
        let unlessTopURLs: [NSRegularExpression]?
        let isGenericHiding: Bool
    }

    private let rules: [Rule]

    init(_ json: [[String: Any]]) {
        func regex(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
            try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
        }
        rules = json.map { rule in
            let trigger = rule["trigger"] as? [String: Any] ?? [:]
            let action = rule["action"] as? [String: Any] ?? [:]
            let caseSensitive = trigger["url-filter-is-case-sensitive"] as? Bool ?? false
            let topCaseSensitive = trigger["top-url-filter-is-case-sensitive"] as? Bool ?? false
            let type = action["type"] as? String ?? ""
            return Rule(
                action: type,
                selector: action["selector"] as? String,
                urlFilter: regex(trigger["url-filter"] as? String ?? "", caseSensitive: caseSensitive),
                resourceTypes: trigger["resource-type"] as? [String],
                loadTypes: trigger["load-type"] as? [String],
                ifDomains: trigger["if-domain"] as? [String],
                unlessDomains: trigger["unless-domain"] as? [String],
                ifTopURLs: (trigger["if-top-url"] as? [String])?.compactMap { regex($0, caseSensitive: topCaseSensitive) },
                unlessTopURLs: (trigger["unless-top-url"] as? [String])?.compactMap { regex($0, caseSensitive: topCaseSensitive) },
                isGenericHiding: type == "css-display-none" && trigger["if-domain"] == nil && trigger["if-top-url"] == nil)
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ string: String) -> Bool {
        regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func host(_ host: String, isIn domains: [String]) -> Bool {
        domains.contains { domain in
            if domain.hasPrefix("*") {
                let base = String(domain.dropFirst())
                return host == base || host.hasSuffix("." + base)
            }
            return host == domain
        }
    }

    private func applies(_ rule: Rule, url: String, page: String, type: String) -> Bool {
        guard let filter = rule.urlFilter, Self.matches(filter, url) else { return false }
        if let types = rule.resourceTypes, !types.contains(type) { return false }
        let urlHost = URL(string: url)?.host ?? ""
        let pageHost = URL(string: page)?.host ?? ""
        if let loadTypes = rule.loadTypes {
            let thirdParty = urlHost != pageHost && !urlHost.hasSuffix("." + pageHost) && !pageHost.hasSuffix("." + urlHost)
            if !loadTypes.contains(thirdParty ? "third-party" : "first-party") { return false }
        }
        if let domains = rule.ifDomains, !Self.host(pageHost, isIn: domains) { return false }
        if let domains = rule.unlessDomains, Self.host(pageHost, isIn: domains) { return false }
        if let filters = rule.ifTopURLs, !filters.contains(where: { Self.matches($0, page) }) { return false }
        if let filters = rule.unlessTopURLs, filters.contains(where: { Self.matches($0, page) }) { return false }
        return true
    }

    private func effectiveRules(_ url: String, on page: String, type: String) -> [Rule] {
        var result: [Rule] = []
        for rule in rules where applies(rule, url: url, page: page, type: type) {
            if rule.action == "ignore-previous-rules" { result.removeAll() } else { result.append(rule) }
        }
        return result
    }

    func blocks(_ url: String, on page: String, type: String) -> Bool {
        effectiveRules(url, on: page, type: type).contains { $0.action == "block" }
    }

    /// The selectors the load hides, sorted and without repeats.
    func hiddenSelectors(_ url: String, on page: String, type: String) -> [String] {
        Array(Set(effectiveRules(url, on: page, type: type).compactMap { $0.action == "css-display-none" ? $0.selector : nil }))
            .sorted()
    }

    /// The generic (no `if-domain`) hiding rules the page's document load applies.
    func genericHiding(_ url: String, on page: String) -> [String] {
        effectiveRules(url, on: page, type: "document").filter(\.isGenericHiding).compactMap(\.selector)
    }
}

/// Records the loads WebKit reports as blocked through the private
/// content-rule-list action callback.
@MainActor
private final class ExceptionRecordingNavigationDelegate: NSObject, WKNavigationDelegate {
    private(set) var blocked: [URL] = []
    private(set) var finished = false

    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String,
                 performedAction action: NSObject, forURL url: URL) {
        guard action.responds(to: NSSelectorFromString("blockedLoad")),
              action.value(forKey: "blockedLoad") as? Bool == true else { return }
        blocked.append(url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finished = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        finished = true
    }
}
