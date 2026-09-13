import XCTest
import GRDB
@testable import Detour

/// The one `BrowserTab` → `TabRecord` mapping every `saveNow` site goes through
/// (TASK-49), and the decision it records about favourite backing tabs.
final class TabRecordFactoryTests: XCTestCase {

    private func makeDatabase() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        return try AppDatabase(dbQueue: dbQueue)
    }

    /// Whether an `Any` holding an `Optional` holds `.none`.
    private func isNil(_ value: Any) -> Bool {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty
    }

    /// An extension page on a pending origin, so the factory's `extensionID`
    /// derivation (via `profile`) has something to resolve.
    private let url = URL(string: "webkit-extension://abcd-1234/page.html?q=1#frag")!
    private let faviconURL = URL(string: "https://example.com/favicon.ico")!
    private let peekURL = URL(string: "https://peek.example.org/article")!
    private let peekFaviconURL = URL(string: "https://peek.example.org/favicon.ico")!

    /// A tab with every persisted property set, so a column the factory forgets
    /// to map shows up as a nil in the record.
    @MainActor
    private func makeFullyPopulatedTab(spaceID: UUID) -> BrowserTab {
        let tab = BrowserTab(
            id: UUID(), title: "Everything", url: url, faviconURL: faviconURL,
            cachedInteractionState: Data([0xDE, 0xAD]), spaceID: spaceID)
        tab.parentID = UUID()
        tab.lastDeselectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        tab.peekURL = peekURL
        tab.peekInteractionState = Data([0xBE, 0xEF])
        tab.peekFaviconURL = peekFaviconURL
        return tab
    }

    // MARK: -

    @MainActor
    func testFactoryPopulatesEveryColumnFromTheTab() throws {
        let spaceID = UUID()
        let tab = makeFullyPopulatedTab(spaceID: spaceID)
        defer { tab.teardown() }
        let splitGroupID = UUID()
        let profile = Profile(name: "Default")
        profile.registerPendingExtensionOrigin(host: "abcd-1234", extensionID: "ext-1")

        let record = TabRecord(
            tab: tab, spaceID: spaceID, sortOrder: 3, profile: profile,
            splitGroupID: splitGroupID, splitFraction: 0.35)

        XCTAssertEqual(record.id, tab.id.uuidString)
        XCTAssertEqual(record.spaceID, spaceID.uuidString)
        XCTAssertEqual(record.url, url.absoluteString)
        XCTAssertEqual(record.title, "Everything")
        XCTAssertEqual(record.faviconURL, faviconURL.absoluteString)
        XCTAssertEqual(record.interactionState, Data([0xDE, 0xAD]))
        XCTAssertEqual(record.sortOrder, 3)
        XCTAssertEqual(record.lastDeselectedAt, 1_700_000_000)
        XCTAssertEqual(record.parentID, tab.parentID?.uuidString)
        XCTAssertEqual(record.peekURL, peekURL.absoluteString)
        XCTAssertEqual(record.peekInteractionState, Data([0xBE, 0xEF]))
        XCTAssertEqual(record.peekFaviconURL, peekFaviconURL.absoluteString)
        XCTAssertEqual(record.splitGroupID, splitGroupID.uuidString)
        XCTAssertEqual(record.splitFraction, 0.35)
        XCTAssertEqual(record.extensionID, "ext-1", "derived from the profile, not passed by the caller")

        // Guard against a column added to TabRecord that no site maps: every
        // field must have come from the tab (or the arguments) above (TASK-49).
        for child in Mirror(reflecting: record).children {
            XCTAssertFalse(isNil(child.value),
                           "TabRecord.\(child.label ?? "?") is not populated by the factory")
        }
    }

    /// The TASK-49 decision: a favourite's backing row is written like any
    /// other, `lastDeselectedAt` and `parentID` included, instead of zeroing
    /// them at the one site that used to hand-copy the literal.
    @MainActor
    func testFavoriteBackingRecordPersistsLastDeselectedAtAndParentID() throws {
        let db = try makeDatabase()
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Default")
        let space = store.addSpace(name: "Main", emoji: "🌐", colorHex: "007AFF", profileID: profile.id)

        let tab = makeFullyPopulatedTab(spaceID: space.id)
        store.addFavorite(from: tab, profileID: profile.id)
        store.saveNow()

        let session = try XCTUnwrap(db.loadSession())
        let tabRecords = try XCTUnwrap(session.spaces.first { $0.0.id == space.id.uuidString }?.1)
        let record = try XCTUnwrap(tabRecords.first { $0.sortOrder == -2 },
                                   "the favourite's backing tab is saved with sortOrder -2")

        XCTAssertEqual(record.id, tab.id.uuidString)
        XCTAssertEqual(record.lastDeselectedAt, 1_700_000_000)
        XCTAssertEqual(record.parentID, tab.parentID?.uuidString)
        // Unchanged by the decision: the columns restore actually reads back.
        XCTAssertEqual(record.url, url.absoluteString)
        XCTAssertEqual(record.peekURL, peekURL.absoluteString)
    }
}
