import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-50: every tab whose web view carries the profile's extension controller
/// must be reported to that profile's `WKWebExtensionContext`s, or WebKit cannot
/// map the page back to a tab and rejects its content scripts' messages with
/// "tab not found". Favourite backing tabs and Peek tabs live outside
/// `space.tabs` / `space.pinnedEntries`, so they went unreported.
///
/// These exercise the `ExtensionTabLifecycle` seam with a recording notifier, so
/// no real extension has to be installed: the assertions are about *which*
/// events the store and the window model produce, for which tab and profile.
@MainActor
final class ExtensionTabLifecycleTests: XCTestCase {

    // MARK: - Recording notifier

    private struct Record: Equatable, CustomStringConvertible {
        enum Event: String { case open, close, activate, change }
        let event: Event
        let tabID: UUID
        let profileID: UUID
        /// The properties named by a `.change` event; empty for every other
        /// event. Lets a section move assert *which* property it announced
        /// (TASK-59) rather than just that something changed.
        let properties: WKWebExtension.TabChangedProperties
        /// Whether some container the window enumeration reads already held the
        /// tab when the event was reported — a space's tabs or pinned tabs, the
        /// profile's favourites, or a peek of one of those. The contexts can
        /// only place a tab `tabs(for:)` already enumerates, which is exactly
        /// what the placement rule guarantees (TASK-52).
        let listed: Bool

        var description: String { "\(event.rawValue)(\(tabID.uuidString.prefix(4)))" }
    }

    private final class RecordingNotifier: ExtensionTabLifecycleNotifying {
        var records: [Record] = []
        /// The store whose lists decide `Record.listed`; set by the fixture.
        weak var store: TabStore?

        /// The enumeration a window reports to a context, flattened: every
        /// space's normal and pinned tabs, the profile's favourites, and the
        /// peek of any of those.
        private func isListed(_ tab: BrowserTab, in profile: Profile) -> Bool {
            guard let store else { return false }
            let hosts = store.spaces.flatMap { $0.tabs + $0.pinnedTabs } + profile.favoriteTabs
            return hosts.contains { $0 === tab || $0.peekTab === tab }
        }

        func didOpen(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?) {
            records.append(Record(event: .open, tabID: tab.id, profileID: profile.id,
                                  properties: [], listed: isListed(tab, in: profile)))
        }
        func didClose(_ tab: BrowserTab, in profile: Profile) {
            records.append(Record(event: .close, tabID: tab.id, profileID: profile.id,
                                  properties: [], listed: false))
        }
        func didActivate(_ tab: BrowserTab, previousActiveTab: BrowserTab?, in profile: Profile,
                         contexts: [WKWebExtensionContext]?) {
            records.append(Record(event: .activate, tabID: tab.id, profileID: profile.id,
                                  properties: [], listed: false))
        }
        func didChangeProperties(_ tab: BrowserTab, in profile: Profile,
                                 properties: WKWebExtension.TabChangedProperties) {
            records.append(Record(event: .change, tabID: tab.id, profileID: profile.id,
                                  properties: properties,
                                  listed: isListed(tab, in: profile)))
        }
    }

    private var notifier = RecordingNotifier()
    private var previousNotifier: (any ExtensionTabLifecycleNotifying)!
    private var createdTabs: [BrowserTab] = []
    /// Lent to `TabStore.shared` by `sharedStoreSpace()`, taken back in tearDown.
    private var sharedSpaceIDs: [UUID] = []
    private var sharedProfiles: [Profile] = []
    /// `basePath`s of the throwaway extension fixtures this suite builds.
    private var tempDirs: [URL] = []

