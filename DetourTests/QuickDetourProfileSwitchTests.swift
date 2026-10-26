import XCTest
import GRDB
import WebKit
@testable import Detour

/// The profile pill (TASK-193.4): its menu's rules, the switch decision, and
/// the store's replacement of a Quick Detour's page by one on another
/// profile — the old tab out and torn down, the new one in, the observers
/// told of a replacement (never a close), the Private session and the
/// Private downloads following, and the history scope switching with it.
///
/// Every store here is a private `TabStore` on in-memory databases; pages
/// that must really load come from a loopback HTTP server.
@MainActor
final class QuickDetourProfileSwitchTests: XCTestCase {

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

    private func snapshot(_ name: String, id: UUID = UUID(), isPrivate: Bool = false,
                          isDeleted: Bool = false) -> QuickDetourProfileSnapshot {
        QuickDetourProfileSnapshot(id: id, name: name, isPrivate: isPrivate, isDeleted: isDeleted)
    }

    private struct Fixture {
        let store: TabStore
        let historyDB: HistoryDatabase
        let work: Profile
        let home: Profile
        let privateProfile: Profile
        let settings: SiteSettingsStore
        let downloads: DownloadManager
    }

    private func makeFixture() throws -> Fixture {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let historyDB = try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config))
        let appDB = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: appDB, historyDB: historyDB, historySettleDebounce: 0.2)
        let settings = SiteSettingsStore(database: appDB)
        store.siteSettings = settings
        let downloads = DownloadManager(database: appDB)
        downloads.observeIncognitoSpaces(of: store)
        let work = store.addProfile(name: "Work")
        let home = store.addProfile(name: "Home")
        _ = store.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: work.id)
        let privateProfile = store.ensureIncognitoProfile()
        return Fixture(store: store, historyDB: historyDB, work: work, home: home, privateProfile: privateProfile,
                       settings: settings, downloads: downloads)
    }

    private func open(in store: TabStore, profile: Profile) -> BrowserTab {
        let tab = store.openQuickDetourTab(profile: profile)
        openedTabs.append((store, tab))
        return tab
    }

    private func replace(_ tab: BrowserTab, in store: TabStore, with profile: Profile,
                         betweenPages: () -> Void = {}) -> BrowserTab? {
        let new = store.replaceQuickDetourTab(tab, withPageOn: profile, betweenPages: betweenPages)
        if let new { openedTabs.append((store, new)) }
        return new
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

    private final class Recorder: TabStoreObserver {
        var closed: [UUID] = []
        var replaced: [(old: UUID, new: UUID)] = []
        func tabStoreDidCloseQuickDetour(_ tab: BrowserTab) { closed.append(tab.id) }
        func tabStoreDidReplaceQuickDetour(_ old: BrowserTab, with new: BrowserTab) {
            replaced.append((old.id, new.id))
        }
    }

    private func privateOverride(_ settings: SiteSettingsStore) -> Bool? {
        settings.override(.pictureInPicture, forSite: "youtube.com", profileID: TabStore.incognitoProfileID)
    }

    // MARK: - The menu

    func testTheMenuListsTheNormalProfilesInOrderThenPrivateLast() {
        let privateProfile = snapshot("Private", id: TabStore.incognitoProfileID, isPrivate: true)
        let work = snapshot("Work")
        let home = snapshot("Home")

        // The Private profile comes first in the store on a fresh launch.
        let menu = QuickDetour.profileMenu(windowProfileID: work.id, profiles: [privateProfile, work, home])

        XCTAssertEqual(menu.items.map(\.name), ["Work", "Home", "Private"])
        XCTAssertEqual(menu.items.map(\.isPrivate), [false, false, true])
        XCTAssertEqual(menu.separatorIndex, 2, "a separator before Private")
    }

    func testTheWindowsOwnProfileIsChecked() {
        let privateProfile = snapshot("Private", id: TabStore.incognitoProfileID, isPrivate: true)
        let work = snapshot("Work")
        let home = snapshot("Home")

        let onHome = QuickDetour.profileMenu(windowProfileID: home.id, profiles: [work, home, privateProfile])
        XCTAssertEqual(onHome.items.filter(\.isChecked).map(\.profileID), [home.id])

        let onPrivate = QuickDetour.profileMenu(windowProfileID: privateProfile.id,
                                                profiles: [work, home, privateProfile])
        XCTAssertEqual(onPrivate.items.filter(\.isChecked).map(\.profileID), [privateProfile.id])
    }

    func testWithOneProfileTheMenuShowsItAndPrivate() {
        let privateProfile = snapshot("Private", id: TabStore.incognitoProfileID, isPrivate: true)
        let only = snapshot("Default")

        let menu = QuickDetour.profileMenu(windowProfileID: only.id, profiles: [privateProfile, only])

        XCTAssertEqual(menu.items.map(\.name), ["Default", "Private"])
        XCTAssertEqual(menu.items.first?.isChecked, true)
        XCTAssertEqual(menu.separatorIndex, 1)
    }

    func testDeletedProfilesAreLeftOut() {
        let privateProfile = snapshot("Private", id: TabStore.incognitoProfileID, isPrivate: true)
        let work = snapshot("Work")
        let gone = snapshot("Gone", isDeleted: true)

        let menu = QuickDetour.profileMenu(windowProfileID: work.id, profiles: [work, gone, privateProfile])

        XCTAssertEqual(menu.items.map(\.name), ["Work", "Private"])
    }

    func testWithoutAPrivateProfileThereIsNoSeparator() {
        let work = snapshot("Work")
        let home = snapshot("Home")

        let menu = QuickDetour.profileMenu(windowProfileID: work.id, profiles: [work, home])

        XCTAssertEqual(menu.items.map(\.name), ["Work", "Home"])
        XCTAssertNil(menu.separatorIndex)
    }

    // MARK: - The decision

    func testTheSameProfileStays() {
        let work = snapshot("Work")
        XCTAssertEqual(QuickDetour.profileSwitchDecision(from: work, to: work, privateDownloadsInFlight: 0), .stay)
    }

    func testAGoneOrDeletedTargetStays() {
        let work = snapshot("Work")
        XCTAssertEqual(QuickDetour.profileSwitchDecision(from: work, to: nil, privateDownloadsInFlight: 0), .stay)
        XCTAssertEqual(QuickDetour.profileSwitchDecision(from: work, to: snapshot("Gone", isDeleted: true),
                                                         privateDownloadsInFlight: 0), .stay)
    }

    func testAnotherNormalProfileOrPrivateSwitchesAtOnce() {
        let work = snapshot("Work")
        let privateProfile = snapshot("Private", id: TabStore.incognitoProfileID, isPrivate: true)
        XCTAssertEqual(QuickDetour.profileSwitchDecision(from: work, to: snapshot("Home"), privateDownloadsInFlight: 0),
                       .switchProfile)
        XCTAssertEqual(QuickDetour.profileSwitchDecision(from: work, to: privateProfile, privateDownloadsInFlight: 0),
                       .switchProfile, "into Private: nothing of a normal page's is cancelled")
    }

    func testLeavingPrivateWithNoDownloadRunningSwitchesAtOnce() {
        let privateProfile = snapshot("Private", id: TabStore.incognitoProfileID, isPrivate: true)
        XCTAssertEqual(QuickDetour.profileSwitchDecision(from: privateProfile, to: snapshot("Work"),
                                                         privateDownloadsInFlight: 0), .switchProfile)
    }

    func testLeavingPrivateWithDownloadsRunningAsksFirst() {
        let privateProfile = snapshot("Private", id: TabStore.incognitoProfileID, isPrivate: true)
        let work = snapshot("Work")

        guard case .confirm(let one) = QuickDetour.profileSwitchDecision(from: privateProfile, to: work,
                                                                         privateDownloadsInFlight: 1) else {
            return XCTFail("one Private download running must be asked about")
        }
        XCTAssertEqual(one.messageText, "Switch to Work?")
        XCTAssertEqual(one.informativeText, "1 download is in progress. Leaving Private browsing cancels it.")
        XCTAssertEqual(one.closeButtonTitle, "Switch Profile")
        XCTAssertEqual(one.keepButtonTitle, "Continue Downloading")

        guard case .confirm(let two) = QuickDetour.profileSwitchDecision(from: privateProfile, to: work,
                                                                         privateDownloadsInFlight: 2) else {
            return XCTFail("two Private downloads running must be asked about")
        }
        XCTAssertEqual(two.informativeText, "2 downloads are in progress. Leaving Private browsing cancels them.")
    }

    func testANormalPageNeverAsksAboutDownloads() {
        // A normal page's downloads are listed in every normal window and
        // outlive it; a count passed for one means nothing.
        XCTAssertEqual(QuickDetour.profileSwitchDecision(from: snapshot("Work"), to: snapshot("Home"),
                                                         privateDownloadsInFlight: 3), .switchProfile)
    }

    // MARK: - The store's replacement

    func testReplacingOpensANewTabOnTheOtherProfileAndTearsTheOldOneDown() throws {
        let f = try makeFixture()
        let old = open(in: f.store, profile: f.work)

        let new = try XCTUnwrap(replace(old, in: f.store, with: f.home))

        XCTAssertFalse(new === old)
        XCTAssertNotEqual(new.id, old.id)
        XCTAssertTrue(new.quickDetourProfile === f.home)
        XCTAssertTrue(new.webView?.configuration.websiteDataStore === f.home.dataStore, "the other profile's cookies")
        XCTAssertNil(new.spaceID)
        XCTAssertTrue(f.store.isQuickDetourTab(new))
        XCTAssertFalse(f.store.isQuickDetourTab(old))
        XCTAssertEqual(f.store.quickDetourTabs.map(\.id), [new.id])
        XCTAssertNil(old.webView, "the old page is torn down (its release: QuickDetourProfileSwitchWindowTests)")
    }

    func testReplacingUsesTheGivenID() throws {
        let f = try makeFixture()
        let old = open(in: f.store, profile: f.work)
        let id = UUID()

        let new = try XCTUnwrap(f.store.replaceQuickDetourTab(old, withPageOn: f.home, id: id))
        openedTabs.append((f.store, new))

        XCTAssertEqual(new.id, id)
        XCTAssertTrue(f.store.quickDetourTab(withID: id) === new)
    }

    func testTheHookRunsBetweenTheOldPageLeavingAndTheNewOneEntering() throws {
        let f = try makeFixture()
        let old = open(in: f.store, profile: f.work)
        var listedDuringHook: [UUID]?
        var oldTornDownDuringHook: Bool?

        let new = try XCTUnwrap(replace(old, in: f.store, with: f.home) {
            listedDuringHook = f.store.quickDetourTabs.map(\.id)
            oldTornDownDuringHook = old.webView == nil
        })

        XCTAssertEqual(listedDuringHook, [], "neither page is listed while the window changes profile")
        XCTAssertEqual(oldTornDownDuringHook, true, "the old page's close is already reported")
        XCTAssertEqual(f.store.quickDetourTabs.map(\.id), [new.id])
    }

    func testObserversHearAReplacementNotAClose() throws {
        let f = try makeFixture()
        let recorder = Recorder()
        f.store.addObserver(recorder)
        defer { f.store.removeObserver(recorder) }
        let old = open(in: f.store, profile: f.work)

        let new = try XCTUnwrap(replace(old, in: f.store, with: f.home))

        XCTAssertTrue(recorder.closed.isEmpty, "a close would take the window down")
        XCTAssertEqual(recorder.replaced.map(\.old), [old.id])
        XCTAssertEqual(recorder.replaced.map(\.new), [new.id])
    }

    func testTheSameProfileADeletedOneOrAStrangersTabIsRefused() throws {
        let f = try makeFixture()
        let tab = open(in: f.store, profile: f.work)
        var hookRan = false

        XCTAssertNil(replace(tab, in: f.store, with: f.work) { hookRan = true }, "the same profile")
        let gone = f.store.addProfile(name: "Gone")
        gone.isDeleted = true
        XCTAssertNil(replace(tab, in: f.store, with: gone) { hookRan = true }, "a deleted profile")
        let stranger = BrowserTab(id: UUID(), configuration: Space.makeWebViewConfiguration(for: f.work))
        XCTAssertNil(replace(stranger, in: f.store, with: f.home) { hookRan = true }, "not a Quick Detour's")
        stranger.teardown()

        XCTAssertFalse(hookRan)
        XCTAssertEqual(f.store.quickDetourTabs.map(\.id), [tab.id])
        XCTAssertNotNil(tab.webView, "left as it was")
    }

    func testDeletingTheNewProfileClosesTheReplacedPage() throws {
        let f = try makeFixture()
        let recorder = Recorder()
        f.store.addObserver(recorder)
        defer { f.store.removeObserver(recorder) }
        let old = open(in: f.store, profile: f.work)
        let new = try XCTUnwrap(replace(old, in: f.store, with: f.home))

        XCTAssertNotNil(f.store.deleteProfile(id: f.home.id))

        XCTAssertTrue(f.store.quickDetourTabs.isEmpty)
        XCTAssertNil(new.webView)
        XCTAssertEqual(recorder.closed, [new.id], "its window closes, as for a page opened on it")
    }

    // MARK: - Private

    func testSwitchingIntoPrivateUsesThePrivateStoreAndKeepsTheSessionLive() throws {
        let f = try makeFixture()
        let old = open(in: f.store, profile: f.work)
        XCTAssertFalse(f.store.hasLivePrivateSession)

        let new = try XCTUnwrap(replace(old, in: f.store, with: f.privateProfile))

        XCTAssertTrue(new.webView?.configuration.websiteDataStore === f.privateProfile.dataStore)
        XCTAssertTrue(f.store.hasLivePrivateSession, "now a Private page")
        XCTAssertEqual(f.store.liveIncognitoDownloadScopeIDs, [new.id], "its downloads are its own")
    }

    func testLeavingPrivateEndsTheSessionWhenItWasTheLastPrivatePage() throws {
        let f = try makeFixture()
        let old = open(in: f.store, profile: f.privateProfile)
        f.settings.set(.pictureInPicture, site: "youtube.com", to: false, profileID: TabStore.incognitoProfileID)

        _ = try XCTUnwrap(replace(old, in: f.store, with: f.work))

        XCTAssertFalse(f.store.hasLivePrivateSession)
        XCTAssertNil(privateOverride(f.settings), "the Private session's settings go with its last page")
    }

    func testLeavingPrivateKeepsTheSessionForAPrivateWindow() throws {
        let f = try makeFixture()
        let space = f.store.addIncognitoSpace()
        let old = open(in: f.store, profile: f.privateProfile)
        f.settings.set(.pictureInPicture, site: "youtube.com", to: false, profileID: TabStore.incognitoProfileID)

        _ = try XCTUnwrap(replace(old, in: f.store, with: f.work))

        XCTAssertTrue(f.store.hasLivePrivateSession)
        XCTAssertEqual(privateOverride(f.settings), false, "a Private window is still open")
        f.store.removeIncognitoSpace(id: space.id)
    }

    func testLeavingPrivateDropsItsDownloads() throws {
        let f = try makeFixture()
        let old = open(in: f.store, profile: f.privateProfile)
        let scope = DownloadScope.incognito(spaceID: old.id)
        let item = f.downloads.addManualItem(filename: "secret.zip", sourceURL: URL(string: "https://example.com/s.zip"),
                                             scope: scope)
        f.downloads.downloadDidEnd(item)

        _ = try XCTUnwrap(replace(old, in: f.store, with: f.work))

        XCTAssertTrue(f.downloads.items(in: scope).isEmpty, "gone with the Private page")
    }

    // MARK: - History

    private func visits(_ db: HistoryDatabase, in scope: [String]) -> [HistoryVisitEntry] {
        db.visits(spaceIDs: scope, limit: 50)
    }

    func testVisitsAfterTheSwitchGoToTheNewProfilesScope() async throws {
        let f = try makeFixture()
        let base = try await serve(["/": Self.page, "/after": "<html><head><title>After</title></head></html>"])
        let old = open(in: f.store, profile: f.work)
        let workScope = QuickDetour.historySpaceIDString(forProfileID: f.work.id)
        let homeScope = QuickDetour.historySpaceIDString(forProfileID: f.home.id)
        old.load(base, typed: true)
        try await waitUntil("the first visit") {
            self.pump(0.05)
            return self.visits(f.historyDB, in: [workScope]).first?.title == "Lookup"
        }

        let new = try XCTUnwrap(replace(old, in: f.store, with: f.home))
        XCTAssertEqual(new.historySpaceID?.uuidString, homeScope)
        new.load(base.appendingPathComponent("after"))
        try await waitUntil("the visit after the switch") {
            self.pump(0.05)
            return self.visits(f.historyDB, in: [homeScope]).first?.title == "After"
        }

        XCTAssertEqual(visits(f.historyDB, in: [workScope]).map(\.url), [base.absoluteString],
                       "the visits before stay under the old profile's scope")
        XCTAssertEqual(visits(f.historyDB, in: [homeScope]).map(\.url),
                       [base.appendingPathComponent("after").absoluteString])
    }

    func testSwitchingToPrivateRecordsNothing() async throws {
        let f = try makeFixture()
        let base = try await serve(["/": Self.page])
        let old = open(in: f.store, profile: f.work)

        let new = try XCTUnwrap(replace(old, in: f.store, with: f.privateProfile))
        new.load(base)
        try await waitUntil("the page to load") {
            self.pump(0.05)
            return new.title == "Lookup" && !new.isLoading
        }
        pump(0.5)

        let everything = try await f.historyDB.dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM historyVisit") }
        XCTAssertEqual(everything, 0)
    }
}
