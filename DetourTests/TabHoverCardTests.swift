import XCTest
@testable import Detour

/// TASK-190: the rules behind the sidebar's tab hover card — when it shows,
/// what its text says, which tab a hovered row (or split half) describes, and
/// where its thumbnail comes from.
final class TabHoverCardTests: XCTestCase {

    // MARK: - Timing

    func testFreshHoverWaitsTheShowDelay() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: false, lastHiddenAt: nil, now: now),
                       HoverCardTiming.showDelay)
        XCTAssertGreaterThan(HoverCardTiming.showDelay, 0.3)
        XCTAssertLessThan(HoverCardTiming.showDelay, 0.6)
    }

    func testHoverWhileACardIsShowingSwapsImmediately() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: true, lastHiddenAt: nil, now: now), 0)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: true, lastHiddenAt: now.addingTimeInterval(-60), now: now), 0)
    }

    func testHoverJustAfterACardHidSwapsImmediately() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: false, lastHiddenAt: now.addingTimeInterval(-0.1), now: now), 0)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: false, lastHiddenAt: now, now: now), 0)
    }

    func testHoverLongAfterACardHidWaitsAgain() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let hidden = now.addingTimeInterval(-HoverCardTiming.swapWindow - 0.01)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: false, lastHiddenAt: hidden, now: now),
                       HoverCardTiming.showDelay)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: false, lastHiddenAt: now.addingTimeInterval(-5), now: now),
                       HoverCardTiming.showDelay)
    }

    func testAHideStampInTheFutureDoesNotSwap() {
        // A clock that went backwards must not make every hover instant.
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(HoverCardTiming.delay(isShowing: false, lastHiddenAt: now.addingTimeInterval(10), now: now),
                       HoverCardTiming.showDelay)
    }

    // MARK: - URL line

    func testURLLineDropsSchemeAndWWWAndSplitsAtTheHost() {
        let line = HoverCardText.urlLine(for: URL(string: "https://www.example.com/a/b?q=1#top"))
        XCTAssertEqual(line, .init(host: "example.com", rest: "/a/b?q=1#top"))
    }

    func testURLLineKeepsOtherSubdomainsAndThePort() {
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "http://docs.example.com:8080/x")),
                       .init(host: "docs.example.com:8080", rest: "/x"))
        // Only a leading "www." goes.
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://wwwexample.com/")),
                       .init(host: "wwwexample.com", rest: ""))
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://example.www.com")),
                       .init(host: "example.www.com", rest: ""))
    }

    func testURLLineDropsABareRootPathAndUserInfo() {
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://www.example.com/")),
                       .init(host: "example.com", rest: ""))
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://user:pw@example.com/p")),
                       .init(host: "example.com", rest: "/p"))
    }

    func testURLLineKeepsAQueryOnTheRoot() {
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://www.google.com/?q=detour")),
                       .init(host: "google.com", rest: "/?q=detour"))
    }

    func testURLLineDecodesThePath() {
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://example.com/caf%C3%A9%20menu")),
                       .init(host: "example.com", rest: "/café menu"))
    }

    func testURLLineKeepsAPathEncodedWhenDecodingWouldAddControlOrBidiCharacters() {
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://example.com/a%E2%80%AEmoc.elgoog")),
                       .init(host: "example.com", rest: "/a%E2%80%AEmoc.elgoog"))
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "https://example.com/a%0Ab")),
                       .init(host: "example.com", rest: "/a%0Ab"))
    }

    func testURLLineForNonWebSchemes() {
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "file:///Users/me/page.html")),
                       .init(host: "", rest: "/Users/me/page.html"))
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "about:blank")),
                       .init(host: "about:blank", rest: ""))
        XCTAssertEqual(HoverCardText.urlLine(for: URL(string: "detour://history")),
                       .init(host: "detour://history", rest: ""))
    }

    func testURLLineIsNilWithoutAURL() {
        XCTAssertNil(HoverCardText.urlLine(for: nil))
    }

    // MARK: - Text

    func testTextKeepsTheFullTitleAndTheURLLine() {
        let long = Array(repeating: "A long page title", count: 10).joined(separator: " ")
        let text = HoverCardText.make(title: long, url: URL(string: "https://www.example.com/a"))
        XCTAssertEqual(text.title, long)
        XCTAssertEqual(text.url, .init(host: "example.com", rest: "/a"))
    }

    func testTextTrimsTheTitle() {
        let text = HoverCardText.make(title: "  Hello \n", url: URL(string: "https://example.com"))
        XCTAssertEqual(text.title, "Hello")
    }

    func testBlankTitleFallsBackToTheURLAndDropsTheURLLine() {
        let text = HoverCardText.make(title: "  ", url: URL(string: "https://www.example.com/a"))
        XCTAssertEqual(text.title, "example.com/a")
        XCTAssertNil(text.url)
    }

    func testBlankTitleWithoutURL() {
        let text = HoverCardText.make(title: "", url: nil)
        XCTAssertEqual(text.title, "Untitled")
        XCTAssertNil(text.url)
    }

    func testTitleWithoutURLHasNoURLLine() {
        let text = HoverCardText.make(title: "New Tab", url: nil)
        XCTAssertEqual(text.title, "New Tab")
        XCTAssertNil(text.url)
    }

    // MARK: - Targets

    private func makeTab(_ title: String = "Tab", url: String = "https://example.com") -> BrowserTab {
        BrowserTab(id: UUID(), title: title, url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: UUID())
    }

    private func tabOf(_ target: HoverCardTarget?) -> BrowserTab? {
        guard case .tab(let tab) = target else { return nil }
        return tab
    }

    private func entryOf(_ target: HoverCardTarget?) -> PinnedEntry? {
        guard case .pinned(let entry) = target else { return nil }
        return entry
    }

    func testSingleTabRowTargetsItsTab() {
        let tab = makeTab()
        XCTAssertTrue(tabOf(HoverCardTarget.forTabItem(.single(tab), splitSide: nil)) === tab)
    }

    func testSplitRowTargetsOnlyTheHoveredHalf() {
        let left = makeTab("Left"), right = makeTab("Right")
        let item = TabListItem.split(groupID: UUID(), members: [left, right])
        XCTAssertTrue(tabOf(HoverCardTarget.forTabItem(item, splitSide: 0)) === left)
        XCTAssertTrue(tabOf(HoverCardTarget.forTabItem(item, splitSide: 1)) === right)
        // No side known yet: no card rather than a guess.
        XCTAssertNil(HoverCardTarget.forTabItem(item, splitSide: nil))
        XCTAssertNil(HoverCardTarget.forTabItem(item, splitSide: 2))
    }

    func testPinnedRowsTargetTheEntryOrTheHoveredHalf() {
        let a = PinnedEntry(pinnedURL: URL(string: "https://a.example")!, pinnedTitle: "A")
        let b = PinnedEntry(pinnedURL: URL(string: "https://b.example")!, pinnedTitle: "B")
        XCTAssertTrue(entryOf(HoverCardTarget.forPinnedItem(.entry(a, depth: 1), splitSide: nil)) === a)
        let split = PinnedItem.split(groupID: UUID(), entries: [a, b], depth: 0)
        XCTAssertTrue(entryOf(HoverCardTarget.forPinnedItem(split, splitSide: 0)) === a)
        XCTAssertTrue(entryOf(HoverCardTarget.forPinnedItem(split, splitSide: 1)) === b)
        XCTAssertNil(HoverCardTarget.forPinnedItem(split, splitSide: nil))
    }

    func testFolderRowsGetNoCard() {
        let folder = PinnedFolder(name: "Folder")
        XCTAssertNil(HoverCardTarget.forPinnedItem(.folder(folder, depth: 0), splitSide: nil))
    }

    func testTargetsCompareByIdentity() {
        let tab = makeTab()
        let entry = PinnedEntry(pinnedURL: URL(string: "https://a.example")!, pinnedTitle: "A", tab: tab)
        XCTAssertTrue(HoverCardTarget.tab(tab).isSame(as: .tab(tab)))
        XCTAssertFalse(HoverCardTarget.tab(tab).isSame(as: .tab(makeTab())))
        XCTAssertTrue(HoverCardTarget.pinned(entry).isSame(as: .pinned(entry)))
        // The same tab seen as a pinned row is a different row.
        XCTAssertFalse(HoverCardTarget.pinned(entry).isSame(as: .tab(tab)))
        XCTAssertTrue(HoverCardTarget.pinned(entry).tab === tab)
    }

    // MARK: - Content

    private func preview() -> NSImage { NSImage(size: NSSize(width: 480, height: 300)) }

    func testNormalTabShowsItsTitleURLAndPreview() {
        let tab = makeTab("Docs", url: "https://www.example.com/docs")
        let image = preview()
        tab.switcherPreview = image
        let content = HoverCardContent.make(for: .tab(tab), isOnScreen: { _ in false },
                                            thumbnailKey: { $0.id })
        XCTAssertEqual(content.text, HoverCardText(title: "Docs", url: .init(host: "example.com", rest: "/docs")))
        XCTAssertTrue(content.preview === image)
        XCTAssertEqual(content.thumbnailKey, tab.id)
    }

    func testTabWithoutPreviewFallsBackToTheDiskKey() {
        let tab = makeTab()
        let content = HoverCardContent.make(for: .tab(tab), isOnScreen: { _ in false }, thumbnailKey: { $0.id })
        XCTAssertNil(content.preview)
        XCTAssertEqual(content.thumbnailKey, tab.id)
    }

    func testPrivateTabHasNoDiskKey() {
        let tab = makeTab()
        let content = HoverCardContent.make(for: .tab(tab), isOnScreen: { _ in false }, thumbnailKey: { _ in nil })
        XCTAssertNil(content.thumbnailKey)
    }

    func testOnScreenTabShowsNoThumbnail() {
        let tab = makeTab()
        tab.switcherPreview = preview()
        let content = HoverCardContent.make(for: .tab(tab), isOnScreen: { $0 === tab }, thumbnailKey: { $0.id })
        XCTAssertNil(content.preview)
        XCTAssertNil(content.thumbnailKey)
        XCTAssertEqual(content.text.title, "Tab")
    }

    func testLivePinnedEntryShowsTheTabsCurrentPage() {
        let tab = makeTab("Inbox (3)", url: "https://mail.example.com/inbox/42")
        let image = preview()
        tab.switcherPreview = image
        let entry = PinnedEntry(pinnedURL: URL(string: "https://mail.example.com")!, pinnedTitle: "Mail", tab: tab)
        let content = HoverCardContent.make(for: .pinned(entry), isOnScreen: { _ in false },
                                            thumbnailKey: { _ in entry.id })
        XCTAssertEqual(content.text, HoverCardText(title: "Inbox (3)",
                                                   url: .init(host: "mail.example.com", rest: "/inbox/42")))
        XCTAssertTrue(content.preview === image)
        XCTAssertEqual(content.thumbnailKey, entry.id)
    }

    func testDormantPinnedEntryShowsItsOwnPageAndItsDiskThumbnail() {
        let entry = PinnedEntry(pinnedURL: URL(string: "https://www.mail.example.com/")!, pinnedTitle: "Mail")
        let content = HoverCardContent.make(for: .pinned(entry), isOnScreen: { _ in false },
                                            thumbnailKey: { _ in XCTFail("no tab to ask about"); return nil })
        XCTAssertEqual(content.text, HoverCardText(title: "Mail", url: .init(host: "mail.example.com", rest: "")))
        XCTAssertNil(content.preview)
        XCTAssertEqual(content.thumbnailKey, entry.id)
    }

    func testLiveFavoriteShowsTheTabsCurrentPage() {
        let tab = makeTab("Video", url: "https://www.youtube.com/watch?v=1")
        let favorite = Favorite(url: URL(string: "https://youtube.com")!, title: "YouTube", tab: tab)
        let content = HoverCardContent.make(for: .favorite(favorite), isOnScreen: { _ in false },
                                            thumbnailKey: { _ in favorite.id })
        XCTAssertEqual(content.text.title, "Video")
        XCTAssertEqual(content.text.url, .init(host: "youtube.com", rest: "/watch?v=1"))
        XCTAssertEqual(content.thumbnailKey, favorite.id)
    }

    func testDormantFavoriteShowsItsOwnPage() {
        let favorite = Favorite(url: URL(string: "https://youtube.com")!, title: "YouTube")
        let content = HoverCardContent.make(for: .favorite(favorite), isOnScreen: { _ in false },
                                            thumbnailKey: { _ in nil })
        XCTAssertEqual(content.text, HoverCardText(title: "YouTube", url: .init(host: "youtube.com", rest: "")))
        XCTAssertEqual(content.thumbnailKey, favorite.id)
    }

    func testSelectedFavoriteShowsNoThumbnail() {
        let tab = makeTab()
        tab.switcherPreview = preview()
        let favorite = Favorite(url: URL(string: "https://example.com")!, title: "Ex", tab: tab)
        let content = HoverCardContent.make(for: .favorite(favorite), isOnScreen: { $0 === tab },
                                            thumbnailKey: { _ in favorite.id })
        XCTAssertNil(content.preview)
        XCTAssertNil(content.thumbnailKey)
    }

    // MARK: - Peek (TASK-229)

    private func peekOf(_ target: HoverCardTarget?) -> BrowserTab? {
        guard case .peek(let host) = target else { return nil }
        return host
    }

    func testThePeekBadgeOfARowTargetsItsHost() {
        let host = makeTab("Host")
        host.peekTab = makeTab("Peek", url: "https://peek.example/a")
        XCTAssertTrue(peekOf(HoverCardTarget.peekBadge(of: .tab(host))) === host)
        let entry = PinnedEntry(pinnedURL: URL(string: "https://a.example")!, pinnedTitle: "A", tab: host)
        XCTAssertTrue(peekOf(HoverCardTarget.peekBadge(of: .pinned(entry))) === host)
        let favorite = Favorite(url: URL(string: "https://a.example")!, title: "A", tab: host)
        XCTAssertTrue(peekOf(HoverCardTarget.peekBadge(of: .favorite(favorite))) === host)
    }

    func testAParkedOrRestoredPeekHasABadgeCard() {
        let restored = makeTab("Host")
        restored.peekURL = URL(string: "https://peek.example/a")
        XCTAssertTrue(peekOf(HoverCardTarget.peekBadge(of: .tab(restored))) === restored)
    }

    func testNoPeekBadgeCardWithoutAPeekOrALiveHost() {
        XCTAssertNil(HoverCardTarget.peekBadge(of: .tab(makeTab())))
        let dormant = PinnedEntry(pinnedURL: URL(string: "https://a.example")!, pinnedTitle: "A")
        XCTAssertNil(HoverCardTarget.peekBadge(of: .pinned(dormant)))
        XCTAssertNil(HoverCardTarget.peekBadge(of: .favorite(Favorite(url: URL(string: "https://a.example")!, title: "A"))))
        let host = makeTab()
        host.peekURL = URL(string: "https://peek.example")
        XCTAssertNil(HoverCardTarget.peekBadge(of: .peek(host: host)), "a Peek has no Peek of its own")
    }

    func testAPeekBadgeIsInItsHostsRow() {
        let host = makeTab()
        let entry = PinnedEntry(pinnedURL: URL(string: "https://a.example")!, pinnedTitle: "A", tab: host)
        let favorite = Favorite(url: URL(string: "https://a.example")!, title: "A", tab: host)
        for target in [HoverCardTarget.tab(host), .pinned(entry), .favorite(favorite)] {
            XCTAssertTrue(target.isSameRow(as: .peek(host: host)))
            XCTAssertTrue(HoverCardTarget.peek(host: host).isSameRow(as: target))
        }
        let other = makeTab()
        XCTAssertFalse(HoverCardTarget.tab(other).isSameRow(as: .peek(host: host)))
        XCTAssertFalse(HoverCardTarget.peek(host: other).isSameRow(as: .peek(host: host)))
        XCTAssertFalse(HoverCardTarget.tab(other).isSameRow(as: .tab(host)))
    }

    func testPeekTargetsCompareByHost() {
        let host = makeTab()
        XCTAssertTrue(HoverCardTarget.peek(host: host).isSame(as: .peek(host: host)))
        XCTAssertFalse(HoverCardTarget.peek(host: host).isSame(as: .peek(host: makeTab())))
        // The badge and the rest of the row are different targets.
        XCTAssertFalse(HoverCardTarget.peek(host: host).isSame(as: .tab(host)))
        XCTAssertFalse(HoverCardTarget.tab(host).isSame(as: .peek(host: host)))
    }

    func testALivePeekShowsItsOwnTitleURLAndPreview() {
        let host = makeTab("Host", url: "https://host.example/")
        host.switcherPreview = preview()
        let peek = makeTab("Article", url: "https://www.news.example/story")
        let image = preview()
        peek.switcherPreview = image
        host.peekTab = peek
        host.peekURL = peek.url
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { _ in false },
                                            thumbnailKey: { $0.id })
        XCTAssertEqual(content.text, HoverCardText(title: "Article", url: .init(host: "news.example", rest: "/story")))
        XCTAssertTrue(content.preview === image)
        XCTAssertEqual(content.thumbnailKey,
                       TabStore.peekThumbnailKey(hostKey: host.id, peekURL: URL(string: "https://www.news.example/story")!),
                       "the Peek's own disk key, never the host's")
    }

    /// TASK-230: with no picture in memory, the card reads the Peek's from
    /// disk, never the host's.
    func testAPeekWithoutAPreviewLooksOnDiskUnderItsOwnKey() {
        let host = makeTab()
        host.switcherPreview = preview()
        host.peekTab = makeTab("Article", url: "https://news.example/story")
        host.peekURL = host.peekTab?.url
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { _ in false },
                                            thumbnailKey: { $0.id })
        XCTAssertNil(content.preview)
        XCTAssertEqual(content.thumbnailKey,
                       TabStore.peekThumbnailKey(hostKey: host.id, peekURL: URL(string: "https://news.example/story")!))
    }

    func testAPrivateHostsPeekHasNoDiskKey() {
        let host = makeTab()
        host.peekTab = makeTab("Article", url: "https://news.example/story")
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { _ in false },
                                            thumbnailKey: { _ in nil })
        XCTAssertNil(content.thumbnailKey)
    }

    func testAParkedPeekShowsTheSavedURLWhenItsTabHasNone() {
        let host = makeTab()
        host.peekTab = BrowserTab(id: UUID(), title: "Article", url: nil, faviconURL: nil,
                                  cachedInteractionState: nil, spaceID: UUID())
        host.peekURL = URL(string: "https://news.example/story")
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { _ in false },
                                            thumbnailKey: { $0.id })
        XCTAssertEqual(content.text, HoverCardText(title: "Article", url: .init(host: "news.example", rest: "/story")))
    }

    func testARestoredPeekIsNamedByItsURL() {
        // After a relaunch only the host's peek columns are left: no title,
        // and Peeks record no history to look one up in.
        let host = makeTab()
        host.peekURL = URL(string: "https://www.news.example/story")
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { _ in false },
                                            thumbnailKey: { $0.id })
        XCTAssertEqual(content.text, HoverCardText(title: "news.example/story", url: nil))
        XCTAssertNil(content.preview)
        XCTAssertEqual(content.thumbnailKey, TabStore.peekThumbnailKey(hostKey: host.id, peekURL: host.peekURL!),
                       "the picture saved before the relaunch")
    }

    func testAPeekOverTheTabOnScreenShowsNoThumbnail() {
        // A host on screen has its Peek presented over it.
        let host = makeTab()
        let peek = makeTab("Article", url: "https://news.example/story")
        peek.switcherPreview = preview()
        host.peekTab = peek
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { $0 === peek },
                                            thumbnailKey: { $0.id })
        XCTAssertNil(content.preview)
        XCTAssertNil(content.thumbnailKey)
        XCTAssertEqual(content.text.title, "Article")
    }

    /// The unfocused pane of the selected split is on screen, but its Peek is
    /// not: only the focused pane's Peek is presented.
    func testAPeekOfAPaneOnScreenButNotPresentedKeepsItsPicture() {
        let host = makeTab()
        let peek = makeTab("Article", url: "https://news.example/story")
        let image = preview()
        peek.switcherPreview = image
        host.peekTab = peek
        host.peekURL = peek.url
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { $0 === host },
                                            thumbnailKey: { $0.id })
        XCTAssertTrue(content.preview === image)
        XCTAssertNotNil(content.thumbnailKey)
    }

    /// The text names the page the Peek tab is on; the disk key follows the
    /// URL the session saves, which is what a relaunch reads it back under.
    func testAPeeksDiskKeyFollowsTheSavedURLAndItsTextTheTabs() {
        let host = makeTab()
        host.peekTab = makeTab("Article", url: "https://news.example/failed")
        host.peekURL = URL(string: "https://news.example/saved")
        let content = HoverCardContent.make(for: .peek(host: host), isOnScreen: { _ in false },
                                            thumbnailKey: { $0.id })
        XCTAssertEqual(content.text.url, .init(host: "news.example", rest: "/failed"))
        XCTAssertEqual(content.thumbnailKey,
                       TabStore.peekThumbnailKey(hostKey: host.id, peekURL: URL(string: "https://news.example/saved")!))
    }

    // MARK: - Peek badge hit areas

    func testTheRowsPeekBadgeAreaIsItsTrailingEnd() {
        let bounds = NSRect(x: 0, y: 0, width: 224, height: 32)
        let area = TabCellView.peekBadgeHoverRect(in: bounds)
        XCTAssertEqual(area.maxX, bounds.maxX, "the inset to the row's edge belongs to the badge")
        XCTAssertEqual(area.height, bounds.height)
        XCTAssertTrue(area.contains(NSPoint(x: 224 - 4 - 8, y: 16)), "the badge's centre")
        XCTAssertFalse(area.contains(NSPoint(x: 224 - 4 - 16 - 4 - 8, y: 16)), "the close button beside it")
    }

    func testTheTilesPeekBadgeAreaIsItsChip() {
        let bounds = NSRect(x: 0, y: 0, width: 44, height: 32)
        let area = FavoriteTileView.peekBadgeHoverRect(in: bounds)
        XCTAssertTrue(area.contains(NSPoint(x: 44 - 2 - 7, y: 32 - 2 - 7)), "the chip's centre (top right)")
        XCTAssertFalse(area.contains(NSPoint(x: 22, y: 16)), "the tile's favicon")
        XCTAssertEqual(area.maxX, bounds.maxX)
        XCTAssertEqual(area.maxY, bounds.maxY)
    }

    // MARK: - Placement

    func testCardSitsBesideTheSidebarTopAlignedWithTheRow() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = HoverCardPlacement.frame(cardSize: NSSize(width: 260, height: 200),
                                             sidebarMaxX: 280, rowTop: 700, visibleFrame: screen)
        XCTAssertEqual(frame, NSRect(x: 286, y: 500, width: 260, height: 200))
    }

    func testCardStaysOnScreenNearTheBottomAndTop() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 850)
        let low = HoverCardPlacement.frame(cardSize: NSSize(width: 260, height: 200),
                                           sidebarMaxX: 280, rowTop: 100, visibleFrame: screen)
        XCTAssertEqual(low.minY, 25)
        XCTAssertEqual(low.minX, 286)
        let high = HoverCardPlacement.frame(cardSize: NSSize(width: 260, height: 200),
                                            sidebarMaxX: 280, rowTop: 2000, visibleFrame: screen)
        XCTAssertEqual(high.maxY, 875)
    }

    func testCardStaysOnScreenAtTheRightEdge() {
        // A window pushed off the right of the screen.
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = HoverCardPlacement.frame(cardSize: NSSize(width: 260, height: 100),
                                             sidebarMaxX: 1400, rowTop: 500, visibleFrame: screen)
        XCTAssertEqual(frame.maxX, 1440)
    }
}

