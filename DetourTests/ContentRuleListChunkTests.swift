import XCTest
import WebKit
@testable import Detour

/// A filter list with more rules than one `WKContentRuleList` may hold is
/// compiled as several — `<id>`, `<id>-1`, `<id>-2`, … — and every one of them
/// has to be attached, counted, found again at launch and removed (TASK-145).
///
/// A split list's chunks each end with the list's exception rules, so an `@@`
/// exception applies to the block rules of every chunk (TASK-155).
///
/// The cap is injected (2 rules per list) and the rule sets are a handful of
/// rules: nothing here compiles a real filter list. Each test gets its own
/// rule list store and defaults suite in a temporary directory, so the lists
/// named `easylist` below never meet the test host's own.
@MainActor
final class ContentRuleListChunkTests: XCTestCase {

    // MARK: - Chunk arithmetic

    func testChunkCountRoundsUp() {
        XCTAssertEqual(ContentRuleListChunks.chunkCount(ruleCount: 0, maxRulesPerList: 150_000), 0)
        XCTAssertEqual(ContentRuleListChunks.chunkCount(ruleCount: 1, maxRulesPerList: 150_000), 1)
        XCTAssertEqual(ContentRuleListChunks.chunkCount(ruleCount: 150_000, maxRulesPerList: 150_000), 1)
        XCTAssertEqual(ContentRuleListChunks.chunkCount(ruleCount: 150_001, maxRulesPerList: 150_000), 2)
        XCTAssertEqual(ContentRuleListChunks.chunkCount(ruleCount: 300_000, maxRulesPerList: 150_000), 2)
        XCTAssertEqual(ContentRuleListChunks.chunkCount(ruleCount: 300_001, maxRulesPerList: 150_000), 3)
    }

    func testTheFirstChunkKeepsTheListIdentifier() {
        XCTAssertEqual(ContentRuleListChunks.identifier(forList: "easylist", chunk: 0), "easylist")
        XCTAssertEqual(ContentRuleListChunks.identifier(forList: "easylist", chunk: 1), "easylist-1")
        XCTAssertEqual(ContentRuleListChunks.identifier(forList: "easylist-cookie", chunk: 2), "easylist-cookie-2")
    }

    func testIdentifiersOfAList() {
        XCTAssertEqual(ContentRuleListChunks.identifiers(forList: "easylist", chunkCount: 0), [])
        XCTAssertEqual(ContentRuleListChunks.identifiers(forList: "easylist", chunkCount: 1), ["easylist"])
        XCTAssertEqual(ContentRuleListChunks.identifiers(forList: "easylist", chunkCount: 3),
                       ["easylist", "easylist-1", "easylist-2"])
    }

    func testRuleRangesCoverEveryRuleOnce() {
        XCTAssertEqual(ContentRuleListChunks.ruleRanges(ruleCount: 0, maxRulesPerList: 2), [])
        XCTAssertEqual(ContentRuleListChunks.ruleRanges(ruleCount: 2, maxRulesPerList: 2), [0 ..< 2])
        XCTAssertEqual(ContentRuleListChunks.ruleRanges(ruleCount: 4, maxRulesPerList: 2), [0 ..< 2, 2 ..< 4])
        XCTAssertEqual(ContentRuleListChunks.ruleRanges(ruleCount: 5, maxRulesPerList: 2), [0 ..< 2, 2 ..< 4, 4 ..< 5])
        XCTAssertEqual(ContentRuleListChunks.ruleRanges(ruleCount: 74_973, maxRulesPerList: 150_000), [0 ..< 74_973])
    }

    func testAShrunkListsStaleChunks() {
        XCTAssertEqual(ContentRuleListChunks.staleIdentifiers(forList: "easylist", previousChunkCount: 3, chunkCount: 2),
                       ["easylist-2"])
        XCTAssertEqual(ContentRuleListChunks.staleIdentifiers(forList: "easylist", previousChunkCount: 3, chunkCount: 1),
                       ["easylist-1", "easylist-2"])
    }

