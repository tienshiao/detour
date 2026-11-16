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
}