/// The controller's state machine against a real (borderless) window: the
/// show delay, the immediate swap, dismissal with suppression until the
/// pointer leaves, and the event monitor's lifetime.
final class TabHoverCardControllerTests: XCTestCase {

    private final class FakeHost: TabHoverCardHost {
        let window: NSWindow
        var onScreen: Set<ObjectIdentifier> = []
        init(window: NSWindow) { self.window = window }
        var hoverCardParentWindow: NSWindow? { window }
        var hoverCardSidebarRectInWindow: NSRect? { NSRect(x: 0, y: 0, width: 240, height: 500) }
        func hoverCardIsOnScreen(_ tab: BrowserTab) -> Bool { onScreen.contains(ObjectIdentifier(tab)) }
        func hoverCardThumbnailKey(for tab: BrowserTab) -> UUID? { nil }
    }

    private var window: NSWindow!
    private var host: FakeHost!
    private var controller: TabHoverCardController!

    override func setUp() {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        host = FakeHost(window: window)
        controller = TabHoverCardController()
        controller.host = host
        controller.pressedMouseButtons = { 0 }
    }

    override func tearDown() {
        controller.dismiss()
        controller = nil
        window.orderOut(nil)
        window = nil
    }

    private func makeTab(_ title: String) -> BrowserTab {
        BrowserTab(id: UUID(), title: title, url: URL(string: "https://example.com"), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: UUID())
    }

