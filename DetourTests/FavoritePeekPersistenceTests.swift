import XCTest
import GRDB
@testable import Detour

/// A favourite peeks on cross-host link clicks exactly as a pinned entry does
/// (TASK-42), so its peek state has to survive a relaunch the same way.
final class FavoritePeekPersistenceTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        return try AppDatabase(dbQueue: dbQueue)
    }

    private func makeSleepingTab(spaceID: UUID, url: String = "https://example.com") -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Tab",
            url: URL(string: url),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: spaceID
        )
    }

    private let peekURL = URL(string: "https://peek.example.org/article")!
    private let peekState = Data([1, 2, 3])
    private let peekFaviconURL = URL(string: "https://peek.example.org/favicon.ico")!

    func testFavoritePeekStateSurvivesRestore() throws {
        let db = try makeDatabase()
        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Default")
        let space1 = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile1.id)

        // A favourite's backing tab lives on the favourite, not in space.tabs;
        // it is saved under the first persistent space with the profile.
        let tab = makeSleepingTab(spaceID: space1.id, url: "https://fav.example.com/home")
        store1.addFavorite(from: tab, profileID: profile1.id)
        tab.peekURL = peekURL
        tab.peekInteractionState = peekState
        tab.peekFaviconURL = peekFaviconURL
        store1.saveNow()

        let store2 = TabStore(appDB: db)
        _ = store2.restoreSession()

        let profile2 = try XCTUnwrap(store2.profiles.first { $0.id == profile1.id })
        let favorite = try XCTUnwrap(profile2.favorites.first)
        let restored = try XCTUnwrap(favorite.tab, "the favourite's backing tab should be restored live")
        XCTAssertEqual(restored.id, tab.id)
        XCTAssertEqual(restored.peekURL, peekURL)
        XCTAssertEqual(restored.peekInteractionState, peekState)
        XCTAssertEqual(restored.peekFaviconURL, peekFaviconURL)
    }

    func testFavoriteWithoutPeekRestoresWithNoPeekState() throws {
        let db = try makeDatabase()
        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Default")
        let space1 = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile1.id)

        let tab = makeSleepingTab(spaceID: space1.id, url: "https://fav.example.com/home")
        store1.addFavorite(from: tab, profileID: profile1.id)
        store1.saveNow()

        let store2 = TabStore(appDB: db)
        _ = store2.restoreSession()

        let profile2 = try XCTUnwrap(store2.profiles.first { $0.id == profile1.id })
        let restored = try XCTUnwrap(profile2.favorites.first?.tab)
        XCTAssertNil(restored.peekURL)
        XCTAssertNil(restored.peekInteractionState)
        XCTAssertNil(restored.peekFaviconURL)
    }

    /// Removing a favourite outright must not leave its live backing tab (and
    /// the peek hosted on it) alive off-list.
    func testRemovingFavoriteTearsDownItsBackingTab() throws {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Default")
        let space = store.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile.id)

        let tab = makeSleepingTab(spaceID: space.id, url: "https://fav.example.com/home")
        store.addFavorite(from: tab, profileID: profile.id)
        let fav = try XCTUnwrap(profile.favorites.first)
        tab.peekURL = peekURL
        tab.peekTab = BrowserTab(
            id: UUID(),
            title: "Peek",
            url: URL(string: "https://peek.example.org"),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: space.id
        )

        store.removeFavorite(id: fav.id, profileID: profile.id)

        XCTAssertTrue(profile.favorites.isEmpty)
        // `teardown()` on a sleeping tab has no webView to release, but it does
        // discard the peek — which is how the teardown is observable here.
        XCTAssertNil(tab.peekTab, "the favourite's backing tab should have been torn down")
    }

    /// Symmetry check: the pinned path this mirrors already persisted its peek.
    func testPinnedEntryPeekStateSurvivesRestore() throws {
        let db = try makeDatabase()
        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Default")
        let space1 = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile1.id)

        let tab = makeSleepingTab(spaceID: space1.id, url: "https://pinned.example.com/home")
        space1.tabs.append(tab)
        store1.pinTab(id: tab.id, in: space1)
        tab.peekURL = peekURL
        tab.peekInteractionState = peekState
        tab.peekFaviconURL = peekFaviconURL
        store1.saveNow()

        let store2 = TabStore(appDB: db)
        _ = store2.restoreSession()

        let space2 = try XCTUnwrap(store2.spaces.first { $0.id == space1.id })
        let entry = try XCTUnwrap(space2.pinnedEntries.first)
        let restored = try XCTUnwrap(entry.tab, "the pinned entry's backing tab should be restored live")
        XCTAssertEqual(restored.id, tab.id)
        XCTAssertEqual(restored.peekURL, peekURL)
        XCTAssertEqual(restored.peekInteractionState, peekState)
        XCTAssertEqual(restored.peekFaviconURL, peekFaviconURL)
    }

    /// A favourite's backing tab selected at quit is the tab the launch selects
    /// again (TASK-54): it is in no space list, so restore must keep pointing at
    /// it rather than falling back to the first pinned or normal tab.
    func testSelectedFavoriteBackingTabSurvivesRestore() throws {
        let db = try makeDatabase()
        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Default")
        let space1 = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile1.id)

        // A pinned tab the old fallback would have selected instead.
        let pinned = makeSleepingTab(spaceID: space1.id, url: "https://pinned.example.com/home")
        space1.tabs.append(pinned)
        store1.pinTab(id: pinned.id, in: space1)

        let favTab = makeSleepingTab(spaceID: space1.id, url: "https://fav.example.com/home")
        store1.addFavorite(from: favTab, profileID: profile1.id)
        space1.selectedTabID = favTab.id
        store1.saveNow()

        let store2 = TabStore(appDB: db)
        let restored = try XCTUnwrap(store2.restoreSession())

        XCTAssertEqual(restored.spaceID, space1.id)
        XCTAssertEqual(restored.tabID, favTab.id, "the launch selects the favourite, not the pinned tab")
        let space2 = try XCTUnwrap(store2.spaces.first { $0.id == space1.id })
        XCTAssertEqual(space2.selectedTabID, favTab.id)
        let profile2 = try XCTUnwrap(store2.profiles.first { $0.id == profile1.id })
        XCTAssertEqual(profile2.favorites.first?.tab?.id, favTab.id)
        // And the window's rule agrees, from the space it was handed.
        XCTAssertEqual(space2.tabToSelectOnEntry()?.id, favTab.id)
    }
}
