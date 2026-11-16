import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-358: the tab opener link (`BrowserTab.parentID`).
///
/// - A pinned or favourite tab's link survives a relaunch, as a normal tab's
///   does: the session database saved it for every row but read it back only
///   for normal tabs.
/// - Which tabs count as an opener is one rule, `Space.openerTab(id:)` (a
///   normal tab, a live pinned tab or a live favourite tab of the space), used
///   by every reader that resolves the link: the Back button and the back
///   swipe (`parentTab(for:)`), the close selection, a page's `window.close()`,
///   Reopen Closed Tab and the close undos, and Move to Space and its undo.
///   Before it the readers accepted different openers.
nonisolated final class TabOpenerRuleTests: XCTestCase {

    // MARK: - Fixture (a private store)

    @MainActor private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let profile: Profile
        /// `a` and `b` share `profile`; `c` is on another profile.
        let a: Space
        let b: Space
        let c: Space
    }

    @MainActor private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Opener")
        let other = store.addProfile(name: "Opener Other")
        let a = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let b = store.addSpace(name: "B", emoji: "🅱️", colorHex: "FF3B30", profileID: profile.id)
        let c = store.addSpace(name: "C", emoji: "🇨", colorHex: "34C759", profileID: other.id)
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        return Fixture(db: db, store: store, profile: profile, a: a, b: b, c: c)
    }

    @MainActor private func inUndoGroup(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    /// A sleeping tab (no web view), so nothing loads.
    @MainActor private func makeTab(_ url: String, in space: Space, parent: BrowserTab? = nil) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), title: url, url: URL(string: url), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: space.id)
        tab.parentID = parent?.id
        return tab
    }

    /// A live favourite of `f.profile`, backed by a sleeping tab.
    @MainActor private func addFavorite(_ f: Fixture, url: String = "https://favourite.example/") -> BrowserTab {
        let tab = makeTab(url, in: f.a)
        f.store.addFavorite(from: tab, profileID: f.profile.id)
        return tab
    }

    @MainActor private func favorite(backedBy tab: BrowserTab, in f: Fixture) throws -> Favorite {
        try XCTUnwrap(f.profile.favorites.first { $0.tab === tab })
    }

    // MARK: - Relaunch

    @MainActor func testAPinnedTabsOpenerSurvivesARelaunch() throws {
        let f = try makeFixture()
        let opener = makeTab("https://opener.example/", in: f.a)
        let child = makeTab("https://child.example/", in: f.a, parent: opener)
        f.a.tabs.append(contentsOf: [opener, child])
        inUndoGroup(f.store) { f.store.pinTab(id: child.id, in: f.a) }
        XCTAssertEqual(child.parentID, opener.id, "precondition: pinning keeps the link")
        f.store.saveNow()

        let store2 = TabStore(appDB: f.db)
        _ = store2.restoreSession()

        let a2 = try XCTUnwrap(store2.spaces.first { $0.id == f.a.id })
        let restored = try XCTUnwrap(a2.pinnedEntries.first?.tab, "the pinned entry comes back live")
        XCTAssertEqual(restored.id, child.id)
        XCTAssertEqual(restored.parentID, opener.id, "the pinned tab's opener link survives the relaunch")
        XCTAssertEqual(a2.openerTab(id: opener.id)?.id, opener.id, "and still resolves: ids are kept")
    }

    @MainActor func testAPinnedTabOpenedFromAPinnedTabKeepsItsOpenerAcrossARelaunch() throws {
        let f = try makeFixture()
        let opener = makeTab("https://opener.example/", in: f.a)
        let child = makeTab("https://child.example/", in: f.a, parent: opener)
        f.a.tabs.append(contentsOf: [opener, child])
        inUndoGroup(f.store) { f.store.pinTab(id: child.id, in: f.a) }
        inUndoGroup(f.store) { f.store.pinTab(id: opener.id, in: f.a) }
        f.store.saveNow()

        let store2 = TabStore(appDB: f.db)
        _ = store2.restoreSession()

        let a2 = try XCTUnwrap(store2.spaces.first { $0.id == f.a.id })
        let restored = try XCTUnwrap(a2.pinnedTabs.first { $0.id == child.id })
        XCTAssertEqual(restored.parentID, opener.id)
        XCTAssertEqual(a2.openerTab(id: opener.id)?.id, opener.id, "a live pinned opener resolves")
    }

    @MainActor func testAFavouriteTabsOpenerSurvivesARelaunch() throws {
        let f = try makeFixture()
        let opener = makeTab("https://opener.example/", in: f.a)
        let child = makeTab("https://child.example/", in: f.a, parent: opener)
        f.a.tabs.append(contentsOf: [opener, child])
        XCTAssertTrue(f.store.moveTabToFavorites(id: child.id, from: f.a, profileID: f.profile.id))
        XCTAssertEqual(child.parentID, opener.id, "precondition: the move to the favourites keeps the link")
        f.store.saveNow()

        let store2 = TabStore(appDB: f.db)
        _ = store2.restoreSession()

        let profile2 = try XCTUnwrap(store2.profiles.first { $0.id == f.profile.id })
        let restored = try XCTUnwrap(profile2.favorites.first?.tab, "the favourite comes back live")
        XCTAssertEqual(restored.id, child.id)
        XCTAssertEqual(restored.parentID, opener.id, "the favourite's opener link survives the relaunch")
    }

    @MainActor func testANormalTabOpenedFromAFavouriteKeepsItsOpenerAcrossARelaunch() throws {
        let f = try makeFixture()
        let favouriteTab = addFavorite(f)
        let child = makeTab("https://child.example/", in: f.a, parent: favouriteTab)
        f.a.tabs.append(child)
        f.store.saveNow()

        let store2 = TabStore(appDB: f.db)
        _ = store2.restoreSession()

        let a2 = try XCTUnwrap(store2.spaces.first { $0.id == f.a.id })
        let restored = try XCTUnwrap(a2.tabs.first { $0.id == child.id })
        XCTAssertEqual(restored.parentID, favouriteTab.id)
        XCTAssertEqual(a2.openerTab(id: favouriteTab.id)?.id, favouriteTab.id,
                       "the favourite restores after the spaces, and still resolves")
    }

    // MARK: - The one rule: which tabs count

    @MainActor func testTheOpenerKinds() throws {
        let f = try makeFixture()
        let normal = makeTab("https://normal.example/", in: f.a)
        let pinned = makeTab("https://pinned.example/", in: f.a)
        let asleepPinned = makeTab("https://asleep.example/", in: f.a)
        let elsewhere = makeTab("https://elsewhere.example/", in: f.b)
        f.a.tabs.append(contentsOf: [normal, pinned, asleepPinned])
        f.b.tabs.append(elsewhere)
        inUndoGroup(f.store) { f.store.pinTab(id: pinned.id, in: f.a) }
        inUndoGroup(f.store) { f.store.pinTab(id: asleepPinned.id, in: f.a) }
        inUndoGroup(f.store) { f.store.closePinnedTab(id: asleepPinned.id, in: f.a) }
        let favouriteTab = addFavorite(f)
        let dormantFavouriteTab = addFavorite(f, url: "https://dormant.example/")
        f.store.deactivateFavorite(id: try favorite(backedBy: dormantFavouriteTab, in: f).id, profileID: f.profile.id)

        XCTAssertTrue(f.a.openerTab(id: normal.id) === normal, "a normal tab of the space")
        XCTAssertTrue(f.a.openerTab(id: pinned.id) === pinned, "a live pinned tab")
        XCTAssertTrue(f.a.openerTab(id: favouriteTab.id) === favouriteTab, "a live favourite's tab")
        XCTAssertTrue(f.b.openerTab(id: favouriteTab.id) === favouriteTab,
                      "in every space of the favourite's profile")
        XCTAssertNil(f.a.openerTab(id: asleepPinned.id), "not an asleep pinned entry")
        XCTAssertNil(f.a.openerTab(id: dormantFavouriteTab.id), "not a dormant favourite")
        XCTAssertNil(f.a.openerTab(id: elsewhere.id), "not a tab of another space")
        XCTAssertNil(f.c.openerTab(id: favouriteTab.id), "not another profile's favourite")
        XCTAssertNil(f.a.openerTab(id: UUID()), "not a closed or unknown tab")
    }

    // MARK: - Readers in the store

    @MainActor func testAReopenedChildOfAFavouriteKeepsItsOpener() throws {
        let f = try makeFixture()
        let favouriteTab = addFavorite(f)
        let child = makeTab("https://child.example/", in: f.a, parent: favouriteTab)
        let other = makeTab("https://other.example/", in: f.a)
        f.a.tabs.append(contentsOf: [child, other])
        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.a) }

        let reopened = try XCTUnwrap(f.store.reopenClosedTab(in: f.a))

        XCTAssertEqual(reopened.parentID, favouriteTab.id, "a live favourite is an opener Back selects")
    }

    @MainActor func testUndoCloseOfAChildOfAFavouriteKeepsItsOpenerOnlyWhileLive() throws {
        let f = try makeFixture()
        let favouriteTab = addFavorite(f)
        let child = makeTab("https://child.example/", in: f.a, parent: favouriteTab)
        let other = makeTab("https://other.example/", in: f.a)
        f.a.tabs.append(contentsOf: [child, other])

        inUndoGroup(f.store) { f.store.closeTab(id: child.id, in: f.a) }
        f.store.undoManager.undo()
        XCTAssertEqual(f.a.tabs.first { $0.url == child.url }?.parentID, favouriteTab.id)

        let again = try XCTUnwrap(f.a.tabs.first { $0.url == child.url })
        inUndoGroup(f.store) { f.store.closeTab(id: again.id, in: f.a) }
        f.store.deactivateFavorite(id: try favorite(backedBy: favouriteTab, in: f).id, profileID: f.profile.id)
        f.store.undoManager.undo()
        XCTAssertNil(f.a.tabs.first { $0.url == child.url }?.parentID, "a dormant favourite is no opener")
    }

    @MainActor func testUndoMoveToSpaceRelinksALivePinnedOpener() throws {
        let f = try makeFixture()
        let opener = makeTab("https://opener.example/", in: f.a)
        let child = makeTab("https://child.example/", in: f.a, parent: opener)
        let other = makeTab("https://other.example/", in: f.a)
        f.a.tabs.append(contentsOf: [opener, child, other])
        inUndoGroup(f.store) { f.store.pinTab(id: opener.id, in: f.a) }

        inUndoGroup(f.store) { XCTAssertTrue(f.store.moveTab(id: child.id, from: f.a, to: f.b)) }
        XCTAssertNil(child.parentID, "the pinned opener stays behind in A")

        f.store.undoManager.undo()
        XCTAssertTrue(f.a.tabs.contains { $0 === child })
        XCTAssertEqual(child.parentID, opener.id, "home again under its live pinned opener")
    }

    /// Chosen by Claude (TASK-358): a favourite belongs to every space of its
    /// profile, so a child moved within the profile keeps it; across profiles
    /// it is cut, as for any opener left behind.
    @MainActor func testMoveToSpaceKeepsAFavouriteOpenerOnlyWithinItsProfile() throws {
        let f = try makeFixture()
        let favouriteTab = addFavorite(f)
        let child = makeTab("https://child.example/", in: f.a, parent: favouriteTab)
        let other = makeTab("https://other.example/", in: f.a)
        f.a.tabs.append(contentsOf: [child, other])

        inUndoGroup(f.store) { XCTAssertTrue(f.store.moveTab(id: child.id, from: f.a, to: f.b)) }
        XCTAssertEqual(child.parentID, favouriteTab.id, "the favourite is in B too")

        inUndoGroup(f.store) { XCTAssertTrue(f.store.moveTab(id: child.id, from: f.b, to: f.c)) }
        XCTAssertNil(child.parentID, "C's profile has no such favourite")
    }

    /// The move keeps any link that still resolves in the destination, by the
    /// one rule: a child following its opener to another space arrives under
    /// it again (before TASK-358 it always arrived as a root tab). Undoing the
    /// child's move takes it home, where that opener no longer is.
    @MainActor func testAChildFollowingItsOpenerToAnotherSpaceKeepsTheLink() throws {
        let f = try makeFixture()
        let opener = makeTab("https://opener.example/", in: f.a)
        let child = makeTab("https://child.example/", in: f.a, parent: opener)
        let other = makeTab("https://other.example/", in: f.a)
        f.a.tabs.append(contentsOf: [opener, child, other])

        inUndoGroup(f.store) { XCTAssertTrue(f.store.moveTab(id: opener.id, from: f.a, to: f.b)) }
        inUndoGroup(f.store) { XCTAssertTrue(f.store.moveTab(id: child.id, from: f.a, to: f.b)) }
        XCTAssertEqual(child.parentID, opener.id, "the opener is in B: the link resolves there")

        f.store.undoManager.undo()
        XCTAssertTrue(f.a.tabs.contains { $0 === child })
        XCTAssertNil(child.parentID, "home in A, where its opener no longer is")
    }
}

