import XCTest
import WebKit
@testable import Detour

/// A filter list with more rules than one `WKContentRuleList` may hold is
/// compiled as several — `<id>`, `<id>-1`, `<id>-2`, … — and every one of them
/// has to be attached, counted, found again at launch and removed (TASK-145).
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
