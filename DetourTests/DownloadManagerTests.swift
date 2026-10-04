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

    private func addItem(_ f: Fixture, _ name: String = "file.zip") -> DownloadItem {
        let item = f.manager.addManualItem(filename: name, sourceURL: URL(string: "https://example.com/\(name)"))
        item.destinationURL = URL(fileURLWithPath: "/tmp/\(name)")
        return item
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
}
