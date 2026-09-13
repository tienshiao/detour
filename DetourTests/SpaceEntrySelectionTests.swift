import XCTest
import GRDB
@testable import Detour

/// TASK-54: which tab a window selects when it enters a space
/// (`Space.tabToSelectOnEntry`), and the single membership lookup it resolves a
/// selected tab through (`Space.displayableTab(id:)`).
///
/// A favourite's backing tab lives on the space's *profile*, outside `tabs` and
/// `pinnedEntries`, so a space switch used to drop it and wake the first pinned
/// tab instead.
final class SpaceEntrySelectionTests: XCTestCase {

    private struct Fixture {
        let store: TabStore
        let profile: Profile
        let space: Space
        var normalTab: BrowserTab?
        var pinnedTab: BrowserTab?
        var favoriteTab: BrowserTab?

        func teardown() {
            for tab in space.tabs + space.pinnedTabs + profile.favoriteTabs { tab.teardown() }
        }
    }

    private func sleepingTab(spaceID: UUID, url: String) -> BrowserTab {
        BrowserTab(id: UUID(), title: "Tab", url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: spaceID)
    }

    /// A space holding one tab of each section the window can display.
    private func makeFixture(normal: Bool = true,
                             pinned: Bool = true,
                             favorite: Bool = true,
                             dormantFavorite: Bool = false) throws -> Fixture {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Default")
        let space = store.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile.id)

        var normalTab: BrowserTab?
        var pinnedTab: BrowserTab?
        var favoriteTab: BrowserTab?
        if normal {
            let tab = sleepingTab(spaceID: space.id, url: "https://normal.example.com")
            space.tabs.append(tab)
            normalTab = tab
        }
        if pinned {
            let tab = sleepingTab(spaceID: space.id, url: "https://pinned.example.com")
            space.tabs.append(tab)
            store.pinTab(id: tab.id, in: space)
            pinnedTab = tab
        }
        if favorite || dormantFavorite {
            let tab = sleepingTab(spaceID: space.id, url: "https://fav.example.com")
            store.addFavorite(from: tab, profileID: profile.id)
            if dormantFavorite {
                let favID = try XCTUnwrap(profile.favorites.last?.id)
                store.deactivateFavorite(id: favID, profileID: profile.id)
                XCTAssertNil(profile.favorites.last?.tab, "precondition: dormant favourite")
            } else {
                favoriteTab = tab
            }
        }
        return Fixture(store: store, profile: profile, space: space,
                       normalTab: normalTab, pinnedTab: pinnedTab, favoriteTab: favoriteTab)
    }

    // MARK: - The selection rule

    func testSavedNormalTabIsKept() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.space.selectedTabID = f.normalTab?.id
        XCTAssertEqual(f.space.tabToSelectOnEntry()?.id, f.normalTab?.id)
    }

    func testSavedPinnedTabIsKept() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.space.selectedTabID = f.pinnedTab?.id
        XCTAssertEqual(f.space.tabToSelectOnEntry()?.id, f.pinnedTab?.id)
    }

    func testSavedFavoriteTabIsKept() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.space.selectedTabID = f.favoriteTab?.id
        XCTAssertEqual(f.space.tabToSelectOnEntry()?.id, f.favoriteTab?.id,
                       "a favourite's backing tab is displayable even though it is in no space list")
    }

    func testStaleSavedIDFallsBackToTheFirstLivePinnedTab() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.space.selectedTabID = UUID()
        XCTAssertEqual(f.space.tabToSelectOnEntry()?.id, f.pinnedTab?.id)
    }

    func testNoSavedIDFallsBackToTheFirstLivePinnedTab() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        f.space.selectedTabID = nil
        XCTAssertEqual(f.space.tabToSelectOnEntry()?.id, f.pinnedTab?.id)
    }

    func testWithoutPinnedTabsTheFallbackIsTheFirstNormalTab() throws {
        let f = try makeFixture(pinned: false)
        defer { f.teardown() }
        f.space.selectedTabID = UUID()
        XCTAssertEqual(f.space.tabToSelectOnEntry()?.id, f.normalTab?.id)
    }

    func testDormantFavoriteDoesNotSubstituteForAFallback() throws {
        // A favourite is never a fallback, and a dormant one has no tab at all:
        // a space with nothing else deselects everything.
        let f = try makeFixture(normal: false, pinned: false, favorite: false, dormantFavorite: true)
        defer { f.teardown() }
        f.space.selectedTabID = nil
        XCTAssertNil(f.space.tabToSelectOnEntry())
    }

    func testEmptySpaceSelectsNothing() throws {
        let f = try makeFixture(normal: false, pinned: false, favorite: false)
        defer { f.teardown() }
        f.space.selectedTabID = UUID()
        XCTAssertNil(f.space.tabToSelectOnEntry())
    }

    // MARK: - Space.displayableTab

    func testDisplayableTabResolvesEverySectionAndNothingElse() throws {
        let f = try makeFixture()
        defer { f.teardown() }
        let normalTab = try XCTUnwrap(f.normalTab)
        let pinnedTab = try XCTUnwrap(f.pinnedTab)
        let favoriteTab = try XCTUnwrap(f.favoriteTab)

        XCTAssertIdentical(f.space.displayableTab(id: normalTab.id), normalTab)
        XCTAssertIdentical(f.space.displayableTab(id: pinnedTab.id), pinnedTab)
        XCTAssertIdentical(f.space.displayableTab(id: favoriteTab.id), favoriteTab)
        XCTAssertNil(f.space.displayableTab(id: UUID()), "a stale id resolves to nothing")
    }
}
