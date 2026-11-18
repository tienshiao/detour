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
        away: Bool = false,
        capturing: Bool = false,
        contextLossAgo: TimeInterval? = nil,
        lastRecycleAgo: TimeInterval? = nil
    ) -> GPUProcessRecyclePolicy.Inputs {
        .init(surfaceCount: surfaces,
              inactiveSince: inactiveFor.map { now.addingTimeInterval(-$0) },
              userIdleSeconds: userIdle,
              mediaInUse: audio || capturing,
              userAway: away,
              capturingMedia: capturing,
              lastContextLossAt: contextLossAgo.map { now.addingTimeInterval(-$0) },
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
        XCTAssertEqual(policy.decide(inputs(surfaces: 13_999, inactiveFor: nil, userIdle: 3600)), .wait)
    }

    // MARK: - Hard limit: also while active, once the user is idle

    @MainActor func testLimitDefaults() {
        XCTAssertEqual(policy.hardLimit, 14_000)
        XCTAssertEqual(policy.exhaustedLimit, 16_384)
    }

    @MainActor func testHardLimitRecyclesWhileActiveOnceUserIdle() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 14_000, inactiveFor: nil, userIdle: 60)), .recycle)
    }

    @MainActor func testHardLimitWaitsWhileActiveAndUserBusy() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_383, inactiveFor: nil, userIdle: 59)), .wait)
    }

    @MainActor func testHardLimitRecyclesAsSoonAsAppIsInactive() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 14_500, inactiveFor: 1, userIdle: 0)), .recycle)
    }

    // MARK: - Exhausted: already broken, recycle even while the user is busy (TASK-403)

    @MainActor func testExhaustedRecyclesWhileActiveAndUserBusy() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_384, inactiveFor: nil, userIdle: 0)), .recycle)
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_697, inactiveFor: nil, userIdle: 0)), .recycle)
    }

    @MainActor func testExhaustedStillWaitsForMediaAndRateLimit() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_697, inactiveFor: nil, userIdle: 0, audio: true)), .wait)
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_697, inactiveFor: nil, userIdle: 0,
                                            lastRecycleAgo: 60 * 60 - 1)), .wait)
    }

    // MARK: - Away: screen locked or every display asleep (TASK-406)

    @MainActor func testAwayLimitDefault() {
        XCTAssertEqual(policy.awayLimit, 6_000)
    }

    @MainActor func testAwayRecyclesFromAwayLimitEvenWhileActiveAndBusy() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 6_000, inactiveFor: nil, userIdle: 0, away: true)), .recycle)
        XCTAssertEqual(policy.decide(inputs(surfaces: 11_999, inactiveFor: 1, away: true)), .recycle)
        XCTAssertEqual(policy.decide(inputs(surfaces: 13_000, inactiveFor: nil, away: true)), .recycle)
    }

    @MainActor func testAwayBelowAwayLimitKeeps() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 5_999, inactiveFor: 3600, userIdle: 3600, away: true)), .keep)
    }

    @MainActor func testAwayStillWaitsForMedia() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 6_000, inactiveFor: 3600, userIdle: 3600, audio: true,
                                            away: true)), .wait)
        XCTAssertEqual(policy.decide(inputs(surfaces: 12_500, inactiveFor: 3600, audio: true, away: true)), .wait)
    }

    @MainActor func testAwayStillWaitsForRateLimit() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 8_000, inactiveFor: 3600, userIdle: 3600, away: true,
                                            lastRecycleAgo: 60 * 60 - 1)), .wait)
        XCTAssertEqual(policy.decide(inputs(surfaces: 8_000, inactiveFor: 3600, userIdle: 3600, away: true,
                                            lastRecycleAgo: 60 * 60)), .recycle)
    }

    /// Not away, the band between the away and soft limits is untouched: keep,
    /// however long the app has been inactive or the user idle.
    @MainActor func testNotAwayBetweenAwayAndSoftLimitKeeps() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 6_000, inactiveFor: 3600, userIdle: 3600)), .keep)
        XCTAssertEqual(policy.decide(inputs(surfaces: 11_999, inactiveFor: 3600, userIdle: 3600)), .keep)
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
            "DETOUR_GPU_RECYCLE_AWAY_LIMIT": "50",
            "DETOUR_GPU_RECYCLE_SOFT_LIMIT": "100",
            "DETOUR_GPU_RECYCLE_HARD_LIMIT": "200",
            "DETOUR_GPU_RECYCLE_EXHAUSTED_LIMIT": "300",
            "DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS": "5",
            "DETOUR_GPU_RECYCLE_USER_IDLE_SECONDS": "0",
            "DETOUR_GPU_RECYCLE_MIN_INTERVAL_SECONDS": "30",
            "DETOUR_GPU_RECYCLE_BREAKAGE_LIMIT": "250",
            "DETOUR_GPU_RECYCLE_POST_RECYCLE_GRACE_SECONDS": "7",
        ])
        XCTAssertEqual(p, GPUProcessRecyclePolicy(awayLimit: 50, softLimit: 100, hardLimit: 200, exhaustedLimit: 300, inactiveGrace: 5,
                                                  userIdleGrace: 0, minimumInterval: 30, breakageLimit: 250,
                                                  postRecycleGrace: 7))
    }

    @MainActor func testInvalidEnvironmentOverridesAreIgnored() {
        let p = GPUProcessRecyclePolicy.fromEnvironment([
            "DETOUR_GPU_RECYCLE_AWAY_LIMIT": "-6000",
            "DETOUR_GPU_RECYCLE_SOFT_LIMIT": "0",
            "DETOUR_GPU_RECYCLE_HARD_LIMIT": "lots",
            "DETOUR_GPU_RECYCLE_EXHAUSTED_LIMIT": "-5",
            "DETOUR_GPU_RECYCLE_INACTIVE_GRACE_SECONDS": "-1",
            "DETOUR_GPU_RECYCLE_USER_IDLE_SECONDS": "nan",
            "DETOUR_GPU_RECYCLE_MIN_INTERVAL_SECONDS": "inf",
            "DETOUR_GPU_RECYCLE_BREAKAGE_LIMIT": "0",
            "DETOUR_GPU_RECYCLE_POST_RECYCLE_GRACE_SECONDS": "-3",
        ])
        XCTAssertEqual(p, GPUProcessRecyclePolicy())
    }

    // MARK: - A page reports a lost WebGL context (TASK-410)

    @MainActor func testBreakageDefaults() {
        XCTAssertEqual(policy.breakageLimit, 15_000)
        XCTAssertEqual(policy.contextLossWindow, 30)
        XCTAssertEqual(policy.postRecycleGrace, 5 * 60)
    }

    @MainActor func testContextLossNearTheCapRecyclesWhileTheUserIsBusy() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000, contextLossAgo: 1)), .recycle)
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000)), .wait, "without the report, the hard-limit gate stays closed")
    }

    @MainActor func testContextLossRecyclesWithinTheHourAndWhileAudioPlays() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_500, audio: true, contextLossAgo: 2, lastRecycleAgo: 600)), .recycle)
    }

    @MainActor func testContextLossNeverCutsACallOff() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 16_500, capturing: true, contextLossAgo: 1)), .wait)
    }

    @MainActor func testContextLossBelowTheBreakageLimitChangesNothing() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 14_999, contextLossAgo: 1)), .wait)
        XCTAssertEqual(policy.decide(inputs(surfaces: 800, contextLossAgo: 1)), .keep, "a page calling WEBGL_lose_context")
    }

    @MainActor func testAStaleContextLossIsIgnored() {
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000, contextLossAgo: 30)), .recycle)
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000, contextLossAgo: 31)), .wait)
    }

    @MainActor func testContextLossSoonAfterARecycleIsTheRecyclesOwn() {
        // 59 s after the recycle: every WebGL page loses its context then.
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000, contextLossAgo: 1, lastRecycleAgo: 60)), .wait)
        // Reported before the recycle.
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000, contextLossAgo: 20, lastRecycleAgo: 10)), .wait)
        // Past the grace: a new breakage.
        XCTAssertEqual(policy.decide(inputs(surfaces: 15_000, contextLossAgo: 1, lastRecycleAgo: 5 * 60 + 1)), .recycle)
    }

    @MainActor func testIsRecyclesOwn() {
        let recycle = now
        XCTAssertFalse(policy.isRecyclesOwn(reportAt: now, lastRecycleAt: nil))
        XCTAssertTrue(policy.isRecyclesOwn(reportAt: recycle.addingTimeInterval(-1), lastRecycleAt: recycle), "before it")
        XCTAssertTrue(policy.isRecyclesOwn(reportAt: recycle.addingTimeInterval(299), lastRecycleAt: recycle))
        XCTAssertFalse(policy.isRecyclesOwn(reportAt: recycle.addingTimeInterval(300), lastRecycleAt: recycle))
    }

    // MARK: - How often reports start a check (TASK-410)

    @MainActor func testTheFirstReportChecksAtOnce() {
        var throttle = ContextLossCheckThrottle()
        XCTAssertEqual(throttle.report(at: now), .checkNow)
    }

    @MainActor func testAReportInsideTheGapSchedulesOneCheckForItsEnd() {
        var throttle = ContextLossCheckThrottle()
        _ = throttle.report(at: now)
        XCTAssertEqual(throttle.report(at: now.addingTimeInterval(2)), .checkAfter(3))
        XCTAssertEqual(throttle.report(at: now.addingTimeInterval(3)), .none, "rides on the scheduled check")
        XCTAssertEqual(throttle.report(at: now.addingTimeInterval(60)), .none, "until it has fired")
        throttle.scheduledCheckFired(at: now.addingTimeInterval(5))
        XCTAssertEqual(throttle.report(at: now.addingTimeInterval(6)), .checkAfter(4), "the fired check counts as the last one")
    }

    @MainActor func testAReportAfterTheGapChecksAtOnceAgain() {
        var throttle = ContextLossCheckThrottle()
        _ = throttle.report(at: now)
        XCTAssertEqual(throttle.report(at: now.addingTimeInterval(5)), .checkNow)
    }

    // MARK: - Surface counting

    @MainActor func testIOSurfaceCountReadsOwnProcess() {
        XCTAssertNotNil(GPUProcessRecycler.ioSurfaceCount(pid: getpid()))
    }

    @MainActor func testIOSurfaceCountIsNilForMissingProcess() {
        XCTAssertNil(GPUProcessRecycler.ioSurfaceCount(pid: 999_999))
    }
}
