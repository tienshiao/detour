import XCTest
@testable import Detour

/// TASK-404: when the GPU surface telemetry persists a periodic sample, and how
/// its lines read.
nonisolated final class GPUSurfaceTelemetryTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @MainActor private func sample(_ total: Int, nonResident: Int = 0, pid: pid_t = 100,
                                   processes: Int = 5, after seconds: TimeInterval = 0) -> GPUSurfaceSample {
        GPUSurfaceSample(gpuPID: pid, counts: .init(total: total, nonResident: nonResident),
                         tabProcesses: processes, at: t0.addingTimeInterval(seconds))
    }

    // MARK: - Periodic logging

    @MainActor func testFirstSampleIsLogged() {
        XCTAssertTrue(GPUSurfaceTelemetryRules.shouldLogPeriodic(sample(500), lastLogged: nil))
    }

    @MainActor func testSmallMoveWithinSilenceIsNotLogged() {
        XCTAssertFalse(GPUSurfaceTelemetryRules.shouldLogPeriodic(
            sample(549, after: 599), lastLogged: sample(500)))
        XCTAssertFalse(GPUSurfaceTelemetryRules.shouldLogPeriodic(
            sample(451, after: 120), lastLogged: sample(500)))
    }

    @MainActor func testMoveOfFiftyEitherWayIsLogged() {
        XCTAssertTrue(GPUSurfaceTelemetryRules.shouldLogPeriodic(sample(550, after: 120), lastLogged: sample(500)))
        XCTAssertTrue(GPUSurfaceTelemetryRules.shouldLogPeriodic(sample(450, after: 120), lastLogged: sample(500)))
    }

    @MainActor func testTenMinutesOfSilenceIsLogged() {
        XCTAssertTrue(GPUSurfaceTelemetryRules.shouldLogPeriodic(sample(500, after: 600), lastLogged: sample(500)))
    }

    @MainActor func testNewGPUProcessIsLogged() {
        XCTAssertTrue(GPUSurfaceTelemetryRules.shouldLogPeriodic(
            sample(500, pid: 200, after: 10), lastLogged: sample(500, pid: 100)))
    }

    // MARK: - Sample lines

    @MainActor func testSampleLineCarriesDeltas() {
        XCTAssertEqual(
            GPUSurfaceTelemetryRules.describe(sample(2291, nonResident: 1564, processes: 10, after: 100),
                                              since: sample(2234, nonResident: 1871)),
            "total=2291 (+57) nonResident=1564 (-307) tabProcesses=10 gpu=100 over 100s")
    }

    @MainActor func testSampleLineWithoutPreviousHasNoDelta() {
        XCTAssertEqual(GPUSurfaceTelemetryRules.describe(sample(506, nonResident: 3), since: nil),
                       "total=506 nonResident=3 tabProcesses=5 gpu=100")
    }

    @MainActor func testSampleLineAcrossGPUProcessesSaysSo() {
        XCTAssertEqual(GPUSurfaceTelemetryRules.describe(sample(481, pid: 200), since: sample(16_697, pid: 100)),
                       "total=481 nonResident=0 tabProcesses=5 gpu=200 (new GPU process)")
    }

    // MARK: - Event coalescing

    @MainActor func testIdenticalEventsFoldInFirstSeenOrder() {
        let show = GPUSurfaceEvent(kind: .show, host: "www.youtube.com", webProcess: 7011)
        let close = GPUSurfaceEvent(kind: .close, host: "jira.example.com", webProcess: 24775)
        let wake = GPUSurfaceEvent(kind: .wake, host: "jira.example.com", webProcess: 0)
        XCTAssertEqual(GPUSurfaceTelemetryRules.describe([show, close, show, wake, show]),
                       "show www.youtube.com[7011]×3, close jira.example.com[24775], wake jira.example.com")
    }

    @MainActor func testSameHostInAnotherProcessIsAnotherGroup() {
        let a = GPUSurfaceEvent(kind: .close, host: "www.youtube.com", webProcess: 1)
        let b = GPUSurfaceEvent(kind: .close, host: "www.youtube.com", webProcess: 2)
        XCTAssertEqual(GPUSurfaceTelemetryRules.describe([a, b]),
                       "close www.youtube.com[1], close www.youtube.com[2]")
    }

    @MainActor func testGroupsPastTheLimitAreCounted() {
        let events = (1...5).map { GPUSurfaceEvent(kind: .show, host: "h\($0)", webProcess: 0) }
        XCTAssertEqual(GPUSurfaceTelemetryRules.describe(events, limit: 2), "show h1, show h2, +3 more")
    }

    // MARK: - Region counting

    @MainActor func testRegionCountsOfOwnProcessAreConsistent() throws {
        let counts = try XCTUnwrap(GPUProcessRecycler.ioSurfaceRegionCounts(pid: getpid()))
        XCTAssertLessThanOrEqual(counts.nonResident, counts.total)
    }

    @MainActor func testRegionCountsAreNilForMissingProcess() {
        XCTAssertNil(GPUProcessRecycler.ioSurfaceRegionCounts(pid: 999_999))
    }
}
