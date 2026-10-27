import XCTest
import GRDB
import WebKit
@testable import Detour

/// Quick Detour's model (TASK-193.1): the rules in `QuickDetour`, and the
/// store's `quickDetourTabs` — a page in a tab of no space, built from its
/// profile's configuration.
///
/// Every store here is a private `TabStore` on in-memory databases; pages that
/// must really load come from a loopback HTTP server, as in
/// `SameDocumentVisitTests` (only http(s) is recorded).
@MainActor
final class QuickDetourTests: XCTestCase {

    private var openedTabs: [(store: TabStore, tab: BrowserTab)] = []
    private var servers: [LoopbackHTTPServer] = []

    override func tearDown() {
        for (store, tab) in openedTabs { store.closeQuickDetourTab(tab) }
        openedTabs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct Fixture {
        let store: TabStore
        let appDB: AppDatabase
        let historyDB: HistoryDatabase
        let profile: Profile
        let space: Space
    }

    private func makeFixture(debounce: TimeInterval = 0.2) throws -> Fixture {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let appDB = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: appDB, historyDB: historyDB, historySettleDebounce: debounce)
        let profile = store.addProfile(name: "Work")
        let space = store.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: profile.id)
        return Fixture(store: store, appDB: appDB, historyDB: historyDB, profile: profile, space: space)
    }

    private func open(in store: TabStore, profile: Profile) -> BrowserTab {
        let tab = store.openQuickDetourTab(profile: profile)
        openedTabs.append((store, tab))
        return tab
    }

    private func serve(_ routes: [String: String]) async throws -> URL {
        let server = try LoopbackHTTPServer(routes: routes)
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static let page = "<html><head><title>Lookup</title></head><body>looked up</body></html>"

    // MARK: - The history scope

    func testTheHistoryScopeIsDeterministicPerProfileAndNotTheProfilesOwnID() {
        let a = UUID()
        let b = UUID()
        XCTAssertEqual(QuickDetour.historySpaceID(forProfileID: a), QuickDetour.historySpaceID(forProfileID: a),
                       "derived, not minted: a relaunch must find the same scope")
        XCTAssertNotEqual(QuickDetour.historySpaceID(forProfileID: a), QuickDetour.historySpaceID(forProfileID: b))
        XCTAssertNotEqual(QuickDetour.historySpaceID(forProfileID: a), a)
        XCTAssertEqual(QuickDetour.historySpaceIDString(forProfileID: a),
                       QuickDetour.historySpaceID(forProfileID: a).uuidString)
    }

    func testTheHistoryScopeIsRecognisedOnlyForItsProfile() {
        let a = UUID()
        let b = UUID()
        let scope = QuickDetour.historySpaceIDString(forProfileID: a)
        XCTAssertTrue(QuickDetour.isHistorySpaceID(scope, ofProfileID: a))
        XCTAssertTrue(QuickDetour.isHistorySpaceID(scope.lowercased(), ofProfileID: a))
        XCTAssertFalse(QuickDetour.isHistorySpaceID(scope, ofProfileID: b))
        XCTAssertFalse(QuickDetour.isHistorySpaceID(a.uuidString, ofProfileID: a), "the profile's id is no scope")
        XCTAssertFalse(QuickDetour.isHistorySpaceID("not a uuid", ofProfileID: a))
    }

    // MARK: - Cmd+click

    /// A Cmd+click opens another window (in a quarantine, another quarantine
    /// with a store of its own) only from the user: a link activation the
    /// page's own script makes never opens windows (code review, TASK-194
    /// follow-up), as Link Routes treat a click without a gesture.
    func testOnlyTheUsersCmdClickOpensAWindow() {
        XCTAssertTrue(QuickDetour.linkClickOpensWindow(isLinkActivation: true, modifiers: .command, isUserGesture: true))
        XCTAssertTrue(QuickDetour.linkClickOpensWindow(isLinkActivation: true, modifiers: [.command, .shift],
                                                       isUserGesture: true))
        XCTAssertFalse(QuickDetour.linkClickOpensWindow(isLinkActivation: true, modifiers: .command, isUserGesture: false),
                       "a page's scripted click")
        XCTAssertFalse(QuickDetour.linkClickOpensWindow(isLinkActivation: true, modifiers: [], isUserGesture: true))
        XCTAssertFalse(QuickDetour.linkClickOpensWindow(isLinkActivation: false, modifiers: .command, isUserGesture: true),
                       "a script navigation")
    }

    // MARK: - Which profile a new window uses

    func testANewWindowUsesTheFrontmostWindowsProfile() {
        let first = Profile(name: "Default")
        let work = Profile(name: "Work")
        XCTAssertTrue(QuickDetour.profileForNewWindow(frontmostSpaceProfile: work, profiles: [first, work]) === work)
    }

    func testANewWindowFromAPrivateWindowIsPrivate() {
        let first = Profile(name: "Default")
        let privateProfile = Profile(id: TabStore.incognitoProfileID, name: "Private", isIncognito: true)
        XCTAssertTrue(QuickDetour.profileForNewWindow(frontmostSpaceProfile: privateProfile,
                                                      profiles: [privateProfile, first]) === privateProfile)
    }

    func testWithNoFrontmostWindowTheFirstNormalProfileIsUsed() {
        let privateProfile = Profile(id: TabStore.incognitoProfileID, name: "Private", isIncognito: true)
        let first = Profile(name: "Default")
        let work = Profile(name: "Work")
        XCTAssertTrue(QuickDetour.profileForNewWindow(frontmostSpaceProfile: nil,
                                                      profiles: [privateProfile, first, work]) === first,
                      "never the Private profile by default: it is listed first on a fresh launch")
        XCTAssertNil(QuickDetour.profileForNewWindow(frontmostSpaceProfile: nil, profiles: [privateProfile]))
    }

    func testADeletedFrontmostProfileFallsBack() {
        let first = Profile(name: "Default")
        let gone = Profile(name: "Gone")
        gone.isDeleted = true
        XCTAssertTrue(QuickDetour.profileForNewWindow(frontmostSpaceProfile: gone, profiles: [gone, first]) === first)
    }

    // MARK: - The tab in no space

    func testOpeningPlacesTheTabInNoSpace() throws {
        let f = try makeFixture()
        let tab = open(in: f.store, profile: f.profile)

        XCTAssertEqual(f.store.quickDetourTabs.map(\.id), [tab.id])
        XCTAssertTrue(f.store.isQuickDetourTab(tab))
        XCTAssertTrue(f.store.quickDetourTab(withID: tab.id) === tab)
        XCTAssertNil(tab.spaceID)
        XCTAssertTrue(tab.quickDetourProfile === f.profile)
        XCTAssertFalse(f.store.spaces.contains { $0.tabs.contains { $0 === tab } || $0.pinnedTabs.contains { $0 === tab } })
        XCTAssertEqual(tab.historySpaceID, QuickDetour.historySpaceID(forProfileID: f.profile.id))
        XCTAssertTrue(tab.owningProfile === f.profile)
    }

    func testTheTabIsBuiltFromItsProfilesDataStoreAndController() throws {
        let f = try makeFixture()
        let tab = open(in: f.store, profile: f.profile)
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertTrue(webView.configuration.websiteDataStore === f.profile.dataStore,
                      "the profile's cookies and logins")
        XCTAssertTrue(webView.configuration.webExtensionController === f.profile.extensionController,
                      "content scripts and the extension button work in the window")
    }

    func testAdoptingAWebViewKeepsIt() throws {
        let f = try makeFixture()
        let config = f.space.makeWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        let tab = f.store.openQuickDetourTab(profile: f.profile, adopting: webView)
        openedTabs.append((f.store, tab))
        XCTAssertTrue(tab.webView === webView, "a window the page opened keeps its opener")
        XCTAssertTrue(f.store.isQuickDetourTab(tab))
    }

    func testClosingReleasesTheWebViewAndIsIdempotent() throws {
        let f = try makeFixture()
        let tab = open(in: f.store, profile: f.profile)
        XCTAssertNotNil(tab.webView)

        f.store.closeQuickDetourTab(tab)
        XCTAssertNil(tab.webView, "the web view is released")
        XCTAssertTrue(f.store.quickDetourTabs.isEmpty)
        XCTAssertFalse(f.store.isQuickDetourTab(tab))

        f.store.closeQuickDetourTab(tab)
        XCTAssertTrue(f.store.quickDetourTabs.isEmpty)
    }

    private final class CloseSpy: TabStoreObserver {
        var closed: [UUID] = []
        func tabStoreDidCloseQuickDetour(_ tab: BrowserTab) { closed.append(tab.id) }
    }

    func testClosingTellsTheObserversOnce() throws {
        let f = try makeFixture()
        let spy = CloseSpy()
        f.store.addObserver(spy)
        let tab = open(in: f.store, profile: f.profile)

        f.store.closeQuickDetourTab(tab)
        f.store.closeQuickDetourTab(tab)

        XCTAssertEqual(spy.closed, [tab.id])
    }

    func testSeveralQuickDetoursAreIndependent() throws {
        let f = try makeFixture()
        let first = open(in: f.store, profile: f.profile)
        let second = open(in: f.store, profile: f.profile)
        XCTAssertEqual(f.store.quickDetourTabs.map(\.id), [first.id, second.id])
        XCTAssertFalse(first.webView === second.webView)

        f.store.closeQuickDetourTab(first)
        XCTAssertEqual(f.store.quickDetourTabs.map(\.id), [second.id])
        XCTAssertNotNil(second.webView)
    }

    /// What each lookup that walks the spaces does with a tab that is in none.
    func testTheSpaceWalkingLookups() throws {
        let f = try makeFixture()
        let tab = open(in: f.store, profile: f.profile)
        let webView = try XCTUnwrap(tab.webView)

        XCTAssertTrue(f.store.tab(hosting: webView) === tab,
                      "the tab whose web view this is, wherever it lives (internal-page sender check, opener)")
        XCTAssertNil(f.store.tab(hosting: webView, in: f.space), "but in no space")
        XCTAssertNil(f.store.tab(hostingPeek: tab), "not a Peek")
        XCTAssertFalse(f.store.isPinned(tab))
        XCTAssertNil(f.store.favorite(backedBy: tab))
        XCTAssertTrue(f.store.allLiveTabs.contains { $0 === tab }, "its media holds the GPU recycler back")
    }

    func testNeverSleptOrArchived() throws {
        let f = try makeFixture()
        let tab = open(in: f.store, profile: f.profile)
        tab.lastDeselectedAt = Date(timeIntervalSince1970: 0)
        let muchLater = Date().addingTimeInterval(400 * 24 * 3600)

        f.store.sleepStaleTabs(now: muchLater)
        f.store.archiveStaleTabs(now: muchLater)

        XCTAssertNotNil(tab.webView, "it lives as long as its window")
        XCTAssertFalse(tab.isSleeping)
        XCTAssertTrue(f.store.isQuickDetourTab(tab))
    }

    func testNeverSavedWithTheSession() throws {
        let f = try makeFixture()
        let tab = open(in: f.store, profile: f.profile)
        _ = f.store.addTab(in: f.space, url: URL(string: "https://kept.example/"))

        let snapshot = f.store.makeSessionSnapshot()
        let savedTabIDs = snapshot.spaces.flatMap { $0.1.map(\.id) }
        XCTAssertEqual(savedTabIDs.count, 1, "the space's tab and nothing else")
        XCTAssertFalse(savedTabIDs.contains(tab.id.uuidString), "not restored at launch")
    }

    func testDeletingAProfileClosesItsQuickDetours() throws {
        let f = try makeFixture()
        let spare = f.store.addProfile(name: "Spare")
        let spy = CloseSpy()
        f.store.addObserver(spy)
        let kept = open(in: f.store, profile: f.profile)
        let doomed = open(in: f.store, profile: spare)

        XCTAssertNotNil(f.store.deleteProfile(id: spare.id))

        XCTAssertEqual(f.store.quickDetourTabs.map(\.id), [kept.id])
        XCTAssertNil(doomed.webView, "nothing may hold the deleted profile's store")
        XCTAssertEqual(spy.closed, [doomed.id], "its window closes")
    }

    // MARK: - History

    private func visits(_ db: HistoryDatabase, in scope: [String]) -> [HistoryVisitEntry] {
        db.visits(spaceIDs: scope, limit: 50)
    }

    func testAVisitIsRecordedUnderTheProfilesQuickDetourScope() async throws {
        let f = try makeFixture()
        let base = try await serve(["/": Self.page])
        let tab = open(in: f.store, profile: f.profile)
        let scope = QuickDetour.historySpaceIDString(forProfileID: f.profile.id)

        tab.load(base, typed: true)
        try await waitUntil("the visit to be recorded with the page's title") {
            self.pump(0.05)
            return self.visits(f.historyDB, in: [scope]).first?.title == "Lookup"
        }

        let recorded = visits(f.historyDB, in: [scope])
        XCTAssertEqual(recorded.map(\.url), [base.absoluteString])
        XCTAssertEqual(recorded.first?.spaceID, scope)
        XCTAssertTrue(visits(f.historyDB, in: [f.space.id.uuidString]).isEmpty, "no space's history is touched")
    }

    func testAPrivateQuickDetourRecordsNothing() async throws {
        let f = try makeFixture()
        let base = try await serve(["/": Self.page])
        let privateProfile = f.store.ensureIncognitoProfile()
        let tab = open(in: f.store, profile: privateProfile)
        XCTAssertTrue(tab.webView?.configuration.websiteDataStore === privateProfile.dataStore,
                      "the Private profile's throwaway store")

        tab.load(base, typed: true)
        try await waitUntil("the page to load") {
            self.pump(0.05)
            return tab.title == "Lookup" && !tab.isLoading
        }
        pump(0.5)

        let everything = try await f.historyDB.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM historyVisit") }
        XCTAssertEqual(everything, 0)
    }

    func testTheProfilesHistoryScopeIncludesItsQuickDetourVisits() throws {
        let f = try makeFixture()
        let scope = try XCTUnwrap(HistoryPageBridge.scope(forProfile: f.profile, in: f.store))
        XCTAssertTrue(scope.contains(f.space.id.uuidString))
        XCTAssertTrue(scope.contains(QuickDetour.historySpaceIDString(forProfileID: f.profile.id)),
                      "the History page and chrome.history.search find them like any visit")

        let other = f.store.addProfile(name: "Other")
        let otherScope = try XCTUnwrap(HistoryPageBridge.scope(forProfile: other, in: f.store))
        XCTAssertFalse(otherScope.contains(QuickDetour.historySpaceIDString(forProfileID: f.profile.id)),
                       "another profile never reads them")
        XCTAssertNil(HistoryPageBridge.scope(forProfile: f.store.ensureIncognitoProfile(), in: f.store))
    }

    func testTheLaunchSweepKeepsQuickDetourVisits() throws {
        let f = try makeFixture()
        let scope = QuickDetour.historySpaceIDString(forProfileID: f.profile.id)
        let goneProfileScope = QuickDetour.historySpaceIDString(forProfileID: UUID())
        let expectation = expectation(description: "recorded")
        expectation.expectedFulfillmentCount = 3
        for spaceID in [f.space.id.uuidString, scope, goneProfileScope] {
            f.historyDB.recordVisit(url: "https://\(spaceID.prefix(4)).example/", title: "Page", faviconURL: nil,
                                    spaceID: spaceID, typed: false) { _ in expectation.fulfill() }
        }
        wait(for: [expectation], timeout: 5)

        f.store.sweepHistoryOfDeletedSpaces()

        XCTAssertEqual(visits(f.historyDB, in: [scope]).count, 1, "a live profile's Quick Detour visits stay")
        XCTAssertEqual(visits(f.historyDB, in: [f.space.id.uuidString]).count, 1)
        XCTAssertTrue(visits(f.historyDB, in: [goneProfileScope]).isEmpty,
                      "a deleted profile's go with it, like its spaces'")
    }

    func testTheHistoryPageLabelsQuickDetourVisits() {
        let profileID = UUID()
        let quick = HistoryVisitEntry(visitID: 1, url: "https://a.example/", title: "A", faviconURL: nil,
                                      visitTime: 1, spaceID: QuickDetour.historySpaceIDString(forProfileID: profileID))
        let spaced = HistoryVisitEntry(visitID: 2, url: "https://b.example/", title: "B", faviconURL: nil,
                                       visitTime: 2, spaceID: UUID().uuidString)

        XCTAssertEqual(HistoryPageBridge.payload(for: quick, profileID: profileID)["quickDetour"] as? Bool, true)
        XCTAssertNil(HistoryPageBridge.payload(for: spaced, profileID: profileID)["quickDetour"])
        XCTAssertNil(HistoryPageBridge.payload(for: quick, profileID: UUID())["quickDetour"],
                     "only the page's own profile's scope is labelled")
    }

    func testListedAndSearchedVisitsCarryTheirScope() throws {
        let f = try makeFixture()
        let scope = QuickDetour.historySpaceIDString(forProfileID: f.profile.id)
        let expectation = expectation(description: "recorded")
        f.historyDB.recordVisit(url: "https://lookup.example/", title: "Lookup", faviconURL: nil,
                                spaceID: scope, typed: false) { _ in expectation.fulfill() }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(f.historyDB.visits(spaceIDs: [scope], limit: 5).first?.spaceID, scope)
        XCTAssertEqual(f.historyDB.searchVisits(query: "lookup", spaceIDs: [scope], limit: 5).first?.spaceID, scope)
    }

    // MARK: - The Private session

    private func privateSessionFixture() throws -> (store: TabStore, settings: SiteSettingsStore, privateProfile: Profile) {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let settings = SiteSettingsStore(database: db)
        let store = TabStore(appDB: db)
        store.siteSettings = settings
        let privateProfile = store.ensureIncognitoProfile()
        settings.set(.pictureInPicture, site: "youtube.com", to: false, profileID: TabStore.incognitoProfileID)
        return (store, settings, privateProfile)
    }

    private func privateOverride(_ settings: SiteSettingsStore) -> Bool? {
        settings.override(.pictureInPicture, forSite: "youtube.com", profileID: TabStore.incognitoProfileID)
    }

    func testClosingTheLastPrivateWindowKeepsTheSessionForAPrivateQuickDetour() throws {
        let (store, settings, privateProfile) = try privateSessionFixture()
        let space = store.addIncognitoSpace()
        let quick = open(in: store, profile: privateProfile)
        let storeInUse = try XCTUnwrap(quick.webView?.configuration.websiteDataStore)

        store.removeIncognitoSpace(id: space.id)

        XCTAssertTrue(store.hasLivePrivateSession)
        XCTAssertEqual(privateOverride(settings), false, "the Private Quick Detour is still open")
        XCTAssertNotNil(quick.webView)
        XCTAssertTrue(privateProfile.dataStore === storeInUse, "the store it uses is not torn down")

        store.closeQuickDetourTab(quick)
        XCTAssertFalse(store.hasLivePrivateSession)
        XCTAssertNil(privateOverride(settings), "the last Private page closed")
    }

    func testClosingThePrivateQuickDetourKeepsTheSessionForAPrivateWindow() throws {
        let (store, settings, privateProfile) = try privateSessionFixture()
        let space = store.addIncognitoSpace()
        let quick = open(in: store, profile: privateProfile)

        store.closeQuickDetourTab(quick)
        XCTAssertTrue(store.hasLivePrivateSession)
        XCTAssertEqual(privateOverride(settings), false, "the Private window is still open")

        store.removeIncognitoSpace(id: space.id)
        XCTAssertNil(privateOverride(settings))
    }

    func testANormalQuickDetourDoesNotKeepThePrivateSession() throws {
        let (store, settings, _) = try privateSessionFixture()
        let normal = store.addProfile(name: "Default")
        let space = store.addIncognitoSpace()
        _ = open(in: store, profile: normal)

        store.removeIncognitoSpace(id: space.id)

        XCTAssertFalse(store.hasLivePrivateSession)
        XCTAssertNil(privateOverride(settings))
    }

    // MARK: - Downloads

    func testAPrivateQuickDetoursDownloadsLiveAsLongAsItsWindow() throws {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let manager = DownloadManager(database: db)
        manager.observeIncognitoSpaces(of: store)
        let privateProfile = store.ensureIncognitoProfile()
        let quick = open(in: store, profile: privateProfile)
        XCTAssertEqual(store.liveIncognitoDownloadScopeIDs, [quick.id])
        let scope = DownloadScope.incognito(spaceID: quick.id)
        let item = manager.addManualItem(filename: "secret.zip", sourceURL: URL(string: "https://example.com/s.zip"),
                                         scope: scope)
        manager.downloadDidEnd(item)

        // Any space change reconciles the Private downloads against what is open.
        let space = store.addIncognitoSpace()
        store.removeIncognitoSpace(id: space.id)
        XCTAssertEqual(manager.items(in: scope).map(\.id), [item.id], "its window is still open")

        store.closeQuickDetourTab(quick)
        XCTAssertTrue(manager.items(in: scope).isEmpty, "gone with its window")
        XCTAssertTrue(db.loadDownloads().isEmpty, "never saved")
    }
}
