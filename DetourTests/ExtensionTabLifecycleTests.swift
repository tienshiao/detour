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
        /// Whether the profile already listed the tab as a favourite's backing
        /// tab when the event was reported — the contexts can only place a
        /// favourite that `tabs(for:)` already enumerates.
        let listedAsFavorite: Bool

        var description: String { "\(event.rawValue)(\(tabID.uuidString.prefix(4)))" }
    }

    private final class RecordingNotifier: ExtensionTabLifecycleNotifying {
        var records: [Record] = []

        func didOpen(_ tab: BrowserTab, in profile: Profile, contexts: [WKWebExtensionContext]?) {
            records.append(Record(event: .open, tabID: tab.id, profileID: profile.id,
                                  listedAsFavorite: profile.favoriteTabs.contains { $0 === tab }))
        }
        func didClose(_ tab: BrowserTab, in profile: Profile) {
            records.append(Record(event: .close, tabID: tab.id, profileID: profile.id,
                                  listedAsFavorite: false))
        }
        func didActivate(_ tab: BrowserTab, previousActiveTab: BrowserTab?, in profile: Profile,
                         contexts: [WKWebExtensionContext]?) {
            records.append(Record(event: .activate, tabID: tab.id, profileID: profile.id,
                                  listedAsFavorite: false))
        }
        func didChangeProperties(_ tab: BrowserTab, in profile: Profile,
                                 properties: WKWebExtension.TabChangedProperties) {
            records.append(Record(event: .change, tabID: tab.id, profileID: profile.id,
                                  listedAsFavorite: false))
        }
    }

    private var notifier = RecordingNotifier()
    private var previousNotifier: (any ExtensionTabLifecycleNotifying)!
    private var createdTabs: [BrowserTab] = []

    override func setUp() {
        super.setUp()
        notifier = RecordingNotifier()
        previousNotifier = ExtensionTabLifecycle.notifier
        ExtensionTabLifecycle.notifier = notifier
    }

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
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

    /// Dragging a tab onto the favourites bar detaches it (which reports it
    /// closed) and re-homes the same live tab under the favourite.
    func testDetachThenAddFavoriteClosesAndReopensTheSameTab() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.space, url: favoriteURL)
        createdTabs.append(tab)
        XCTAssertEqual(events(for: tab), [.open], "insertTab reports the new tab")

        f.store.detachTab(id: tab.id, from: f.space)
        f.store.addFavorite(from: tab, profileID: f.profile.id)

        XCTAssertEqual(events(for: tab), [.open, .close, .open])
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

        XCTAssertEqual(notifier.records.last(where: { $0.tabID == tab.id && $0.event == .open })?
            .listedAsFavorite, true)
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
}