    func testAListThatDidNotShrinkHasNoStaleChunks() {
        XCTAssertEqual(ContentRuleListChunks.staleIdentifiers(forList: "easylist", previousChunkCount: 1, chunkCount: 1), [])
        XCTAssertEqual(ContentRuleListChunks.staleIdentifiers(forList: "easylist", previousChunkCount: 2, chunkCount: 2), [])
        XCTAssertEqual(ContentRuleListChunks.staleIdentifiers(forList: "easylist", previousChunkCount: 2, chunkCount: 3), [])
        XCTAssertEqual(ContentRuleListChunks.staleIdentifiers(forList: "easylist", previousChunkCount: 0, chunkCount: 2), [])
    }

    /// The list's own identifier is every compile's first chunk, so it is
    /// never a leftover: an empty rule set is not compiled at all and the
    /// previous list stays.
    func testTheFirstChunkIsNeverStale() {
        XCTAssertEqual(ContentRuleListChunks.staleIdentifiers(forList: "easylist", previousChunkCount: 3, chunkCount: 0),
                       ["easylist-1", "easylist-2"])
    }

    // MARK: - Exceptions in a split list (TASK-155)

    /// Rules as strings: `b…` blocks, `x…` is an exception.
    private func layout(_ rules: [String], cap: Int) -> [[String]] {
        ContentRuleListChunks.chunks(of: rules, maxRulesPerList: cap) { $0.hasPrefix("x") }.map(\.rules)
    }

    private func counted(_ rules: [String], cap: Int) -> [Int] {
        ContentRuleListChunks.chunks(of: rules, maxRulesPerList: cap) { $0.hasPrefix("x") }.map(\.countedRuleCount)
    }

    func testAListWithinTheCapIsOneChunkInListOrder() {
        XCTAssertEqual(layout([], cap: 4), [])
        XCTAssertEqual(layout(["b0", "x0", "b1"], cap: 4), [["b0", "x0", "b1"]])
        XCTAssertEqual(layout(["x0", "b0", "x1", "b1"], cap: 4), [["x0", "b0", "x1", "b1"]], "exactly at the cap")
        XCTAssertEqual(counted(["x0", "b0", "x1", "b1"], cap: 4), [4])
    }

    func testEveryChunkOfASplitListEndsWithTheListsExceptions() {
        let rules = ["b0", "b1", "x0", "b2", "b3", "b4", "b5", "b6"]

        // Cap 4, one exception: three block rules a chunk, then the exception.
        XCTAssertEqual(layout(rules, cap: 4), [["b0", "b1", "b2", "x0"], ["b3", "b4", "b5", "x0"], ["b6", "x0"]])
    }

    /// The task's case: the exception is past the cap, the block rule it
    /// exempts is in the first chunk.
    func testAnExceptionPastTheCapStillFollowsTheBlockRulesOfTheFirstChunk() {
        XCTAssertEqual(layout(["b0", "b1", "x0"], cap: 2), [["b0", "x0"], ["b1", "x0"]])
    }

    func testExceptionsKeepTheirOrderAndFollowEveryBlockRule() {
        let rules = ["x0", "b0", "b1", "x1", "b2", "b3", "b4"]

        XCTAssertEqual(layout(rules, cap: 5), [["b0", "b1", "b2", "x0", "x1"], ["b3", "b4", "x0", "x1"]])
    }