    private let row = NSRect(x: 8, y: 400, width: 224, height: 32)

    private func waitUntilShowing(file: StaticString = #filePath, line: UInt = #line) {
        let shown = expectation(for: NSPredicate { [weak self] _, _ in self?.controller.isShowing == true },
                                evaluatedWith: nil)
        wait(for: [shown], timeout: 2)
    }

    func testFreshHoverIsPendingThenShowsBesideTheSidebar() {
        let tab = makeTab("A")
        controller.hoverBegan(.tab(tab), rowRectInWindow: row)
        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(controller.isPendingForTesting)
        XCTAssertTrue(controller.hasEventMonitorForTesting)
        waitUntilShowing()
        let panel = try! XCTUnwrap(controller.panelForTesting)
        XCTAssertTrue(panel.parent === window)
        XCTAssertTrue(panel.ignoresMouseEvents)
        let sidebarOnScreen = window.convertToScreen(NSRect(x: 0, y: 0, width: 240, height: 500))
        XCTAssertEqual(panel.frame.minX, sidebarOnScreen.maxX + HoverCardPlacement.gap)
        XCTAssertEqual(panel.frame.maxY, window.convertToScreen(row).maxY, accuracy: 0.5)
    }

    func testLeavingBeforeTheDelayShowsNothingAndRemovesTheMonitor() {
        let tab = makeTab("A")
        controller.hoverBegan(.tab(tab), rowRectInWindow: row)
        controller.hoverEnded(.tab(tab))
        XCTAssertFalse(controller.isPendingForTesting)
        XCTAssertFalse(controller.hasEventMonitorForTesting)
        XCTAssertFalse(controller.isShowing)
    }

