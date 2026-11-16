import XCTest
import WebKit
@testable import Detour

/// A rules change reaches every live web view of a browser window's spaces,
/// not only the selected tab's panes (TASK-368): a background tab, a
/// background split pair, a background tab's Peek and a pinned tab follow a
/// list switched off and a list recompiled without being selected, and a tab
/// of another profile keeps its own profile's lists.
///
/// A real `BrowserWindowController` on a space of a profile made for the
/// test; `TabStore.shared.contentRuleStore` is a private temporary store
/// holding tiny lists under the real list identifiers. The pages come from a
/// loopback server and `fetch` two paths, one per list, so both outcomes
/// (loaded, blocked) are positive signals. The blocked counter is not read:
/// only a window controller implements WebKit's blocked-load callback, and a
/// background tab is its own navigation delegate.
nonisolated final class LivePageContentBlockingTests: XCTestCase {

    private var directory: URL!
    private var defaultsSuiteName: String!
    private var ruleStore: ContentRuleStore!
    private var previousRuleStore: ContentRuleStore!
    private var controllers: [BrowserWindowController] = []
    private var looseTabs: [BrowserTab] = []
    private var quickDetourTabs: [BrowserTab] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var createdProfiles: [Profile] = []
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    /// Released profiles take their process pool down with them, which WebKit
    /// traps on inside an IPC dispatch (`ExtensionPrivateStoreTests`): kept for
    /// the rest of the test process.
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePageContentBlockingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuiteName = "LivePageContentBlockingTests.\(UUID().uuidString)"
        ruleStore = ContentRuleStore(storage: ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: directory),
            filterListCacheDirectory: directory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))))
        previousRuleStore = TabStore.shared.contentRuleStore
        TabStore.shared.contentRuleStore = ruleStore
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    @MainActor override func tearDown() async throws {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        for tab in quickDetourTabs { TabStore.shared.closeQuickDetourTab(tab, disposition: .discard) }
        quickDetourTabs.removeAll()
        for tab in looseTabs {
            tab.peekTab?.teardown()
            tab.teardown()
        }
        looseTabs.removeAll()
        for id in createdSpaceIDs { TabStore.shared.deleteSpace(id: id) }
        createdSpaceIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        TabStore.shared.contentRuleStore = previousRuleStore
        previousRuleStore = nil
        ruleStore = nil
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The path `easylist` blocks in these tests, and `easyprivacy`'s.
    private static let firstPath = "/task368-first"
    private static let secondPath = "/task368-second"

    @MainActor private func blockRule(_ path: String) -> ContentRule {
        ["trigger": ["url-filter": NSRegularExpression.escapedPattern(for: path)], "action": ["type": "block"]]
    }

    @MainActor private func compile(_ identifier: String, blocking path: String) async {
        let rules = [blockRule(path)]
        let compiled = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ruleStore.compile(identifier: identifier, rules: rules) { outcome in
                if case .compiled = outcome { continuation.resume(returning: true) } else { continuation.resume(returning: false) }
            }
        }
        XCTAssertTrue(compiled, "\(identifier) compiled")
    }

    @MainActor private func serve() async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>Blocking</title></head><body>a page</body></html>",
            Self.firstPath: "first",
            Self.secondPath: "second",
        ])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    @MainActor private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    @MainActor private func makeSpace(on profile: Profile) -> Space {
        let space = TabStore.shared.addSpace(name: "Live page blocking", emoji: "B", colorHex: "007AFF",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    @MainActor private func makeWindow(showing space: Space) -> BrowserWindowController {
        let controller = BrowserWindowController(incognito: false)
        controllers.append(controller)
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        controller.sidebarSplitView.autosaveName = nil
        controller.setActiveSpace(id: space.id)
        controller.showWindow(nil)
        return controller
    }

    /// Waits for the tab's page, then gives its web view the lists `profile`
    /// has on in this test's store: what `Space.makeWebViewConfiguration`
    /// gives it from the shared manager's.
    @MainActor private func settle(_ tab: BrowserTab, at url: URL, profile: Profile,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("the page to load", file: file, line: line) {
            tab.url == url && !tab.isLoading && tab.title == "Blocking"
        }
        let webView = try XCTUnwrap(tab.webView, file: file, line: line)
        ContentBlockerManager.replaceRuleLists(on: webView.configuration.userContentController, profile: profile,
                                               from: ruleStore)
    }

    private enum Outcome: String { case loaded, blocked }

    /// Fetches both paths from the page; a load a rule list blocks rejects.
    @MainActor private func fetchBoth(in tab: BrowserTab, file: StaticString = #filePath,
                                      line: UInt = #line) async throws -> (first: Outcome, second: Outcome) {
        let page = try XCTUnwrap(tab.webView, file: file, line: line)
        let tag = UUID().uuidString
        let js = """
        const outcome = async (path) => {
            try { await fetch(path + '?' + tag, { cache: 'no-store' }); return 'loaded'; }
            catch (e) { return 'blocked'; }
        };
        return JSON.stringify({ first: await outcome(first), second: await outcome(second) });
        """
        let raw = try await page.callAsyncJavaScript(
            js, arguments: ["tag": tag, "first": Self.firstPath, "second": Self.secondPath], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, file: file, line: line)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
                                   file: file, line: line)
        let first = try XCTUnwrap(result["first"].flatMap(Outcome.init(rawValue:)), file: file, line: line)
        let second = try XCTUnwrap(result["second"].flatMap(Outcome.init(rawValue:)), file: file, line: line)
        return (first, second)
    }

    /// The pages of one window's space: the selected tab, and around it a
    /// background tab with a Peek, a background split pair and a pinned tab,
    /// every one loaded with this test's lists.
    private struct Pages {
        let window: BrowserWindowController
        let selected: BrowserTab
        let background: BrowserTab
        let peek: BrowserTab
        let splitLeft: BrowserTab
        let splitRight: BrowserTab
        let pinned: BrowserTab

        var all: [(name: String, tab: BrowserTab)] {
            [("selected", selected), ("background", background), ("peek", peek), ("split left", splitLeft),
             ("split right", splitRight), ("pinned", pinned)]
        }
    }

    @MainActor private func openPages(on profile: Profile) async throws -> Pages {
        let store = TabStore.shared
        let url = try await serve()
        let space = makeSpace(on: profile)
        let controller = makeWindow(showing: space)

        let pinned = store.addTab(in: space, url: url)
        store.pinTab(id: pinned.id, in: space)
        let background = store.addTab(in: space, url: url)
        let peek = BrowserTab(configuration: space.makeWebViewConfiguration())
        background.peekTab = peek
        peek.load(url)
        let splitLeft = store.addTab(in: space, url: url)
        let splitRight = try XCTUnwrap(store.addTabInSplit(with: splitLeft.id, url: url, in: space))
        let selected = store.addTab(in: space, url: url)
        controller.selectTab(id: selected.id)

        let pages = Pages(window: controller, selected: selected, background: background, peek: peek, splitLeft: splitLeft,
                          splitRight: splitRight, pinned: pinned)
        for (_, tab) in pages.all { try await settle(tab, at: url, profile: profile) }
        XCTAssertTrue(controller.selectedTab === selected)
        XCTAssertTrue(store.splitGroup(containing: splitLeft.id, in: space).map { $0.members.count == 2 } ?? false,
                      "the split pair is a group")
        XCTAssertTrue(space.pinnedTabs.contains { $0 === pinned })
        return pages
    }

    // MARK: - Tests

    /// A list switched off in Settings > Profiles stops blocking on every page
    /// of the space, selected or not; the other list keeps blocking.
    @MainActor func testAListSwitchedOffStopsBlockingInEveryTabOfTheSpace() async throws {
        await compile("easylist", blocking: Self.firstPath)
        await compile("easyprivacy", blocking: Self.secondPath)
        let profile = makeProfile("Live Page Blocking")
        let pages = try await openPages(on: profile)
        for (name, tab) in pages.all {
            let outcome = try await fetchBoth(in: tab)
            XCTAssertEqual(outcome.first, .blocked, "\(name): the lists the page opened with block")
            XCTAssertEqual(outcome.second, .blocked, name)
        }

        profile.isEasyListEnabled = false
        ContentBlockerManager.shared.reapplyRuleLists()

        for (name, tab) in pages.all {
            let outcome = try await fetchBoth(in: tab)
            XCTAssertEqual(outcome.first, .loaded, "\(name): the list switched off no longer blocks")
            XCTAssertEqual(outcome.second, .blocked, "\(name): the list still on still blocks")
        }
        XCTAssertTrue(pages.window.selectedTab === pages.selected, "no other page was selected meanwhile")
    }

    /// A list recompiled with other rules (a refresh, or Clear Cache &
    /// Redownload's recompile) blocks with its new rules in the background
    /// pages, and its old ones are gone.
    @MainActor func testARecompiledListReachesEveryTabOfTheSpace() async throws {
        await compile("easylist", blocking: Self.firstPath)
        let profile = makeProfile("Live Page Recompile")
        let pages = try await openPages(on: profile)
        for (name, tab) in pages.all {
            let outcome = try await fetchBoth(in: tab)
            XCTAssertEqual(outcome.first, .blocked, name)
            XCTAssertEqual(outcome.second, .loaded, name)
        }

        await compile("easylist", blocking: Self.secondPath)
        ContentBlockerManager.shared.reapplyRuleLists()

        for (name, tab) in pages.all {
            let outcome = try await fetchBoth(in: tab)
            XCTAssertEqual(outcome.first, .loaded, "\(name): the old rules are gone")
            XCTAssertEqual(outcome.second, .blocked, "\(name): the new rules block")
        }
    }

    /// Each page keeps its own profile's lists: a list switched off in one
    /// profile leaves another profile's tab blocking with it.
    @MainActor func testAnotherProfilesTabKeepsItsOwnLists() async throws {
        await compile("easylist", blocking: Self.firstPath)
        await compile("easyprivacy", blocking: Self.secondPath)
        let url = try await serve()
        let changed = makeProfile("Live Page Changed")
        let other = makeProfile("Live Page Other")
        let changedSpace = makeSpace(on: changed)
        let otherSpace = makeSpace(on: other)
        let controller = makeWindow(showing: changedSpace)
        let changedTab = TabStore.shared.addTab(in: changedSpace, url: url)
        let otherTab = TabStore.shared.addTab(in: otherSpace, url: url)
        controller.selectTab(id: changedTab.id)
        try await settle(changedTab, at: url, profile: changed)
        try await settle(otherTab, at: url, profile: other)

        changed.isEasyListEnabled = false
        ContentBlockerManager.shared.reapplyRuleLists()

        let changedOutcome = try await fetchBoth(in: changedTab)
        XCTAssertEqual(changedOutcome.first, .loaded)
        XCTAssertEqual(changedOutcome.second, .blocked)
        let otherOutcome = try await fetchBoth(in: otherTab)
        XCTAssertEqual(otherOutcome.first, .blocked, "the other profile still has the list on")
        XCTAssertEqual(otherOutcome.second, .blocked)
    }

    /// Which web views the pass reaches, with which profile: space tabs,
    /// pinned and favourite backing tabs and Peeks; not a sleeping tab, a
    /// Quick Detour's page (its window replaces its lists) or a page built
    /// from an extension context's configuration.
    @MainActor func testTheLivePagesAreEveryLiveWebViewOfTheSpacesAndFavourites() async throws {
        let store = TabStore.shared
        let profile = makeProfile("Live Page Enumeration")
        let space = makeSpace(on: profile)
        let url = try await serve()

        let tab = store.addTab(in: space, url: url)
        let peek = BrowserTab(configuration: space.makeWebViewConfiguration())
        tab.peekTab = peek
        let pinned = store.addTab(in: space)
        store.pinTab(id: pinned.id, in: space)
        let sleeping = store.addTab(in: space, url: url)
        try await waitUntil("the page to load") { sleeping.url == url && !sleeping.isLoading }
        sleeping.sleep(force: true)
        XCTAssertNil(sleeping.webView)
        let extensionPage = BrowserTab(webView: WKWebView(frame: .zero, configuration: WKWebViewConfiguration()),
                                       servedExtensionOriginHost: "an-extension")
        store.insertTab(extensionPage, in: space, parentID: nil)
        let favorite = BrowserTab(configuration: space.makeWebViewConfiguration())
        looseTabs.append(favorite)
        favorite.load(url)
        try await waitUntil("the favourite's page to load") { favorite.url == url && !favorite.isLoading }
        store.addFavorite(from: favorite, profileID: profile.id)
        XCTAssertTrue(profile.favoriteTabs.contains { $0 === favorite })
        let quickDetour = store.openQuickDetourTab(profile: profile)
        quickDetourTabs.append(quickDetour)
        XCTAssertNotNil(quickDetour.webView)

        let pages = store.contentBlockingPages.filter { $0.profile === profile }
        let reached = pages.map(\.tab)
        for (name, expected) in [("tab", tab), ("peek", peek), ("pinned", pinned), ("favourite", favorite)] {
            XCTAssertEqual(reached.filter { $0 === expected }.count, 1, "\(name) is reached once")
        }
        for (name, unexpected) in [("sleeping", sleeping), ("extension page", extensionPage),
                                   ("Quick Detour", quickDetour)] {
            XCTAssertFalse(store.contentBlockingPages.contains { $0.tab === unexpected }, "\(name) is not reached")
        }
        XCTAssertEqual(pages.count, 4)
        for page in pages { XCTAssertTrue(page.webView === page.tab.webView) }
    }

    // MARK: - Between Clear Cache & Redownload and the recompile (TASK-369)

    /// A background tab and one newly opened in the space, with this test's
    /// lists, in a window showing another tab.
    @MainActor private func openBackgroundTab(on profile: Profile) async throws -> (url: URL, space: Space, tab: BrowserTab) {
        let store = TabStore.shared
        let url = try await serve()
        let space = makeSpace(on: profile)
        let controller = makeWindow(showing: space)
        let background = store.addTab(in: space, url: url)
        let selected = store.addTab(in: space, url: url)
        controller.selectTab(id: selected.id)
        try await settle(background, at: url, profile: profile)
        try await settle(selected, at: url, profile: profile)
        return (url, space, background)
    }

    /// Clear Cache & Redownload removes every compiled list; the lists
    /// recompile one at a time, each posting a rules change. Until a list
    /// has compiled again, open pages keep blocking with its old rules — the
    /// first list's recompile does not strip the others — and its recompile
    /// replaces them.
    @MainActor func testOpenPagesKeepAClearedListUntilItCompilesAgain() async throws {
        await compile("easylist", blocking: Self.firstPath)
        await compile("easyprivacy", blocking: Self.secondPath)
        let profile = makeProfile("Clear Cache Gap")
        let (_, _, background) = try await openBackgroundTab(on: profile)

        ruleStore.invalidateAll()
        XCTAssertFalse(ruleStore.isCompiled(list: "easylist"), "cleared lists are not compiled")
        XCTAssertNil(ruleStore.compiledRuleCount(forList: "easyprivacy"))
        await compile("easylist", blocking: Self.firstPath)
        ContentBlockerManager.shared.reapplyRuleLists()

        var outcome = try await fetchBoth(in: background)
        XCTAssertEqual(outcome.first, .blocked, "the recompiled list blocks")
        XCTAssertEqual(outcome.second, .blocked, "the list not compiled again yet still blocks with its old rules")

        await compile("easyprivacy", blocking: Self.firstPath)
        ContentBlockerManager.shared.reapplyRuleLists()

        outcome = try await fetchBoth(in: background)
        XCTAssertEqual(outcome.first, .blocked)
        XCTAssertEqual(outcome.second, .loaded, "once compiled again, the list's old rules are gone")
    }

    /// A page opened between the clear and the recompile gets the cleared
    /// lists too: WebKit still applies a list whose compiled file was removed
    /// from its store, in a new web view. A list switched off meanwhile is
    /// not attached.
    @MainActor func testAPageOpenedBeforeTheRecompileGetsTheClearedLists() async throws {
        await compile("easylist", blocking: Self.firstPath)
        await compile("easyprivacy", blocking: Self.secondPath)
        let profile = makeProfile("Clear Cache New Page")
        let (url, space, background) = try await openBackgroundTab(on: profile)

        ruleStore.invalidateAll()
        // A second clear in the gap keeps the first clear's lists.
        ruleStore.invalidateAll()
        let fresh = TabStore.shared.addTab(in: space, url: url)
        try await settle(fresh, at: url, profile: profile)

        var outcome = try await fetchBoth(in: fresh)
        XCTAssertEqual(outcome.first, .blocked, "a new page gets the cleared lists")
        XCTAssertEqual(outcome.second, .blocked)

        profile.isEasyListEnabled = false
        ContentBlockerManager.shared.reapplyRuleLists()

        for (name, tab) in [("new page", fresh), ("background", background)] {
            outcome = try await fetchBoth(in: tab)
            XCTAssertEqual(outcome.first, .loaded, "\(name): a cleared list switched off is not attached")
            XCTAssertEqual(outcome.second, .blocked, "\(name): the other cleared list still is")
        }
    }

    /// The kept lists are only for attaching: what Settings shows stays
    /// cleared, and nothing comes back in a store opened on the same folder
    /// (the next launch, TASK-202).
    @MainActor func testTheKeptListsAreNeitherCompiledNorStored() async throws {
        await compile("easylist", blocking: Self.firstPath)
        ruleStore.invalidateAll()

        XCTAssertFalse(ruleStore.isCompiled(list: "easylist"))
        XCTAssertNil(ruleStore.compiledRuleCount(forList: "easylist"))
        XCTAssertEqual(ruleStore.attachableLists(forList: "easylist").count, 1, "kept for attaching")
        XCTAssertTrue(ruleStore.attachableLists(forList: "easyprivacy").isEmpty, "never compiled, nothing kept")

        // The removal runs on WebKit's queue; a store opened before it lands
        // would still find the file.
        let ruleListStore = try XCTUnwrap(WKContentRuleListStore(url: directory))
        try await waitUntil("the cleared list is removed from WebKit's store") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                ruleListStore.getAvailableContentRuleListIdentifiers { continuation.resume(returning: ($0 ?? []).isEmpty) }
            }
        }
        let relaunched = ContentRuleStore(storage: ContentBlockerStorage(
            ruleListStore: WKContentRuleListStore(url: directory),
            filterListCacheDirectory: directory,
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))))
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            relaunched.lookUpList(identifier: "easylist") { continuation.resume(returning: $0.count) }
        }
        XCTAssertEqual(found, 0, "the next launch finds nothing")
        XCTAssertTrue(relaunched.attachableLists(forList: "easylist").isEmpty)
    }
}
