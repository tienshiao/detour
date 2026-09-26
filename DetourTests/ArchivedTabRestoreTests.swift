import XCTest
import GRDB
@testable import Detour

/// TASK-119: the Archived Tabs page's data layer — the listing across spaces,
/// restoring a record into its own space, delete and clear, and the
/// `tabStoreDidUpdateClosedTabRecords` notification.
final class ArchivedTabRestoreTests: XCTestCase {

    private final class RecordsObserver: TabStoreObserver {
        var updates = 0
        func tabStoreDidUpdateClosedTabRecords() { updates += 1 }
    }

    private struct Fixture {
        let db: AppDatabase
        let store: TabStore
        let profile: Profile
        let spaceA: Space
        let spaceB: Space
        let observer: RecordsObserver
    }

    private func makeFixture() throws -> Fixture {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let store = TabStore(appDB: db)
        let profile = store.addProfile(name: "Archive")
        let spaceA = store.addSpace(name: "A", emoji: "🅰️", colorHex: "007AFF", profileID: profile.id)
        let spaceB = store.addSpace(name: "B", emoji: "🅱️", colorHex: "FF3B30", profileID: profile.id)
        store.undoManager.removeAllActions()
        store.undoManager.groupsByEvent = false
        let observer = RecordsObserver()
        store.addObserver(observer)
        return Fixture(db: db, store: store, profile: profile, spaceA: spaceA, spaceB: spaceB, observer: observer)
    }

    private func inUndoGroup(_ store: TabStore, _ body: () -> Void) {
        store.undoManager.beginUndoGrouping()
        body()
        store.undoManager.endUndoGrouping()
    }

    private func makeTab(_ url: String, in space: Space) -> BrowserTab {
        BrowserTab(id: UUID(), title: url, url: URL(string: url), faviconURL: nil,
                   cachedInteractionState: nil, spaceID: space.id)
    }

    /// Writes a record straight to the table, as a close in an earlier session would have.
    @discardableResult
    private func pushRecord(_ db: AppDatabase, spaceID: UUID, url: String, sortOrder: Int = 0,
                            closedAt: Double? = 1_800_000_000, archivedAt: Double? = nil,
                            extensionID: String? = nil) -> Int64 {
        db.pushClosedTab(ClosedTabRecord(
            id: nil, tabID: UUID().uuidString, spaceID: spaceID.uuidString, url: url, title: url,
            faviconURL: nil, interactionState: nil, sortOrder: sortOrder, archivedAt: archivedAt,
            closedAt: closedAt, extensionID: extensionID))
        return db.closedTabSummaries().first { $0.url == url }!.id
    }

    private func installExtension(_ id: String, in db: AppDatabase) {
        db.saveExtension(ExtensionRecord(
            id: id, name: id, version: "1.0", manifestJSON: Data("{}".utf8),
            basePath: "/nonexistent/\(id)", isEnabled: true, installedAt: 0))
    }

    // MARK: - Listing

    func testListingSpansSpacesNewestFirst() throws {
        let f = try makeFixture()
        let a = makeTab("https://a.example/", in: f.spaceA)
        let b = makeTab("https://b.example/", in: f.spaceB)
        f.spaceA.tabs.append(a)
        f.spaceB.tabs.append(b)
        inUndoGroup(f.store) { f.store.closeTab(id: a.id, in: f.spaceA) }
        inUndoGroup(f.store) { f.store.closeTab(id: b.id, in: f.spaceB, archivedAt: Date()) }

        let entries = f.store.archiveEntries()
        XCTAssertEqual(entries.map(\.url), ["https://b.example/", "https://a.example/"])
        XCTAssertEqual(entries.map(\.spaceID), [f.spaceB.id, f.spaceA.id])
        XCTAssertTrue(entries.allSatisfy(\.isRestorable))
        XCTAssertNotNil(entries.first?.closedAt)
    }