    override func setUp() {
        super.setUp()
        notifier = RecordingNotifier()
        previousNotifier = ExtensionTabLifecycle.notifier
        ExtensionTabLifecycle.notifier = notifier
    }

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        for id in sharedSpaceIDs {
            TabStore.shared.space(withID: id)?.tabs.forEach { $0.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        sharedSpaceIDs.removeAll()
        for profile in sharedProfiles {
            for favorite in profile.favorites { favorite.tab?.teardown() }
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        sharedProfiles.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        ExtensionTabLifecycle.notifier = previousNotifier
        super.tearDown()
    }

    /// Only the events for `tab` — the notifier is a process-wide seam, so a
    /// stray event from another store must not fail an assertion here.
    private func events(for tab: BrowserTab) -> [Record.Event] {
        notifier.records.filter { $0.tabID == tab.id }.map(\.event)
    }

    private func profileIDs(for tab: BrowserTab) -> [UUID] {
        notifier.records.filter { $0.tabID == tab.id }.map(\.profileID)
    }

    /// Whether the tab was enumerable at each of its open events — one entry per
    /// open, so "reported exactly once, and only once listed" is one assertion.
    private func listedAtOpen(_ tab: BrowserTab) -> [Bool] {
        notifier.records.filter { $0.tabID == tab.id && $0.event == .open }.map(\.listed)
    }

    /// The properties each `.change` event named, in order (TASK-59).
    private func changedProperties(for tab: BrowserTab) -> [WKWebExtension.TabChangedProperties] {
        notifier.records.filter { $0.tabID == tab.id && $0.event == .change }.map(\.properties)
    }

    /// Whether the tab was enumerable at each of its change events — a property
    /// change resolves the tab's window and index just like an open does.
    private func listedAtChange(_ tab: BrowserTab) -> [Bool] {
        notifier.records.filter { $0.tabID == tab.id && $0.event == .change }.map(\.listed)
    }

    // MARK: - Fixture

    private struct Fixture {
        let store: TabStore
        let profile: Profile
        let space: Space
        let observer: ExtensionTabObserver
    }

    /// A private store (its own in-memory database) with one profile, one space
    /// and an `ExtensionTabObserver` bound to it, so store mutations produce the
    /// same notifications they do in the app.
    private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Lifecycle")
        let space = store.addSpace(name: "Lifecycle", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        let observer = ExtensionTabObserver()
        store.addObserver(observer)
        notifier.store = store
        notifier.records.removeAll()
        return Fixture(store: store, profile: profile, space: space, observer: observer)
    }

    private let favoriteURL = URL(string: "https://calendar.example.com/r")!

    /// Adds a dormant favourite tile and returns it.
    private func dormantFavorite(in f: Fixture) throws -> Favorite {
        XCTAssertTrue(f.store.addFavoriteFromEntry(url: favoriteURL, title: "Calendar", faviconURL: nil,
                                                   favicon: nil, profileID: f.profile.id,
                                                   at: f.profile.favorites.count))
        return try XCTUnwrap(f.profile.favorites.last)
    }

    /// Adds a dormant favourite and clicks it (`activateFavorite`), returning the
    /// favourite and its new live backing tab.
    private func liveFavorite(in f: Fixture) throws -> (Favorite, BrowserTab) {
        let favorite = try dormantFavorite(in: f)
        f.store.activateFavorite(id: favorite.id, profileID: f.profile.id, in: f.space)
        let tab = try XCTUnwrap(favorite.tab, "the favourite should have a live backing tab")
        createdTabs.append(tab)
        return (favorite, tab)
    }

    /// Spins the main run loop until `tab` has `count` recorded events or the
    /// deadline passes — the seam's observers deliver on RunLoop.main.
    private func waitForEvents(of tab: BrowserTab, count: Int, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while events(for: tab).count < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Favourite activation

    func testActivateFavoriteReportsTheBackingTabOpen() throws {
        let f = try makeFixture()
        let (_, tab) = try liveFavorite(in: f)

        XCTAssertEqual(events(for: tab), [.open])
        XCTAssertEqual(profileIDs(for: tab), [f.profile.id])
        XCTAssertEqual(listedAtOpen(tab), [true],
                       "the favourite holds the tab before the contexts hear about it")
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile,
                      "the tab remembers who was told, so teardown can close it")
    }

    func testDeactivateFavoriteReportsTheBackingTabClosedExactlyOnce() throws {
        let f = try makeFixture()
        let (favorite, tab) = try liveFavorite(in: f)

        f.store.deactivateFavorite(id: favorite.id, profileID: f.profile.id)

        XCTAssertEqual(events(for: tab), [.open, .close])
        XCTAssertNil(tab.extensionRegisteredProfile)
        XCTAssertNil(favorite.tab, "the favourite is dormant again")

        // The tile teardown path can run again (peek close fires two teardowns).
        tab.teardown()
        XCTAssertEqual(events(for: tab), [.open, .close], "close is idempotent")
    }

    func testRemoveFavoriteReportsTheBackingTabClosed() throws {
        let f = try makeFixture()
        let (favorite, tab) = try liveFavorite(in: f)

        f.store.removeFavorite(id: favorite.id, profileID: f.profile.id)

        XCTAssertEqual(events(for: tab), [.open, .close])
        XCTAssertTrue(f.profile.favorites.isEmpty)
    }

    /// Dragging a tab onto the favourites bar detaches it and re-homes the same
    /// live tab under the favourite. Same profile, same web view, and the pinned
    /// flag was false on both sides — so the contexts hear nothing at all
    /// (TASK-59); the tab they already know is simply still open.
    func testDetachThenAddFavoriteKeepsTheTabOpenSilently() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)
        XCTAssertEqual(events(for: tab), [.open], "insertTab reports the new tab")

        f.store.detachTab(id: tab.id, from: f.space)
        f.store.addFavorite(from: tab, profileID: f.profile.id)

        XCTAssertEqual(events(for: tab), [.open],
                       "a same-profile section move is a hand-off, not a close and re-open")
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
        XCTAssertTrue(f.profile.favorites.first?.tab === tab)
    }

