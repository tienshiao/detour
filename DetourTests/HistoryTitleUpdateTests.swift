import XCTest
import Combine
import GRDB
import WebKit
@testable import Detour

/// Late title changes correcting a recorded history visit (TASK-88).
///
/// The bug: a visit is recorded the moment loading finishes, but a single-page
/// app rewrites `document.title` after that, so the new URL is stored with the
/// previous page's title — and `historyURL` holds one title per URL, so the
/// stale title renames every visit of that URL.
///
/// `HistoryTitleUpdatePolicy` pins the guard matrix without a web view; the
/// integration tests below drive real `WKWebView`s through a `TabStore` of
/// their own, writing to a private in-memory history database so nothing
/// touches the real one.
@MainActor
final class HistoryTitleUpdateTests: XCTestCase {

    private let pageURL = URL(string: "https://page.invalid/a")!
    private var createdTabs: [BrowserTab] = []

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        super.tearDown()
    }

    // MARK: - The pure policy

    private let recordedAt = Date(timeIntervalSince1970: 1_000_000)

    /// - Parameter webViewURL: defaults to `tabURL` — the document the title
    ///   came from is the page the tab is on, unless a test says otherwise.
    ///   `.some(nil)` is a web view with no URL at all.
    private func urlToRename(title: String = "Real Title",
                             webViewTitle: String? = "Real Title",
                             isLoading: Bool = false,
                             tabURL: URL? = URL(string: "https://page.invalid/a")!,
                             webViewURL: URL?? = nil,
                             lastRecordedHistoryURL: URL? = URL(string: "https://page.invalid/a")!,
                             recordedVisitID: Int64? = 42,
                             recordedAt: Date? = Date(timeIntervalSince1970: 1_000_000),
                             now: Date = Date(timeIntervalSince1970: 1_000_000),
                             hasSpace: Bool = true,
                             isIncognito: Bool = false) -> URL? {
        HistoryTitleUpdatePolicy.correction(
            title: title, webViewTitle: webViewTitle, isLoading: isLoading, tabURL: tabURL,
            webViewURL: webViewURL ?? tabURL, lastRecordedHistoryURL: lastRecordedHistoryURL,
            recordedVisitID: recordedVisitID, recordedAt: recordedAt, now: now,
            hasSpace: hasSpace, isIncognito: isIncognito)?.url
    }

    func testPolicyRenamesTheURLTheTabRecorded() {
        XCTAssertEqual(urlToRename(), pageURL)
    }

    /// The correction names the visit it rewrites (TASK-91). While the insert is
    /// still on the writer queue the tab holds no id, and a correction without
    /// one would have to fall back to "every visit of this URL" — exactly what
    /// the retarget removed.
    func testPolicyCarriesTheRecordedVisitAndRefusesWithoutOne() {
        let correction = HistoryTitleUpdatePolicy.correction(
            title: "Real Title", webViewTitle: "Real Title", isLoading: false, tabURL: pageURL,
            webViewURL: pageURL, lastRecordedHistoryURL: pageURL, recordedVisitID: 42,
            recordedAt: recordedAt, now: recordedAt, hasSpace: true, isIncognito: false)
        XCTAssertEqual(correction, HistoryTitleUpdatePolicy.Correction(visitID: 42, url: pageURL))

        XCTAssertNil(urlToRename(recordedVisitID: nil), "no visit to correct yet")
    }

    /// AC #3: nothing is written while a navigation is in flight — the title in
    /// hand may belong to either side of it.
    func testPolicyRefusesWhileTheTabIsLoading() {
        XCTAssertNil(urlToRename(isLoading: true))
    }

    func testPolicyRefusesAnEmptyTitle() {
        XCTAssertNil(urlToRename(title: "", webViewTitle: ""))
    }

    /// AC #3: `BrowserTab.updateTitle` publishes the scheme-stripped URL while a
    /// navigation is pending, and an internal page's name, and the persisted
    /// title of a session still restoring. None of them is the document's title,
    /// so none of them reaches the history.
    func testPolicyRefusesATitleTheDocumentDoesNotReport() {
        XCTAssertNil(urlToRename(title: "page.invalid/a", webViewTitle: "Real Title"))
        XCTAssertNil(urlToRename(title: "History", webViewTitle: nil))
    }

    /// A sleeping tab has no web view, so it can never write a title.
    func testPolicyRefusesASleepingTab() {
        XCTAssertNil(urlToRename(webViewTitle: nil))
    }

    /// AC #3: the tab has moved on — the new page's title must not rename the
    /// URL the tab recorded before it.
    func testPolicyRefusesOnceTheTabHasMovedOn() {
        XCTAssertNil(urlToRename(tabURL: URL(string: "https://page.invalid/b")!,
                                 lastRecordedHistoryURL: pageURL))
    }

    func testPolicyRefusesAURLTheTabNeverRecorded() {
        XCTAssertNil(urlToRename(lastRecordedHistoryURL: nil))
        XCTAssertNil(urlToRename(tabURL: nil, lastRecordedHistoryURL: nil))
    }

    /// AC #4: the same exclusions the recorder applies.
    func testPolicyRefusesNonWebSchemes() {
        for string in ["detour://history/", "browser-error://load?url=x",
                       "webkit-extension://abc/popup.html", "file:///tmp/page.html"] {
            let url = URL(string: string)!
            XCTAssertNil(urlToRename(tabURL: url, lastRecordedHistoryURL: url), "\(string) is not in the history")
        }
    }

    /// AC #4.
    func testPolicyRefusesIncognitoAndSpacelessTabs() {
        XCTAssertNil(urlToRename(isIncognito: true))
        XCTAssertNil(urlToRename(hasSpace: false))
    }

    /// A failed load leaves `tab.url` on the URL the user asked for while the
    /// web view shows the error page, whose title is the stripped URL. That
    /// title must never rename the row the failed URL already has.
    func testPolicyRefusesWhenTheWebViewIsShowingAnErrorPage() {
        let errorURL = ErrorPage.url(for: pageURL, error: URLError(.cannotFindHost))
        XCTAssertNil(urlToRename(title: "page.invalid/a", webViewTitle: "page.invalid/a",
                                 webViewURL: .some(errorURL)))
    }

    /// The general form of the guard above: the title only renames the URL it
    /// actually came from.
    func testPolicyRefusesWhenTheDocumentIsNotTheTabsURL() {
        XCTAssertNil(urlToRename(webViewURL: .some(nil)), "a web view with no URL reports no document")
        XCTAssertNil(urlToRename(webViewURL: .some(URL(string: "https://page.invalid/b")!)))
    }

    /// The correction is for a page still settling after its navigation, not a
    /// licence to follow an unread counter for the life of the tab.
    func testPolicyRefusesOutsideTheCorrectionWindow() {
        let window = HistoryTitleUpdatePolicy.correctionWindow
        XCTAssertEqual(urlToRename(now: recordedAt.addingTimeInterval(window)), pageURL,
                       "the window's last instant still corrects")
        XCTAssertNil(urlToRename(now: recordedAt.addingTimeInterval(window + 0.001)))
        XCTAssertNil(urlToRename(recordedAt: nil), "a tab that recorded nothing has no window")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: TabStore
        let historyDB: HistoryDatabase
        let space: Space
    }

    /// A store of its own, writing to in-memory databases: the assertions are
    /// about the database the recorder actually writes to, and nothing here may
    /// reach the real history.
    ///
    /// - Parameter debounce: how long the title must hold still. Short by
    ///   default so a test need not wait production's real second; a test that
    ///   has to act *within* the window passes a longer one.
    private func makeFixture(incognito: Bool = false, debounce: TimeInterval = 0.05) throws -> Fixture {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), historyDB: historyDB,
                             historySettleDebounce: debounce)
        let space: Space
        if incognito {
            space = store.addIncognitoSpace()
        } else {
            let profile = store.addProfile(name: "Titles")
            space = store.addSpace(name: "Titles", emoji: "🕘", colorHex: "007AFF", profileID: profile.id)
        }
        return Fixture(store: store, historyDB: historyDB, space: space)
    }

    private func makeTab(in f: Fixture) -> BrowserTab {
        makeTab(in: f.space, of: f.store)
    }

    private func makeTab(in space: Space, of store: TabStore) -> BrowserTab {
        let tab = store.addTab(in: space)
        createdTabs.append(tab)
        return tab
    }

    /// Renames the loaded document, the way a page renames itself.
    private func setTitle(_ title: String, on webView: WKWebView) async throws {
        _ = try await webView.callAsyncJavaScript("document.title = t; return true;",
                                                  arguments: ["t": title], contentWorld: .page)
    }

    private func html(title: String, body: String = "") -> String {
        "<html><head><title>\(title)</title></head><body>\(body)</body></html>"
    }

    /// Spins the main run loop — the debounce is scheduled on it, and so is
    /// everything WebKit reports back.
    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Waits for the id `recordVisit` hands back — the write lands on GRDB's
    /// writer queue and then hops to main, and a correction that arrives before
    /// it does is dropped by the policy (TASK-91).
    private func waitForRecordedVisitID(_ tab: BrowserTab, timeout: TimeInterval = 3,
                                        file: StaticString = #filePath, line: UInt = #line) -> Int64? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let visitID = tab.lastRecordedVisitID { return visitID }
            pump(0.02)
        }
        XCTFail("the recorded visit id never arrived", file: file, line: line)
        return nil
    }

    /// The titles stored on the visit rows of `url`, oldest first — what the
    /// History page shows for each visit (TASK-91).
    private func perVisitTitles(_ db: HistoryDatabase, _ url: URL) throws -> [String?] {
        try db.dbQueue.read { conn in
            try Optional<String>.fetchAll(conn, sql: """
                SELECT v.title FROM historyVisit v
                JOIN historyURL h ON h.id = v.urlID
                WHERE h.url = ? ORDER BY v.visitTime, v.id
                """, arguments: [url.absoluteString])
        }
    }

    private func storedTitle(_ db: HistoryDatabase, _ url: URL) throws -> String? {
        try db.dbQueue.read { conn in
            try String.fetchOne(conn, sql: "SELECT title FROM historyURL WHERE url = ?",
                                arguments: [url.absoluteString])
        }
    }

    private func visitCount(_ db: HistoryDatabase, _ url: URL) throws -> Int {
        try db.dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT visitCount FROM historyURL WHERE url = ?",
                             arguments: [url.absoluteString]) ?? 0
        }
    }

    /// Pumps until the stored title changes from `title`, or the deadline passes.
    private func waitForTitleToLeave(_ title: String?, _ db: HistoryDatabase, _ url: URL,
                                     timeout: TimeInterval = 3) throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pump(0.05)
            let stored = try storedTitle(db, url)
            if stored != title { return stored }
        }
        return try storedTitle(db, url)
    }

    // MARK: - The recorded-then-retitled case

    /// AC #1/#2: the visit is recorded, then the page changes its title — the
    /// stored title follows, and the visit itself is untouched.
    func testALateTitleChangeCorrectsTheRecordedVisit() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Old Title"), baseURL: pageURL)
        pump(0.1)
        XCTAssertEqual(tab.url, pageURL)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Old Title")
        XCTAssertEqual(tab.lastRecordedHistoryURL, pageURL, "the recorder remembers what it wrote")
        XCTAssertNotNil(waitForRecordedVisitID(tab), "and which visit row it wrote")

        try await setTitle("New Title", on: webView)

        XCTAssertEqual(try waitForTitleToLeave("Old Title", f.historyDB, pageURL), "New Title")
        XCTAssertEqual(try visitCount(f.historyDB, pageURL), 1, "a correction adds no visit")
        XCTAssertEqual(try perVisitTitles(f.historyDB, pageURL), ["New Title"],
                       "the visit itself carries the corrected title (TASK-91)")
    }

    /// AC #3/#5: the correction reaches the visit this tab recorded and nothing
    /// else — not an earlier visit of the same URL, and not another profile's.
    func testACorrectionTouchesOnlyTheVisitTheTabRecorded() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        // An older visit of this URL, and one in another space (another
        // profile's History page), both with titles of their own.
        let ownSpaceID = f.space.id.uuidString
        let seededURL = pageURL.absoluteString
        try await f.historyDB.dbQueue.write { conn in
            let urlID = try Int64.fetchOne(conn, sql: """
                INSERT INTO historyURL (url, title, visitCount, lastVisitTime)
                VALUES (?, 'Yesterday', 2, 1000) RETURNING id
                """, arguments: [seededURL])!
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime, title)
                VALUES (?, ?, 1000, 'Yesterday'), (?, 'another-space', 1500, 'Their Title')
                """, arguments: [urlID, ownSpaceID, urlID])
        }

        try await loadHTMLStringAndWait(webView, html: html(title: "Old Title"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertNotNil(waitForRecordedVisitID(tab))

        try await setTitle("New Title", on: webView)
        XCTAssertEqual(try waitForTitleToLeave("Old Title", f.historyDB, pageURL), "New Title")

        XCTAssertEqual(try perVisitTitles(f.historyDB, pageURL),
                       ["Yesterday", "Their Title", "New Title"],
                       "the older visit and the other profile's keep their own titles")
    }

    /// AC #5: the latest known title on the shared `historyURL` row is the
    /// newest visit's. A tab settling its title *after* someone else recorded a
    /// newer visit corrects its own visit and leaves that alone (TASK-91).
    func testACorrectionByAnOlderTabDoesNotOverrideANewerVisitsURLTitle() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Old Title"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        let mine = try XCTUnwrap(waitForRecordedVisitID(tab))

        // Another tab — another profile, even — visits the same URL afterwards.
        let seededURL = pageURL.absoluteString
        let newerVisitTime = Date().timeIntervalSince1970 + 10
        try await f.historyDB.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime, title)
                SELECT id, 'another-space', ?, 'Newer Title' FROM historyURL WHERE url = ?
                """, arguments: [newerVisitTime, seededURL])
            try conn.execute(sql: "UPDATE historyURL SET title = 'Newer Title' WHERE url = ?",
                             arguments: [seededURL])
        }

        try await setTitle("New Title", on: webView)
        try await waitUntil("this tab's own visit to be corrected") {
            self.pump(0.05)
            return try self.perVisitTitles(f.historyDB, self.pageURL).contains("New Title")
        }

        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Newer Title",
                       "the latest known title stays the newer visit's")
        let correctedTitle = try await f.historyDB.dbQueue.read { conn in
            try String.fetchOne(conn, sql: "SELECT title FROM historyVisit WHERE id = ?",
                                arguments: [mine])
        }
        XCTAssertEqual(correctedTitle, "New Title", "this tab corrected its own visit")
    }

    /// AC #6: a page rewriting its title in a burst costs one write, not one per
    /// change — the debounce only fires once the title holds still.
    func testRepeatedTitleChangesAreCoalesced() async throws {
        // A long debounce and a burst the page runs by itself: the whole burst
        // has to fit inside one debounce window for the coalescing to be what is
        // under test, and a round trip per title would leave that to the load on
        // the machine.
        let f = try makeFixture(debounce: 0.5)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "(1) Inbox"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertNotNil(waitForRecordedVisitID(tab))

        _ = try await webView.callAsyncJavaScript("""
            await new Promise(resolve => {
                let n = 1;
                const id = setInterval(() => {
                    n += 1;
                    document.title = `(${n}) Inbox`;
                    if (n === 6) { clearInterval(id); resolve(); }
                }, 20);
            });
            return true;
            """, contentWorld: .page)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "(1) Inbox",
                       "nothing is written while the title keeps moving")

        XCTAssertEqual(try waitForTitleToLeave("(1) Inbox", f.historyDB, pageURL), "(6) Inbox",
                       "the title that settled is the one that is stored")
        XCTAssertEqual(try visitCount(f.historyDB, pageURL), 1)
    }

    /// AC #3: a tab that recorded nothing writes nothing — the title change is
    /// dropped rather than landing on whatever row the URL happens to have.
    func testATitleIsNeverWrittenForAURLTheTabDidNotRecord() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Unrecorded"), baseURL: pageURL)
        pump(0.2)
        // The load's own recording, undone: from here the tab is one that never
        // recorded this URL (a sleeping tab woken onto it, say).
        tab.lastRecordedHistoryURL = nil
        tab.lastRecordedHistoryAt = nil
        tab.lastRecordedVisitID = nil
        let before = try storedTitle(f.historyDB, pageURL)
        try await setTitle("Still Unrecorded", on: webView)
        pump(0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), before,
                       "the stored title is untouched")
        XCTAssertNotEqual(try storedTitle(f.historyDB, pageURL), "Still Unrecorded")
    }

    /// AC #4: an incognito space records nothing, and corrects nothing either.
    /// `lastRecordedHistoryURL` is set by hand here because the recorder would
    /// never set it for an incognito tab — this is the incognito guard itself
    /// under test, not the recorder's.
    func testIncognitoNeverWritesATitle() async throws {
        let f = try makeFixture(incognito: true)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        // A row from some earlier, non-incognito visit of the same URL: the
        // incognito tab must not rename it — nor the visit behind it.
        var publicVisitID: Int64?
        let recorded = expectation(description: "the public visit")
        f.historyDB.recordVisit(url: pageURL.absoluteString, title: "Public Title",
                                faviconURL: nil, spaceID: UUID().uuidString) { id in
            publicVisitID = id
            recorded.fulfill()
        }
        await fulfillment(of: [recorded], timeout: 10)

        try await loadHTMLStringAndWait(webView, html: html(title: "Private Title"), baseURL: pageURL)
        pump(0.1)
        tab.lastRecordedHistoryURL = pageURL
        tab.lastRecordedHistoryAt = Date()
        tab.lastRecordedVisitID = publicVisitID
        try await setTitle("Private Title 2", on: webView)
        pump(0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Public Title")
        XCTAssertEqual(try perVisitTitles(f.historyDB, pageURL), ["Public Title"],
                       "and the public visit keeps its own title")
    }

    /// A title that settles *while* the next navigation is in flight is refused
    /// by the policy and never retried by the debounce — so the recorder picks
    /// it up when the load ends, even on the branch where the 30 s dedup skips
    /// the visit itself (TASK-88).
    func testATitleThatSettledWhileLoadingIsWrittenWhenTheLoadEnds() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Old Title"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Old Title")
        XCTAssertNotNil(waitForRecordedVisitID(tab))

        // A navigation starts, and the page renames itself while it is in
        // flight: the debounce fires into a loading tab and the title is
        // dropped.
        tab.isLoading = true
        try await setTitle("New Title", on: webView)
        pump(0.3)
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "Old Title",
                       "nothing is written while the tab is loading")

        // The load ends on the same URL, inside the dedup window, so no visit is
        // recorded — the correction still has to happen.
        tab.isLoading = false
        pump(0.3)

        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "New Title")
        XCTAssertEqual(try visitCount(f.historyDB, pageURL), 1, "the dedup still skipped the visit")
    }

    // MARK: - The window belongs to the visit (TASK-91)

    /// The 30 s dedup marker is shared by every tab in the space, so a reload —
    /// or another tab's visit to the same URL — can skip the write long after
    /// the visit this tab is holding was made. Restarting the correction window
    /// there would let the page's title *today* be written onto a visit made
    /// this morning.
    func testADedupSkippedRecordingDoesNotReopenAnOldVisitsWindow() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "This Morning"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        let visitID = try XCTUnwrap(waitForRecordedVisitID(tab))
        try await waitUntil("the morning visit to carry its own title") {
            self.pump(0.05)
            return try self.perVisitTitles(f.historyDB, self.pageURL) == ["This Morning"]
        }

        // That visit was made ten minutes ago; the page is called something else
        // now, and the debounced correction is refused — it is past the window.
        let recordedAt = Date(timeIntervalSinceNow: -600)
        tab.lastRecordedHistoryAt = recordedAt
        try await setTitle("This Evening", on: webView)
        pump(0.3)

        // A reload: the visit is inside the 30 s dedup, so nothing is written —
        // and the window must stay where the visit put it.
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(tab.lastRecordedHistoryAt, recordedAt,
                       "the window belongs to the visit, not to the recorder pass")
        XCTAssertEqual(tab.lastRecordedVisitID, visitID,
                       "and it is still the same visit that could be corrected")
        pump(0.3)

        XCTAssertEqual(try perVisitTitles(f.historyDB, pageURL), ["This Morning"],
                       "this morning's visit keeps what the page was called then")
        XCTAssertEqual(try storedTitle(f.historyDB, pageURL), "This Morning")
        XCTAssertEqual(try visitCount(f.historyDB, pageURL), 1)
    }

    /// A tab moved to another space (TASK-63) is writing another profile's
    /// history. When the dedup skips its recording there, the visit it was
    /// holding in the space it left is not its to correct any more.
    func testATabThatMovedToAnotherSpaceStopsCorrectingTheVisitItLeft() async throws {
        let f = try makeFixture()
        let otherProfile = f.store.addProfile(name: "Other")
        let otherSpace = f.store.addSpace(name: "Other", emoji: "🕘", colorHex: "007AFF",
                                          profileID: otherProfile.id)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)

        try await loadHTMLStringAndWait(webView, html: html(title: "Mine"), baseURL: pageURL)
        pump(0.1)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertNotNil(waitForRecordedVisitID(tab))
        try await waitUntil("this tab's visit to carry its title") {
            self.pump(0.05)
            return try self.perVisitTitles(f.historyDB, self.pageURL) == ["Mine"]
        }

        // A tab in the other space has just visited the same URL, so the dedup
        // marker for (url, otherSpace) is fresh.
        let otherTab = makeTab(in: otherSpace, of: f.store)
        otherTab.url = pageURL
        f.store.recordHistoryVisit(tab: otherTab, spaceID: otherSpace.id)
        try await waitUntil("the other space's visit to be recorded") {
            self.pump(0.05)
            return try self.perVisitTitles(f.historyDB, self.pageURL).count == 2
        }
        let titlesBefore = try perVisitTitles(f.historyDB, pageURL)

        // The tab is moved across, and records there: the dedup skips the write.
        tab.spaceID = otherSpace.id
        f.store.recordHistoryVisit(tab: tab, spaceID: otherSpace.id)
        XCTAssertNil(tab.lastRecordedVisitID,
                     "the visit it was holding belongs to the space it left")

        try await setTitle("Renamed After Moving", on: webView)
        pump(0.5)

        XCTAssertEqual(try perVisitTitles(f.historyDB, pageURL), titlesBefore,
                       "neither the visit it left nor the other space's is renamed")
    }

    // MARK: - Failed loads

    /// A failed load leaves `tab.url` on the URL the user asked for while the
    /// web view shows `browser-error://…` (TASK-88): the page never loaded, so
    /// it is not a visit, and the error page's title (the stripped URL) must not
    /// rename the row that URL already has.
    ///
    /// The state is set up the way `BrowserTab.showErrorPage` sets it up rather
    /// than by failing a real load: a tab's web view only gets navigation
    /// callbacks through the window controller that hosts it, so a tab with no
    /// window never reaches `didFailProvisionalNavigation` at all.
    func testAnErrorPageRecordsNoVisitAndDoesNotRenameTheURLItFailedOn() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        let failedURL = URL(string: "https://unreachable.invalid/dead")!
        // The row — and the visit — an earlier, successful visit of that URL
        // left behind.
        var earlierVisitID: Int64?
        let recorded = expectation(description: "the earlier visit")
        f.historyDB.recordVisit(url: failedURL.absoluteString, title: "Real Page",
                                faviconURL: nil, spaceID: f.space.id.uuidString) { id in
            earlierVisitID = id
            recorded.fulfill()
        }
        await fulfillment(of: [recorded], timeout: 10)
        XCTAssertEqual(try storedTitle(f.historyDB, failedURL), "Real Page")

        // What `showErrorPage` leaves behind: the tab on the URL that failed,
        // the web view on the error document.
        tab.url = failedURL
        let errorURL = ErrorPage.url(for: failedURL, error: URLError(.cannotFindHost))
        try await loadAndWait(webView, URLRequest(url: errorURL))
        pump(0.2)
        XCTAssertEqual(webView.url?.scheme, ErrorPage.scheme)
        XCTAssertEqual(tab.url, failedURL, "the tab still reports the URL that failed")

        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try visitCount(f.historyDB, failedURL), 1, "the failed load is not a visit")
        XCTAssertNil(tab.lastRecordedHistoryURL, "and so is not a row a late title may correct")

        // Even a tab that *had* recorded this URL before the failure refuses to
        // write the error document's title onto it.
        tab.lastRecordedHistoryURL = failedURL
        tab.lastRecordedHistoryAt = Date()
        tab.lastRecordedVisitID = earlierVisitID
        f.store.updateHistoryTitle(for: tab)
        pump(0.3)
        XCTAssertEqual(try storedTitle(f.historyDB, failedURL), "Real Page")
        XCTAssertEqual(try perVisitTitles(f.historyDB, failedURL), ["Real Page"])
    }

    // MARK: - The real single-page-app sequence

    private let videoURL = URL(string: "https://spa.invalid/watch")!
    private let homeURL = URL(string: "https://spa.invalid/home")!

    /// Loads a page titled "a video - SPA" at `videoURL` and waits until the
    /// document's own title has reached both the tab and the history row — the
    /// visit is recorded the instant loading finishes, which can be a beat
    /// before WebKit reports the title, and the correction under test is what
    /// settles it.
    private func loadVideoPage(_ f: Fixture, _ tab: BrowserTab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        try await loadHTMLStringAndWait(webView, html: html(title: "a video - SPA"), baseURL: videoURL)
        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertNotNil(waitForRecordedVisitID(tab))
        try await waitUntil("the video page's own title to be stored") {
            pump(0.05)
            return try storedTitle(f.historyDB, videoURL) == "a video - SPA"
        }
    }

    /// A `loadHTMLString` document has no back/forward entry at all (WebKit
    /// leaves `backForwardList.currentItem` nil), so a `pushState` in it cannot
    /// be told from a `replaceState` and the same-document recorder refuses it
    /// by design (TASK-91) — which is also why the tests around it, all built on
    /// `loadHTMLString`, see no visits of their own. Real pushState recording is
    /// covered in `SameDocumentVisitTests`, over a real http document.
    func testAPushStateWithNoBackForwardEntryRecordsNothing() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadVideoPage(f, tab)
        XCTAssertNil(webView.backForwardList.currentItem, "precondition: no entry to compare")

        var loadingTransitions: [Bool] = []
        let loadingWatch = tab.$isLoading.dropFirst().sink { loadingTransitions.append($0) }
        defer { loadingWatch.cancel() }

        _ = try await webView.callAsyncJavaScript("history.pushState({}, '', '/home'); return true;",
                                                  contentWorld: .page)
        pump(0.2)
        XCTAssertEqual(tab.url, homeURL, "the tab is on the pushed URL")
        XCTAssertEqual(loadingTransitions, [], "a pushState starts no load")

        // The site renames itself for the page it navigated *to*.
        try await setTitle("SPA Home", on: webView)
        pump(0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, videoURL), "a video - SPA",
                       "the page the tab left is not renamed by the next page's title")
        XCTAssertNil(try storedTitle(f.historyDB, homeURL),
                     "and with no entry to compare, nothing is recorded for the pushed URL")
    }

    /// AC #1, the bug itself: something *does* record a visit for the pushed URL
    /// while the title still belongs to the previous page — in production a load
    /// that finishes after the in-page navigation. The row is written with the
    /// stale title and then corrected when the site renames itself.
    func testAVisitRecordedDuringAnInPageNavigationIsCorrectedByTheLateTitle() async throws {
        let f = try makeFixture()
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadVideoPage(f, tab)

        _ = try await webView.callAsyncJavaScript("history.pushState({}, '', '/home'); return true;",
                                                  contentWorld: .page)
        pump(0.2)
        XCTAssertEqual(tab.title, "a video - SPA", "the site has not renamed itself yet")

        f.store.recordHistoryVisit(tab: tab, spaceID: f.space.id)
        XCTAssertEqual(try storedTitle(f.historyDB, homeURL), "a video - SPA",
                       "this is the bug: the new URL is recorded with the previous page's title")
        XCTAssertNotNil(waitForRecordedVisitID(tab))

        try await setTitle("SPA Home", on: webView)

        XCTAssertEqual(try waitForTitleToLeave("a video - SPA", f.historyDB, homeURL), "SPA Home",
                       "the late title corrects the row")
        XCTAssertEqual(try visitCount(f.historyDB, homeURL), 1, "and adds no visit")
        XCTAssertEqual(try storedTitle(f.historyDB, videoURL), "a video - SPA",
                       "the video page keeps its own title")
    }

    /// The debounce reads the tab a second *after* the title changed, and an
    /// in-page navigation inside that second (a Back, a `replaceState`) puts the
    /// tab back on a URL the new title does not belong to. The URL is captured
    /// with the title, so the write is dropped instead of renaming the page the
    /// tab returned to (TASK-88).
    func testATitleIsNotWrittenOntoAURLTheTabReturnedToWithinTheDebounce() async throws {
        // Long enough that the retitle-then-Back sequence fits inside one
        // debounce window whatever the machine is doing.
        let debounce: TimeInterval = 1.0
        let f = try makeFixture(debounce: debounce)
        let tab = makeTab(in: f)
        let webView = try XCTUnwrap(tab.webView)
        try await loadVideoPage(f, tab)

        _ = try await webView.callAsyncJavaScript("history.pushState({}, '', '/home'); return true;",
                                                  contentWorld: .page)
        pump(0.1)
        XCTAssertEqual(tab.url, homeURL)

        let retitledAt = Date()
        try await setTitle("SPA Home", on: webView)
        // A `replaceState` rather than `history.back()`: the document here came
        // from `loadHTMLString`, which leaves no back-forward entry to traverse.
        // What the pipeline sees is the same either way — the tab's URL moves
        // back to the one it recorded after the title changed.
        _ = try await webView.callAsyncJavaScript("history.replaceState({}, '', '/watch'); return true;",
                                                  contentWorld: .page)
        try await waitUntil("the tab to be back on the page it recorded") {
            pump(0.05)
            return tab.url == videoURL
        }
        XCTAssertLessThan(Date().timeIntervalSince(retitledAt), debounce,
                          "the Back has to land before the debounce fires, or this tests nothing")

        // Past the debounce: the title that settled belongs to /home, and /home
        // is not where the tab is.
        pump(debounce + 0.5)

        XCTAssertEqual(try storedTitle(f.historyDB, videoURL), "a video - SPA",
                       "the page the tab returned to keeps its own title")
        XCTAssertNil(try storedTitle(f.historyDB, homeURL), "and the unrecorded URL gets no row")
    }
}
