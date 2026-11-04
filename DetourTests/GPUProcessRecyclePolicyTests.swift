import XCTest
@testable import Detour

/// TASK-105: when to recycle WebKit's GPU process before it exhausts the
/// kernel's 16,384 IOSurfaces per process.
nonisolated final class GPUProcessRecyclePolicyTests: XCTestCase {

    private let policy = GPUProcessRecyclePolicy()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @MainActor private func inputs(
        surfaces: Int,
        inactiveFor: TimeInterval? = nil,
        userIdle: TimeInterval = 0,
        audio: Bool = false,
        lastRecycleAgo: TimeInterval? = nil
    ) -> GPUProcessRecyclePolicy.Inputs {
        .init(surfaceCount: surfaces,
              inactiveSince: inactiveFor.map { now.addingTimeInterval(-$0) },
              userIdleSeconds: userIdle,
              mediaInUse: audio,
              lastRecycleAt: lastRecycleAgo.map { now.addingTimeInterval(-$0) },
              now: now)
    }

    // MARK: - Below the soft limit

    @MainActor func testBelowSoftLimitKeepsEvenWhenLongInactive() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 11_999, inactiveFor: 3600, userIdle: 3600)), .keep)
    }

    // MARK: - Soft limit: background only

    @MainActor func testSoftLimitRecyclesAfterInactiveGrace() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 12_000, inactiveFor: 5 * 60)), .recycle)
    }

    @MainActor func testSoftLimitWaitsWhileInactiveLessThanGrace() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 13_000, inactiveFor: 5 * 60 - 1, userIdle: 3600)), .wait)
    }

    @MainActor func testSoftLimitNeverRecyclesWhileActiveEvenIfUserIdle() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 14_999, inactiveFor: nil, userIdle: 3600)), .wait)
    }

    // MARK: - Hard limit: also while active, once the user is idle

    @MainActor func testHardLimitRecyclesWhileActiveOnceUserIdle() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000, inactiveFor: nil, userIdle: 60)), .recycle)
    }

    @MainActor func testHardLimitWaitsWhileActiveAndUserBusy() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_384, inactiveFor: nil, userIdle: 59)), .wait)
    }

    @MainActor func testHardLimitRecyclesAsSoonAsAppIsInactive() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_500, inactiveFor: 1, userIdle: 0)), .recycle)
    }

    // MARK: - Guards that apply at every limit

    @MainActor func testAudioBlocksRecycleAtSoftAndHardLimits() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 12_500, inactiveFor: 3600, audio: true)), .wait)
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_384, inactiveFor: 3600, userIdle: 3600, audio: true)), .wait)
    }

    @MainActor func testRateLimitBlocksRecycleWithinAnHour() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_000, inactiveFor: 3600, lastRecycleAgo: 60 * 60 - 1)), .wait)
    }

    @MainActor func testRateLimitReopensAfterAnHour() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_000, inactiveFor: 3600, lastRecycleAgo: 60 * 60)), .recycle)
    }

    // MARK: - Environment overrides (runtime harness)

    @MainActor func testEnvironmentOverridesApply() {
        let p = GPUProcessRecyclePolicy.fromEnvironment([
            "DETOUR_GPU_RECYCLE_SOFT_LIMIT": "100",
            "DETOUR_GPU_RECYCLE_HARD_LIMIT": "200",
            "DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS": "5",
            "DETOUR_GPU_RECYCLE_USER_IDLE_SECONDS": "0",
            "DETOUR_GPU_RECYCLE_MIN_INTERVAL_SECONDS": "30",
        ])
        XCTAssertEqual(p, GPUProcessRecyclePolicy(softLimit: 100, hardLimit: 200, inactiveGrace: 5,
                                                  userIdleGrace: 0, minimumInterval: 30))
    }

    @MainActor func testInvalidEnvironmentOverridesAreIgnored() {
        let p = GPUProcessRecyclePolicy.fromEnvironment([
            "DETOUR_GPU_RECYCLE_SOFT_LIMIT": "0",
            "DETOUR_GPU_RECYCLE_HARD_LIMIT": "lots",
            "DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS": "-1",
            "DETOUR_GPU_RECYCLE_USER_IDLE_SECONDS": "nan",
            "DETOUR_GPU_RECYCLE_MIN_INTERVAL_SECONDS": "inf",
        ])
        XCTAssertEqual(p, GPUProcessRecyclePolicy())
    }

    // MARK: - Surface counting

    @MainActor func testIOSurfaceCountReadsOwnProcess() {
        XCTAssertNotNil(GPUProcessRecycler.ioSurfaceCount(pid: getpid()))
    }

    @MainActor func testIOSurfaceCountIsNilForMissingProcess() {
        XCTAssertNil(GPUProcessRecycler.ioSurfaceCount(pid: 999_999))
    }
}
