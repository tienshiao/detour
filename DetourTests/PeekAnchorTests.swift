import XCTest
@testable import Detour

final class PeekAnchorTests: XCTestCase {

    private func makeSleepingTab(url: String = "https://example.com") -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Tab",
            url: URL(string: url),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: UUID()
        )
    }

    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - anchorURL

    func testAnchorURLIsPinnedURLForLivePinnedEntry() {
        let tab = makeSleepingTab()
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/home"),
                                pinnedTitle: "Pinned", tab: tab)

        XCTAssertEqual(PeekAnchor.anchorURL(forTabID: tab.id, pinnedEntries: [entry], favorites: []),
                       url("https://pinned.example.com/home"))
    }

    func testAnchorURLIsFavoriteURLForLiveFavorite() {
        let tab = makeSleepingTab()
        let favorite = Favorite(url: url("https://fav.example.com/home"), title: "Fav", tab: tab)

        XCTAssertEqual(PeekAnchor.anchorURL(forTabID: tab.id, pinnedEntries: [], favorites: [favorite]),
                       url("https://fav.example.com/home"))
    }

    func testAnchorURLIsNilForOrdinaryTab() {
        let pinnedTab = makeSleepingTab()
        let favoriteTab = makeSleepingTab()
        let plainTab = makeSleepingTab()
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/"),
                                pinnedTitle: "Pinned", tab: pinnedTab)
        let favorite = Favorite(url: url("https://fav.example.com/"), title: "Fav", tab: favoriteTab)

        XCTAssertNil(PeekAnchor.anchorURL(forTabID: plainTab.id,
                                          pinnedEntries: [entry], favorites: [favorite]))
    }

    func testAnchorURLIsNilForDormantFavorite() {
        let favorite = Favorite(url: url("https://fav.example.com/"), title: "Fav", tab: nil)
        // A dormant tile has no backing tab, so no tab id can resolve to it.
        XCTAssertNil(PeekAnchor.anchorURL(forTabID: favorite.id,
                                          pinnedEntries: [], favorites: [favorite]))
    }

    func testAnchorURLIsNilForDormantPinnedEntry() {
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/"),
                                pinnedTitle: "Pinned", tab: nil)
        XCTAssertNil(PeekAnchor.anchorURL(forTabID: entry.id, pinnedEntries: [entry], favorites: []))
    }

    func testPinnedEntriesAreCheckedBeforeFavorites() {
        let tab = makeSleepingTab()
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/"),
                                pinnedTitle: "Pinned", tab: tab)
        let favorite = Favorite(url: url("https://fav.example.com/"), title: "Fav", tab: tab)

        XCTAssertEqual(PeekAnchor.anchorURL(forTabID: tab.id,
                                            pinnedEntries: [entry], favorites: [favorite]),
                       url("https://pinned.example.com/"))
    }

    // MARK: - shouldPeekCrossHostNavigation

    func testPeeksWhenHostsDiffer() {
        XCTAssertTrue(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://other.example.org/page")))
    }

    func testDoesNotPeekWithinSameHost() {
        XCTAssertFalse(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://fav.example.com/deep/page")))
    }

    func testDoesNotPeekForHostlessTarget() {
        XCTAssertFalse(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("https://fav.example.com/home"),
            to: url("about:blank")))
    }

    func testDoesNotPeekForHostlessAnchor() {
        XCTAssertFalse(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("about:blank"),
            to: url("https://other.example.org/page")))
    }
}