/// The readers in a window, against `TabStore.shared` (the test scheme points
/// `DETOUR_DATA_DIR` at an isolated directory) on a profile of its own.
nonisolated final class TabOpenerWindowTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []
    private var profiles: [Profile] = []
    private var spaceIDs: [UUID] = []
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?

    /// Nothing listens on port 1, so a load navigates nowhere real.
    private let pageURL = URL(string: "http://127.0.0.1:1/page")!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    @MainActor override func tearDown() async throws {
        for controller in controllers { controller.window?.close() }
        controllers.removeAll()
        let store = TabStore.shared
        for id in spaceIDs {
            guard let space = store.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            store.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        for profile in profiles {
            for favorite in profile.favorites { favorite.tab?.teardown() }
            store.forceRemoveProfile(id: profile.id)
        }
        profiles.removeAll()
        store.undoManager.removeAllActions()
        store.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        try await super.tearDown()
    }

    @MainActor private func makeWindow(_ name: String) -> (BrowserWindowController, Space, Profile) {
        let store = TabStore.shared
        let profile = store.addProfile(name: "Opener \(name)")
        profiles.append(profile)
        let space = store.addSpace(name: "Opener \(name)", emoji: "O", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        controllers.append(wc)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, space, profile)
    }

    /// A live favourite of `profile`, backed by a sleeping tab.
    @MainActor private func addFavorite(to profile: Profile, in space: Space) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), title: "Favourite", url: pageURL, faviconURL: nil,
                             cachedInteractionState: nil, spaceID: space.id)
        TabStore.shared.addFavorite(from: tab, profileID: profile.id)
        return tab
    }

    @MainActor func testBackOnAChildOfAFavouriteClosesItAndSelectsTheFavourite() throws {
        let (wc, space, profile) = makeWindow("Back")
        let favouriteTab = addFavorite(to: profile, in: space)
        let other = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: favouriteTab.id)
        wc.selectTab(id: child.id)
        XCTAssertTrue(wc.parentTab(for: child) === favouriteTab)

        wc.goBack(nil)

        XCTAssertFalse(space.tabs.contains { $0 === child }, "the child closes")
        XCTAssertTrue(space.tabs.contains { $0 === other })
        XCTAssertEqual(wc.selectedTabID, favouriteTab.id, "and the favourite it was opened from is selected")
    }

    @MainActor func testClosingAChildReturnsToItsPinnedOpener() throws {
        let (wc, space, _) = makeWindow("Close")
        let opener = wc.store.addTab(in: space, url: pageURL)
        let other = wc.store.addTab(in: space)
        let child = wc.store.addTab(in: space, parentID: opener.id)
        wc.store.pinTab(id: opener.id, in: space)
        XCTAssertEqual(space.tabs.map(\.id), [other.id, child.id], "precondition: the child is last, with no siblings")
        wc.selectTab(id: child.id)

        wc.closeCurrentTab(nil)

        XCTAssertFalse(space.tabs.contains { $0 === child })
        XCTAssertEqual(wc.selectedTabID, opener.id, "back on the pinned tab it was opened from, not the neighbour")
    }

    @MainActor func testClosingAChildReturnsToItsFavourite() throws {
        let (wc, space, profile) = makeWindow("Close favourite")
        let favouriteTab = addFavorite(to: profile, in: space)
        let child = wc.store.addTab(in: space, parentID: favouriteTab.id)
        let other = wc.store.addTab(in: space)
        wc.selectTab(id: child.id)

        wc.closeCurrentTab(nil)

        XCTAssertTrue(space.tabs.contains { $0 === other })
        XCTAssertEqual(wc.selectedTabID, favouriteTab.id)
    }

    @MainActor func testAChildsWindowCloseReturnsToItsFavourite() throws {
        let (wc, space, profile) = makeWindow("window.close")
        let favouriteTab = addFavorite(to: profile, in: space)
        let sibling = wc.store.addTab(in: space, parentID: favouriteTab.id)
        let child = wc.store.addTab(in: space, parentID: favouriteTab.id)
        wc.selectTab(id: child.id)

        wc.webViewDidClose(try XCTUnwrap(child.webView))

        XCTAssertFalse(space.tabs.contains { $0 === child })
        XCTAssertTrue(space.tabs.contains { $0 === sibling })
        XCTAssertEqual(wc.selectedTabID, favouriteTab.id, "the opener ahead of the close order's sibling")
    }

    @MainActor func testAChildOfAFavouriteGetsTheOwnSwipeUntilTheFavouriteSleeps() throws {
        let (wc, space, profile) = makeWindow("Swipe")
        let favouriteTab = addFavorite(to: profile, in: space)
        let child = wc.store.addTab(in: space, parentID: favouriteTab.id)
        wc.selectTab(id: child.id)

        let state = try XCTUnwrap(wc.navigationSwipePaneStates().first { $0.tabID == child.id })
        XCTAssertEqual(state.mode, .ownSwipe(canGoForward: false))
        XCTAssertEqual(state.openerID, favouriteTab.id)

        let favorite = try XCTUnwrap(profile.favorites.first { $0.tab === favouriteTab })
        wc.store.deactivateFavorite(id: favorite.id, profileID: profile.id)

        let after = try XCTUnwrap(wc.navigationSwipePaneStates().first { $0.tabID == child.id })
        XCTAssertEqual(after.mode, .webKit, "no opener left: WebKit's gesture is back")
        XCTAssertTrue(after.gesturesEnabled)
    }
}
