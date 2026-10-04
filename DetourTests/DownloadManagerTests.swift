import XCTest
import GRDB
@testable import Detour

/// `DownloadManager` against an in-memory database, a fixed clock and a save
/// scheduler the test fires by hand: no `WKDownload`, no waiting out the
/// debounce. A download is stood in for by a manual item (`addManualItem`) that
/// is ended through `downloadDidEnd`, the method the `WKDownloadDelegate`
/// callbacks call.
final class DownloadManagerTests: XCTestCase {

    /// Whole seconds: the `download` table stores dates to the millisecond.
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Stands in for the main-queue debounce: holds the scheduled saves until
    /// the test fires them.
    private final class ManualScheduler {
        private var nextID = 0
        private(set) var pending: [(id: Int, delay: TimeInterval, work: () -> Void)] = []

        var scheduler: DownloadManager.SaveScheduler {
            { [unowned self] delay, work in
                let id = self.nextID
                self.nextID += 1
                self.pending.append((id, delay, work))
                return { [weak self] in self?.pending.removeAll { $0.id == id } }
            }
        }

        func fire() {
            let due = pending
            pending = []
            due.forEach { $0.work() }
        }
    }

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Fixture {
        let database: AppDatabase
        let clock: Clock
        let scheduler: ManualScheduler
        let manager: DownloadManager

        /// A second manager on the same database: what a relaunch loads.
        func relaunched(at date: Date) -> Fixture {
            let clock = Clock(date)
            let scheduler = ManualScheduler()
            return Fixture(database: database, clock: clock, scheduler: scheduler,
                           manager: DownloadManager(database: database, now: { clock.now },
                                                    scheduler: scheduler.scheduler))
        }

        var records: [DownloadRecord] { database.loadDownloads() }

        func record(for item: DownloadItem) -> DownloadRecord? {
            records.first { $0.id == item.id.uuidString }
        }
    }

    private func makeFixture() throws -> Fixture {
        let database = try AppDatabase(dbQueue: try DatabaseQueue())
        let clock = Clock(Self.t0)
        let scheduler = ManualScheduler()
        let manager = DownloadManager(database: database, now: { clock.now }, scheduler: scheduler.scheduler)
        return Fixture(database: database, clock: clock, scheduler: scheduler, manager: manager)
    }

    private func addItem(_ f: Fixture, _ name: String = "file.zip", scope: DownloadScope = .normal) -> DownloadItem {
        let item = f.manager.addManualItem(filename: name, sourceURL: URL(string: "https://example.com/\(name)"),
                                           scope: scope)
        item.destinationURL = URL(fileURLWithPath: "/tmp/\(name)")
        return item
    }

    /// Records what the manager tells its observers (a window's badge, a popover).
    private final class ObserverSpy: DownloadManagerObserver {
        private(set) var added: [UUID] = []
        private(set) var updated: [UUID] = []
        private(set) var removed: [UUID] = []

        func downloadManagerDidAddItem(_ item: DownloadItem) { added.append(item.id) }
        func downloadManagerDidUpdateItem(_ item: DownloadItem) { updated.append(item.id) }
        func downloadManagerDidRemoveItem(_ item: DownloadItem) { removed.append(item.id) }
    }

    // MARK: - completedAt (TASK-143)

