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

    // MARK: - interceptTab (TASK-48)

    func testInterceptsALinkFiredByTheFocusedPane() {
        let focused = makeSleepingTab()
        let other = makeSleepingTab()

        XCTAssertTrue(PeekAnchor.interceptTab(clicked: focused, selectedTab: focused,
                                              splitMembers: [focused, other]) === focused)
    }

    /// The bug: a link activated in the pane that does not hold first responder
    /// fires from a web view that is not `selectedTab.webView`.
    func testInterceptsALinkFiredByTheUnfocusedPaneOfTheSelectedSplit() {
        let focused = makeSleepingTab()
        let unfocused = makeSleepingTab()

        XCTAssertTrue(PeekAnchor.interceptTab(clicked: unfocused, selectedTab: focused,
                                              splitMembers: [focused, unfocused]) === unfocused,
                      "the clicked pane is anchored even while the other pane is selected")
    }

    func testIgnoresALinkFiredByATabOutsideTheSelectedSplit() {
        let selected = makeSleepingTab()
        let background = makeSleepingTab()

        XCTAssertNil(PeekAnchor.interceptTab(clicked: background, selectedTab: selected,
                                             splitMembers: [selected]),
                     "a background tab's navigation must not take over the window's overlay")
    }

    func testIgnoresALinkFiredInsideAPeek() {
        let host = makeSleepingTab()
        let peek = makeSleepingTab()
        host.peekTab = peek

        // `tab(owning:)` resolves a peek web view to the peek tab, which is
        // neither the selected tab nor a split member: peeks navigate in place.
        XCTAssertNil(PeekAnchor.interceptTab(clicked: peek, selectedTab: host,
                                             splitMembers: [host]))
    }

    func testIgnoresAnUnresolvedWebView() {
        let selected = makeSleepingTab()

        XCTAssertNil(PeekAnchor.interceptTab(clicked: nil, selectedTab: selected,
                                             splitMembers: [selected]))
    }

    /// `splitMembers(of:)` scans the store on every link click; the common case
    /// (the clicked tab is the selected tab) must not pay for it.
    func testDoesNotResolveSplitMembersForTheSelectedTab() {
        let selected = makeSleepingTab()

        XCTAssertTrue(PeekAnchor.interceptTab(
            clicked: selected, selectedTab: selected,
            splitMembers: { XCTFail("split members must not be resolved"); return [] }()) === selected)
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

    // MARK: - shouldPeek (TASK-85: target=_blank links)

    func testNewWindowLinkPeeksWithinSameHost() {
        XCTAssertTrue(PeekAnchor.shouldPeek(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://fav.example.com/deep/page"), opensNewWindow: true))
    }

    func testNewWindowLinkPeeksAcrossHosts() {
        XCTAssertTrue(PeekAnchor.shouldPeek(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://other.example.org/page"), opensNewWindow: true))
    }

    func testNewWindowLinkToHostlessTargetDoesNotPeek() {
        // blob:/about:blank popups keep their new-tab behaviour.
        XCTAssertFalse(PeekAnchor.shouldPeek(
            anchorURL: url("https://fav.example.com/home"),
            to: url("about:blank"), opensNewWindow: true))
    }

    func testInPlaceLinkFollowsTheCrossHostRule() {
        let anchor = url("https://fav.example.com/home")
        XCTAssertFalse(PeekAnchor.shouldPeek(
            anchorURL: anchor, to: url("https://fav.example.com/deep/page"), opensNewWindow: false))
        XCTAssertTrue(PeekAnchor.shouldPeek(
            anchorURL: anchor, to: url("https://other.example.org/page"), opensNewWindow: false))
    }
}
