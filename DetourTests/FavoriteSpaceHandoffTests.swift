import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-58: favourites are per-profile and show in every space that shares the
/// profile, so a live favourite's backing tab can be activated in space A and
/// dragged into space B. The restore paths move the tab as it is, and used to
/// leave `tab.spaceID` naming A — the space `wake()` builds its configuration
/// from, that per-space lookups key on, and that its history visits are recorded
/// under. Once A was reassigned to another profile or deleted, the tab woke with
/// no extension controller and no content scripts.
@MainActor
final class FavoriteSpaceHandoffTests: XCTestCase {

    /// Nothing listens on port 1: a wake navigates nowhere real.
    private let favoriteURL = URL(string: "http://127.0.0.1:1/calendar")!

    private var createdTabs: [BrowserTab] = []
    /// Lent to `TabStore.shared` by the wake test, taken back in tearDown.
    private var sharedSpaceIDs: [UUID] = []
    private var sharedProfiles: [Profile] = []
    private var defaultFaviconFetch: ((URL, @escaping (NSImage?) -> Void) -> Void)!

    override func setUp() {
        super.setUp()
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    override func tearDown() {
        for tab in createdTabs { tab.teardown() }
        createdTabs.removeAll()
        for id in sharedSpaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        sharedSpaceIDs.removeAll()
        for profile in sharedProfiles {
            for favorite in profile.favorites { favorite.tab?.teardown() }
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        sharedProfiles.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Fixture

    /// A private store (its own in-memory database) with one profile and two
    /// spaces on it — a favourite is per-profile, so both spaces have to share
    /// the profile for the move to be possible at all.
    private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let profile: Profile
        let a: Space
        let b: Space
    }

    private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: try DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Handoff")
        let a = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let b = store.addSpace(name: "B", emoji: "🅱️", colorHex: "FF9500", profileID: profile.id)
        return Fixture(db: db, store: store, profile: profile, a: a, b: b)
    }

    /// A favourite with a live backing tab, activated in `space`.
    private func liveFavorite(in store: TabStore, profile: Profile,
                              activatedIn space: Space) throws -> (Favorite, BrowserTab) {
        XCTAssertTrue(store.addFavoriteFromEntry(url: favoriteURL, title: "Calendar", faviconURL: nil,
                                                 favicon: nil, profileID: profile.id, at: 0))
        let favorite = try XCTUnwrap(profile.favorites.first)
        XCTAssertTrue(store.activateFavorite(id: favorite.id, profileID: profile.id, in: space))
        let tab = try XCTUnwrap(favorite.tab)
        createdTabs.append(tab)
        XCTAssertEqual(tab.spaceID, space.id, "precondition: the tab was brought to life in this space")
        return (favorite, tab)
    }

    // MARK: - Rehoming

    func testRestoreFavoriteAsTabRehomesTheBackingTabOntoTheDestinationSpace() throws {
        let f = try makeFixture()
        let (favorite, tab) = try liveFavorite(in: f.store, profile: f.profile, activatedIn: f.a)

        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: favorite.id, profileID: f.profile.id,
                                                   in: f.b, at: 0))