    func testMovingToTheNextRowSwapsImmediately() {
        let a = makeTab("A"), b = makeTab("B")
        controller.hoverBegan(.tab(a), rowRectInWindow: row)
        waitUntilShowing()
        controller.hoverEnded(.tab(a))
        XCTAssertFalse(controller.isShowing)
        controller.hoverBegan(.tab(b), rowRectInWindow: row.offsetBy(dx: 0, dy: -32))
        XCTAssertTrue(controller.isShowing, "a card hidden a moment ago swaps at once")
        XCTAssertFalse(controller.isPendingForTesting)
    }

    func testEnterBeforeExitAlsoSwaps() {
        let a = makeTab("A"), b = makeTab("B")
        controller.hoverBegan(.tab(a), rowRectInWindow: row)
        waitUntilShowing()
        controller.hoverBegan(.tab(b), rowRectInWindow: row.offsetBy(dx: 0, dy: -32))
        controller.hoverEnded(.tab(a))   // late exit of the old row: ignored
        XCTAssertTrue(controller.isShowing)
    }

    /// TASK-229: as the pointer crosses into the Peek badge the sidebar
    /// begins the badge's target over the row's (or the reverse), without
    /// ending the row's: the pointer has not left the row.
    func testMovingBetweenTheRowAndItsPeekBadgeSwapsImmediately() {
        let host = makeTab("Host")
        host.peekTab = makeTab("Peek")
        controller.hoverBegan(.tab(host), rowRectInWindow: row)
        waitUntilShowing()
        let rowCardTop = try! XCTUnwrap(controller.panelForTesting).frame.maxY

        controller.hoverBegan(.peek(host: host), rowRectInWindow: row)
        XCTAssertTrue(controller.isShowing, "the Peek's card replaces the row's at once")
        XCTAssertFalse(controller.isPendingForTesting)
        XCTAssertEqual(try! XCTUnwrap(controller.panelForTesting).frame.maxY, rowCardTop, accuracy: 0.5,
                       "placed beside the row as the host's card is")

        controller.hoverBegan(.tab(host), rowRectInWindow: row)
        XCTAssertTrue(controller.isShowing, "and back")
    }