    func testCompletedAtIsTheTimeTheDownloadCompleted() throws {
        let f = try makeFixture()
        let item = addItem(f)

        f.clock.now = Self.t0.addingTimeInterval(30)
        f.manager.downloadDidEnd(item)
        // The debounced save runs later than the completion.
        f.clock.now = Self.t0.addingTimeInterval(31)
        f.scheduler.fire()

        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.completedAt, Self.t0.addingTimeInterval(30))
        XCTAssertEqual(f.record(for: item)?.completedAt, Self.t0.addingTimeInterval(30))
    }

    func testLaterSavesLeaveCompletedAtUnchanged() throws {
        let f = try makeFixture()
        let first = addItem(f, "first.zip")
        f.manager.downloadDidEnd(first)
        f.scheduler.fire()
        XCTAssertEqual(f.record(for: first)?.completedAt, Self.t0)

        // Another download ends an hour later; its save rewrites every row.
        f.clock.now = Self.t0.addingTimeInterval(3600)
        let second = addItem(f, "second.zip")
        f.manager.downloadDidEnd(second)
        f.scheduler.fire()

        XCTAssertEqual(f.record(for: first)?.completedAt, Self.t0)
        XCTAssertEqual(f.record(for: second)?.completedAt, Self.t0.addingTimeInterval(3600))
    }

    func testMarkCompletedTwiceKeepsTheFirstTime() {
        let item = DownloadItem(filename: "file.zip", sourceURL: nil, createdAt: Self.t0)
        item.markCompleted(at: Self.t0.addingTimeInterval(5))
        item.markCompleted(at: Self.t0.addingTimeInterval(50))

        XCTAssertEqual(item.completedAt, Self.t0.addingTimeInterval(5))
    }

    func testFailedAndCancelledDownloadsHaveNoCompletedAt() throws {
        let f = try makeFixture()
        let failed = addItem(f, "failed.zip")
        let cancelled = addItem(f, "cancelled.zip")

        f.manager.downloadDidEnd(failed, failure: "The network connection was lost.")
        f.manager.cancelDownload(cancelled)
        f.scheduler.fire()

        XCTAssertEqual(failed.state, .failed("The network connection was lost."))
        XCTAssertNil(failed.completedAt)
        XCTAssertNil(cancelled.completedAt)
        XCTAssertEqual(f.record(for: failed)?.state, "failed")
        XCTAssertNil(f.record(for: failed)?.completedAt)
        XCTAssertEqual(f.record(for: cancelled)?.state, "cancelled")
        XCTAssertNil(f.record(for: cancelled)?.completedAt)
    }

    func testCompletedAtSurvivesARelaunchAndTheNextSave() throws {
        let f = try makeFixture()
        let item = addItem(f)
        f.manager.downloadDidEnd(item)
        f.scheduler.fire()

        // A day later the app relaunches and something else is saved.
        let later = f.relaunched(at: Self.t0.addingTimeInterval(86_400))
        let restored = try XCTUnwrap(later.manager.items.first { $0.id == item.id })
        XCTAssertEqual(restored.state, .completed)
        XCTAssertEqual(restored.completedAt, Self.t0)
        XCTAssertEqual(restored.createdAt, Self.t0)

        let other = addItem(later, "other.zip")
        later.manager.cancelDownload(other)
        later.scheduler.fire()

        XCTAssertEqual(later.record(for: item)?.completedAt, Self.t0)
    }

    func testARecordThatIsNotCompletedLoadsWithoutACompletionTime() throws {
        let record = DownloadRecord(id: UUID().uuidString, filename: "a.zip", sourceURL: nil,
                                    destinationURL: "/tmp/a.zip", totalBytes: 10, bytesWritten: 4,
                                    state: "downloading", createdAt: Self.t0,
                                    completedAt: Self.t0.addingTimeInterval(9))
        let item = DownloadItem(record: record)

        XCTAssertEqual(item.state, .failed("Interrupted"))
        XCTAssertNil(item.completedAt)
    }

    // MARK: - Debounce and the termination flush (TASK-143)

    func testAStateChangeIsNotWrittenUntilTheDebounceFires() throws {
        let f = try makeFixture()
        let item = addItem(f)

        f.manager.downloadDidEnd(item)

        XCTAssertTrue(f.records.isEmpty)
        XCTAssertEqual(f.scheduler.pending.map(\.delay), [DownloadManager.saveDebounce])

        f.scheduler.fire()
        XCTAssertEqual(f.records.map(\.id), [item.id.uuidString])
    }

    func testABurstOfChangesSchedulesOneSave() throws {
        let f = try makeFixture()
        let a = addItem(f, "a.zip")
        let b = addItem(f, "b.zip")

        f.manager.downloadDidEnd(a)
        f.manager.downloadDidEnd(b, failure: "nope")

        XCTAssertEqual(f.scheduler.pending.count, 1)
        f.scheduler.fire()
        XCTAssertEqual(Set(f.records.map(\.id)), [a.id.uuidString, b.id.uuidString])
    }

    func testFlushWritesAChangeStillInTheDebounceWindow() throws {
        let f = try makeFixture()
        let item = addItem(f)
        f.manager.downloadDidEnd(item)
        XCTAssertTrue(f.records.isEmpty)

        // What `applicationWillTerminate` calls.
        f.manager.flushPendingSave()

        let record = try XCTUnwrap(f.record(for: item))
        XCTAssertEqual(record.state, "completed")
        XCTAssertEqual(record.completedAt, Self.t0)
        XCTAssertTrue(f.scheduler.pending.isEmpty, "the flush cancels the debounced save it replaced")

        // After the flush a relaunch lists the download as completed.
        let later = f.relaunched(at: Self.t0.addingTimeInterval(60))
        XCTAssertEqual(later.manager.items.map(\.state), [.completed])
    }

    func testFlushWritesACancelStillInTheDebounceWindow() throws {
        let f = try makeFixture()
        let item = addItem(f)

        f.manager.cancelDownload(item)
        f.manager.flushPendingSave()

        XCTAssertEqual(f.record(for: item)?.state, "cancelled")
    }

    func testFlushWithNothingPendingWritesNothing() throws {
        let f = try makeFixture()
        let item = addItem(f)
        f.manager.downloadDidEnd(item)
        f.scheduler.fire()

        // Take the row away behind the manager's back: a flush with no save
        // pending must not write it again.
        f.database.deleteDownload(id: item.id.uuidString)
        f.manager.flushPendingSave()

        XCTAssertTrue(f.records.isEmpty)
    }

    func testADownloadStillInFlightIsNeverWritten() throws {
        let f = try makeFixture()
        let inFlight = addItem(f, "big.iso")
        let done = addItem(f, "small.zip")

        f.manager.downloadDidEnd(done)
        f.manager.flushPendingSave()

        XCTAssertEqual(inFlight.state, .downloading)
        XCTAssertEqual(f.records.map(\.id), [done.id.uuidString])
    }

    // MARK: - Private windows: the rules (TASK-148)

    private static let windowA = DownloadScope.incognito(spaceID: UUID())
    private static let windowB = DownloadScope.incognito(spaceID: UUID())

    func testOnlyANormalWindowsDownloadsArePersisted() {
        XCTAssertTrue(DownloadScope.normal.isPersisted)
        XCTAssertFalse(Self.windowA.isPersisted)
    }

    func testAWindowListsOnlyTheDownloadsOfItsOwnScope() {
        // A normal window's download: every normal window, no Private window.
        XCTAssertTrue(DownloadScope.normal.isListed(inWindowWith: .normal))
        XCTAssertFalse(DownloadScope.normal.isListed(inWindowWith: Self.windowA))
        // A Private window's download: that window only.
        XCTAssertTrue(Self.windowA.isListed(inWindowWith: Self.windowA))
        XCTAssertFalse(Self.windowA.isListed(inWindowWith: .normal))
        XCTAssertFalse(Self.windowA.isListed(inWindowWith: Self.windowB))
    }

    func testAPrivateDownloadIsOrphanedOnceItsSpaceIsGone() {
        guard case .incognito(let spaceA) = Self.windowA, case .incognito(let spaceB) = Self.windowB else {
            return XCTFail("fixture scopes are incognito")
        }
        XCTAssertFalse(Self.windowA.isOrphaned(liveIncognitoSpaceIDs: [spaceA, spaceB]))
        XCTAssertTrue(Self.windowA.isOrphaned(liveIncognitoSpaceIDs: [spaceB]))
        XCTAssertTrue(Self.windowA.isOrphaned(liveIncognitoSpaceIDs: []))
        XCTAssertFalse(DownloadScope.normal.isOrphaned(liveIncognitoSpaceIDs: []))
    }

    // MARK: - Private windows: nothing is saved (TASK-148)

    func testAPrivateDownloadLeavesNoRowInTheTable() throws {
        let f = try makeFixture()
        let completed = addItem(f, "completed.zip", scope: Self.windowA)
        let failed = addItem(f, "failed.zip", scope: Self.windowA)
        let cancelled = addItem(f, "cancelled.zip", scope: Self.windowB)

        f.manager.downloadDidEnd(completed)
        f.manager.downloadDidEnd(failed, failure: "nope")
        f.manager.cancelDownload(cancelled)
        f.scheduler.fire()
        f.manager.scheduleSave()
        f.scheduler.fire()

        XCTAssertEqual(completed.state, .completed)
        XCTAssertTrue(f.records.isEmpty)
    }

    func testANormalDownloadIsStillSavedNextToAPrivateOne() throws {
        let f = try makeFixture()
        let normal = addItem(f, "normal.zip")
        let secret = addItem(f, "private.zip", scope: Self.windowA)

        f.manager.downloadDidEnd(secret)
        f.manager.downloadDidEnd(normal)
        f.scheduler.fire()

        XCTAssertEqual(f.records.map(\.id), [normal.id.uuidString])
        XCTAssertEqual(f.record(for: normal)?.state, "completed")
    }

    func testTheTerminationFlushDoesNotWriteAPrivateDownload() throws {
        let f = try makeFixture()
        let normal = addItem(f, "normal.zip")
        let secret = addItem(f, "private.zip", scope: Self.windowA)

        f.manager.downloadDidEnd(secret)
        f.manager.downloadDidEnd(normal)
        f.manager.flushPendingSave()

        XCTAssertEqual(f.records.map(\.id), [normal.id.uuidString])
    }

    func testAPrivateDownloadIsNotListedAfterARelaunch() throws {
        let f = try makeFixture()
        let secret = addItem(f, "private.zip", scope: Self.windowA)
        f.manager.downloadDidEnd(secret)
        f.manager.flushPendingSave()

        let later = f.relaunched(at: Self.t0.addingTimeInterval(60))
        XCTAssertTrue(later.manager.items.isEmpty)
    }

    // MARK: - Private windows: listed in their own window only (TASK-148)

    func testEachWindowListsItsOwnDownloads() throws {
        let f = try makeFixture()
        let normal = addItem(f, "normal.zip")
        let inA = addItem(f, "a.zip", scope: Self.windowA)
        let inB = addItem(f, "b.zip", scope: Self.windowB)

        XCTAssertEqual(f.manager.items(in: .normal).map(\.id), [normal.id])
        XCTAssertEqual(f.manager.items(in: Self.windowA).map(\.id), [inA.id])
        XCTAssertEqual(f.manager.items(in: Self.windowB).map(\.id), [inB.id])
    }

    func testNormalWindowsShareOneListNewestFirst() throws {
        let f = try makeFixture()
        let first = addItem(f, "first.zip")
        _ = addItem(f, "private.zip", scope: Self.windowA)
        let second = addItem(f, "second.zip")

        XCTAssertEqual(f.manager.items(in: .normal).map(\.id), [second.id, first.id])
    }

    func testOnlyTheOwningWindowsBadgeShowsAPrivateDownloadInFlight() throws {
        let f = try makeFixture()
        let secret = addItem(f, "private.iso", scope: Self.windowA)

        XCTAssertTrue(f.manager.hasActiveDownloads(in: Self.windowA))
        XCTAssertFalse(f.manager.hasActiveDownloads(in: .normal))
        XCTAssertFalse(f.manager.hasActiveDownloads(in: Self.windowB))

        f.manager.downloadDidEnd(secret)
        XCTAssertFalse(f.manager.hasActiveDownloads(in: Self.windowA))
    }

    func testANormalDownloadInFlightDoesNotBadgeAPrivateWindow() throws {
        let f = try makeFixture()
        _ = addItem(f, "normal.iso")

        XCTAssertTrue(f.manager.hasActiveDownloads(in: .normal))
        XCTAssertFalse(f.manager.hasActiveDownloads(in: Self.windowA))
    }

    func testClearInANormalWindowLeavesPrivateDownloadsListed() throws {
        let f = try makeFixture()
        let normal = addItem(f, "normal.zip")
        let secret = addItem(f, "private.zip", scope: Self.windowA)
        f.manager.downloadDidEnd(normal)
        f.manager.downloadDidEnd(secret)
        f.scheduler.fire()

        f.manager.clearCompleted(in: .normal)

        XCTAssertTrue(f.manager.items(in: .normal).isEmpty)
        XCTAssertEqual(f.manager.items(in: Self.windowA).map(\.id), [secret.id])
        XCTAssertTrue(f.records.isEmpty)
    }

    func testClearInAPrivateWindowLeavesNormalDownloadsAndTheirRows() throws {
        let f = try makeFixture()
        let normal = addItem(f, "normal.zip")
        let secret = addItem(f, "private.zip", scope: Self.windowA)
        let inFlight = addItem(f, "private.iso", scope: Self.windowA)
        f.manager.downloadDidEnd(normal)
        f.manager.downloadDidEnd(secret)
        f.scheduler.fire()

        f.manager.clearCompleted(in: Self.windowA)

        XCTAssertEqual(f.manager.items(in: Self.windowA).map(\.id), [inFlight.id])
        XCTAssertEqual(f.manager.items(in: .normal).map(\.id), [normal.id])
        XCTAssertEqual(f.records.map(\.id), [normal.id.uuidString])
    }

    // MARK: - Private windows: dropped when the window closes (TASK-148)

    /// A real `TabStore` on an in-memory database, followed by the manager as
    /// `DownloadManager.shared` follows `TabStore.shared`.
    private func makeStore(observedBy f: Fixture) throws -> TabStore {
        let store = TabStore(appDB: f.database)
        f.manager.observeIncognitoSpaces(of: store)
        return store
    }

    func testClosingThePrivateWindowDropsItsDownloadsFromTheList() throws {
        let f = try makeFixture()
        let store = try makeStore(observedBy: f)
        let space = store.addIncognitoSpace()
        let window = DownloadScope.incognito(spaceID: space.id)
        let normal = addItem(f, "normal.zip")
        let secret = addItem(f, "private.zip", scope: window)
        f.manager.downloadDidEnd(secret)
        let spy = ObserverSpy()
        f.manager.addObserver(spy)

        // What `windowWillClose` does for a Private window.
        store.removeIncognitoSpace(id: space.id)

        XCTAssertTrue(f.manager.items(in: window).isEmpty)
        XCTAssertEqual(f.manager.items.map(\.id), [normal.id])
        XCTAssertTrue(f.manager.unlistedItems.isEmpty, "an ended download is discarded outright")
        XCTAssertEqual(spy.removed, [secret.id])
    }

    func testAnotherPrivateWindowKeepsItsDownloads() throws {
        let f = try makeFixture()
        let store = try makeStore(observedBy: f)
        let closing = store.addIncognitoSpace()
        let staying = store.addIncognitoSpace()
        let gone = addItem(f, "gone.zip", scope: .incognito(spaceID: closing.id))
        let kept = addItem(f, "kept.zip", scope: .incognito(spaceID: staying.id))
        f.manager.downloadDidEnd(gone)
        f.manager.downloadDidEnd(kept)

        store.removeIncognitoSpace(id: closing.id)

        XCTAssertEqual(f.manager.items.map(\.id), [kept.id])
        XCTAssertEqual(f.manager.items(in: .incognito(spaceID: staying.id)).map(\.id), [kept.id])
    }

    func testOtherSpaceChangesLeaveAPrivateDownloadListed() throws {
        let f = try makeFixture()
        let store = try makeStore(observedBy: f)
        let space = store.addIncognitoSpace()
        let secret = addItem(f, "private.zip", scope: .incognito(spaceID: space.id))

        // Another Private window opens: `tabStoreDidUpdateSpaces` fires.
        _ = store.addIncognitoSpace()

        XCTAssertEqual(f.manager.items.map(\.id), [secret.id])
    }

    func testADownloadStillRunningWhenItsWindowClosesKeepsRunningUnlisted() throws {
        let f = try makeFixture()
        let store = try makeStore(observedBy: f)
        let space = store.addIncognitoSpace()
        let window = DownloadScope.incognito(spaceID: space.id)
        let secret = addItem(f, "private.iso", scope: window)
        let spy = ObserverSpy()
        f.manager.addObserver(spy)

        store.removeIncognitoSpace(id: space.id)

        // Listed nowhere, badged nowhere, but still held and still running.
        XCTAssertTrue(f.manager.items.isEmpty)
        XCTAssertFalse(f.manager.hasActiveDownloads(in: window))
        XCTAssertFalse(f.manager.hasActiveDownloads(in: .normal))
        XCTAssertEqual(spy.removed, [secret.id])
        XCTAssertEqual(secret.state, .downloading)
        XCTAssertEqual(f.manager.unlistedItems.map(\.id), [secret.id])

        // It finishes: the item is discarded, nobody is told, nothing is saved.
        f.manager.downloadDidEnd(secret)
        f.scheduler.fire()
        f.manager.flushPendingSave()

        XCTAssertEqual(secret.state, .completed)
        XCTAssertTrue(f.manager.unlistedItems.isEmpty)
        XCTAssertTrue(f.manager.items.isEmpty)
        XCTAssertEqual(spy.updated, [])
        XCTAssertTrue(f.records.isEmpty)
    }

    func testAnUnlistedDownloadThatFailsIsDiscarded() throws {
        let f = try makeFixture()
        let store = try makeStore(observedBy: f)
        let space = store.addIncognitoSpace()
        let secret = addItem(f, "private.iso", scope: .incognito(spaceID: space.id))
        store.removeIncognitoSpace(id: space.id)
        XCTAssertEqual(f.manager.unlistedItems.map(\.id), [secret.id])

        f.manager.downloadDidEnd(secret, failure: "The network connection was lost.")
        f.manager.flushPendingSave()

        XCTAssertTrue(f.manager.unlistedItems.isEmpty)
        XCTAssertTrue(f.records.isEmpty)
    }

    /// The CRX fetch removes its manual item itself when the fetch ends.
    func testRemovingAnUnlistedDownloadDiscardsItQuietly() throws {
        let f = try makeFixture()
        let store = try makeStore(observedBy: f)
        let space = store.addIncognitoSpace()
        let crx = addItem(f, "extension.crx", scope: .incognito(spaceID: space.id))
        store.removeIncognitoSpace(id: space.id)
        let spy = ObserverSpy()
        f.manager.addObserver(spy)

        f.manager.removeDownload(crx)

        XCTAssertTrue(f.manager.unlistedItems.isEmpty)
        XCTAssertEqual(spy.removed, [])
    }

    func testClosingAPrivateWindowLeavesNormalDownloadsAndTheirRows() throws {
        let f = try makeFixture()
        let store = try makeStore(observedBy: f)
        let space = store.addIncognitoSpace()
        let normal = addItem(f, "normal.zip")
        let running = addItem(f, "normal.iso")
        f.manager.downloadDidEnd(normal)
        f.scheduler.fire()

        store.removeIncognitoSpace(id: space.id)

        XCTAssertEqual(f.manager.items(in: .normal).map(\.id), [running.id, normal.id])
        XCTAssertEqual(f.records.map(\.id), [normal.id.uuidString])
    }
}

