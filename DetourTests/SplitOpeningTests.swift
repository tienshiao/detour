import XCTest
import GRDB
import WebKit
@testable import Detour

/// Opening a split from a link or a Peek (TASK-185): which tabs can, the Peek
/// hand-off variant of `addTabInSplit`, and the normal-section split a
/// favourite or a lone pinned tab opens.
final class SplitOpeningTests: XCTestCase {

    private func makeStore() throws -> (TabStore, Space) {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let profile = store.addProfile(name: "Test")
        let space = store.addSpace(name: "Test", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, space)
    }

    private func makeSleepingTab(spaceID: UUID, url: String = "https://example.com",
                                 parentID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(id: UUID(), title: "Tab", url: URL(string: url), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: spaceID)
        tab.parentID = parentID
        return tab
    }

    /// A lone pinned entry whose backing tab is live (asleep, with a URL).
    private func makePinnedTab(_ store: TabStore, _ space: Space,
                               url: String = "https://pinned.example/home") -> (PinnedEntry, BrowserTab) {
        let tab = makeSleepingTab(spaceID: space.id, url: url)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        return (space.pinnedEntries.first { $0.tab === tab }!, tab)
    }

    /// A favourite of the space's profile, live on a sleeping backing tab.
    private func makeFavoriteTab(_ store: TabStore, _ space: Space,
                                 url: String = "https://fav.example/") -> (Favorite, BrowserTab) {
        let tab = makeSleepingTab(spaceID: space.id, url: url)
        store.addFavorite(from: tab, profileID: space.profileID)
        return (space.profile!.favorites.first { $0.tab === tab }!, tab)
    }

    private func makeWebView(for space: Space) -> WKWebView {
        WKWebView(frame: .zero, configuration: space.makeWebViewConfiguration())
    }

    private let linkURL = URL(string: "https://link.example/page")!

    /// The groups that form exactly one adjacent run of two (the sanitizer's test).
    private func validGroups(_ tabs: [BrowserTab]) -> Set<UUID> {
        validSplitGroupIDs(in: splitRuns(of: tabs, groupID: \.splitGroupID))
    }

    // MARK: - splitOpening

    func testSplitOpeningClassifiesEachKindOfTab() throws {
        let (store, space) = try makeStore()
        let lone = makeSleepingTab(spaceID: space.id)
        let left = makeSleepingTab(spaceID: space.id)
        let right = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [lone, left, right])
        store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        let (_, pinned) = makePinnedTab(store, space)
        let (_, favorite) = makeFavoriteTab(store, space)