    // MARK: - Favourite property changes

    func testFavoriteTabPropertyChangeReachesTheContexts() throws {
        let f = try makeFixture()
        let (_, tab) = try liveFavorite(in: f)

        tab.title = "Calendar — Week"
        waitForEvents(of: tab, count: 2)

        XCTAssertEqual(events(for: tab), [.open, .change],
                       "a favourite tab's changes used to be dropped by subscribeToTab")
        XCTAssertEqual(Set(profileIDs(for: tab)), [f.profile.id])
    }

    /// A Peek is held only by its host, so no store list ever names it — the
    /// seam's own observers are what carry its changes.
    func testPeekTabPropertyChangeReachesTheContexts() throws {
        let f = try makeFixture()
        let peek = makeLiveTab()
        ExtensionTabLifecycle.didOpen(peek, in: f.profile)

        peek.title = "Peeked"
        waitForEvents(of: peek, count: 2)

        XCTAssertEqual(events(for: peek), [.open, .change])
    }

    /// A pinned tab's updates ride `tabStoreDidUpdatePinnedEntry`, which nothing
    /// mapped to the contexts; the seam observes the tab directly instead.
    func testPinnedTabPropertyChangeReachesTheContexts() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)
        f.store.pinTab(id: tab.id, in: f.space)
        XCTAssertTrue(f.space.pinnedTabs.contains { $0 === tab }, "the tab is pinned")

        tab.title = "Pinned — Week"
        waitForEvents(of: tab, count: 2)

        XCTAssertTrue(events(for: tab).contains(.change))
        XCTAssertEqual(Set(profileIDs(for: tab)), [f.profile.id])
    }

    /// `didClose` removes the observers, so a tab nobody has open stops talking.
    func testPropertyChangesStopAfterClose() throws {
        let f = try makeFixture()
        let tab = makeLiveTab()
        ExtensionTabLifecycle.didOpen(tab, in: f.profile)
        ExtensionTabLifecycle.didClose(tab)

        tab.title = "Late"
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(events(for: tab), [.open, .close])
    }

    // MARK: - Negative cases

    func testTeardownOfANeverOpenedTabReportsNothing() {
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        XCTAssertNil(tab.extensionRegisteredProfile)

        tab.teardown()
        tab.teardown()

        XCTAssertTrue(events(for: tab).isEmpty, "a tab no context was told about has nothing to close")
    }

    // MARK: - Window tab list

    private func makeLiveTab() -> BrowserTab {
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        createdTabs.append(tab)
        return tab
    }

    private func makeSleepingTab() -> BrowserTab {
        BrowserTab(id: UUID(), title: "Parked", url: URL(string: "https://example.com/parked"),
                   faviconURL: nil, cachedInteractionState: nil, spaceID: UUID())
    }

    func testExtensionWindowTabsOrdersPinnedNormalFavoritesWithLivePeeksInline() {
        let pinned = makeLiveTab()
        let normal = makeLiveTab()
        let favorite = makeLiveTab()
        let peek = makeLiveTab()
        normal.peekTab = peek

        let tabs = extensionWindowTabs(pinned: [pinned], normal: [normal], favorites: [favorite])

        XCTAssertEqual(tabs.map(\.id), [pinned.id, normal.id, peek.id, favorite.id],
                       "a live peek follows the tab hosting it")
    }

    func testExtensionWindowTabsOmitsAParkedPeek() {
        let host = makeLiveTab()
        host.peekTab = makeSleepingTab()

        let tabs = extensionWindowTabs(pinned: [], normal: [host], favorites: [])

        XCTAssertEqual(tabs.map(\.id), [host.id],
                       "a peek with no web view has nothing for WebKit to map")
    }

    func testExtensionWindowTabsIncludesAFavoritesLivePeek() {
        let favorite = makeLiveTab()
        let peek = makeLiveTab()
        favorite.peekTab = peek

        let tabs = extensionWindowTabs(pinned: [], normal: [], favorites: [favorite])

        XCTAssertEqual(tabs.map(\.id), [favorite.id, peek.id])
    }

    // MARK: - Profile swap

    /// Editing a space onto another profile sleeps its live tabs. Sleeping is not
    /// closing, so without an explicit close the old profile would keep a phantom
    /// open tab that nothing can ever close.
    func testProfileSwapClosesSpaceTabsInTheOldProfile() throws {
        let f = try makeFixture()
        let other = f.store.addProfile(name: "Other")
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)

        f.store.updateSpace(id: f.space.id, name: f.space.name, emoji: f.space.emoji,
                            colorHex: f.space.colorHex, profileID: other.id)

        XCTAssertEqual(events(for: tab), [.open, .close])
        XCTAssertEqual(profileIDs(for: tab), [f.profile.id, f.profile.id],
                       "the close names the profile that was told it was open")
        XCTAssertNil(tab.extensionRegisteredProfile)
        XCTAssertTrue(tab.isSleeping)
    }

    // MARK: - Ordering and lookups

    /// The contexts resolve a tab's window and index when it is reported, so a
    /// favourite must already be listed by then.
    func testAddFavoriteReportsOpenOnlyOnceListed() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)

        f.store.detachTab(id: tab.id, from: f.space)
        f.store.addFavorite(from: tab, profileID: f.profile.id)

        XCTAssertEqual(listedAtOpen(tab), [true],
                       "the one open names a tab the window already enumerates")
    }

    func testFavoriteBackedByAndPeekHostLookups() throws {
        let f = try makeFixture()
        let (favorite, favoriteTab) = try liveFavorite(in: f)
        let normal = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(normal)

        let found = try XCTUnwrap(f.store.favorite(backedBy: favoriteTab))
        XCTAssertTrue(found.profile === f.profile)
        XCTAssertTrue(found.favorite === favorite)
        XCTAssertNil(f.store.favorite(backedBy: normal), "a normal tab backs no favourite")

        let normalPeek = makeLiveTab()
        normal.peekTab = normalPeek
        XCTAssertTrue(f.store.tab(hostingPeek: normalPeek) === normal)

        let favoritePeek = makeLiveTab()
        favoriteTab.peekTab = favoritePeek
        XCTAssertTrue(f.store.tab(hostingPeek: favoritePeek) === favoriteTab)

        XCTAssertNil(f.store.tab(hostingPeek: makeLiveTab()), "an unhosted tab has no host")
    }

    // MARK: - Parked peeks (TASK-57)

    /// A host tab with a live, registered Peek.
    private func hostWithLivePeek(in f: Fixture) -> (host: BrowserTab, peek: BrowserTab) {
        let host = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(host)
        let peek = BrowserTab(configuration: f.space.makeWebViewConfiguration())
        createdTabs.append(peek)
        host.peekTab = peek
        XCTAssertEqual(events(for: peek), [.open], "precondition: the peek is registered")
        return (host, peek)
    }

    /// Parking a Peek is closing it: it is never woken as the same object, so a
    /// registered parked peek would be a phantom open tab with no web view.
    func testHostSleepClosesItsParkedPeek() throws {
        let f = try makeFixture()
        let (host, peek) = hostWithLivePeek(in: f)

        host.sleep(force: true)

        XCTAssertEqual(events(for: peek), [.open, .close])
        XCTAssertNil(peek.extensionRegisteredProfile)
        XCTAssertNil(peek.webView, "the peek released its web view with the host")
        XCTAssertTrue(host.peekTab === peek, "the host keeps the reference the badge reads")
        XCTAssertEqual(events(for: host), [.open], "the host is asleep, not closed")

        // `showPeekOverlay` tears the orphan down when the host is next peeked.
        peek.teardown()
        XCTAssertEqual(events(for: peek), [.open, .close], "close is idempotent")
    }

    func testHostRetargetClosesItsParkedPeek() throws {
        let f = try makeFixture()
        let (host, peek) = hostWithLivePeek(in: f)

        host.retarget(to: URL(string: "webkit-extension://fresh-origin/options.html")!)

        XCTAssertEqual(events(for: peek), [.open, .close])
        XCTAssertNil(peek.extensionRegisteredProfile)
        XCTAssertNil(peek.webView)
        XCTAssertTrue(host.peekTab === peek)
    }

    /// An extension rehost retargets a peek that is itself showing the dead
    /// origin — `retargetExtensionPages` calls `retarget` on the *peek*, not on
    /// its host — which releases the peek's web view. That parks it just as the
    /// host's own sleep does, so the contexts must hear the close there too.
    func testExtensionRehostClosesARetargetedPeek() throws {
        let f = try makeFixture()
        let (host, peek) = hostWithLivePeek(in: f)
        // The peek's test web view never loaded anything, so `showsExtensionPage`
        // falls back to `url` — which is what puts it on the dying origin.
        peek.url = URL(string: "webkit-extension://old-origin/page.html")!
        XCTAssertEqual(events(for: peek), [.open], "precondition: the peek is registered")

        f.profile.retargetExtensionPages(from: URL(string: "webkit-extension://old-origin/")!,
                                         to: URL(string: "webkit-extension://new-origin/")!,
                                         in: f.store)

        XCTAssertEqual(events(for: peek), [.open, .close])
        XCTAssertNil(peek.webView, "the retarget released the peek's web view")
        XCTAssertNil(peek.extensionRegisteredProfile)
        XCTAssertTrue(host.peekTab === peek, "the host keeps the reference the badge reads")
        XCTAssertEqual(host.peekURL?.host, "new-origin",
                       "and the parked URL a re-present loads names the new origin")
    }

    /// The gate: a non-forced sleep spares a peek that is playing audio, and a
    /// peek that kept its web view is still a reachable page.
    func testHostSleepKeepsAPeekThatKeptItsWebView() throws {
        let f = try makeFixture()
        let (host, peek) = hostWithLivePeek(in: f)
        peek.isPlayingAudio = true

        host.sleep()

        XCTAssertNotNil(peek.webView, "an audible peek does not release its web view")
        XCTAssertEqual(events(for: peek), [.open], "so it stays an open tab")
        XCTAssertTrue(peek.extensionRegisteredProfile === f.profile)
    }

    /// A peek parked by the previous session (`peekURL` restored, no peek tab) has
    /// nothing to close and must stay that way.
    func testHostSleepWithASessionRestoredParkedPeekReportsNothing() throws {
        let f = try makeFixture()
        let host = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(host)
        host.peekURL = URL(string: "https://peek.example.org/article")
        host.peekFaviconURL = URL(string: "https://peek.example.org/favicon.ico")
        XCTAssertNil(host.peekTab, "precondition: parked by a restore, no peek object")

        host.sleep(force: true)

        XCTAssertEqual(events(for: host), [.open])
        XCTAssertTrue(notifier.records.allSatisfy { $0.event != .close }, "nothing was closed")
        XCTAssertEqual(host.peekURL?.absoluteString, "https://peek.example.org/article",
                       "the parked state the badge and a re-present need is untouched")
    }

    // MARK: - Section moves (TASK-59)

    /// The rule: a live tab moving between the tab list, the pinned section and
    /// the favourites bar of one profile keeps its registration, and the
    /// contexts hear exactly one `.pinned` change when the flag flips — nothing
    /// when it does not. Six moves, all of them below.

    func testPinningATabAnnouncesThePinnedFlagAndKeepsTheRegistration() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)
        XCTAssertFalse(f.store.isPinned(tab), "precondition: a normal tab is unpinned")

        f.store.pinTab(id: tab.id, in: f.space)

        XCTAssertEqual(events(for: tab), [.open, .change], "no close and re-open")
        XCTAssertEqual(changedProperties(for: tab), [.pinned])
        XCTAssertEqual(listedAtChange(tab), [true],
                       "the entry holds the tab before the contexts hear about the flip")
        XCTAssertTrue(f.store.isPinned(tab))
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
    }

    func testUnpinningATabAnnouncesThePinnedFlag() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)
        f.store.pinTab(id: tab.id, in: f.space)

        XCTAssertTrue(f.store.unpinTab(id: tab.id, in: f.space))

        XCTAssertEqual(events(for: tab), [.open, .change, .change])
        XCTAssertEqual(changedProperties(for: tab), [.pinned, .pinned])
        XCTAssertEqual(listedAtChange(tab), [true, true])
        XCTAssertFalse(f.store.isPinned(tab))
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
    }

    /// Pin's undo is `unpinTab`, so it announces through the same function.
    func testPinUndoAnnouncesTheFlipBack() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)

        f.store.undoManager.removeAllActions()
        f.store.pinTab(id: tab.id, in: f.space)
        f.store.undoManager.undo()

        XCTAssertFalse(f.store.isPinned(tab), "Undo Pin Tab unpinned it")
        XCTAssertEqual(changedProperties(for: tab), [.pinned, .pinned])
        XCTAssertEqual(events(for: tab).filter { $0 != .change }, [.open], "a hand-off both ways")
    }

    /// Unpin's undo re-pins inline instead of calling `pinTab`, so it has to
    /// announce for itself.
    func testUnpinUndoAnnouncesTheFlipBack() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)
        f.store.pinTab(id: tab.id, in: f.space)

        f.store.undoManager.removeAllActions()
        XCTAssertTrue(f.store.unpinTab(id: tab.id, in: f.space))
        f.store.undoManager.undo()

        XCTAssertTrue(f.store.isPinned(tab), "Undo Unpin Tab re-pinned it")
        XCTAssertEqual(changedProperties(for: tab), [.pinned, .pinned, .pinned])
        XCTAssertEqual(events(for: tab).filter { $0 != .change }, [.open])
    }

    /// A move that cannot happen announces nothing: `unpinTab` on a tab that is
    /// not pinned changes no flag.
    func testRefusedUnpinAnnouncesNothing() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)

        XCTAssertFalse(f.store.unpinTab(id: tab.id, in: f.space))

        XCTAssertEqual(events(for: tab), [.open])
    }

    /// Tab list <-> favourites: the flag is false on both sides, so neither
    /// direction announces anything.
    func testTabListToFavoritesAndBackAnnounceNothing() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)

        XCTAssertTrue(f.store.moveTabToFavorites(id: tab.id, from: f.space, profileID: f.profile.id))
        XCTAssertFalse(f.store.isPinned(tab))
        XCTAssertEqual(events(for: tab), [.open])

        let favorite = try XCTUnwrap(f.profile.favorites.first)
        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: favorite.id, profileID: f.profile.id,
                                                   in: f.space, at: 0))

        XCTAssertEqual(events(for: tab), [.open], "still the same open tab, still unpinned")
        XCTAssertFalse(f.store.isPinned(tab))
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
    }

    /// Pinned entry -> favourites, as the sidebar drop does it: the store moves
    /// the entry's live tab under a favourite and announces the flip itself.
    func testPinnedEntryToFavoritesAnnouncesThePinnedFlag() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)
        f.store.pinTab(id: tab.id, in: f.space)
        let entry = try XCTUnwrap(f.space.pinnedEntries.first { $0.tab === tab })

        XCTAssertTrue(f.store.moveTabToFavorites(id: entry.id, from: f.space, profileID: f.profile.id))

        XCTAssertEqual(events(for: tab), [.open, .change, .change],
                       "pin, then the move out of the pinned section — no close")
        XCTAssertEqual(changedProperties(for: tab), [.pinned, .pinned])
        XCTAssertEqual(listedAtChange(tab), [true, true],
                       "the favourite holds the tab before the flip is announced")
        XCTAssertFalse(f.store.isPinned(tab), "a favourite tile is not pinned")
        XCTAssertTrue(f.profile.favorites.first?.tab === tab)
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
    }

    /// Favourites -> pinned section: the live backing tab becomes the new
    /// entry's, so the flag flips on.
    func testFavoriteToPinnedAnnouncesThePinnedFlag() throws {
        let f = try makeFixture()
        let (favorite, tab) = try liveFavorite(in: f)
        XCTAssertFalse(f.store.isPinned(tab))

        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: favorite.id, profileID: f.profile.id,
                                                      in: f.space, at: 0))

        XCTAssertEqual(events(for: tab), [.open, .change])
        XCTAssertEqual(changedProperties(for: tab), [.pinned])
        XCTAssertEqual(listedAtChange(tab), [true])
        XCTAssertTrue(f.store.isPinned(tab))
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
    }

    /// A pinned split moves as a block, and both members' flags flip (§12).
    func testPinningAndUnpinningASplitAnnouncesBothMembers() throws {
        let f = try makeFixture()
        let left = f.store.addTab(in: f.space, url: favoriteURL)
        let right = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(contentsOf: [left, right])
        let groupID = UUID()
        for tab in [left, right] {
            tab.splitGroupID = groupID
            tab.splitFraction = 0.5
        }

        f.store.pinSplitGroup(groupID: groupID, in: f.space)
        XCTAssertTrue(f.store.isPinned(left))
        XCTAssertTrue(f.store.isPinned(right))
        XCTAssertEqual(changedProperties(for: left), [.pinned])
        XCTAssertEqual(changedProperties(for: right), [.pinned])

        XCTAssertTrue(f.store.unpinSplitGroup(groupID: groupID, toGapIndex: 0, in: f.space))

        XCTAssertFalse(f.store.isPinned(left))
        XCTAssertFalse(f.store.isPinned(right))
        XCTAssertEqual(events(for: left), [.open, .change, .change])
        XCTAssertEqual(events(for: right), [.open, .change, .change])
        XCTAssertEqual(changedProperties(for: left), [.pinned, .pinned])
        XCTAssertEqual(changedProperties(for: right), [.pinned, .pinned])
    }

    /// What the flag itself answers, through the conformance WebKit calls. The
    /// context is a real one so the signature is exercised as WebKit uses it;
    /// it is never loaded into a controller, because `isPinned(for:)` answers
    /// from the store and ignores which context is asking.
    func testIsPinnedForContextFollowsTheSection() async throws {
        let (space, _) = sharedStoreSpace()
        let context = try await makeUnloadedContext()
        let tab = TabStore.shared.addTab(in: space, url: favoriteURL)
        createdTabs.append(tab)

        XCTAssertFalse(tab.isPinned(for: context), "a normal tab is unpinned")

        TabStore.shared.pinTab(id: tab.id, in: space)
        XCTAssertTrue(tab.isPinned(for: context), "tabs.query({pinned: true}) must find it")

        XCTAssertTrue(TabStore.shared.unpinTab(id: tab.id, in: space))
        XCTAssertFalse(tab.isPinned(for: context))

        TabStore.shared.detachTab(id: tab.id, from: space)
        TabStore.shared.addFavorite(from: tab, profileID: space.profileID)
        XCTAssertFalse(tab.isPinned(for: context), "a favourite tile is not pinned")
        XCTAssertNotNil(TabStore.shared.favorite(backedBy: tab),
                        "and tabs.get still resolves it: it is still an open tab")
    }

    /// A `WKWebExtensionContext` over a throwaway fixture, for conformance
    /// methods that take a context and don't consult it. Never loaded into a
    /// profile's controller — the fixture's bundle is removed in tearDown.
    private func makeUnloadedContext() async throws -> WKWebExtensionContext {
        let ext = try await makeOptionsPageTestExtension(idPrefix: "lifecycle-pinned",
                                                         name: "Pinned Flag")
        tempDirs.append(ext.basePath)
        return WKWebExtensionContext(for: try XCTUnwrap(ext.wkExtension))
    }

    // MARK: - Placement (TASK-52)

    /// The rule: a tab is reported the moment it enters a container the window
    /// enumeration reads — `space.tabs` for a normal tab, and nothing else
    /// reports it, so the count is exactly one.
    func testInsertingANormalTabReportsItOpenOnceAndListed() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)

        XCTAssertEqual(events(for: tab), [.open])
        XCTAssertEqual(listedAtOpen(tab), [true])
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
    }

    /// A dormant pinned tile has no tab to report; clicking it (`entry.tab = …`)
    /// is the placement.
    func testActivatingAPinnedEntryReportsItsBackingTabOnceAndListed() throws {
        let f = try makeFixture()
        let entry = PinnedEntry(pinnedURL: favoriteURL, pinnedTitle: "Calendar")
        f.space.pinnedEntries.append(entry)
        XCTAssertTrue(notifier.records.isEmpty, "a dormant entry has no tab to report")

        XCTAssertTrue(f.store.activatePinnedEntry(id: entry.id, in: f.space))
        let tab = try XCTUnwrap(entry.tab)
        createdTabs.append(tab)

        XCTAssertEqual(events(for: tab), [.open])
        XCTAssertEqual(listedAtOpen(tab), [true],
                       "the entry is already in pinnedEntries when its tab arrives")
    }

    /// A Peek belongs to no list at all — it is enumerated behind its host, so
    /// pointing the host at it is what reports it.
    func testAssigningAPeekReportsItOpenAndListed() throws {
        let f = try makeFixture()
        let host = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(host)
        let peek = BrowserTab(configuration: f.space.makeWebViewConfiguration())
        createdTabs.append(peek)
        XCTAssertTrue(events(for: peek).isEmpty, "an unplaced peek is nobody's tab yet")

        host.peekTab = peek

        XCTAssertEqual(events(for: peek), [.open])
        XCTAssertEqual(listedAtOpen(peek), [true])
        XCTAssertTrue(peek.extensionRegisteredProfile === f.profile)
    }

    /// `wake()` builds a *new* web view for a tab that never left its space, and
    /// WebKit maps a tab to a particular web view — so the wake re-opens it.
    ///
    /// Driven through `TabStore.shared`: `BrowserTab.wake()` resolves its space
    /// there, so a private fixture store cannot produce a woken web view built
    /// from a profile's configuration. The space and profile are handed back in
    /// tearDown.
    func testWakingAPlacedSleepingTabReportsTheNewWebView() throws {
        let (space, profile) = sharedStoreSpace()
        let tab = sleepingTab(favoriteURL, in: space)
        createdTabs.append(tab)

        space.tabs.append(tab)
        XCTAssertTrue(events(for: tab).isEmpty,
                      "a tab with no web view injects no content scripts, so there is nothing to map")

        tab.wake()

        XCTAssertEqual(events(for: tab), [.open])
        XCTAssertEqual(listedAtOpen(tab), [true])
        XCTAssertTrue(tab.extensionRegisteredProfile === profile)
    }

    // MARK: - Placement negatives (TASK-52)

    /// The rule's other half: a configuration with no extension controller runs
    /// no extension code, so placing such a tab reports nothing — incognito and
    /// test web views must stay invisible to the contexts.
    func testPlacingATabWithNoExtensionControllerReportsNothing() throws {
        let f = try makeFixture()
        let tab = BrowserTab(configuration: WKWebViewConfiguration())
        createdTabs.append(tab)

        f.space.tabs.append(tab)

        XCTAssertTrue(events(for: tab).isEmpty)
        XCTAssertNil(tab.extensionRegisteredProfile)
    }

    /// Moving a tab between two spaces of one profile is a pair of raw list
    /// mutations — no store API covers it, so no remove notification closes the
    /// tab. The arrival must not re-open it either: it is still registered, and
    /// its web view is the one WebKit already maps.
    func testMovingATabBetweenSpacesOfOneProfileReportsNothingNew() throws {
        let f = try makeFixture()
        let other = f.store.addSpace(name: "Other", emoji: "🧪", colorHex: "007AFF",
                                     profileID: f.profile.id)
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)

        f.space.tabs.removeAll { $0 === tab }
        other.tabs.append(tab)

        XCTAssertEqual(events(for: tab), [.open],
                       "one open and no close: the move went around the store's remove path")
        XCTAssertTrue(tab.extensionRegisteredProfile === f.profile)
    }

    /// A space and profile in `TabStore.shared`, for the one path that resolves
    /// itself through the singleton (`BrowserTab.wake()`).
    private func sharedStoreSpace() -> (Space, Profile) {
        let profile = TabStore.shared.addProfile(name: "Lifecycle Wake")
        sharedProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "Lifecycle Wake", emoji: "🧪",
                                             colorHex: "007AFF", profileID: profile.id)
        sharedSpaceIDs.append(space.id)
        notifier.store = TabStore.shared
        notifier.records.removeAll()
        return (space, profile)
    }
}