    /// TASK-229: a dismissal keeps the card away until the pointer leaves the
    /// row, not until it crosses onto or off the row's Peek badge.
    func testDismissSuppressesAcrossThePeekBadgeUntilThePointerLeavesTheRow() {
        let host = makeTab("Host")
        host.peekTab = makeTab("Peek")
        controller.hoverBegan(.tab(host), rowRectInWindow: row)
        waitUntilShowing()
        controller.dismiss()

        controller.hoverBegan(.peek(host: host), rowRectInWindow: row)
        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(controller.isPendingForTesting, "the badge is part of the dismissed row")
        controller.hoverBegan(.tab(host), rowRectInWindow: row)
        XCTAssertFalse(controller.isPendingForTesting, "and so is the rest of the row")

        // Leaving from the badge ends the suppression.
        controller.hoverBegan(.peek(host: host), rowRectInWindow: row)
        controller.hoverEnded(.peek(host: host))
        controller.hoverBegan(.tab(host), rowRectInWindow: row)
        XCTAssertTrue(controller.isPendingForTesting)
    }

    func testDismissSuppressesUntilThePointerLeavesTheRow() {
        let a = makeTab("A")
        controller.hoverBegan(.tab(a), rowRectInWindow: row)
        waitUntilShowing()
        controller.dismiss()
        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(controller.hasEventMonitorForTesting)
        // A re-report of the same row (recheckHover) stays quiet.
        controller.hoverBegan(.tab(a), rowRectInWindow: row)
        XCTAssertFalse(controller.isPendingForTesting)
        // Leaving and coming back waits the full delay again.
        controller.hoverEnded(.tab(a))
        controller.hoverBegan(.tab(a), rowRectInWindow: row)
        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(controller.isPendingForTesting)
    }