    func testListingExcludesIncognitoAndOrphanedRecords() throws {
        let f = try makeFixture()
        let incognito = f.store.addIncognitoSpace()
        pushRecord(f.db, spaceID: f.spaceA.id, url: "https://kept.example/")
        pushRecord(f.db, spaceID: incognito.id, url: "https://private.example/")
        pushRecord(f.db, spaceID: UUID(), url: "https://orphan.example/")

        XCTAssertEqual(f.store.archiveEntries().map(\.url), ["https://kept.example/"])
        XCTAssertTrue(f.store.hasClosedTabRecords())
        XCTAssertNil(f.store.restoreClosedTab(recordID: f.db.closedTabSummaries()
            .first { $0.url == "https://orphan.example/" }!.id), "an orphan's space is gone")
    }

    func testHasClosedTabRecordsIsFalseWithOnlyOrphans() throws {
        let f = try makeFixture()
        XCTAssertFalse(f.store.hasClosedTabRecords())
        pushRecord(f.db, spaceID: UUID(), url: "https://orphan.example/")
        XCTAssertFalse(f.store.hasClosedTabRecords())
    }

    // MARK: - Restore

    func testRestoreIntoItsOwnNonActiveSpaceAtItsIndex() throws {
        let f = try makeFixture()
        let tabs = ["https://0.example/", "https://1.example/", "https://2.example/"].map { makeTab($0, in: f.spaceB) }
        f.spaceB.tabs.append(contentsOf: tabs)
        inUndoGroup(f.store) { f.store.closeTab(id: tabs[1].id, in: f.spaceB) }
        let recordID = try XCTUnwrap(f.store.archiveEntries().first).id

        let restored = try XCTUnwrap(f.store.restoreClosedTab(recordID: recordID))

        XCTAssertEqual(restored.spaceID, f.spaceB.id)
        XCTAssertEqual(f.spaceB.tabs.map(\.url?.absoluteString),
                       ["https://0.example/", "https://1.example/", "https://2.example/"])
        XCTAssertTrue(f.spaceA.tabs.isEmpty)
        XCTAssertTrue(f.store.archiveEntries().isEmpty, "the record is deleted")
        XCTAssertNil(f.db.closedTab(id: recordID))
        XCTAssertNil(f.store.restoreClosedTab(recordID: recordID), "a second restore finds nothing")
    }

    func testRestoreClampsAndSnapsOutOfASplitGroup() throws {
        let f = try makeFixture()
        let tabs = ["https://x.example/", "https://left.example/", "https://right.example/"].map { makeTab($0, in: f.spaceA) }
        let group = UUID()
        tabs[1].splitGroupID = group
        tabs[2].splitGroupID = group
        f.spaceA.tabs.append(contentsOf: tabs)

        let inside = pushRecord(f.db, spaceID: f.spaceA.id, url: "https://inside.example/", sortOrder: 2)
        let beyond = pushRecord(f.db, spaceID: f.spaceA.id, url: "https://beyond.example/", sortOrder: 99)

        f.store.restoreClosedTab(recordID: inside)
        XCTAssertEqual(f.spaceA.tabs.map(\.url?.absoluteString),
                       ["https://x.example/", "https://left.example/", "https://right.example/",
                        "https://inside.example/"], "index 2 splits the pair, so it snaps past it")
        f.store.restoreClosedTab(recordID: beyond)
        XCTAssertEqual(f.spaceA.tabs.last?.url?.absoluteString, "https://beyond.example/", "clamped to the end")
    }

    func testArchivedRecordIsRestorableUnlikeReopen() throws {
        let f = try makeFixture()
        let tab = makeTab("https://archived.example/", in: f.spaceA)
        f.spaceA.tabs.append(tab)
        inUndoGroup(f.store) { f.store.closeTab(id: tab.id, in: f.spaceA, archivedAt: Date()) }

        XCTAssertNil(f.store.reopenClosedTab(in: f.spaceA), "Cmd+Shift+T skips archived records")
        let entry = try XCTUnwrap(f.store.archiveEntries().first)
        XCTAssertTrue(entry.isRestorable)
        XCTAssertEqual(f.store.restoreClosedTab(recordID: entry.id)?.url?.absoluteString, "https://archived.example/")
        XCTAssertTrue(f.store.archiveEntries().isEmpty)
    }

