import XCTest
@testable import Detour

final class TabStoreTests: XCTestCase {

    private func makeStore() -> (TabStore, Space) {
        let store = TabStore()
        let profile = store.addProfile(name: "Test")
        let space = store.addSpace(name: "Test", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        return (store, space)
    }

    private func makeSleepingTab(spaceID: UUID) -> BrowserTab {
        BrowserTab(
            id: UUID(),
            title: "Tab",
            url: URL(string: "https://example.com"),
            faviconURL: nil,
            cachedInteractionState: nil,
            spaceID: spaceID
        )
    }

    // MARK: - Pin / Unpin

    func testPinTabMovesToPinnedTabs() {
        let (store, space) = makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)

        store.pinTab(id: tab.id, in: space)

        XCTAssertTrue(space.tabs.isEmpty)
        XCTAssertEqual(space.pinnedTabs.count, 1)
        XCTAssertTrue(space.pinnedTabs[0].isPinned)
        XCTAssertEqual(space.pinnedTabs[0].pinnedURL, tab.url)
        XCTAssertEqual(space.pinnedTabs[0].pinnedTitle, tab.title)
    }

    func testUnpinTabMovesBackToTabs() {
        let (store, space) = makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)

        store.unpinTab(id: tab.id, in: space)

        XCTAssertTrue(space.pinnedTabs.isEmpty)
        XCTAssertEqual(space.tabs.count, 1)
        XCTAssertFalse(space.tabs[0].isPinned)
        XCTAssertNil(space.tabs[0].pinnedURL)
        XCTAssertNil(space.tabs[0].pinnedTitle)
    }

    func testPinTabAtSpecificIndex() {
        let (store, space) = makeStore()
        let tab1 = makeSleepingTab(spaceID: space.id)
        let tab2 = makeSleepingTab(spaceID: space.id)
        let tab3 = makeSleepingTab(spaceID: space.id)
        space.tabs.append(contentsOf: [tab1, tab2, tab3])

        store.pinTab(id: tab1.id, in: space)
        store.pinTab(id: tab2.id, in: space)
        // Pin tab3 at index 0 (before tab1)
        store.pinTab(id: tab3.id, in: space, at: 0)

        XCTAssertEqual(space.pinnedTabs.map(\.id), [tab3.id, tab1.id, tab2.id])
    }

    // MARK: - Move Tab

    func testMoveTabReorders() {
        let (store, space) = makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)

        store.moveTab(from: 0, to: 2, in: space)

        XCTAssertEqual(space.tabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id])
    }

    func testMoveTabSameIndexIsNoOp() {
        let (store, space) = makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let originalOrder = space.tabs.map(\.id)

        store.moveTab(from: 1, to: 1, in: space)

        XCTAssertEqual(space.tabs.map(\.id), originalOrder)
    }

    func testMoveTabOutOfBoundsIsNoOp() {
        let (store, space) = makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)

        store.moveTab(from: 0, to: 5, in: space)

        XCTAssertEqual(space.tabs.count, 1)
        XCTAssertEqual(space.tabs[0].id, tab.id)
    }

    // MARK: - Move Pinned Tab

    func testMovePinnedTabReorders() {
        let (store, space) = makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        for tab in tabs { store.pinTab(id: tab.id, in: space) }

        store.movePinnedTab(from: 0, to: 2, in: space)

        XCTAssertEqual(space.pinnedTabs.map(\.id), [tabs[1].id, tabs[2].id, tabs[0].id])
    }

    // MARK: - Observer Tests

    func testPinTabNotifiesObserver() {
        let (store, space) = makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        let observer = MockTabStoreObserver()
        store.addObserver(observer)

        store.pinTab(id: tab.id, in: space)

        XCTAssertEqual(observer.pinCalls.count, 1)
        XCTAssertEqual(observer.pinCalls[0].fromIndex, 0)
        XCTAssertEqual(observer.pinCalls[0].toIndex, 0)
    }

    func testUnpinTabNotifiesObserver() {
        let (store, space) = makeStore()
        let tab = makeSleepingTab(spaceID: space.id)
        space.tabs.append(tab)
        store.pinTab(id: tab.id, in: space)
        let observer = MockTabStoreObserver()
        store.addObserver(observer)

        store.unpinTab(id: tab.id, in: space)

        XCTAssertEqual(observer.unpinCalls.count, 1)
        XCTAssertEqual(observer.unpinCalls[0].fromIndex, 0)
        XCTAssertEqual(observer.unpinCalls[0].toIndex, 0)
    }

    func testMoveTabNotifiesObserver() {
        let (store, space) = makeStore()
        let tabs = (0..<3).map { _ in makeSleepingTab(spaceID: space.id) }
        space.tabs.append(contentsOf: tabs)
        let observer = MockTabStoreObserver()
        store.addObserver(observer)

        store.moveTab(from: 0, to: 2, in: space)

        XCTAssertEqual(observer.reorderCalls, 1)
    }
}

// MARK: - Mock Observer

private class MockTabStoreObserver: TabStoreObserver {
    var pinCalls: [(fromIndex: Int, toIndex: Int)] = []
    var unpinCalls: [(fromIndex: Int, toIndex: Int)] = []
    var reorderCalls: Int = 0

    func tabStoreDidPinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        pinCalls.append((fromIndex: fromIndex, toIndex: toIndex))
    }

    func tabStoreDidUnpinTab(_ tab: BrowserTab, fromIndex: Int, toIndex: Int, in space: Space) {
        unpinCalls.append((fromIndex: fromIndex, toIndex: toIndex))
    }

    func tabStoreDidReorderTabs(in space: Space) {
        reorderCalls += 1
    }
}