    func testNoChunkOfASplitListExceedsTheCap() {
        for cap in 1 ... 9 {
            for exceptionCount in 0 ... 12 {
                let rules = (0 ..< 20).map { "b\($0)" } + (0 ..< exceptionCount).map { "x\($0)" }
                let chunks = layout(rules, cap: cap)
                XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= cap },
                              "cap \(cap), \(exceptionCount) exceptions: \(chunks.map(\.count))")
                XCTAssertEqual(chunks.flatMap { $0.filter { $0.hasPrefix("b") } }, (0 ..< 20).map { "b\($0)" },
                               "every block rule is compiled once, in order")
            }
        }
    }

    /// A repeated exception is counted in the first chunk only.
    func testARepeatedExceptionIsCountedOnce() {
        let rules = ["b0", "b1", "x0", "b2", "b3", "b4", "b5", "b6"]

        XCTAssertEqual(counted(rules, cap: 4), [4, 3, 1])
        XCTAssertEqual(counted(rules, cap: 4).reduce(0, +), rules.count)
        XCTAssertEqual(counted(["b0", "b1", "b2", "b3", "b4"], cap: 2), [2, 2, 1], "no exceptions: plain slices")
    }

    /// Every chunk has to hold all the carried exceptions, so they may take
    /// half the cap at most; the ones beyond that are left out.
    func testExceptionsBeyondHalfTheCapAreLeftOut() {
        XCTAssertEqual(ContentRuleListChunks.maxCarriedExceptions(maxRulesPerList: 150_000), 75_000)
        XCTAssertEqual(ContentRuleListChunks.maxCarriedExceptions(maxRulesPerList: 5), 2)
        let rules = ["b0", "b1", "b2", "x0", "x1", "x2"]

        XCTAssertEqual(layout(rules, cap: 4), [["b0", "b1", "x0", "x1"], ["b2", "x0", "x1"]])
        XCTAssertEqual(counted(rules, cap: 4), [4, 1], "five of the six rules are compiled")
        XCTAssertEqual(ContentRuleListChunks.droppedExceptionCount(ruleCount: 6, exceptionCount: 3, maxRulesPerList: 4), 1)
    }

    func testExceptionsAtHalfTheCapAreAllCarried() {
        let rules = ["b0", "b1", "b2", "x0", "x1"]

        XCTAssertEqual(layout(rules, cap: 4), [["b0", "b1", "x0", "x1"], ["b2", "x0", "x1"]])
        XCTAssertEqual(ContentRuleListChunks.droppedExceptionCount(ruleCount: 5, exceptionCount: 2, maxRulesPerList: 4), 0)
    }

    func testAListWithinTheCapDropsNoException() {
        XCTAssertEqual(ContentRuleListChunks.droppedExceptionCount(ruleCount: 4, exceptionCount: 4, maxRulesPerList: 4), 0)
        XCTAssertEqual(layout(["x0", "x1", "x2", "x3"], cap: 4), [["x0", "x1", "x2", "x3"]])
    }

    /// Exceptions with nothing to exempt undo nothing; they still compile as
    /// one list, so the compile does not read as a failure.
    func testASplitListOfOnlyExceptionsIsOneChunk() {
        XCTAssertEqual(layout(["x0", "x1", "x2", "x3", "x4"], cap: 4), [["x0", "x1"]])
        XCTAssertEqual(counted(["x0", "x1", "x2", "x3", "x4"], cap: 4), [2])
        XCTAssertEqual(layout(["x0", "x1"], cap: 1), [], "a cap of one carries no exception: nothing to compile")
    }

    func testWhichCompiledRulesAreExceptions() {
        XCTAssertTrue(ContentRuleListChunks.isException(
            ["trigger": ["url-filter": "a"], "action": ["type": "ignore-previous-rules"]]))
        XCTAssertFalse(ContentRuleListChunks.isException(["trigger": ["url-filter": "a"], "action": ["type": "block"]]))
        XCTAssertFalse(ContentRuleListChunks.isException(
            ["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": ".ad"]]))
        XCTAssertFalse(ContentRuleListChunks.isException(["trigger": ["url-filter": "a"]]))
    }

    // MARK: - Fixture

    private var directory: URL!
    private var defaultsSuiteName: String!
    private var storage: ContentBlockerStorage!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentRuleListChunkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuiteName = "ContentRuleListChunkTests.\(UUID().uuidString)"
        storage = ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: directory),
            filterListCacheDirectory: directory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName)))
    }

    override func tearDown() async throws {
        storage = nil
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    /// A store over this test's storage with a cap of two rules per list.
    private func makeStore() -> ContentRuleStore {
        ContentRuleStore(storage: storage, maxRulesPerList: 2)
    }

    /// Rule `n` blocks everything under `blocked-<n>.example`.
    private func blockRules(_ count: Int) -> [[String: Any]] {
        (0 ..< count).map { index in
            ["trigger": ["url-filter": "blocked-\(index)\\.example"], "action": ["type": "block"]]
        }
    }

    private func compile(_ store: ContentRuleStore, _ identifier: String, ruleCount: Int) async {
        let rules = blockRules(ruleCount)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.compile(identifier: identifier, rules: rules) { _ in continuation.resume() }
        }
    }

    private func lookUp(_ store: ContentRuleStore, _ identifier: String) async -> [WKContentRuleList] {
        await withCheckedContinuation { continuation in
            store.lookUpList(identifier: identifier) { continuation.resume(returning: $0) }
        }
    }

    /// What WebKit's store holds on disk.
    private func storedIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            storage.ruleListStore.getAvailableContentRuleListIdentifiers { identifiers in
                continuation.resume(returning: (identifiers ?? []).sorted())
            }
        }
    }

    // MARK: - Compiling

    func testEveryChunkOfASplitListIsCompiledCachedAndCounted() async {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)

        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier),
                       ["easylist", "easylist-1", "easylist-2"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 5, "the count is the sum over the chunks")
        XCTAssertTrue(store.isCompiled(list: "easylist"))
        let stored = await storedIdentifiers()
        XCTAssertEqual(stored, ["easylist", "easylist-1", "easylist-2"])
    }

    func testAListAtTheCapIsOneRuleList() async {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 2)

        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier), ["easylist"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 2)
        let stored = await storedIdentifiers()
        XCTAssertEqual(stored, ["easylist"])
    }

    func testOneListsChunksAreNotAnotherLists() async {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 3)
        await compile(store, "easylist-cookie", ruleCount: 1)

        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier), ["easylist", "easylist-1"])
        XCTAssertEqual(store.cachedLists(forList: "easylist-cookie").map(\.identifier), ["easylist-cookie"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 3)
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist-cookie"), 1)
        XCTAssertFalse(store.isCompiled(list: "easyprivacy"))
        XCTAssertNil(store.compiledRuleCount(forList: "easyprivacy"))
        XCTAssertEqual(store.cachedLists(forList: "easyprivacy").map(\.identifier), [])
    }

    func testAListThatShrinksLosesItsStaleChunks() async throws {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)

        await compile(store, "easylist", ruleCount: 3)
        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier), ["easylist", "easylist-1"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 3)
        try await waitUntil("the third chunk is removed from WebKit's store") {
            await self.storedIdentifiers() == ["easylist", "easylist-1"]
        }

        await compile(store, "easylist", ruleCount: 2)
        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier), ["easylist"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 2)
        try await waitUntil("the second chunk is removed from WebKit's store") {
            await self.storedIdentifiers() == ["easylist"]
        }

        // And it grows back.
        await compile(store, "easylist", ruleCount: 5)
        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier),
                       ["easylist", "easylist-1", "easylist-2"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 5)
    }

    /// A relaunch: nothing in memory, the chunk count comes from the defaults.
    func testANewStoreKnowsAShrunkListsChunkCount() async throws {
        let first = makeStore()
        await compile(first, "easylist", ruleCount: 5)
        await compile(first, "easylist", ruleCount: 3)
        try await waitUntil("the third chunk is removed from WebKit's store") {
            await self.storedIdentifiers() == ["easylist", "easylist-1"]
        }

        let relaunched = makeStore()
        let found = await lookUp(relaunched, "easylist")
        XCTAssertEqual(found.map(\.identifier), ["easylist", "easylist-1"])
        XCTAssertEqual(relaunched.compiledRuleCount(forList: "easylist"), 3)
    }

    // MARK: - Looking a compiled list up at launch

    func testANewStoreFindsEveryChunkOfACompiledList() async {
        let first = makeStore()
        await compile(first, "easylist", ruleCount: 5)

        let relaunched = makeStore()
        XCTAssertFalse(relaunched.isCompiled(list: "easylist"), "nothing is cached before the lookup")
        let found = await lookUp(relaunched, "easylist")

        XCTAssertEqual(found.map(\.identifier), ["easylist", "easylist-1", "easylist-2"])
        XCTAssertEqual(relaunched.cachedLists(forList: "easylist").map(\.identifier),
                       ["easylist", "easylist-1", "easylist-2"])
        XCTAssertEqual(relaunched.compiledRuleCount(forList: "easylist"), 5)
        XCTAssertTrue(relaunched.isCompiled(list: "easylist"))
    }

    func testLookingUpAListThatWasNeverCompiledFindsNothing() async {
        let store = makeStore()
        let found = await lookUp(store, "easylist")
        XCTAssertEqual(found.map(\.identifier), [])
        XCTAssertFalse(store.isCompiled(list: "easylist"))
        XCTAssertNil(store.compiledRuleCount(forList: "easylist"))
    }

    // MARK: - Invalidating

    func testInvalidateAllRemovesEveryChunk() async throws {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)
        await compile(store, "easyprivacy", ruleCount: 1)

        store.invalidateAll()

        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier), [])
        XCTAssertFalse(store.isCompiled(list: "easylist"))
        XCTAssertNil(store.compiledRuleCount(forList: "easylist"))
        XCTAssertNil(store.compiledRuleCount(forList: "easyprivacy"))
        try await waitUntil("every chunk is removed from WebKit's store") {
            await self.storedIdentifiers().isEmpty
        }
        let relaunched = makeStore()
        let found = await lookUp(relaunched, "easylist")
        XCTAssertEqual(found.map(\.identifier), [])
        XCTAssertNil(relaunched.compiledRuleCount(forList: "easylist"))
    }

    // MARK: - What a profile gets

    func testEveryChunkOfEveryEnabledListIsApplied() async {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)
        await compile(store, "easyprivacy", ruleCount: 1)
        await compile(store, "urlhaus-filter", ruleCount: 3)
        let profile = Profile(name: "Test")

        XCTAssertEqual(ContentBlockerManager.ruleLists(for: profile, in: store).map(\.identifier),
                       ["easylist", "easylist-1", "easylist-2", "easyprivacy", "urlhaus-filter", "urlhaus-filter-1"])
    }

    func testADisabledListContributesNoChunk() async {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)
        await compile(store, "easyprivacy", ruleCount: 1)
        let profile = Profile(name: "Test")

        profile.isEasyListEnabled = false
        XCTAssertEqual(ContentBlockerManager.ruleLists(for: profile, in: store).map(\.identifier), ["easyprivacy"])

        profile.isEasyListEnabled = true
        profile.isAdBlockingEnabled = false
        XCTAssertEqual(ContentBlockerManager.ruleLists(for: profile, in: store).map(\.identifier), [],
                       "the master switch turns every chunk of every list off")
    }

    // MARK: - In a real web view

    private let pageURL = URL(string: "http://site.example/")!
    /// Matched by rule 4 of 5: the only rule of the third chunk.
    private let lastChunkImageURL = URL(string: "http://blocked-4.example/x.png")!
    /// Matched by rule 0: the first chunk.
    private let firstChunkImageURL = URL(string: "http://blocked-0.example/x.png")!

    private var pageHTML: String {
        "<html><body><img src='\(firstChunkImageURL.absoluteString)'><img src='\(lastChunkImageURL.absoluteString)'></body></html>"
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration)
    }

    /// What `Space.makeWebViewConfiguration` and the window's rules-changed
    /// handler do to a user content controller.
    private func apply(_ lists: [WKContentRuleList], to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        lists.forEach(controller.add)
    }

    func testARuleInTheLastChunkBlocksInAWebView() async throws {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)
        let delegate = ChunkRecordingNavigationDelegate()
        let webView = makeWebView()
        defer { webView.navigationDelegate = nil }
        webView.navigationDelegate = delegate
        apply(ContentBlockerManager.ruleLists(for: Profile(name: "Test"), in: store), to: webView)

        webView.loadHTMLString(pageHTML, baseURL: pageURL)
        try await waitUntil("the page finished loading") { delegate.finished }
        try await waitUntil("both blocked loads are reported", timeout: 5) { delegate.blocked.count >= 2 }

        XCTAssertEqual(delegate.blocked.filter { $0.url == lastChunkImageURL }.map(\.identifier), ["easylist-2"],
                       "blocked: \(delegate.blocked)")
        XCTAssertEqual(delegate.blocked.filter { $0.url == firstChunkImageURL }.map(\.identifier), ["easylist"],
                       "blocked: \(delegate.blocked)")
    }

    /// The window's reaction to a profile toggle: remove every rule list, add
    /// back what the profile still has on. No chunk of the disabled list stays.
    func testDisablingAListDetachesEveryChunkFromAWebView() async throws {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)
        let profile = Profile(name: "Test")
        let delegate = ChunkRecordingNavigationDelegate()
        let webView = makeWebView()
        defer { webView.navigationDelegate = nil }
        webView.navigationDelegate = delegate
        apply(ContentBlockerManager.ruleLists(for: profile, in: store), to: webView)

        profile.isEasyListEnabled = false
        apply(ContentBlockerManager.ruleLists(for: profile, in: store), to: webView)

        webView.loadHTMLString(pageHTML, baseURL: pageURL)
        try await waitUntil("the page finished loading") { delegate.finished }
        // Let the image loads run out: a blocked one is reported by the time
        // the page finishes, an unblocked one fails at DNS instead.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(delegate.blocked.isEmpty, "no chunk of a disabled list may act: \(delegate.blocked)")
    }

    /// The per-site switch turns content blockers off for the navigation,
    /// which covers every rule list — every chunk included.
    func testAWhitelistedNavigationIsNotBlockedByAnyChunk() async throws {
        let store = makeStore()
        await compile(store, "easylist", ruleCount: 5)
        let delegate = ChunkRecordingNavigationDelegate()
        delegate.configurePreferences = { preferences in
            ContentBlockerManager.setContentBlockersEnabled(false, on: preferences)
        }
        let webView = makeWebView()
        defer { webView.navigationDelegate = nil }
        webView.navigationDelegate = delegate
        apply(ContentBlockerManager.ruleLists(for: Profile(name: "Test"), in: store), to: webView)

        webView.loadHTMLString(pageHTML, baseURL: pageURL)
        try await waitUntil("the page finished loading") { delegate.finished }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(delegate.blocked.isEmpty, "no chunk may act on a whitelisted page: \(delegate.blocked)")
    }

    // MARK: - Exceptions in a split list (TASK-155)

    private func blockRule(_ host: String) -> [String: Any] {
        ["trigger": ["url-filter": "\(host)\\.example"], "action": ["type": "block"]]
    }

    /// An `@@` rule: undoes the block rules before it in the same rule list.
    private func exceptionRule(_ urlFilter: String) -> [String: Any] {
        ["trigger": ["url-filter": urlFilter], "action": ["type": "ignore-previous-rules"]]
    }

    private func compile(_ store: ContentRuleStore, _ identifier: String, rules: [[String: Any]]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.compile(identifier: identifier, rules: rules) { _ in continuation.resume() }
        }
    }

    /// Loads a page with one image per URL, in order, and returns the loads
    /// WebKit reported as blocked once `expectedBlocked` of them are in.
    /// Images load in document order, so by then an earlier one that was going
    /// to be blocked has been reported too.
    private func blockedLoads(of imageURLs: [URL], with lists: [WKContentRuleList],
                              expectedBlocked: Int) async throws -> [URL] {
        let delegate = ChunkRecordingNavigationDelegate()
        let webView = makeWebView()
        defer { webView.navigationDelegate = nil }
        webView.navigationDelegate = delegate
        apply(lists, to: webView)
        let images = imageURLs.map { "<img src='\($0.absoluteString)'>" }.joined()

        webView.loadHTMLString("<html><body>\(images)</body></html>", baseURL: pageURL)
        try await waitUntil("the page finished loading") { delegate.finished }
        try await waitUntil("\(expectedBlocked) blocked loads are reported", timeout: 5) {
            Set(delegate.blocked.map(\.url)).count >= expectedBlocked
        }
        return delegate.blocked.map(\.url)
    }

    /// The exception is the third of three rules under a cap of two: in list
    /// order it lands in a later chunk than the block rule it exempts, and
    /// WebKit only lets `ignore-previous-rules` undo rules of its own list.
    func testAnExceptionAppliesToABlockRuleOfAnEarlierChunk() async throws {
        let store = makeStore()
        await compile(store, "easylist", rules: [
            blockRule("blocked-0"),
            blockRule("blocked-1"),
            exceptionRule("blocked-0\\.example/allowed"),
        ])
        let allowed = URL(string: "http://blocked-0.example/allowed.png")!
        let blockedSameHost = URL(string: "http://blocked-0.example/x.png")!
        let blockedOtherHost = URL(string: "http://blocked-1.example/x.png")!

        let blocked = try await blockedLoads(
            of: [allowed, blockedSameHost, blockedOtherHost],
            with: ContentBlockerManager.ruleLists(for: Profile(name: "Test"), in: store), expectedBlocked: 2)

        XCTAssertFalse(blocked.contains(allowed), "the exception must exempt it: \(blocked)")
        XCTAssertTrue(blocked.contains(blockedSameHost), "blocked: \(blocked)")
        XCTAssertTrue(blocked.contains(blockedOtherHost), "blocked: \(blocked)")
    }

    /// An exception ahead of the cap exempts a block rule of the last chunk.
    func testAnExceptionAppliesToABlockRuleOfALaterChunk() async throws {
        let store = makeStore()
        await compile(store, "easylist", rules: [
            exceptionRule("blocked-2\\.example/allowed"),
            blockRule("blocked-0"),
            blockRule("blocked-1"),
            blockRule("blocked-2"),
        ])
        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier),
                       ["easylist", "easylist-1", "easylist-2"])
        let allowed = URL(string: "http://blocked-2.example/allowed.png")!
        let blockedSameHost = URL(string: "http://blocked-2.example/x.png")!
        let blockedOtherHost = URL(string: "http://blocked-0.example/x.png")!

        let blocked = try await blockedLoads(
            of: [allowed, blockedSameHost, blockedOtherHost],
            with: ContentBlockerManager.ruleLists(for: Profile(name: "Test"), in: store), expectedBlocked: 2)

        XCTAssertFalse(blocked.contains(allowed), "the exception must exempt it: \(blocked)")
        XCTAssertTrue(blocked.contains(blockedSameHost), "blocked: \(blocked)")
        XCTAssertTrue(blocked.contains(blockedOtherHost), "blocked: \(blocked)")
    }

    /// Settings shows this count: the exception both chunks carry is one rule.
    func testTheRuleCountOfASplitListCountsARepeatedExceptionOnce() async throws {
        let store = makeStore()
        let rules = [blockRule("blocked-0"), blockRule("blocked-1"), exceptionRule("blocked-0\\.example/allowed")]
        await compile(store, "easylist", rules: rules)

        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier), ["easylist", "easylist-1"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 3)

        // And after a relaunch, from the defaults.
        let relaunched = makeStore()
        _ = await lookUp(relaunched, "easylist")
        XCTAssertEqual(relaunched.compiledRuleCount(forList: "easylist"), 3)
    }

    /// Under a cap of two every chunk carries one exception at most; the
    /// second is left out and the count shows it.
    func testTheRuleCountLeavesOutExceptionsThatWereNotCompiled() async throws {
        let store = makeStore()
        await compile(store, "easylist", rules: [
            blockRule("blocked-0"),
            exceptionRule("blocked-0\\.example/allowed"),
            exceptionRule("blocked-0\\.example/also-allowed"),
        ])

        XCTAssertEqual(store.cachedLists(forList: "easylist").map(\.identifier), ["easylist"])
        XCTAssertEqual(store.compiledRuleCount(forList: "easylist"), 2)
    }
}

/// Records the loads WebKit reports as blocked through the private
/// content-rule-list action callback, the one `BrowserWindowController`
/// implements for the blocked counter.
@MainActor
private final class ChunkRecordingNavigationDelegate: NSObject, WKNavigationDelegate {

    struct BlockedLoad: CustomStringConvertible {
        let identifier: String
        let url: URL
        var description: String { "\(identifier) \(url)" }
    }

    private(set) var blocked: [BlockedLoad] = []
    private(set) var finished = false
    var configurePreferences: ((WKWebpagePreferences) -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true {
            configurePreferences?(preferences)
        }
        decisionHandler(.allow, preferences)
    }

    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String,
                 performedAction action: NSObject, forURL url: URL) {
        // Guarded like production: an undefined key raises an ObjC exception.
        guard action.responds(to: NSSelectorFromString("blockedLoad")),
              action.value(forKey: "blockedLoad") as? Bool == true else { return }
        blocked.append(BlockedLoad(identifier: identifier, url: url))
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