    func testDismissWhilePendingCancelsTheShow() {
        let a = makeTab("A"), b = makeTab("B")
        controller.hoverBegan(.tab(a), rowRectInWindow: row)
        controller.dismiss()
        XCTAssertFalse(controller.isPendingForTesting)
        // Another row is a fresh hover: it waits, it does not swap.
        controller.hoverBegan(.tab(b), rowRectInWindow: row)
        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(controller.isPendingForTesting)
    }

    func testNoCardWhileTheSidebarIsHidden() {
        final class HiddenSidebarHost: TabHoverCardHost {
            let window: NSWindow
            init(window: NSWindow) { self.window = window }
            var hoverCardParentWindow: NSWindow? { window }
            var hoverCardSidebarRectInWindow: NSRect? { nil }
            func hoverCardIsOnScreen(_ tab: BrowserTab) -> Bool { false }
            func hoverCardThumbnailKey(for tab: BrowserTab) -> UUID? { nil }
        }
        let hidden = HiddenSidebarHost(window: window)
        controller.host = hidden
        let a = makeTab("A"), b = makeTab("B")
        controller.hoverBegan(.tab(a), rowRectInWindow: row)
        let fired = expectation(description: "delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverCardTiming.showDelay + 0.2) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
        XCTAssertFalse(controller.isShowing)
        XCTAssertFalse(controller.hasEventMonitorForTesting)
        controller.hoverEnded(.tab(a))
        controller.hoverBegan(.tab(b), rowRectInWindow: row)
        XCTAssertFalse(controller.isShowing)
    }
}

/// TASK-229: a row reports when the pointer is over a Peek badge — the
/// trailing one of a single row or a split's right pane, and the left pane's
/// before the divider — so the hover card can be the Peek's.
final class TabCellPeekBadgeHoverTests: XCTestCase {