    // MARK: - Extension pages

    func testDisabledExtensionPageIsListedButNotRestorable() throws {
        let f = try makeFixture()
        installExtension("ext", in: f.db)
        f.db.setProfileExtensionEnabled(extensionID: "ext", profileID: f.profile.id.uuidString, enabled: false)
        let url = "webkit-extension://abcd/options.html"
        let recordID = pushRecord(f.db, spaceID: f.spaceA.id, url: url, extensionID: "ext")

        let entry = try XCTUnwrap(f.store.archiveEntries().first)
        XCTAssertEqual(entry.id, recordID)
        XCTAssertFalse(entry.isRestorable)

        let updatesBefore = f.observer.updates
        XCTAssertNil(f.store.restoreClosedTab(recordID: recordID))
        XCTAssertTrue(f.spaceA.tabs.isEmpty)
        XCTAssertNotNil(f.db.closedTab(id: recordID), "kept for when the extension is enabled again")
        XCTAssertEqual(f.observer.updates, updatesBefore, "nothing changed")
    }

    func testUninstalledExtensionPageIsPurgedFromTheListing() throws {
        let f = try makeFixture()
        let gone = pushRecord(f.db, spaceID: f.spaceA.id, url: "webkit-extension://abcd/options.html",
                              extensionID: "uninstalled")
        pushRecord(f.db, spaceID: f.spaceA.id, url: "https://web.example/")

        let updatesBefore = f.observer.updates
        XCTAssertEqual(f.store.archiveEntries().map(\.url), ["https://web.example/"])
        XCTAssertNil(f.db.closedTab(id: gone), "deleted: it can never load again")
        XCTAssertEqual(f.observer.updates, updatesBefore, "a silent purge: no reload loop")
    }

    func testRestoringAnUninstalledExtensionPageDeletesItsRecord() throws {
        let f = try makeFixture()
        let gone = pushRecord(f.db, spaceID: f.spaceA.id, url: "webkit-extension://abcd/options.html",
                              extensionID: "uninstalled")
        let updatesBefore = f.observer.updates
        XCTAssertNil(f.store.restoreClosedTab(recordID: gone))
        XCTAssertNil(f.db.closedTab(id: gone))
        XCTAssertEqual(f.observer.updates, updatesBefore + 1)
    }

    // MARK: - Delete and clear

    func testDeleteRecord() throws {
        let f = try makeFixture()
        let keep = pushRecord(f.db, spaceID: f.spaceA.id, url: "https://keep.example/")
        let drop = pushRecord(f.db, spaceID: f.spaceA.id, url: "https://drop.example/")
        f.store.deleteClosedTabRecord(id: drop)
        XCTAssertEqual(f.store.archiveEntries().map(\.id), [keep])
    }

    func testClearPerSpaceAndAll() throws {
        let f = try makeFixture()
        pushRecord(f.db, spaceID: f.spaceA.id, url: "https://a1.example/")
        pushRecord(f.db, spaceID: f.spaceA.id, url: "https://a2.example/")
        pushRecord(f.db, spaceID: f.spaceB.id, url: "https://b1.example/")

        f.store.clearClosedTabRecords(spaceIDs: [f.spaceA.id])
        XCTAssertEqual(f.store.archiveEntries().map(\.url), ["https://b1.example/"])

        pushRecord(f.db, spaceID: f.spaceA.id, url: "https://a3.example/")
        f.store.clearClosedTabRecords(spaceIDs: [f.spaceA.id, f.spaceB.id])
        XCTAssertTrue(f.store.archiveEntries().isEmpty)
        XCTAssertFalse(f.store.hasClosedTabRecords())
    }