/// The production wiring behind the rules above: a Private window's scope, and
/// `DownloadManager.shared` following `TabStore.shared` (TASK-148).
@MainActor
final class DownloadWindowScopeTests: XCTestCase {

    private var controller: BrowserWindowController?
    private var leftover: DownloadItem?

    override func tearDown() {
        controller?.window?.close()
        controller = nil
        // Only reached with an item still listed when a test failed half way.
        if let leftover { DownloadManager.shared.removeDownload(leftover) }
        leftover = nil
        super.tearDown()
    }

    private func makePrivateWindow() throws -> (BrowserWindowController, Space) {
        let wc = BrowserWindowController(incognito: true)
        controller = wc
        // Never let this window's split view touch the autosaved sidebar
        // geometry other windows restore from.
        wc.sidebarSplitView.autosaveName = nil
        return (wc, try XCTUnwrap(wc.activeSpace))
    }

    func testAPrivateWindowsDownloadScopeIsItsIncognitoSpace() throws {
        let (wc, space) = try makePrivateWindow()

        XCTAssertTrue(space.isIncognito)
        XCTAssertEqual(wc.downloadScope, .incognito(spaceID: space.id))
    }

    func testClosingAPrivateWindowDropsItsDownloadsFromTheSharedManager() throws {
        let (wc, space) = try makePrivateWindow()
        let manager = DownloadManager.shared
        let scope = wc.downloadScope
        let item = manager.addManualItem(filename: "private.zip", sourceURL: nil, scope: scope)
        leftover = item
        manager.downloadDidEnd(item)
        XCTAssertEqual(manager.items(in: scope).map(\.id), [item.id])
        XCTAssertFalse(manager.items(in: .normal).contains { $0 === item })

        wc.window?.close()

        XCTAssertNil(TabStore.shared.space(withID: space.id), "closing the window removes its incognito space")
        XCTAssertFalse(manager.items.contains { $0 === item })
        XCTAssertFalse(manager.unlistedItems.contains { $0 === item })
    }
}