    private final class Recorder: TabCellHoverDelegate {
        var reports: [(hovering: Bool, side: Int?, overPeekBadge: Bool)] = []
        func tabCell(_ cell: TabCellView, hoverChanged hovering: Bool, splitSide: Int?, overPeekBadge: Bool) {
            reports.append((hovering, splitSide, overPeekBadge))
        }
    }

    private let bounds = NSRect(x: 0, y: 0, width: 240, height: 32)
    private let badge = NSImage(size: NSSize(width: 16, height: 16))

    private func makeCell(_ recorder: Recorder) -> TabCellView {
        let cell = TabCellView(frame: bounds)
        cell.hoverDelegate = recorder
        return cell
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        if type == .mouseMoved {
            return NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        return NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                      userData: nil)!
    }

    private func center(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }

    func testASingleRowReportsItsTrailingBadge() {
        let recorder = Recorder()
        let cell = makeCell(recorder)
        cell.updatePeekFavicon(badge)
        cell.mouseEntered(with: event(.mouseEntered, at: center(TabCellView.peekBadgeHoverRect(in: bounds))))
        XCTAssertEqual(recorder.reports.last?.overPeekBadge, true)
        XCTAssertNil(recorder.reports.last?.side)
        cell.mouseMoved(with: event(.mouseMoved, at: NSPoint(x: 60, y: 16)))
        XCTAssertEqual(recorder.reports.last?.overPeekBadge, false)
        XCTAssertEqual(recorder.reports.last?.hovering, true)
    }