    // MARK: - Notifications

    func testRecordsNotificationFiresOnEveryMutation() throws {
        let f = try makeFixture()
        var expected = f.observer.updates
        func expectUpdate(_ what: String, line: UInt = #line) {
            expected += 1
            XCTAssertEqual(f.observer.updates, expected, what, line: line)
        }

        let tabs = ["https://1.example/", "https://2.example/", "https://3.example/", "https://4.example/"]
            .map { makeTab($0, in: f.spaceA) }
        f.spaceA.tabs.append(contentsOf: tabs)

        inUndoGroup(f.store) { f.store.closeTab(id: tabs[0].id, in: f.spaceA) }
        expectUpdate("close pushes a record")

        f.store.undoManager.undo()
        expectUpdate("undo of the close deletes its record")

        inUndoGroup(f.store) { f.store.closeTab(id: tabs[1].id, in: f.spaceA) }
        expectUpdate("close")
        let restoreID = try XCTUnwrap(f.store.archiveEntries().first).id
        f.store.restoreClosedTab(recordID: restoreID)
        expectUpdate("restore")

        inUndoGroup(f.store) { f.store.closeTab(id: tabs[2].id, in: f.spaceA) }
        expectUpdate("close")
        f.store.reopenClosedTab(in: f.spaceA)
        expectUpdate("reopen")

        inUndoGroup(f.store) { f.store.closeTab(id: tabs[3].id, in: f.spaceA) }
        expectUpdate("close")
        f.store.deleteClosedTabRecord(id: try XCTUnwrap(f.store.archiveEntries().first).id)
        expectUpdate("delete")

        f.store.clearClosedTabRecords(spaceIDs: [f.spaceA.id])
        expectUpdate("clear")
    }

    func testIncognitoCloseDoesNotNotify() throws {
        let f = try makeFixture()
        let incognito = f.store.addIncognitoSpace()
        let tab = makeTab("https://private.example/", in: incognito)
        incognito.tabs.append(tab)
        let before = f.observer.updates
        inUndoGroup(f.store) { f.store.closeTab(id: tab.id, in: incognito) }
        XCTAssertEqual(f.observer.updates, before)
    }

    func testSpaceDeleteAndUndoNotify() throws {
        let f = try makeFixture()
        pushRecord(f.db, spaceID: f.spaceB.id, url: "https://b.example/")
        let before = f.observer.updates
        inUndoGroup(f.store) { f.store.deleteSpace(id: f.spaceB.id) }
        XCTAssertEqual(f.observer.updates, before + 1)
        XCTAssertTrue(f.store.archiveEntries().isEmpty)
        f.store.undoManager.undo()
        XCTAssertEqual(f.observer.updates, before + 2)
        XCTAssertEqual(f.store.archiveEntries().map(\.url), ["https://b.example/"])
    }

    // MARK: - Close undo after the record is consumed or deleted

    private func urls(_ space: Space) -> [String] { space.tabs.map { $0.url?.absoluteString ?? "" } }

    func testUndoCloseAfterArchiveRestoreDoesNotDuplicate() throws {
        let f = try makeFixture()
        let keep = makeTab("https://keep.example/", in: f.spaceA)
        let tab = makeTab("https://closed.example/", in: f.spaceA)
        f.spaceA.tabs = [keep, tab]
        inUndoGroup(f.store) { f.store.closeTab(id: tab.id, in: f.spaceA) }
        let recordID = try XCTUnwrap(f.store.archiveEntries().first).id
        XCTAssertNotNil(f.store.restoreClosedTab(recordID: recordID))
        XCTAssertEqual(urls(f.spaceA), ["https://keep.example/", "https://closed.example/"])

        f.store.undoManager.undo()
        XCTAssertEqual(urls(f.spaceA), ["https://keep.example/", "https://closed.example/"],
                       "the close's undo is a no-op once its record was restored")
    }