        XCTAssertEqual(tab.spaceID, f.b.id, "the tab belongs to the space it was dropped in")
        XCTAssertTrue(f.b.tabs.contains { $0 === tab })
        XCTAssertTrue(f.profile.favorites.isEmpty)
    }

    func testRestoreFavoriteAsPinnedRehomesTheBackingTabOntoTheDestinationSpace() throws {
        let f = try makeFixture()
        let (favorite, tab) = try liveFavorite(in: f.store, profile: f.profile, activatedIn: f.a)

        XCTAssertTrue(f.store.restoreFavoriteAsPinned(id: favorite.id, profileID: f.profile.id,
                                                      in: f.b, at: 0))

        XCTAssertEqual(tab.spaceID, f.b.id)
        XCTAssertTrue(f.b.pinnedTabs.contains { $0 === tab })
        XCTAssertTrue(f.profile.favorites.isEmpty)
    }

    /// The session row follows the section the tab is in, so the move must not
    /// leave a row under the old space.
    func testSessionSaveRecordsAMovedFavoriteTabUnderTheDestinationSpace() throws {
        let f = try makeFixture()
        let (favorite, tab) = try liveFavorite(in: f.store, profile: f.profile, activatedIn: f.a)
        XCTAssertTrue(f.store.restoreFavoriteAsTab(id: favorite.id, profileID: f.profile.id,
                                                   in: f.b, at: 0))

        f.store.saveNow()

        let session = try XCTUnwrap(f.db.loadSession())
        let inB = session.spaces.first { $0.0.id == f.b.id.uuidString }?.1 ?? []
        let inA = session.spaces.first { $0.0.id == f.a.id.uuidString }?.1 ?? []
        let record = try XCTUnwrap(inB.first { $0.id == tab.id.uuidString },
                                   "the tab is saved under space B")
        XCTAssertEqual(record.spaceID, f.b.id.uuidString)
        XCTAssertFalse(inA.contains { $0.id == tab.id.uuidString }, "and nowhere under space A")
    }

    /// The consequence that made the stale id a bug: the tab's own space has to
    /// still resolve after the space it was activated in is gone, or the wake
    /// falls back to a bare configuration — no data store of the profile, and no
    /// extension controller, so no content scripts.
    func testAMovedFavoriteTabWakesFromItsNewSpaceAfterTheOldOneIsDeleted() throws {
        let store = TabStore.shared
        let profile = store.addProfile(name: "Handoff Wake")
        sharedProfiles.append(profile)
        let a = store.addSpace(name: "Handoff A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let b = store.addSpace(name: "Handoff B", emoji: "🅱️", colorHex: "FF9500", profileID: profile.id)
        sharedSpaceIDs.append(contentsOf: [a.id, b.id])

        let (favorite, tab) = try liveFavorite(in: store, profile: profile, activatedIn: a)
        XCTAssertTrue(store.restoreFavoriteAsTab(id: favorite.id, profileID: profile.id, in: b, at: 0))

        store.deleteSpace(id: a.id)
        XCTAssertNil(store.space(withID: a.id), "precondition: space A is gone")

        tab.sleep(force: true)
        XCTAssertNil(tab.webView)
        tab.wake()

        let webView = try XCTUnwrap(tab.webView, "the tab woke")
        XCTAssertTrue(webView.configuration.websiteDataStore === profile.dataStore,
                      "woken from space B's profile store")
        XCTAssertTrue(webView.configuration.webExtensionController === profile.extensionController,
                      "and with the profile's extension controller, so content scripts inject")
    }

    // MARK: - Space delete

    /// The same stale id without any move: a favourite activated in A is still
    /// shown in B after A is deleted, so its tab has to belong to B by then.
    func testDeletingTheSpaceAFavoriteWasActivatedInRehomesItsTab() throws {
        let f = try makeFixture()
        let (favorite, tab) = try liveFavorite(in: f.store, profile: f.profile, activatedIn: f.a)

        f.store.deleteSpace(id: f.a.id)

        XCTAssertNil(f.store.space(withID: f.a.id))
        XCTAssertTrue(favorite.tab === tab, "the favourite stays live")
        XCTAssertEqual(tab.spaceID, f.b.id, "and its tab moved onto the profile's remaining space")
        XCTAssertNotNil(tab.webView, "nothing of it was torn down")
    }

    /// With no space of the profile left to show the tile, the favourite goes
    /// back to a dormant tile rather than keeping a live web view off-list —
    /// the same outcome as a profile swap (`updateSpace`).
    func testDeletingTheLastSpaceOfAProfileReturnsItsLiveFavoritesToDormant() throws {
        let f = try makeFixture()
        let other = f.store.addProfile(name: "Other")
        _ = f.store.addSpace(name: "Other", emoji: "🅾️", colorHex: "000000", profileID: other.id)
        f.store.deleteSpace(id: f.b.id)
        let (favorite, tab) = try liveFavorite(in: f.store, profile: f.profile, activatedIn: f.a)

        f.store.deleteSpace(id: f.a.id)

        XCTAssertNil(favorite.tab, "returned to a dormant tile")
        XCTAssertNil(tab.webView, "its web view was released")
        XCTAssertTrue(f.profile.favorites.contains { $0.id == favorite.id }, "the favourite itself stays")
    }

    // MARK: - Guards

    /// A favourite only moves into a space of its own profile: rehoming a live
    /// tab onto another profile's space would rebuild it, on its next wake, from
    /// that profile's data store and extension controller.
    func testRestoreFavoriteRefusesASpaceOfAnotherProfile() throws {
        let f = try makeFixture()
        let other = f.store.addProfile(name: "Other")
        let c = f.store.addSpace(name: "C", emoji: "©️", colorHex: "000000", profileID: other.id)
        let (favorite, tab) = try liveFavorite(in: f.store, profile: f.profile, activatedIn: f.a)

        XCTAssertFalse(f.store.restoreFavoriteAsTab(id: favorite.id, profileID: f.profile.id, in: c, at: 0))
        XCTAssertFalse(f.store.restoreFavoriteAsPinned(id: favorite.id, profileID: f.profile.id, in: c, at: 0))

        XCTAssertEqual(tab.spaceID, f.a.id, "nothing moved")
        XCTAssertTrue(favorite.tab === tab)
        XCTAssertTrue(c.tabs.isEmpty)
        XCTAssertTrue(c.pinnedEntries.isEmpty)
    }

    /// A tab with no URL yet cannot be favourited; the refusal comes *before*
    /// the detach, so the tab stays in its list instead of being stranded in no
    /// section (still live, still registered with the extension contexts).
    func testMoveTabToFavoritesRefusesATabWithNoURLBeforeDetaching() throws {
        let f = try makeFixture()
        let tab = f.store.addTab(in: f.a)
        createdTabs.append(tab)
        XCTAssertNil(tab.url, "precondition: a blank new tab")

        XCTAssertFalse(f.store.moveTabToFavorites(id: tab.id, from: f.a, profileID: f.profile.id, at: 0))

        XCTAssertTrue(f.a.tabs.contains { $0 === tab }, "still listed where it was")
        XCTAssertTrue(f.profile.favorites.isEmpty)

        f.store.pinTab(id: tab.id, in: f.a)
        XCTAssertFalse(f.store.moveTabToFavorites(id: tab.id, from: f.a, profileID: f.profile.id, at: 0))
        XCTAssertTrue(f.a.pinnedTabs.contains { $0 === tab }, "a pinned one stays pinned")
        XCTAssertTrue(f.profile.favorites.isEmpty)
    }
}
