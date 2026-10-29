import XCTest
import WebKit
@testable import Detour

/// A tab opened for a link whose response is a download (TASK-205), against a
/// loopback server whose `/file` is an attachment: the download starts, the
/// empty tab closes, and a routed open puts the window back.
@MainActor
final class DownloadOpenedTabTests: XCTestCase {

    private var store: TabStore { .shared }
    private var server: SlowDownloadServer!
    private var directory: URL!
    private var previousDownloadsDirectory: URL!
    private var appDelegate: AppDelegate!
    private var windowsBefore: Set<ObjectIdentifier> = []
    private var itemsBefore: Set<ObjectIdentifier> = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private static var retainedProfiles: [Profile] = []

    override func setUp() async throws {
        try await super.setUp()
        appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        windowsBefore = Set(browserWindows().map(ObjectIdentifier.init))
        itemsBefore = Set(DownloadManager.shared.items.map(ObjectIdentifier.init))
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadOpenedTabTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Before anything can download: never write into the user's Downloads.
        previousDownloadsDirectory = DownloadManager.shared.downloadsDirectory
        DownloadManager.shared.downloadsDirectory = directory
        server = try SlowDownloadServer()
        try await server.start()
    }

    override func tearDown() async throws {
        for item in newDownloads() {
            if item.state == .downloading { DownloadManager.shared.cancelDownload(item) }
            DownloadManager.shared.removeDownload(item)
        }
        for wc in browserWindows() where !windowsBefore.contains(ObjectIdentifier(wc)) {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        for id in createdSpaceIDs {
            if let space = store.space(withID: id) {
                for tab in space.tabs { tab.teardown() }
            }
            store.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for profile in createdProfiles {
            store.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        store.undoManager.removeAllActions()
        server.stop()
        server = nil
        DownloadManager.shared.downloadsDirectory = previousDownloadsDirectory
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func browserWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { $0.window?.isVisible == true }
    }

    private func newDownloads() -> [DownloadItem] {
        DownloadManager.shared.items.filter { !itemsBefore.contains(ObjectIdentifier($0)) }
    }

    private func makeSpace(_ name: String) -> Space {
        let profile = createdProfiles.first ?? {
            let profile = store.addProfile(name: "TASK-205 \(UUID().uuidString.prefix(4))")
            createdProfiles.append(profile)
            return profile
        }()
        let space = store.addSpace(name: name, emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func makeWindow(showing space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    /// A tab showing a page of the fixture server.
    private func pageTab(in space: Space) async throws -> BrowserTab {
        let tab = store.addTab(in: space, url: server.url("/page"))
        try await waitUntil("the page to commit") { tab.webView?.backForwardList.currentItem != nil }
        return tab
    }

    private func waitForTheDownload() async throws -> DownloadItem {
        try await waitUntil("the attachment to become a download") { !self.newDownloads().isEmpty }
        let item = try XCTUnwrap(newDownloads().first)
        XCTAssertEqual(item.state, .downloading)
        return item
    }

    // MARK: - Tabs

    /// The Cmd+click shape, in a space no window shows: the web view's
    /// delegate is the tab's own. Before TASK-205 no download started at all
    /// and the tab stayed with its URL as its title.
    func testABackgroundTabOpenedOnADownloadDownloadsAndCloses() async throws {
        let space = makeSpace("Background")
        let opener = try await pageTab(in: space)

        let tab = store.addTab(in: space, url: server.url("/file"), parentID: opener.id)
        _ = try await waitForTheDownload()

        try await waitUntil("the empty tab to close") { !space.tabs.contains { $0 === tab } }
        XCTAssertTrue(space.tabs.contains { $0 === opener })
        XCTAssertFalse(store.canReopenClosedTab(in: space), "nothing to reopen: the tab never showed a page")
    }

    /// A tab selected in a window (a `target=_blank` link, or a Cmd+click
    /// tab once shown): the download goes on and the opener is selected again.
    func testASelectedTabOpenedOnADownloadClosesAndTheOpenerIsSelectedAgain() async throws {
        let space = makeSpace("Selected")
        let wc = makeWindow(showing: space)
        let opener = try await pageTab(in: space)
        wc.selectTab(id: opener.id)

        let tab = store.addTab(in: space, url: server.url("/file"), parentID: opener.id)
        wc.selectTab(id: tab.id)
        let item = try await waitForTheDownload()

        try await waitUntil("the empty tab to close") { !space.tabs.contains { $0 === tab } }
        XCTAssertEqual(wc.selectedTabID, opener.id)
        XCTAssertEqual(item.state, .downloading, "the download outlives the tab")
    }

    /// The selection leaves the closed tab by the close order — its opener —
    /// not by the removal observer's plain neighbour.
    func testAClosedDownloadTabSelectsItsOpenerOverItsNeighbour() async throws {
        let space = makeSpace("Opener")
        let wc = makeWindow(showing: space)
        // A new tab without an opener goes to the top: the neighbour first.
        let neighbour = try await pageTab(in: space)
        let opener = try await pageTab(in: space)
        wc.selectTab(id: opener.id)

        let tab = store.addTab(in: space, url: server.url("/file"), parentID: opener.id)
        XCTAssertEqual(space.tabs.map(\.id), [opener.id, tab.id, neighbour.id],
                       "precondition: the child opens next to its opener, before the neighbour")
        wc.selectTab(id: tab.id)
        _ = try await waitForTheDownload()

        try await waitUntil("the empty tab to close") { !space.tabs.contains { $0 === tab } }
        XCTAssertEqual(wc.selectedTabID, opener.id)
    }

    /// A tab that already shows a page stays on it when a link in it downloads.
    func testATabShowingAPageStaysWhenItsLinkDownloads() async throws {
        let space = makeSpace("Page")
        let wc = makeWindow(showing: space)
        let tab = try await pageTab(in: space)
        wc.selectTab(id: tab.id)

        tab.load(server.url("/file"))
        _ = try await waitForTheDownload()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(space.tabs.contains { $0 === tab })
        XCTAssertEqual(wc.selectedTabID, tab.id)
    }

    /// A tab restored or put to sleep stands for a page the user kept: woken
    /// onto a download, it stays, whatever its web view's back-forward list
    /// holds after the wake.
    func testASleptTabWokenOntoADownloadStays() async throws {
        let space = makeSpace("Slept")
        let opener = try await pageTab(in: space)
        let tab = try await pageTab(in: space)
        tab.sleep(force: true)
        XCTAssertTrue(tab.isSleeping)
        XCTAssertTrue(tab.standsForSavedPage)

        tab.load(server.url("/file"))
        _ = try await waitForTheDownload()
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(space.tabs.contains { $0 === tab })
        XCTAssertTrue(space.tabs.contains { $0 === opener })
    }

    // MARK: - Routed links

    /// A route sends the clicked link to another space, which the clicked
    /// window switches to: once the link turns out to be a download, the tab
    /// closes and the window is back on the space it was clicked in.
    func testARoutedLinkThatDownloadsSwitchesTheWindowBack() async throws {
        let clickedIn = makeSpace("Clicked")
        let routedTo = makeSpace("Routed")
        let wc = makeWindow(showing: clickedIn)
        let opener = try await pageTab(in: clickedIn)
        wc.selectTab(id: opener.id)
        wc.window?.makeKeyAndOrderFront(nil)

        appDelegate.openLink(server.url("/file"), routedTo: .openInSpace(routedTo.id), from: clickedIn, sourceWindow: wc)
        XCTAssertEqual(wc.activeSpaceID, routedTo.id, "the placement switched the clicked window")
        let routed = try XCTUnwrap(routedTo.tabs.last)
        XCTAssertNotNil(routed.routedOpen)
        _ = try await waitForTheDownload()

        try await waitUntil("the routed tab to close and the window to switch back") {
            !routedTo.tabs.contains { $0 === routed } && wc.activeSpaceID == clickedIn.id
        }
        XCTAssertEqual(wc.selectedTabID, opener.id)
    }
}