    func testTheLeftPanesBadgeSitsInTheLeftHalfBeforeTheDivider() {
        let area = TabCellView.leftPanePeekBadgeHoverRect(in: bounds)
        XCTAssertFalse(area.isEmpty)
        XCTAssertLessThanOrEqual(area.maxX, bounds.midX, "inside the left half")
        XCTAssertGreaterThan(area.minX, bounds.midX - 40, "next to the divider, not over the title")
        XCTAssertEqual(area.height, bounds.height)
        XCTAssertFalse(area.intersects(TabCellView.peekBadgeHoverRect(in: bounds)))
    }

    func testASplitRowReportsEachPanesBadgeInItsOwnHalf() {
        let recorder = Recorder()
        let cell = makeCell(recorder)
        cell.updateSplitPane(favicon: badge, title: "Right")
        cell.updateLeftPanePeekFavicon(badge)
        cell.updatePeekFavicon(badge)

        cell.mouseEntered(with: event(.mouseEntered, at: center(TabCellView.leftPanePeekBadgeHoverRect(in: bounds))))
        XCTAssertEqual(recorder.reports.last?.side, 0)
        XCTAssertEqual(recorder.reports.last?.overPeekBadge, true, "the left pane's badge")

        cell.mouseMoved(with: event(.mouseMoved, at: NSPoint(x: 30, y: 16)))
        XCTAssertEqual(recorder.reports.last?.side, 0)
        XCTAssertEqual(recorder.reports.last?.overPeekBadge, false, "the left pane's title")

        cell.mouseMoved(with: event(.mouseMoved, at: center(TabCellView.peekBadgeHoverRect(in: bounds))))
        XCTAssertEqual(recorder.reports.last?.side, 1)
        XCTAssertEqual(recorder.reports.last?.overPeekBadge, true, "the right pane's badge")
    }

    func testAPaneWithoutAPeekHasNoBadgeArea() {
        let recorder = Recorder()
        let cell = makeCell(recorder)
        cell.updateSplitPane(favicon: badge, title: "Right")
        cell.updateLeftPanePeekFavicon(nil)
        cell.updatePeekFavicon(badge)
        cell.mouseEntered(with: event(.mouseEntered, at: center(TabCellView.leftPanePeekBadgeHoverRect(in: bounds))))
        XCTAssertEqual(recorder.reports.last?.side, 0)
        XCTAssertEqual(recorder.reports.last?.overPeekBadge, false)
        XCTAssertTrue(cell.leftPanePeekFaviconImageView.isHidden)
    }

    func testTheLeftPanesBadgeGoesWithTheSplit() {
        let cell = makeCell(Recorder())
        cell.updateSplitPane(favicon: badge, title: "Right")
        cell.updateLeftPanePeekFavicon(badge)
        XCTAssertFalse(cell.leftPanePeekFaviconImageView.isHidden)
        cell.updateSplitPane(favicon: nil, title: nil)
        XCTAssertTrue(cell.leftPanePeekFaviconImageView.isHidden, "a single row has one badge, the trailing one")
    }

    func testASplitAgainDoesNotInheritTheOldLeftPanesBadge() {
        let recorder = Recorder()
        let cell = makeCell(recorder)
        cell.updateSplitPane(favicon: badge, title: "Right")
        cell.updateLeftPanePeekFavicon(badge)
        cell.updateSplitPane(favicon: nil, title: nil)
        cell.updateSplitPane(favicon: badge, title: "Right")
        XCTAssertTrue(cell.leftPanePeekFaviconImageView.isHidden)
        XCTAssertNil(cell.leftPanePeekFaviconImageView.image)
        cell.mouseEntered(with: event(.mouseEntered, at: center(TabCellView.leftPanePeekBadgeHoverRect(in: bounds))))
        XCTAssertEqual(recorder.reports.last?.overPeekBadge, false)
    }
}
