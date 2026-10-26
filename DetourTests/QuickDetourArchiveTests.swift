import XCTest
import GRDB
import WebKit
@testable import Detour

/// TASK-193.5: closed Quick Detours in the archive — the store's half. A
/// record is a `closedTab` row filed under the profile's Quick Detour scope
/// (`QuickDetour.historySpaceID`), plain for a close by hand or at quit,
/// `archivedAt` for the idle timer; listed on the Archived Tabs page, never by
/// Reopen Closed Tab, taken back by a restore, gone with its profile. Private
/// pages are never archived.
///
/// Private stores on in-memory databases; the pages never load (`.invalid`
/// hosts), their address is set the moment `load` is called.
@MainActor
final class QuickDetourArchiveTests: XCTestCase {

    private var openedTabs: [(store: TabStore, tab: BrowserTab)] = []

    override func tearDown() {
        for (store, tab) in openedTabs { store.closeQuickDetourTab(tab, disposition: .discard) }
        openedTabs.removeAll()
        super.tearDown()
    }

    private final class RecordsObserver: TabStoreObserver {
        var updates = 0
        func tabStoreDidUpdateClosedTabRecords() { updates += 1 }
    }

    private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let profile: Profile
        let space: Space
        let observer: RecordsObserver
        var scope: String { QuickDetour.historySpaceIDString(forProfileID: profile.id) }
    }

    private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Work")
        let space = store.addSpace(name: "Work", emoji: "W", colorHex: "007AFF", profileID: profile.id)
        let observer = RecordsObserver()
        store.addObserver(observer)
        return Fixture(db: db, store: store, profile: profile, space: space, observer: observer)
    }

    private func open(_ url: String, in store: TabStore, profile: Profile, title: String = "Lookup") -> BrowserTab {
        let tab = store.openQuickDetourTab(profile: profile)
        tab.load(URL(string: url)!)
        tab.title = title
        openedTabs.append((store, tab))
        return tab
    }

    private func records(_ db: AppDatabase) -> [ClosedTabSummary] { db.closedTabSummaries() }

    // MARK: - Closing archives

    func testClosingArchivesUnderTheProfilesQuickDetourScope() throws {
        let f = try makeFixture()
        let tab = open("https://lookup.invalid/a", in: f.store, profile: f.profile)
        let before = f.observer.updates

        f.store.closeQuickDetourTab(tab)

        let record = try XCTUnwrap(records(f.db).first)
        XCTAssertEqual(records(f.db).count, 1)
        XCTAssertEqual(record.spaceID, f.scope, "the per-profile scope, which is no space's")
        XCTAssertEqual(record.url, "https://lookup.invalid/a")
        XCTAssertEqual(record.title, "Lookup")
        XCTAssertEqual(record.tabID, tab.id.uuidString)
        XCTAssertNil(record.archivedAt, "closed by hand: a plain close")
        XCTAssertNotNil(record.closedAt)
        XCTAssertGreaterThan(f.observer.updates, before, "the archive page reloads")
        XCTAssertTrue(f.store.quickDetourTabs.isEmpty)
    }

    func testAnAutoCloseIsMarkedArchived() throws {
        let f = try makeFixture()
        let tab = open("https://lookup.invalid/idle", in: f.store, profile: f.profile)

        f.store.closeQuickDetourTab(tab, disposition: .archive(autoClosed: true))

        let record = try XCTUnwrap(records(f.db).first)
        XCTAssertNotNil(record.archivedAt, "auto-closed")
        XCTAssertEqual(record.archivedAt, record.closedAt)
    }

    func testAPrivateQuickDetourIsNeverArchived() throws {
        let f = try makeFixture()
        let privateProfile = f.store.ensureIncognitoProfile()
        let tab = open("https://secret.invalid/", in: f.store, profile: privateProfile)

        XCTAssertFalse(f.store.archiveQuickDetourTab(tab, autoClosed: false))
        f.store.closeQuickDetourTab(tab)
        f.store.closeQuickDetourTab(open("https://secret.invalid/2", in: f.store, profile: privateProfile),
                                    disposition: .archive(autoClosed: true))

        XCTAssertTrue(records(f.db).isEmpty)
    }

    func testAPageWithNoAddressIsNotArchived() throws {
        let f = try makeFixture()
        let tab = f.store.openQuickDetourTab(profile: f.profile)
        openedTabs.append((f.store, tab))
        f.store.closeQuickDetourTab(tab)
        XCTAssertTrue(records(f.db).isEmpty)
    }

    func testDiscardingWritesNothing() throws {
        let f = try makeFixture()
        f.store.closeQuickDetourTab(open("https://lookup.invalid/", in: f.store, profile: f.profile),
                                    disposition: .discard)
        XCTAssertTrue(records(f.db).isEmpty)
    }

    func testTheRecordKeepsTheBackForwardList() async throws {
        let f = try makeFixture()
        let tab = open("about:blank", in: f.store, profile: f.profile)
        try await waitUntil("the blank page loaded") { tab.webView?.isLoading == false }

        f.store.closeQuickDetourTab(tab)

        let id = try XCTUnwrap(records(f.db).first?.id)
        XCTAssertNotNil(f.db.closedTab(id: id)?.interactionState, "captured like a closed tab's")
    }

    // MARK: - Quit

    func testQuittingArchivesEveryOpenNormalQuickDetourOnce() throws {
        let f = try makeFixture()
        let privateProfile = f.store.ensureIncognitoProfile()
        let a = open("https://a.invalid/", in: f.store, profile: f.profile)
        let b = open("https://b.invalid/", in: f.store, profile: f.profile)
        _ = open("https://p.invalid/", in: f.store, profile: privateProfile)

        f.store.archiveOpenQuickDetours()

        XCTAssertEqual(Set(records(f.db).compactMap(\.url)), ["https://a.invalid/", "https://b.invalid/"])
        XCTAssertTrue(records(f.db).allSatisfy { $0.archivedAt == nil }, "archived as closed, not auto-closed")
        XCTAssertEqual(f.store.quickDetourTabs.count, 3, "the windows stay open until the app exits")

        // Windows AppKit closes after that write nothing more.
        f.store.closeQuickDetourTab(a)
        f.store.archiveOpenQuickDetours()
        f.store.closeQuickDetourTab(b, disposition: .archive(autoClosed: true))
        XCTAssertEqual(records(f.db).count, 2)
    }

    // MARK: - Listing

    func testTheArchivePageListsThemLabelled() throws {
        let f = try makeFixture()
        let spaceTab = BrowserTab(id: UUID(), title: "Tab", url: URL(string: "https://tab.invalid/"), faviconURL: nil,
                                  cachedInteractionState: nil, spaceID: f.space.id)
        f.space.tabs.append(spaceTab)
        f.store.closeTab(id: spaceTab.id, in: f.space, undoable: true, registersUndo: false)
        f.store.closeQuickDetourTab(open("https://closed.invalid/", in: f.store, profile: f.profile))
        f.store.closeQuickDetourTab(open("https://idle.invalid/", in: f.store, profile: f.profile),
                                    disposition: .archive(autoClosed: true))

        let entries = f.store.archiveEntries()
        XCTAssertEqual(entries.count, 3)
        let scope = QuickDetour.historySpaceID(forProfileID: f.profile.id)
        let closed = try XCTUnwrap(entries.first { $0.url == "https://closed.invalid/" })
        let idle = try XCTUnwrap(entries.first { $0.url == "https://idle.invalid/" })
        let tab = try XCTUnwrap(entries.first { $0.url == "https://tab.invalid/" })
        XCTAssertEqual(closed.kind, .quickDetour(profileID: f.profile.id, autoClosed: false))
        XCTAssertEqual(idle.kind, .quickDetour(profileID: f.profile.id, autoClosed: true))
        XCTAssertEqual(closed.spaceID, scope)
        XCTAssertTrue(closed.isRestorable)
        XCTAssertEqual(tab.kind, .tab)
        XCTAssertTrue(f.store.hasClosedTabRecords())
    }

    func testAQuickDetourAloneMakesTheArchiveNonEmpty() throws {
        let f = try makeFixture()
        f.store.closeQuickDetourTab(open("https://closed.invalid/", in: f.store, profile: f.profile))
        XCTAssertTrue(f.store.hasClosedTabRecords(), "Clear Archived Tabs… is enabled")
    }

    func testRecordsOfAProfileNoLongerThereAreNotListed() throws {
        let f = try makeFixture()
        f.db.pushClosedTab(ClosedTabRecord(
            id: nil, tabID: UUID().uuidString, spaceID: QuickDetour.historySpaceIDString(forProfileID: UUID()),
            url: "https://gone.invalid/", title: "Gone", faviconURL: nil, interactionState: nil, sortOrder: 0,
            archivedAt: nil, closedAt: 1_900_000_000, extensionID: nil))
        XCTAssertTrue(f.store.archiveEntries().isEmpty)
    }

    func testReopenClosedTabNeverReopensAQuickDetour() throws {
        let f = try makeFixture()
        f.store.closeQuickDetourTab(open("https://closed.invalid/", in: f.store, profile: f.profile))

        XCTAssertFalse(f.store.canReopenClosedTab(in: f.space))
        XCTAssertNil(f.store.reopenClosedTab(in: f.space))
        XCTAssertEqual(records(f.db).count, 1, "left for the archive page")
    }

    func testTheRecordsSurviveASessionSave() throws {
        let f = try makeFixture()
        f.store.closeQuickDetourTab(open("https://closed.invalid/", in: f.store, profile: f.profile))
        f.store.saveNow()
        XCTAssertEqual(records(f.db).count, 1)
        XCTAssertEqual(f.store.archiveEntries().count, 1)
    }

    // MARK: - Restoring

    func testTakingARecordGivesItsPageAndConsumesIt() throws {
        let f = try makeFixture()
        f.store.closeQuickDetourTab(open("https://closed.invalid/x", in: f.store, profile: f.profile, title: "X"))
        let id = try XCTUnwrap(records(f.db).first?.id)
        XCTAssertTrue(f.store.isQuickDetourArchiveRecord(id: id))
        let before = f.observer.updates

        let page = try XCTUnwrap(f.store.takeQuickDetourArchiveRecord(id: id))

        XCTAssertTrue(page.profile === f.profile)
        XCTAssertEqual(page.url, URL(string: "https://closed.invalid/x"))
        XCTAssertEqual(page.title, "X")
        XCTAssertTrue(records(f.db).isEmpty, "consumed, like a restored tab's record")
        XCTAssertGreaterThan(f.observer.updates, before)
        XCTAssertFalse(f.store.isQuickDetourArchiveRecord(id: id))
        XCTAssertNil(f.store.takeQuickDetourArchiveRecord(id: id))
    }

    func testASpacesRecordIsNotAQuickDetour() throws {
        let f = try makeFixture()
        let tab = BrowserTab(id: UUID(), title: "Tab", url: URL(string: "https://tab.invalid/"), faviconURL: nil,
                             cachedInteractionState: nil, spaceID: f.space.id)
        f.space.tabs.append(tab)
        f.store.closeTab(id: tab.id, in: f.space, undoable: true, registersUndo: false)
        let id = try XCTUnwrap(records(f.db).first?.id)

        XCTAssertFalse(f.store.isQuickDetourArchiveRecord(id: id))
        XCTAssertNil(f.store.takeQuickDetourArchiveRecord(id: id))
        XCTAssertEqual(records(f.db).count, 1, "left alone")
    }

    func testARestoredPageOpensOnItsProfileWithItsAddressAndTitle() throws {
        let f = try makeFixture()
        f.store.closeQuickDetourTab(open("https://closed.invalid/r", in: f.store, profile: f.profile, title: "R"))
        let id = try XCTUnwrap(records(f.db).first?.id)
        let page = try XCTUnwrap(f.store.takeQuickDetourArchiveRecord(id: id))

        let tab = f.store.openQuickDetourTab(profile: page.profile, restoring: page)
        openedTabs.append((f.store, tab))

        XCTAssertTrue(tab.quickDetourProfile === f.profile)
        XCTAssertEqual(tab.url, URL(string: "https://closed.invalid/r"))
        XCTAssertEqual(tab.title, "R", "the archived title until the page reports its own")
        XCTAssertNotNil(tab.webView)
        XCTAssertTrue(tab.webView?.configuration.websiteDataStore === f.profile.dataStore)
    }

    // MARK: - Clearing and profile deletion

    func testClearingEveryRecordCoversTheQuickDetourScopes() throws {
        let f = try makeFixture()
        let privateProfile = f.store.ensureIncognitoProfile()
        f.store.closeQuickDetourTab(open("https://closed.invalid/", in: f.store, profile: f.profile))
        let scopes = f.store.quickDetourArchiveScopeIDs
        XCTAssertTrue(scopes.contains(QuickDetour.historySpaceID(forProfileID: f.profile.id)))
        XCTAssertFalse(scopes.contains(QuickDetour.historySpaceID(forProfileID: privateProfile.id)))

        f.store.clearClosedTabRecords(spaceIDs: f.store.nonIncognitoSpaces.map(\.id) + scopes)

        XCTAssertTrue(records(f.db).isEmpty)
    }

    func testDeletingAProfileDeletesItsArchivedQuickDetoursOnly() throws {
        let f = try makeFixture()
        let spare = f.store.addProfile(name: "Spare")
        f.store.closeQuickDetourTab(open("https://kept.invalid/", in: f.store, profile: f.profile))
        f.store.closeQuickDetourTab(open("https://doomed.invalid/", in: f.store, profile: spare))
        let open = open("https://open.invalid/", in: f.store, profile: spare)

        XCTAssertNotNil(f.store.deleteProfile(id: spare.id))

        XCTAssertEqual(records(f.db).map(\.url), ["https://kept.invalid/"],
                       "its archive goes; its open Quick Detour closes without a record")
        XCTAssertNil(open.webView)
    }
}