    func testUndoCloseAfterReopenClosedTabDoesNotDuplicate() throws {
        let f = try makeFixture()
        let tab = makeTab("https://closed.example/", in: f.spaceA)
        f.spaceA.tabs = [tab]
        inUndoGroup(f.store) { f.store.closeTab(id: tab.id, in: f.spaceA) }
        XCTAssertNotNil(f.store.reopenClosedTab(in: f.spaceA))
        f.store.undoManager.undo()
        XCTAssertEqual(urls(f.spaceA), ["https://closed.example/"])
    }

    func testUndoCloseAfterDeleteOrClearDoesNothing() throws {
        let f = try makeFixture()
        let a = makeTab("https://deleted.example/", in: f.spaceA)
        let b = makeTab("https://cleared.example/", in: f.spaceB)
        f.spaceA.tabs = [a]
        f.spaceB.tabs = [b]
        inUndoGroup(f.store) { f.store.closeTab(id: a.id, in: f.spaceA) }
        inUndoGroup(f.store) { f.store.closeTab(id: b.id, in: f.spaceB) }
        let recordA = try XCTUnwrap(f.store.archiveEntries().first { $0.spaceID == f.spaceA.id }).id
        f.store.deleteClosedTabRecord(id: recordA)
        f.store.clearClosedTabRecords(spaceIDs: [f.spaceB.id])

        f.store.undoManager.undo()  // B's close
        f.store.undoManager.undo()  // A's close
        XCTAssertTrue(f.spaceA.tabs.isEmpty, "a deleted record's tab stays closed")
        XCTAssertTrue(f.spaceB.tabs.isEmpty, "a cleared record's tab stays closed")
    }

    func testUndoCloseStillWorksWhileTheRecordExists() throws {
        let f = try makeFixture()
        let tab = makeTab("https://closed.example/", in: f.spaceA)
        f.spaceA.tabs = [tab]
        inUndoGroup(f.store) { f.store.closeTab(id: tab.id, in: f.spaceA) }
        f.store.undoManager.undo()
        XCTAssertEqual(urls(f.spaceA), ["https://closed.example/"])
        XCTAssertTrue(f.store.archiveEntries().isEmpty, "the undo consumed the record")
    }

    func testIncognitoUndoCloseIsUnaffected() throws {
        let f = try makeFixture()
        let incognito = f.store.addIncognitoSpace()
        let tab = makeTab("https://private.example/", in: incognito)
        incognito.tabs = [tab]
        inUndoGroup(f.store) { f.store.closeTab(id: tab.id, in: incognito) }
        f.store.undoManager.undo()
        XCTAssertEqual(urls(incognito), ["https://private.example/"], "no record is pushed, so none is required")
    }

    func testUndoCloseBothSplitsSkipsARestoredMember() throws {
        let f = try makeFixture()
        let left = makeTab("https://left.example/", in: f.spaceA)
        let right = makeTab("https://right.example/", in: f.spaceA)
        let groupID = UUID()
        left.splitGroupID = groupID
        right.splitGroupID = groupID
        f.spaceA.tabs = [left, right]
        inUndoGroup(f.store) { f.store.closeSplitGroup(groupID: groupID, in: f.spaceA) }
        let leftRecord = try XCTUnwrap(f.store.archiveEntries().first { $0.url == "https://left.example/" }).id
        XCTAssertNotNil(f.store.restoreClosedTab(recordID: leftRecord))

        f.store.undoManager.undo()
        XCTAssertEqual(urls(f.spaceA).sorted(), ["https://left.example/", "https://right.example/"],
                       "the right pane comes back; the restored left one is not duplicated")
        XCTAssertTrue(f.spaceA.tabs.allSatisfy { $0.splitGroupID == nil }, "a lone member does not rejoin a split")
        XCTAssertTrue(f.store.archiveEntries().isEmpty)
    }
}
