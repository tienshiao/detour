import XCTest
@testable import Detour

nonisolated final class PeekAnchorTests: XCTestCase {

    @MainActor private func makeSleepingTab(url: String = "https://example.com") -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Tab",
            url: URL(string: url),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: UUID()
        )
    }

    @MainActor private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    // MARK: - anchorURL

    @MainActor func testAnchorURLIsPinnedURLForLivePinnedEntry() {
        let tab = makeSleepingTab()
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/home"),
                                pinnedTitle: "Pinned", tab: tab)

        XCTAssertEqual(PeekAnchor.anchorURL(forTabID: tab.id, pinnedEntries: [entry], favorites: []),
                       url("https://pinned.example.com/home"))
    }

    @MainActor func testAnchorURLIsFavoriteURLForLiveFavorite() {
        let tab = makeSleepingTab()
        let favorite = Favorite(url: url("https://fav.example.com/home"), title: "Fav", tab: tab)

        XCTAssertEqual(PeekAnchor.anchorURL(forTabID: tab.id, pinnedEntries: [], favorites: [favorite]),
                       url("https://fav.example.com/home"))
    }

    @MainActor func testAnchorURLIsNilForOrdinaryTab() {
        let pinnedTab = makeSleepingTab()
        let favoriteTab = makeSleepingTab()
        let plainTab = makeSleepingTab()
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/"),
                                pinnedTitle: "Pinned", tab: pinnedTab)
        let favorite = Favorite(url: url("https://fav.example.com/"), title: "Fav", tab: favoriteTab)

        XCTAssertNil(PeekAnchor.anchorURL(forTabID: plainTab.id,
                                          pinnedEntries: [entry], favorites: [favorite]))
    }

    @MainActor func testAnchorURLIsNilForDormantFavorite() {
        let favorite = Favorite(url: url("https://fav.example.com/"), title: "Fav", tab: nil)
        // A dormant tile has no backing tab, so no tab id can resolve to it.
        XCTAssertNil(PeekAnchor.anchorURL(forTabID: favorite.id,
                                          pinnedEntries: [], favorites: [favorite]))
    }

    @MainActor func testAnchorURLIsNilForDormantPinnedEntry() {
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/"),
                                pinnedTitle: "Pinned", tab: nil)
        XCTAssertNil(PeekAnchor.anchorURL(forTabID: entry.id, pinnedEntries: [entry], favorites: []))
    }

    @MainActor func testPinnedEntriesAreCheckedBeforeFavorites() {
        let tab = makeSleepingTab()
        let entry = PinnedEntry(pinnedURL: url("https://pinned.example.com/"),
                                pinnedTitle: "Pinned", tab: tab)
        let favorite = Favorite(url: url("https://fav.example.com/"), title: "Fav", tab: tab)

        XCTAssertEqual(PeekAnchor.anchorURL(forTabID: tab.id,
                                            pinnedEntries: [entry], favorites: [favorite]),
                       url("https://pinned.example.com/"))
    }

    // MARK: - interceptTab (TASK-48)

    @MainActor func testInterceptsALinkFiredByTheFocusedPane() {
        let focused = makeSleepingTab()
        let other = makeSleepingTab()

        XCTAssertTrue(PeekAnchor.interceptTab(clicked: focused, selectedTab: focused,
                                              splitMembers: [focused, other]) === focused)
    }

    /// The bug: a link activated in the pane that does not hold first responder
    /// fires from a web view that is not `selectedTab.webView`.
    @MainActor func testInterceptsALinkFiredByTheUnfocusedPaneOfTheSelectedSplit() {
        let focused = makeSleepingTab()
        let unfocused = makeSleepingTab()

        XCTAssertTrue(PeekAnchor.interceptTab(clicked: unfocused, selectedTab: focused,
                                              splitMembers: [focused, unfocused]) === unfocused,
                      "the clicked pane is anchored even while the other pane is selected")
    }

    @MainActor func testIgnoresALinkFiredByATabOutsideTheSelectedSplit() {
        let selected = makeSleepingTab()
        let background = makeSleepingTab()

        XCTAssertNil(PeekAnchor.interceptTab(clicked: background, selectedTab: selected,
                                             splitMembers: [selected]),
                     "a background tab's navigation must not take over the window's overlay")
    }

    @MainActor func testIgnoresALinkFiredInsideAPeek() {
        let host = makeSleepingTab()
        let peek = makeSleepingTab()
        host.peekTab = peek

        // `tab(owning:)` resolves a peek web view to the peek tab, which is
        // neither the selected tab nor a split member: peeks navigate in place.
        XCTAssertNil(PeekAnchor.interceptTab(clicked: peek, selectedTab: host,
                                             splitMembers: [host]))
    }

    @MainActor func testIgnoresAnUnresolvedWebView() {
        let selected = makeSleepingTab()

        XCTAssertNil(PeekAnchor.interceptTab(clicked: nil, selectedTab: selected,
                                             splitMembers: [selected]))
    }

    /// `splitMembers(of:)` scans the store on every link click; the common case
    /// (the clicked tab is the selected tab) must not pay for it.
    @MainActor func testDoesNotResolveSplitMembersForTheSelectedTab() {
        let selected = makeSleepingTab()

        XCTAssertTrue(PeekAnchor.interceptTab(
            clicked: selected, selectedTab: selected,
            splitMembers: { XCTFail("split members must not be resolved"); return [] }()) === selected)
    }

    // MARK: - shouldPeekCrossHostNavigation

    @MainActor func testPeeksWhenHostsDiffer() {
        XCTAssertTrue(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://other.example.org/page")))
    }

    @MainActor func testDoesNotPeekWithinSameHost() {
        XCTAssertFalse(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://fav.example.com/deep/page")))
    }

    @MainActor func testDoesNotPeekForHostlessTarget() {
        XCTAssertFalse(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("https://fav.example.com/home"),
            to: url("about:blank")))
    }

    @MainActor func testDoesNotPeekForHostlessAnchor() {
        XCTAssertFalse(PeekAnchor.shouldPeekCrossHostNavigation(
            anchorURL: url("about:blank"),
            to: url("https://other.example.org/page")))
    }

    // MARK: - shouldPeek (TASK-85: target=_blank links)

    @MainActor func testNewWindowLinkPeeksWithinSameHost() {
        XCTAssertTrue(PeekAnchor.shouldPeek(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://fav.example.com/deep/page"), opensNewWindow: true))
    }

    @MainActor func testNewWindowLinkPeeksAcrossHosts() {
        XCTAssertTrue(PeekAnchor.shouldPeek(
            anchorURL: url("https://fav.example.com/home"),
            to: url("https://other.example.org/page"), opensNewWindow: true))
    }

    @MainActor func testNewWindowLinkToHostlessTargetDoesNotPeek() {
        // blob:/about:blank popups keep their new-tab behaviour.
        XCTAssertFalse(PeekAnchor.shouldPeek(
            anchorURL: url("https://fav.example.com/home"),
            to: url("about:blank"), opensNewWindow: true))
    }

    @MainActor func testInPlaceLinkFollowsTheCrossHostRule() {
        let anchor = url("https://fav.example.com/home")
        XCTAssertFalse(PeekAnchor.shouldPeek(
            anchorURL: anchor, to: url("https://fav.example.com/deep/page"), opensNewWindow: false))
        XCTAssertTrue(PeekAnchor.shouldPeek(
            anchorURL: anchor, to: url("https://other.example.org/page"), opensNewWindow: false))
    }

    // MARK: - shouldPeekScriptedWindow (TASK-85: window.open)

    @MainActor func testTabStyleScriptedWindowPeeks() {
        XCTAssertTrue(PeekAnchor.shouldPeekScriptedWindow(to: url("https://zoom.us/j/123"), wantsPopup: false))
    }

    @MainActor func testPopupStyleScriptedWindowDoesNotPeek() {
        XCTAssertFalse(PeekAnchor.shouldPeekScriptedWindow(to: url("https://accounts.example.com/oauth"),
                                                           wantsPopup: true))
    }

    @MainActor func testHostlessScriptedWindowDoesNotPeek() {
        XCTAssertFalse(PeekAnchor.shouldPeekScriptedWindow(to: url("about:blank"), wantsPopup: false))
    }

    // MARK: - The Peek setting (TASK-307)

    @MainActor func testWithPeekOnAnAnchoredLinkPeeks() {
        let anchor = url("https://mail.example.com/")
        XCTAssertEqual(PeekAnchor.anchoredLinkAction(anchorURL: anchor, to: url("https://other.example.org/"),
                                                     opensNewWindow: false, peekEnabled: true), .peek)
        XCTAssertEqual(PeekAnchor.anchoredLinkAction(anchorURL: anchor, to: url("https://mail.example.com/x"),
                                                     opensNewWindow: true, peekEnabled: true), .peek)
    }

    @MainActor func testWithPeekOffACrossHostLinkOpensANewTab() {
        XCTAssertEqual(PeekAnchor.anchoredLinkAction(anchorURL: url("https://mail.example.com/"),
                                                     to: url("https://other.example.org/"),
                                                     opensNewWindow: false, peekEnabled: false), .newTab)
    }

    /// A `_blank` link is left to WebKit's new window, which becomes a tab.
    @MainActor func testWithPeekOffABlankLinkIsLeftToItsNewWindow() {
        XCTAssertEqual(PeekAnchor.anchoredLinkAction(anchorURL: url("https://mail.example.com/"),
                                                     to: url("https://other.example.org/"),
                                                     opensNewWindow: true, peekEnabled: false), .none)
    }

    /// What would not have peeked is untouched by the setting either way.
    @MainActor func testTheSettingLeavesSameHostLinksAlone() {
        for enabled in [true, false] {
            XCTAssertEqual(PeekAnchor.anchoredLinkAction(anchorURL: url("https://mail.example.com/"),
                                                         to: url("https://mail.example.com/inbox"),
                                                         opensNewWindow: false, peekEnabled: enabled), .none)
        }
    }

    @MainActor func testWithPeekOffAScriptedWindowOpensAsATab() {
        XCTAssertTrue(PeekAnchor.scriptedWindowPeeks(to: url("https://zoom.us/j/1"), wantsPopup: false, peekEnabled: true))
        XCTAssertFalse(PeekAnchor.scriptedWindowPeeks(to: url("https://zoom.us/j/1"), wantsPopup: false, peekEnabled: false))
        XCTAssertFalse(PeekAnchor.scriptedWindowPeeks(to: url("https://a.example/"), wantsPopup: true, peekEnabled: true))
    }

    @MainActor func testPeekSettingIsOnUntilTurnedOff() throws {
        let suite = "PeekAnchorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = PeekSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled)
        settings.isEnabled = false
        XCTAssertFalse(PeekSettings(defaults: defaults).isEnabled, "kept in the defaults")
        settings.isEnabled = true
        XCTAssertTrue(PeekSettings(defaults: defaults).isEnabled)
    }
}
