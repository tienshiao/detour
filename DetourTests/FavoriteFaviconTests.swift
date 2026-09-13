import XCTest
import AppKit
import GRDB
@testable import Detour

/// A favourite's tile has to show its favicon in the first window of a cold
/// launch (TASK-53). Two things broke that: a favourite restored with a live
/// (but sleeping) backing tab never downloaded its own icon, and the single
/// `onFaviconDownloaded` callback only reached whichever tile registered last.
/// Both are covered here through `FaviconLoader`'s fetch seam, which completes
/// downloads on demand instead of hitting the network.
final class FavoriteFaviconTests: XCTestCase {

    private var pendingFetches: [URL: [(NSImage?) -> Void]] = [:]
    private var defaultFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    private let faviconURL = URL(string: "https://fav.example.com/favicon.ico")!
    private let favoriteURL = URL(string: "https://fav.example.com/home")!

    override func setUp() {
        super.setUp()
        defaultFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { [weak self] url, completion in
            self?.pendingFetches[url, default: []].append(completion)
        }
    }

    override func tearDown() {
        FaviconLoader.shared.fetch = defaultFetch
        FaviconLoader.shared.resetForTesting()
        pendingFetches.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeDatabase() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        return try AppDatabase(dbQueue: dbQueue)
    }

    private func makeImage() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16))
    }

    private func makeSleepingTab(spaceID: UUID = UUID(), faviconURL: URL? = nil) -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Tab",
            url: favoriteURL,
            faviconURL: faviconURL,
            cachedInteractionState: nil,
            spaceID: spaceID
        )
    }

    private func spinRunLoop(_ interval: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    /// Completes the single coalesced fetch for `url` and lets the loader's
    /// main-thread delivery and the tiles' `receive(on:)` hops run.
    private func completeFetch(_ url: URL, with image: NSImage,
                               file: StaticString = #filePath, line: UInt = #line) {
        let completions = pendingFetches.removeValue(forKey: url) ?? []
        XCTAssertFalse(completions.isEmpty, "no favicon fetch was started for \(url)", file: file, line: line)
        for completion in completions { completion(image) }
        spinRunLoop()
    }

    // MARK: - Restore (AC #2, #4)

    /// A favourite restored with a sleeping backing tab shows an icon before the
    /// tab wakes: the favourite downloads its own `faviconURL` even though it has
    /// a tab, and the tab's identical URL coalesces onto the same fetch.
    func testRestoredFavoriteWithBackingTabGetsFaviconFromItsOwnDownload() throws {
        let db = try makeDatabase()
        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "Default")
        let space1 = store1.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile1.id)

        let tab = makeSleepingTab(spaceID: space1.id, faviconURL: faviconURL)
        store1.addFavorite(from: tab, profileID: profile1.id)
        store1.saveNow()

        let store2 = TabStore(appDB: db)
        _ = store2.restoreSession()

        let profile2 = try XCTUnwrap(store2.profiles.first { $0.id == profile1.id })
        let favorite = try XCTUnwrap(profile2.favorites.first)
        let restored = try XCTUnwrap(favorite.tab, "the favourite should restore with a live backing tab")
        XCTAssertEqual(restored.faviconURL, faviconURL)
        XCTAssertNil(favorite.displayFavicon, "nothing to show while the download is pending")

        let image = makeImage()
        completeFetch(faviconURL, with: image)

        XCTAssertTrue(favorite.favicon === image, "the favourite keeps its own copy, not only the tab's")
        XCTAssertNotNil(favorite.displayFavicon)
    }

    // MARK: - Tiles (AC #1, #3)

    /// Two tiles for one favourite stand in for two windows: the download has to
    /// reach both, not just the one that registered last.
    func testFaviconDownloadUpdatesEveryTileForTheSameFavorite() {
        // A live backing tab with no favicon of its own — as after a restore,
        // where only the favourite's URL is known up front.
        let favorite = Favorite(url: favoriteURL, title: "Fav", faviconURL: faviconURL,
                                tab: makeSleepingTab())
        let first = FavoriteTileView(favorite: favorite, index: 0)
        let second = FavoriteTileView(favorite: favorite, index: 0)

        let image = makeImage()
        XCTAssertFalse(first.imageView.image === image)
        XCTAssertFalse(second.imageView.image === image)
        XCTAssertNotNil(first.imageView.image, "tiles start on the globe placeholder")

        completeFetch(faviconURL, with: image)

        XCTAssertTrue(first.imageView.image === image)
        XCTAssertTrue(second.imageView.image === image, "every window's tile sees the download")
    }

    /// A dormant favourite (no backing tab) still updates its tile when its own
    /// download lands.
    func testDormantFavoriteDownloadUpdatesItsTile() {
        let favorite = Favorite(url: favoriteURL, title: "Fav", faviconURL: faviconURL)
        let tile = FavoriteTileView(favorite: favorite, index: 0)
        XCTAssertNil(favorite.displayFavicon)

        let image = makeImage()
        completeFetch(faviconURL, with: image)

        XCTAssertTrue(tile.imageView.image === image)
    }

    /// The favourite's `tab` swaps as it activates and goes dormant, so
    /// `refreshFavicon()` has to rebind — the tile then follows the new tab.
    func testTileFollowsFaviconOfTheTabAttachedOnActivation() {
        let favorite = Favorite(url: favoriteURL, title: "Fav")
        let tile = FavoriteTileView(favorite: favorite, index: 0)

        let tab = makeSleepingTab()
        favorite.tab = tab            // activateFavorite's effect on the tile
        tile.refreshFavicon()

        let tabFavicon = makeImage()
        tab.favicon = tabFavicon
        spinRunLoop()
        XCTAssertTrue(tile.imageView.image === tabFavicon)

        // ...and going dormant falls back to the favourite's own icon.
        let ownFavicon = makeImage()
        favorite.favicon = ownFavicon
        favorite.tab = nil            // deactivateFavorite's effect
        tile.refreshFavicon()
        XCTAssertTrue(tile.imageView.image === ownFavicon)

        // The old tab's later publishes must not reach the tile any more.
        tab.favicon = makeImage()
        spinRunLoop()
        XCTAssertTrue(tile.imageView.image === ownFavicon)
    }
}
