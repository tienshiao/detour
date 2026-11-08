import XCTest
import WebKit
@testable import Detour

/// TASK-308: Control+W in the Control+Tab switcher closes the highlighted
/// card through the paths Cmd+W takes, in a real window: a lone tab, a split
/// (both tabs), a pinned tab (dormant).
nonisolated final class RecentTabSwitcherCloseTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var createdTabs: [BrowserTab] = []

    @MainActor override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        try await super.tearDown()
    }

    @MainActor private func makeController() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        wc.sidebarSplitView.autosaveName = nil
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    @MainActor private func addTab(_ url: String, to wc: BrowserWindowController, in space: Space) -> BrowserTab {
        let tab = wc.store.addTab(in: space, url: URL(string: url))
        createdTabs.append(tab)
        return tab
    }

    @MainActor private func entry(_ tabs: [BrowserTab]) -> RecentTabSwitcher.Entry {
        RecentTabSwitcher.Entry(tabs: tabs, focusTabID: tabs[0].id)
    }

    @MainActor func testALoneTabCardClosesThatTab() throws {
        let (wc, space) = try makeController()
        let a = addTab("https://a.example.com/", to: wc, in: space)
        let b = addTab("https://b.example.com/", to: wc, in: space)
        wc.selectTab(id: a.id)

        XCTAssertTrue(wc.closeSwitcherEntry(entry([b])))

        XCTAssertEqual(space.tabs.map(\.id), [a.id])
        XCTAssertEqual(wc.selectedTabID, a.id, "closing another card leaves the selection")
    }

    @MainActor func testClosingTheCurrentCardMovesTheSelectionAsCmdWDoes() throws {
        let (wc, space) = try makeController()
        let a = addTab("https://a.example.com/", to: wc, in: space)
        let b = addTab("https://b.example.com/", to: wc, in: space)
        wc.selectTab(id: b.id)

        XCTAssertTrue(wc.closeSwitcherEntry(entry([b])))

        XCTAssertEqual(space.tabs.map(\.id), [a.id])
        XCTAssertEqual(wc.selectedTabID, a.id)
    }

    @MainActor func testASplitCardClosesBothTabs() throws {
        let (wc, space) = try makeController()
        let keep = addTab("https://keep.example.com/", to: wc, in: space)
        let left = addTab("https://left.example.com/", to: wc, in: space)
        let right = addTab("https://right.example.com/", to: wc, in: space)
        wc.store.createSplit(draggedTabID: right.id, targetTabID: left.id, edge: .right, in: space)
        XCTAssertNotNil(wc.store.splitGroup(containing: left.id, in: space))
        wc.selectTab(id: right.id)

        XCTAssertTrue(wc.closeSwitcherEntry(entry([left, right])))

        XCTAssertEqual(space.tabs.map(\.id), [keep.id], "both panes close")
        XCTAssertEqual(wc.selectedTabID, keep.id)
    }

    @MainActor func testAPinnedCardGoesDormant() throws {
        let (wc, space) = try makeController()
        let other = addTab("https://other.example.com/", to: wc, in: space)
        let pinned = addTab("https://pinned.example.com/", to: wc, in: space)
        wc.store.pinTab(id: pinned.id, in: space)
        let pinnedEntry = try XCTUnwrap(space.pinnedEntries.first { $0.tab?.id == pinned.id })
        wc.selectTab(id: other.id)

        XCTAssertTrue(wc.closeSwitcherEntry(entry([pinned])))

        XCTAssertNil(pinnedEntry.tab, "the entry is dormant")
        XCTAssertTrue(space.pinnedEntries.contains { $0.id == pinnedEntry.id }, "and still pinned")
        XCTAssertEqual(wc.selectedTabID, other.id)
    }

    @MainActor func testAStaleCardClosesNothing() throws {
        let (wc, space) = try makeController()
        let a = addTab("https://a.example.com/", to: wc, in: space)
        let gone = BrowserTab(id: UUID(), title: "Gone", url: URL(string: "https://gone.example.com/"),
                              faviconURL: nil, cachedInteractionState: nil, spaceID: space.id)
        createdTabs.append(gone)
        wc.selectTab(id: a.id)

        XCTAssertFalse(wc.closeSwitcherEntry(entry([gone])))
        XCTAssertEqual(space.tabs.map(\.id), [a.id])
    }
}
