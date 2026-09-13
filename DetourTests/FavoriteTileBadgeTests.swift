import XCTest
import AppKit
@testable import Detour

/// Headless coverage for the favourite tile's peek favicon badge (TASK-47).
/// The tile keeps its centred main favicon and adds a small chip in the
/// top-right corner whenever the backing tab has a live or parked Peek; a
/// favourite with no peek must render with no badge and no reserved space.
final class FavoriteTileBadgeTests: XCTestCase {

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16))
    }

    private func makeSleepingTab(url: String = "https://fav.example.com/home") -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Tab",
            url: URL(string: url),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: UUID()
        )
    }

    private func makeFavorite(tab: BrowserTab?, url: String = "https://fav.example.com/home") -> Favorite {
        Favorite(url: URL(string: url)!, title: "Fav", tab: tab)
    }

    private func spinRunLoop(_ interval: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func showsPeekBadge(_ tile: FavoriteTileView) -> Bool {
        !tile.peekBadgeView.isHidden
    }

    // MARK: - Tile

    func testDormantFavoriteHasNoBadge() {
        let tile = FavoriteTileView(favorite: makeFavorite(tab: nil), index: 0)
        XCTAssertFalse(showsPeekBadge(tile))
        XCTAssertNil(tile.peekFaviconImageView.image)
    }

    func testLiveTabWithoutPeekHasNoBadge() {
        let tile = FavoriteTileView(favorite: makeFavorite(tab: makeSleepingTab()), index: 0)
        XCTAssertFalse(showsPeekBadge(tile))
    }

    func testPeekFaviconSetBeforeTileCreationShowsBadge() {
        let tab = makeSleepingTab()
        let favicon = makeImage()
        tab.peekURL = URL(string: "https://peek.example.org/article")
        tab.peekFavicon = favicon

        let tile = FavoriteTileView(favorite: makeFavorite(tab: tab), index: 0)

        XCTAssertTrue(showsPeekBadge(tile))
        XCTAssertTrue(tile.peekFaviconImageView.image === favicon)
    }

    func testPeekFaviconPublishedAfterTileCreationShowsBadge() {
        let tab = makeSleepingTab()
        let tile = FavoriteTileView(favorite: makeFavorite(tab: tab), index: 0)
        XCTAssertFalse(showsPeekBadge(tile))

        // Mirrors BrowserTab.downloadPeekFavicon landing after a relaunch.
        let favicon = makeImage()
        tab.peekFavicon = favicon
        spinRunLoop()

        XCTAssertTrue(showsPeekBadge(tile))
        XCTAssertTrue(tile.peekFaviconImageView.image === favicon)
    }

    func testClearPeekStateHidesBadgeOnRefresh() {
        let tab = makeSleepingTab()
        tab.peekURL = URL(string: "https://peek.example.org/article")
        tab.peekFavicon = makeImage()
        let tile = FavoriteTileView(favorite: makeFavorite(tab: tab), index: 0)
        XCTAssertTrue(showsPeekBadge(tile))

        tab.clearPeekState()
        tile.refreshPeekBadge()

        XCTAssertFalse(showsPeekBadge(tile))
        XCTAssertNil(tile.peekFaviconImageView.image)
    }

    func testLivePeekFaviconShowsBadgeAndWinsOverParkedFavicon() {
        let tab = makeSleepingTab()
        let parked = makeImage()
        tab.peekFavicon = parked
        let tile = FavoriteTileView(favorite: makeFavorite(tab: tab), index: 0)
        XCTAssertTrue(tile.peekFaviconImageView.image === parked)

        // A live Peek opens and its page's favicon lands; the window pushes a
        // refresh (reloadSelectedTabSidebarCell) rather than publishing.
        let peek = makeSleepingTab(url: "https://peek.example.org/article")
        let live = makeImage()
        tab.peekTab = peek
        peek.favicon = live
        tile.refreshPeekBadge()

        XCTAssertTrue(showsPeekBadge(tile))
        XCTAssertTrue(tile.peekFaviconImageView.image === live, "the live peek favicon wins over the parked one")
    }

    func testBadgeFollowsFavoriteTabSwapOnRefresh() {
        let favorite = makeFavorite(tab: nil)
        let tile = FavoriteTileView(favorite: favorite, index: 0)
        XCTAssertFalse(showsPeekBadge(tile))

        // The favourite activates: a live tab with a parked peek is attached.
        let tab = makeSleepingTab()
        let favicon = makeImage()
        tab.peekFavicon = favicon
        favorite.tab = tab
        tile.refreshPeekBadge()

        XCTAssertTrue(showsPeekBadge(tile))
        XCTAssertTrue(tile.peekFaviconImageView.image === favicon)

        // ...and the new tab's later publishes are observed too.
        let newFavicon = makeImage()
        tab.peekFavicon = newFavicon
        spinRunLoop()
        XCTAssertTrue(tile.peekFaviconImageView.image === newFavicon)
    }

    // MARK: - Bar routing

    func testRefreshTileRefreshesTheMatchingFavorite() throws {
        let bar = FavoritesBarView(frame: .zero)
        let tabA = makeSleepingTab(url: "https://a.example.com/")
        let tabB = makeSleepingTab(url: "https://b.example.com/")
        let favA = makeFavorite(tab: tabA, url: "https://a.example.com/")
        let favB = makeFavorite(tab: tabB, url: "https://b.example.com/")

        bar.update(favorites: [favA, favB], selectedTabID: tabA.id)

        let tileA = try XCTUnwrap(bar.tileViews.first)
        let tileB = try XCTUnwrap(bar.tileViews.dropFirst().first)
        XCTAssertFalse(showsPeekBadge(tileA))
        XCTAssertFalse(showsPeekBadge(tileB))

        // A live Peek opens on B: the window pushes a refresh by tab ID before
        // anything is published. A tile whose tab has no peek stays plain —
        // even after the run loop turns.
        let peek = makeSleepingTab(url: "https://peek.example.org/")
        let favicon = makeImage()
        tabB.peekTab = peek
        peek.favicon = favicon
        bar.refreshTile(forTabID: tabB.id)
        spinRunLoop()

        XCTAssertFalse(showsPeekBadge(tileA))
        XCTAssertTrue(showsPeekBadge(tileB))
        XCTAssertTrue(tileB.peekFaviconImageView.image === favicon)
    }

    func testReusedTileRefreshesBadgeOnUpdate() throws {
        let bar = FavoritesBarView(frame: NSRect(x: 0, y: 0, width: 200, height: 48))
        let tab = makeSleepingTab()
        let favorite = makeFavorite(tab: tab)

        bar.update(favorites: [favorite], selectedTabID: tab.id)
        let tile = try XCTUnwrap(bar.tileViews.first)
        XCTAssertFalse(showsPeekBadge(tile))

        let favicon = makeImage()
        tab.peekFavicon = favicon
        bar.update(favorites: [favorite], selectedTabID: tab.id)

        XCTAssertTrue(bar.tileViews.first === tile, "the tile should be reused, not rebuilt")
        XCTAssertTrue(showsPeekBadge(tile))
        XCTAssertTrue(tile.peekFaviconImageView.image === favicon)
    }
}
