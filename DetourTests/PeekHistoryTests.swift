import XCTest
import Combine
import GRDB
import WebKit
@testable import Detour

/// TASK-306: a Peek's pages are recorded in History under its host's space and
/// profile, through `recordHistoryVisit`'s own rules, and stop being recorded
/// by the Peek once it is closed, replaced or expanded into a tab.
///
/// Pages come from a loopback HTTP server: the recorder keeps http(s) only.
nonisolated final class PeekHistoryTests: XCTestCase {

    private var createdTabs: [BrowserTab] = []
    private var servers: [LoopbackHTTPServer] = []

    @MainActor override func tearDown() async throws {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        try await super.tearDown()
    }

    @MainActor private struct Fixture {
        let store: TabStore
        let historyDB: HistoryDatabase
        let space: Space
        let base: URL
        func url(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }
    }

    @MainActor private func makeFixture(incognito: Bool = false) async throws -> Fixture {
        let server = try LoopbackHTTPServer(routes: [
            "/a": "<html><head><title>Page A</title></head><body>A</body></html>",
            "/b": "<html><head><title>Page B</title></head><body>B</body></html>",
            "/c": "<html><head><title>Page C</title></head><body>C</body></html>",
        ])
        let port = try await server.start()
        servers.append(server)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB,
                             historySettleDebounce: 0.1)
        let space: Space
        if incognito {
            space = store.addIncognitoSpace()
        } else {
            let profile = store.addProfile(name: "Peek")
            space = store.addSpace(name: "Peek", emoji: "👀", colorHex: "007AFF", profileID: profile.id)
        }
        return Fixture(store: store, historyDB: historyDB, space: space,
                       base: URL(string: "http://127.0.0.1:\(port)/")!)
    }

    /// A host tab in the space and a live Peek on it, built as
    /// `showPeekOverlay` builds one: from the space's configuration, in no list.
    @MainActor private func makeHostAndPeek(_ f: Fixture) -> (host: BrowserTab, peek: BrowserTab) {
        let host = f.store.addTab(in: f.space)
        createdTabs.append(host)
        let peek = BrowserTab(configuration: f.space.makeWebViewConfiguration())
        host.peekTab = peek
        f.store.recordHistory(ofPeek: peek)
        return (host, peek)
    }

    @MainActor private func titles(_ f: Fixture, in spaceID: UUID) throws -> [String: String] {
        let rows = f.historyDB.visits(spaceIDs: [spaceID.uuidString], limit: 50)
        return Dictionary(rows.map { ($0.url, $0.title) }, uniquingKeysWith: { first, _ in first })
    }

    @MainActor private func allVisitCount(_ f: Fixture) async throws -> Int {
        try await f.historyDB.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM historyVisit") } ?? 0
    }

    @MainActor private func load(_ url: URL, in tab: BrowserTab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        webView.load(URLRequest(url: url))
        try await waitUntil("\(url.path) loaded") { webView.url == url && !webView.isLoading && tab.title != "New Tab" }
    }

    // MARK: - Recording

    @MainActor func testPeekPageIsRecordedUnderTheHostSpaceWithItsTitle() async throws {
        let f = try await makeFixture()
        let (host, peek) = makeHostAndPeek(f)
        XCTAssertNil(peek.spaceID, "precondition: a Peek is in no space")
        XCTAssertEqual(peek.historySpaceID, host.historySpaceID)

        try await load(f.url("/a"), in: peek)

        try await waitUntil("the Peek's visit is recorded") {
            try self.titles(f, in: f.space.id)[f.url("/a").absoluteString] == "Page A"
        }
    }

    @MainActor func testNavigationsInsideThePeekAreRecorded() async throws {
        let f = try await makeFixture()
        let (_, peek) = makeHostAndPeek(f)

        try await load(f.url("/a"), in: peek)
        try await load(f.url("/b"), in: peek)

        try await waitUntil("both pages are recorded") {
            let recorded = try self.titles(f, in: f.space.id)
            return recorded[f.url("/a").absoluteString] == "Page A"
                && recorded[f.url("/b").absoluteString] == "Page B"
        }
    }

    // MARK: - Exclusions

    @MainActor func testAPeekInAPrivateWindowRecordsNothing() async throws {
        let f = try await makeFixture(incognito: true)
        let (_, peek) = makeHostAndPeek(f)

        try await load(f.url("/a"), in: peek)
        try await load(f.url("/b"), in: peek)

        let anything = try await pollUntil(timeout: 1) { try await self.allVisitCount(f) > 0 }
        XCTAssertFalse(anything, "a Private host's Peek leaves no history")
    }

    /// Quick Detours have no Peek today; the rule is still the host's, so a
    /// Private Quick Detour (and a quarantine, which is one) would record
    /// nothing either.
    @MainActor func testAPeekOnAPrivateQuickDetourRecordsNothing() async throws {
        let f = try await makeFixture()
        let privateProfile = try XCTUnwrap(f.store.addIncognitoSpace().profile)
        XCTAssertTrue(privateProfile.isIncognito)
        let host = BrowserTab(configuration: Space.makeWebViewConfiguration(for: privateProfile))
        host.spaceID = nil
        host.quickDetourProfile = privateProfile
        createdTabs.append(host)
        let peek = BrowserTab(configuration: Space.makeWebViewConfiguration(for: privateProfile))
        host.peekTab = peek
        f.store.recordHistory(ofPeek: peek)
        XCTAssertNotNil(peek.historySpaceID, "the Quick Detour's scope")

        try await load(f.url("/a"), in: peek)

        let anything = try await pollUntil(timeout: 1) { try await self.allVisitCount(f) > 0 }
        XCTAssertFalse(anything)
    }

    // MARK: - Teardown and expansion

    @MainActor func testAPeekNoLongerOnItsHostStopsRecording() async throws {
        let f = try await makeFixture()
        let (host, peek) = makeHostAndPeek(f)
        try await load(f.url("/a"), in: peek)
        try await waitUntil("the first page is recorded") {
            try self.titles(f, in: f.space.id)[f.url("/a").absoluteString] != nil
        }

        host.clearPeekState()
        XCTAssertNil(peek.peekHost)
        XCTAssertTrue(peek.historyObservers.isEmpty)
        XCTAssertNil(peek.historySpaceID)

        // Its web view still loads (an expanded Peek's lives on in a tab).
        try await load(f.url("/b"), in: peek)
        let recorded = try await pollUntil(timeout: 1) {
            try self.titles(f, in: f.space.id)[f.url("/b").absoluteString] != nil
        }
        XCTAssertFalse(recorded)
        peek.teardown()
    }

    /// Open in New Tab hands the Peek's web view to a new tab
    /// (`expandPeekToNewTab`): the page is not recorded again, and from then on
    /// only the tab records — the old Peek object, which still observes the
    /// same web view, records nothing.
    @MainActor func testExpandingAPeekRecordsEachVisitOnce() async throws {
        let f = try await makeFixture()
        let (host, peek) = makeHostAndPeek(f)
        try await load(f.url("/a"), in: peek)
        try await waitUntil("the Peek's page is recorded") {
            try self.titles(f, in: f.space.id)[f.url("/a").absoluteString] != nil
        }
        let webView = try XCTUnwrap(peek.webView)

        // The hand-over, in `expandPeekToNewTab`'s order.
        host.clearPeekState()
        let expanded = f.store.addTab(in: f.space, webView: webView, parentID: host.id)
        createdTabs.append(expanded)
        try await Task.sleep(nanoseconds: 300_000_000)
        let aURL = f.url("/a").absoluteString
        let aVisits = try await f.historyDB.dbQueue.read {
            try Int.fetchOne($0, sql: "SELECT visitCount FROM historyURL WHERE url = ?", arguments: [aURL])
        }
        XCTAssertEqual(aVisits, 1, "expanding is not a second visit")

        try await load(f.url("/c"), in: expanded)
        try await waitUntil("the expanded tab records its next page") {
            try self.titles(f, in: f.space.id)[f.url("/c").absoluteString] == "Page C"
        }
        XCTAssertEqual(expanded.lastRecordedHistoryURL, f.url("/c"))
        XCTAssertEqual(peek.lastRecordedHistoryURL, f.url("/a"),
                       "the old Peek object saw the load but recorded nothing")
    }

    @MainActor func testTeardownDropsThePeeksSubscriptionsAndNothingRetainsIt() async throws {
        let f = try await makeFixture()
        let host = f.store.addTab(in: f.space)
        createdTabs.append(host)
        weak var weakPeek: BrowserTab?
        do {
            let peek = BrowserTab(configuration: f.space.makeWebViewConfiguration())
            host.peekTab = peek
            f.store.recordHistory(ofPeek: peek)
            XCTAssertFalse(peek.historyObservers.isEmpty)
            weakPeek = peek
            peek.teardown()
            XCTAssertTrue(peek.historyObservers.isEmpty)
            host.peekTab = nil
        }
        try await waitUntil("the closed Peek is released") { weakPeek == nil }
    }
}