        XCTAssertEqual(store.splitOpening(from: lone.id, in: space), .besideTab)
        XCTAssertNil(store.splitOpening(from: left.id, in: space), "a pane of a split opens no other split")
        XCTAssertEqual(store.splitOpening(from: pinned.id, in: space), .inNormalSection)
        XCTAssertEqual(store.splitOpening(from: favorite.id, in: space), .inNormalSection)
        XCTAssertNil(store.splitOpening(from: UUID(), in: space))
    }

    func testSplitOpeningRefusesPinnedSplitMemberEvenWithDormantPartner() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<2).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        store.createSplit(draggedTabID: tabs[1].id, targetTabID: tabs[0].id, edge: .right, in: space)
        let groupID = try XCTUnwrap(tabs[0].splitGroupID)
        store.pinSplitGroup(groupID: groupID, in: space)
        let entries = store.pinnedSplitEntries(groupID: groupID, in: space)
        XCTAssertEqual(entries.count, 2)

        XCTAssertNil(store.splitOpening(from: tabs[0].id, in: space))
        // The partner goes dormant: the live member is still a pane of a split.
        entries[1].tab = nil
        XCTAssertNil(store.splitOpening(from: tabs[0].id, in: space))
        XCTAssertNil(store.addSplitInNormalSection(copying: tabs[0].id, rightPane: .url(linkURL), in: space))
        XCTAssertTrue(space.tabs.isEmpty)
    }

    func testSplitOpeningRefusesAPeek() throws {
        let (store, space) = try makeStore()
        let host = makeSleepingTab(spaceID: space.id)
        space.tabs.append(host)
        let peek = BrowserTab(webView: makeWebView(for: space))
        host.peekTab = peek

        XCTAssertNil(store.splitOpening(from: peek.id, in: space))
        host.peekTab = nil
        peek.teardown()
    }

    /// A page of an extension cannot be copied into a tab built from the
    /// space's configuration, which cannot load the scheme.
    func testSplitOpeningRefusesAnExtensionPagePinnedTab() throws {
        let (store, space) = try makeStore()
        let (_, pinned) = makePinnedTab(store, space, url: "webkit-extension://abcdef/page.html")

        XCTAssertNil(store.splitOpening(from: pinned.id, in: space))
        XCTAssertNil(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL), in: space))
        XCTAssertTrue(space.tabs.isEmpty)
    }

    // MARK: - addTabInSplit(with:webView:in:)

    func testAddTabInSplitWithWebViewAdoptsTheSameWebView() throws {
        let (store, space) = try makeStore()
        let anchor = makeSleepingTab(spaceID: space.id)
        let other = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [anchor, other])
        let webView = makeWebView(for: space)

        let pane = try XCTUnwrap(store.addTabInSplit(with: anchor.id, webView: webView, in: space))

        XCTAssertTrue(pane.webView === webView, "the Peek's own web view, not a new one")
        XCTAssertEqual(space.tabs.map(\.id), [anchor.id, pane.id, other.id])
        XCTAssertNotNil(anchor.splitGroupID)
        XCTAssertEqual(pane.splitGroupID, anchor.splitGroupID)
        XCTAssertEqual(pane.parentID, anchor.id)
        XCTAssertEqual(pane.splitFraction, 0.5)
        XCTAssertEqual(pane.spaceID, space.id)
    }

    func testAddTabInSplitWithWebViewRefusesGroupedPinnedAndFavoriteAnchors() throws {
        let (store, space) = try makeStore()
        let tabs = (0..<2).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        store.createSplit(draggedTabID: tabs[1].id, targetTabID: tabs[0].id, edge: .right, in: space)
        let (_, pinned) = makePinnedTab(store, space)
        let (_, favorite) = makeFavoriteTab(store, space)

        for anchor in [tabs[0], pinned, favorite] {
            XCTAssertNil(store.addTabInSplit(with: anchor.id, webView: makeWebView(for: space), in: space))
        }
        XCTAssertEqual(space.tabs.map(\.id), tabs.map(\.id))
    }

    func testAddTabInSplitWithWebViewUndoRemovesThePaneWithoutArchiving() throws {
        let (store, space) = try makeStore()
        let anchor = makeSleepingTab(spaceID: space.id)
        space.tabs.append(anchor)

        XCTAssertNotNil(store.addTabInSplit(with: anchor.id, webView: makeWebView(for: space), in: space))
        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.id), [anchor.id])
        XCTAssertNil(anchor.splitGroupID)
        XCTAssertTrue(store.closedTabRecords(in: space).isEmpty)
    }

    // MARK: - addSplitInNormalSection

    func testSplitFromPinnedTabOpensInNormalSectionWithACopyOnTheLeft() throws {
        let (store, space) = try makeStore()
        let others = (0..<2).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: others)
        let (entry, pinned) = makePinnedTab(store, space)

        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL),
                                                                in: space))

        XCTAssertEqual(space.tabs.count, 4)
        let left = space.tabs[0]
        XCTAssertEqual(space.tabs.map(\.id), [left.id, right.id] + others.map(\.id),
                       "a new tab from a pinned parent goes to the top of the normal section")
        XCTAssertFalse(left === pinned, "the left pane is a copy, not the pinned tab")
        XCTAssertEqual(left.url, pinned.url)
        XCTAssertEqual(right.url, linkURL)
        XCTAssertNotNil(left.splitGroupID)
        XCTAssertEqual(left.splitGroupID, right.splitGroupID)
        XCTAssertEqual(store.splitGroup(containing: right.id, in: space)?.members.map(\.id), [left.id, right.id])
        XCTAssertEqual(left.splitFraction, 0.5)
        XCTAssertEqual(right.splitFraction, 0.5)
        XCTAssertEqual(left.parentID, pinned.id)
        XCTAssertEqual(right.parentID, pinned.id)
        XCTAssertEqual(validGroups(space.tabs), [left.splitGroupID!])

        // The pinned entry and its tab are untouched.
        XCTAssertEqual(space.pinnedEntries.count, 1)
        XCTAssertTrue(entry.tab === pinned)
        XCTAssertNil(entry.splitGroupID)
        XCTAssertNil(pinned.splitGroupID)
        XCTAssertFalse(space.tabs.contains { $0 === pinned })
    }

    func testSplitFromFavoriteOpensInNormalSectionAndLeavesTheFavorite() throws {
        let (store, space) = try makeStore()
        let other = makeSleepingTab(spaceID: space.id)
        space.tabs.append(other)
        let (favorite, favoriteTab) = makeFavoriteTab(store, space)
        let favoriteURL = favorite.url

        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: favoriteTab.id,
                                                                rightPane: .url(linkURL), in: space))

        let left = space.tabs[0]
        XCTAssertEqual(space.tabs.map(\.id), [left.id, right.id, other.id])
        XCTAssertEqual(left.url, favoriteTab.url)
        XCTAssertEqual(left.splitGroupID, right.splitGroupID)
        XCTAssertNotNil(left.splitGroupID)
        XCTAssertEqual(right.parentID, favoriteTab.id)
        XCTAssertEqual(space.profile?.favorites.count, 1)
        XCTAssertTrue(favorite.tab === favoriteTab)
        XCTAssertEqual(favorite.url, favoriteURL)
        XCTAssertNil(favoriteTab.splitGroupID)
    }

    func testSplitCopiesTheParentsCurrentURLNotItsPinnedHome() throws {
        let (store, space) = try makeStore()
        let (entry, pinned) = makePinnedTab(store, space, url: "https://pinned.example/home")
        pinned.url = URL(string: "https://pinned.example/inbox/42")

        XCTAssertNotNil(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL), in: space))

        XCTAssertEqual(space.tabs.first?.url, URL(string: "https://pinned.example/inbox/42"))
        XCTAssertEqual(entry.pinnedURL, URL(string: "https://pinned.example/home"))
    }

    /// The `TabInsertion` rule for a pinned or favourite parent: the top of the
    /// normal section, after the run of tabs that parent already opened.
    func testSplitLandsAfterTheParentsExistingChildren() throws {
        let (store, space) = try makeStore()
        let (_, pinned) = makePinnedTab(store, space)
        let children = (0..<2).map { _ in makeSleepingTab(spaceID: space.id, parentID: pinned.id) }
        let unrelated = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: children + [unrelated])

        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL),
                                                                in: space))

        XCTAssertEqual(space.tabs.count, 5)
        XCTAssertEqual(space.tabs[3].id, right.id)
        XCTAssertEqual(space.tabs.map(\.id), children.map(\.id) + [space.tabs[2].id, right.id, unrelated.id])
    }

    /// The insertion point falls between the two panes of an existing split
    /// (its left pane is the parent's last child): the new pair snaps past it.
    func testSplitSnapsPastAnExistingSplitAtTheInsertionPoint() throws {
        let (store, space) = try makeStore()
        let (_, favoriteTab) = makeFavoriteTab(store, space)
        let child = makeSleepingTab(spaceID: space.id, parentID: favoriteTab.id)
        let partner = makeSleepingTab(spaceID: space.id)
        let unrelated = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [child, partner, unrelated])
        store.createSplit(draggedTabID: partner.id, targetTabID: child.id, edge: .right, in: space)
        let existingGroup = try XCTUnwrap(child.splitGroupID)

        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: favoriteTab.id,
                                                                rightPane: .url(linkURL), in: space))

        let left = space.tabs[2]
        XCTAssertEqual(space.tabs.map(\.id), [child.id, partner.id, left.id, right.id, unrelated.id])
        XCTAssertEqual(child.splitGroupID, existingGroup)
        XCTAssertEqual(partner.splitGroupID, existingGroup)
        XCTAssertNotEqual(left.splitGroupID, existingGroup)
        XCTAssertEqual(validGroups(space.tabs), [existingGroup, left.splitGroupID!])
    }

    /// With no children of the parent, the pair goes to index 0 — before a
    /// split that already starts the section, never inside it.
    func testSplitLandsBeforeASplitThatStartsTheSection() throws {
        let (store, space) = try makeStore()
        let (_, pinned) = makePinnedTab(store, space)
        let pair = (0..<2).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: pair)
        store.createSplit(draggedTabID: pair[1].id, targetTabID: pair[0].id, edge: .right, in: space)

        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL),
                                                                in: space))

        XCTAssertEqual(space.tabs.map(\.id), [space.tabs[0].id, right.id] + pair.map(\.id))
        XCTAssertEqual(validGroups(space.tabs).count, 2)
    }

    /// Both panes count as the parent's children, so a second split from the
    /// same parent stacks after the first rather than splitting it.
    func testSecondSplitFromTheSameParentLandsAfterTheFirst() throws {
        let (store, space) = try makeStore()
        let (_, pinned) = makePinnedTab(store, space)

        let firstRight = try XCTUnwrap(store.addSplitInNormalSection(copying: pinned.id,
                                                                     rightPane: .url(linkURL), in: space))
        let secondRight = try XCTUnwrap(store.addSplitInNormalSection(copying: pinned.id,
                                                                      rightPane: .url(linkURL), in: space))

        XCTAssertEqual(space.tabs.count, 4)
        XCTAssertEqual(space.tabs[1].id, firstRight.id)
        XCTAssertEqual(space.tabs[3].id, secondRight.id)
        XCTAssertEqual(validGroups(space.tabs).count, 2)
    }

    func testSplitWithWebViewAdoptsTheSameWebView() throws {
        let (store, space) = try makeStore()
        let (_, favoriteTab) = makeFavoriteTab(store, space)
        let webView = makeWebView(for: space)

        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: favoriteTab.id,
                                                                rightPane: .webView(webView), in: space))

        XCTAssertTrue(right.webView === webView)
        XCTAssertEqual(space.tabs.map(\.id).last, right.id)
        XCTAssertEqual(space.tabs.first?.url, favoriteTab.url)
        XCTAssertEqual(space.tabs.first?.splitGroupID, right.splitGroupID)
    }

    func testSplitInNormalSectionRefusesNormalTabs() throws {
        let (store, space) = try makeStore()
        let lone = makeSleepingTab(spaceID: space.id)
        space.tabs.append(lone)

        XCTAssertNil(store.addSplitInNormalSection(copying: lone.id, rightPane: .url(linkURL), in: space))
        XCTAssertEqual(space.tabs.map(\.id), [lone.id])
        XCTAssertNil(lone.splitGroupID)
    }

    func testSplitInNormalSectionUndoRemovesBothWithoutArchivingAndLeavesTheEntry() throws {
        let (store, space) = try makeStore()
        let other = makeSleepingTab(spaceID: space.id)
        space.tabs.append(other)
        let (entry, pinned) = makePinnedTab(store, space)
        let (sortOrder, folderID, pinnedURL, pinnedTitle) = (entry.sortOrder, entry.folderID,
                                                             entry.pinnedURL, entry.pinnedTitle)
        // pinTab registered its own undo; only the split's is under test.
        store.undoManager.removeAllActions()

        XCTAssertNotNil(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL), in: space))
        XCTAssertEqual(space.tabs.count, 3)
        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.id), [other.id])
        XCTAssertTrue(store.closedTabRecords(in: space).isEmpty,
                      "the panes never existed as lone tabs; undo must not archive them")
        XCTAssertEqual(space.pinnedEntries.map(\.id), [entry.id])
        XCTAssertTrue(entry.tab === pinned)
        XCTAssertEqual(entry.sortOrder, sortOrder)
        XCTAssertEqual(entry.folderID, folderID)
        XCTAssertEqual(entry.pinnedURL, pinnedURL)
        XCTAssertEqual(entry.pinnedTitle, pinnedTitle)
        XCTAssertNil(entry.splitGroupID)
        XCTAssertFalse(store.undoManager.canUndo, "one gesture, one undo")
    }

    func testSplitInNormalSectionUndoFromAFavoriteLeavesTheFavorite() throws {
        let (store, space) = try makeStore()
        let (favorite, favoriteTab) = makeFavoriteTab(store, space)
        store.undoManager.removeAllActions()

        XCTAssertNotNil(store.addSplitInNormalSection(copying: favoriteTab.id,
                                                      rightPane: .webView(makeWebView(for: space)), in: space))
        store.undoManager.undo()

        XCTAssertTrue(space.tabs.isEmpty)
        XCTAssertTrue(store.closedTabRecords(in: space).isEmpty)
        XCTAssertEqual(space.profile?.favorites.map(\.id), [favorite.id])
        XCTAssertTrue(favorite.tab === favoriteTab)
    }

    private final class RemovalRecorder: TabStoreObserver {
        var removals: [(id: UUID, index: Int)] = []
        func tabStoreDidRemoveTab(_ tab: BrowserTab, at index: Int, in space: Space) {
            removals.append((tab.id, index))
        }
    }

    /// Both panes are gone before either removal is reported, so each index is
    /// given in the final list: `tabs[index]` is the tab that followed the pair,
    /// where a window settles its selection — not the one after that.
    func testSplitInNormalSectionUndoReportsIndicesInTheFinalList() throws {
        let (store, space) = try makeStore()
        let (_, pinned) = makePinnedTab(store, space)
        let followers = (0..<2).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: followers)
        store.undoManager.removeAllActions()
        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL),
                                                                in: space))
        let leftID = space.tabs[0].id
        let recorder = RemovalRecorder()
        store.addObserver(recorder)
        defer { store.removeObserver(recorder) }

        store.undoManager.undo()

        XCTAssertEqual(space.tabs.map(\.id), followers.map(\.id))
        XCTAssertEqual(recorder.removals.map(\.id), [right.id, leftID])
        XCTAssertEqual(recorder.removals.map(\.index), [0, 0])
    }

    /// Undo finds the panes by id: Undo Delete Space rebuilds a space's tabs as
    /// fresh objects of the same ids (TASK-40).
    func testSplitInNormalSectionUndoSkipsPanesThatAreGone() throws {
        let (store, space) = try makeStore()
        let (_, pinned) = makePinnedTab(store, space)
        store.undoManager.removeAllActions()
        let right = try XCTUnwrap(store.addSplitInNormalSection(copying: pinned.id, rightPane: .url(linkURL),
                                                                in: space))
        let leftID = space.tabs[0].id
        // The right pane is closed some other way first.
        store.closeTab(id: right.id, in: space, undoable: false)
        XCTAssertEqual(space.tabs.map(\.id), [leftID])

        store.undoManager.undo()

        XCTAssertTrue(space.tabs.isEmpty, "the surviving pane is still removed")
    }
}
