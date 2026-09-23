import XCTest
@testable import Detour

/// Cmd+Option+Up/Down stop order and targeting (TASK-107).
final class TabNavigationTests: XCTestCase {

    private func makeTab(splitGroupID: UUID? = nil) -> BrowserTab {
        let tab = BrowserTab(
            id: UUID(),
            title: "Tab",
            url: URL(string: "https://example.com"),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: UUID()
        )
        tab.splitGroupID = splitGroupID
        return tab
    }

    private func makeEntry(folderID: UUID? = nil, sortOrder: Int, splitGroupID: UUID? = nil, live: Bool = true) -> PinnedEntry {
        let entry = PinnedEntry(
            pinnedURL: URL(string: "https://example.com")!,
            pinnedTitle: "Pinned",
            folderID: folderID,
            sortOrder: sortOrder
        )
        entry.splitGroupID = splitGroupID
        if live { entry.tab = makeTab() }
        return entry
    }

    private func stops(entries: [PinnedEntry] = [], folders: [PinnedFolder] = [],
                       tabs: [BrowserTab] = [], selectedTabID: UUID? = nil) -> [TabNavigationStop] {
        let pinnedItems = flattenPinnedTree(
            entries: entries,
            folders: folders,
            collapsedFolderIDs: Set(folders.filter(\.isCollapsed).map(\.id)),
            selectedTabID: selectedTabID
        )
        return tabNavigationStops(pinnedItems: pinnedItems, tabItems: tabListItems(from: tabs))
    }

    // MARK: - Stops

    func testPinnedRowsComeBeforeNormalTabs() {
        let p0 = makeEntry(sortOrder: 0)
        let p1 = makeEntry(sortOrder: 1)
        let t0 = makeTab()
        let t1 = makeTab()

        let result = stops(entries: [p1, p0], tabs: [t0, t1])

        XCTAssertEqual(result.map(\.target), [.pinnedEntry(p0.id), .pinnedEntry(p1.id), .tab(t0.id), .tab(t1.id)])
    }

    func testFolderRowsAreSkippedAndExpandedChildrenIncluded() {
        let folder = PinnedFolder(name: "F", sortOrder: 0)
        let child = makeEntry(folderID: folder.id, sortOrder: 0)
        let after = makeEntry(sortOrder: 1)

        let result = stops(entries: [child, after], folders: [folder])

        XCTAssertEqual(result.map(\.target), [.pinnedEntry(child.id), .pinnedEntry(after.id)])
    }

    func testCollapsedFolderHidesChildrenUnlessSelected() {
        let folder = PinnedFolder(name: "F", isCollapsed: true, sortOrder: 0)
        let child = makeEntry(folderID: folder.id, sortOrder: 0)
        let hidden = makeEntry(folderID: folder.id, sortOrder: 1)
        let after = makeEntry(sortOrder: 1)

        XCTAssertEqual(stops(entries: [child, hidden, after], folders: [folder]).map(\.target),
                       [.pinnedEntry(after.id)])
        // The selected child is exposed as a row, so it is a stop too.
        XCTAssertEqual(stops(entries: [child, hidden, after], folders: [folder], selectedTabID: child.tab?.id).map(\.target),
                       [.pinnedEntry(child.id), .pinnedEntry(after.id)])
    }

    func testNormalSplitIsOneStopCoveringBothPanes() {
        let group = UUID()
        let left = makeTab(splitGroupID: group)
        let right = makeTab(splitGroupID: group)
        let lone = makeTab()

        let result = stops(tabs: [left, right, lone])

        XCTAssertEqual(result, [
            TabNavigationStop(target: .tab(left.id), tabIDs: [left.id, right.id]),
            TabNavigationStop(target: .tab(lone.id), tabIDs: [lone.id]),
        ])
    }

    func testPinnedSplitIsOneStopCoveringBothPanes() {
        let group = UUID()
        let left = makeEntry(sortOrder: 0, splitGroupID: group)
        let right = makeEntry(sortOrder: 1, splitGroupID: group)

        let result = stops(entries: [left, right])

        XCTAssertEqual(result, [
            TabNavigationStop(target: .pinnedEntry(left.id), tabIDs: [left.tab!.id, right.tab!.id]),
        ])
    }

    func testDormantPinnedEntryIsAStopWithNoTabs() {
        let dormant = makeEntry(sortOrder: 0, live: false)

        XCTAssertEqual(stops(entries: [dormant]), [TabNavigationStop(target: .pinnedEntry(dormant.id), tabIDs: [])])
    }

    // MARK: - Target

    private func stop(_ id: UUID) -> TabNavigationStop {
        TabNavigationStop(target: .tab(id), tabIDs: [id])
    }

    func testMovesByOffsetFromTheCurrentStop() {
        let ids = (0..<3).map { _ in UUID() }
        let list = ids.map(stop)

        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: ids[1], offset: 1), list[2])
        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: ids[1], offset: -1), list[0])
    }

    func testWrapsAtBothEnds() {
        let ids = (0..<3).map { _ in UUID() }
        let list = ids.map(stop)

        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: ids[2], offset: 1), list[0])
        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: ids[0], offset: -1), list[2])
    }

    func testEitherSplitPaneLocatesTheSplitStop() {
        let left = UUID(), right = UUID(), next = UUID()
        let list = [TabNavigationStop(target: .tab(left), tabIDs: [left, right]), stop(next)]

        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: right, offset: 1), list[1])
        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: next, offset: -1), list[0])
    }

    func testNoCurrentStopStartsAtTheEnds() {
        let list = (0..<3).map { _ in stop(UUID()) }

        // A favourite (not in the sidebar list) or nothing selected.
        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: UUID(), offset: 1), list[0])
        XCTAssertEqual(tabNavigationTarget(in: list, selectedTabID: nil, offset: -1), list[2])
    }

    func testNothingToDoWithNoOtherStop() {
        let only = UUID()

        XCTAssertNil(tabNavigationTarget(in: [], selectedTabID: nil, offset: 1))
        XCTAssertNil(tabNavigationTarget(in: [stop(only)], selectedTabID: only, offset: 1))
        XCTAssertNil(tabNavigationTarget(in: [stop(only)], selectedTabID: only, offset: -1))
        // A single stop that is not selected is still reachable.
        XCTAssertEqual(tabNavigationTarget(in: [stop(only)], selectedTabID: nil, offset: 1), stop(only))
    }
}
