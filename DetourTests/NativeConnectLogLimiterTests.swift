import XCTest
@testable import Detour

/// The rate limit on `connectNative` attempt logging (TASK-90): a reconnect loop
/// must stay visible in the persisted log without being able to evict the log
/// history that makes it diagnosable. Pure and clock-injected, so every window
/// boundary is exercised exactly rather than by sleeping.
final class NativeConnectLogLimiterTests: XCTestCase {

    private let linesPerWindow = NativeConnectLogLimiter.linesPerWindow
    private let window = NativeConnectLogLimiter.windowDuration
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    private func key(
        profile: String = "Work", extensionID: String = "ext", host: String = "com.example.host"
    ) -> NativeConnectLogLimiter.Key {
        NativeConnectLogLimiter.Key(profileName: profile, extensionID: extensionID, hostName: host)
    }

    /// Admit `count` attempts with the same outcome at the same instant.
    private func admit(
        _ limiter: inout NativeConnectLogLimiter, _ count: Int,
        outcome: NativeConnectLogLimiter.Outcome = .failed,
        at time: Date, key admitKey: NativeConnectLogLimiter.Key? = nil
    ) -> [NativeConnectLogLimiter.Decision] {
        let target = admitKey ?? key()
        return (0..<count).map { _ in limiter.admit(target, outcome: outcome, now: time) }
    }

    func testTheFirstAttemptsOfAWindowAreLoggedInFull() {
        var limiter = NativeConnectLogLimiter()
        let decisions = admit(&limiter, linesPerWindow, at: t0)
        XCTAssertEqual(decisions, Array(repeating: .log, count: linesPerWindow))
    }

    func testAttemptsBeyondTheCapAreSuppressed() {
        var limiter = NativeConnectLogLimiter()
        _ = admit(&limiter, linesPerWindow, at: t0)
        let overflow = admit(&limiter, 20, at: t0.addingTimeInterval(window / 2))
        XCTAssertEqual(overflow, Array(repeating: .suppress, count: 20))
    }

    /// The summary rides on the first attempt of the next window and carries the
    /// breakdown by outcome, so a suppressed storm still says whether the
    /// extension was connecting or being refused.
    func testTheNextWindowReportsWhatWasSuppressedByOutcome() {
        var limiter = NativeConnectLogLimiter()
        _ = admit(&limiter, linesPerWindow, at: t0)
        _ = admit(&limiter, 7, outcome: .failed, at: t0.addingTimeInterval(1))
        _ = admit(&limiter, 3, outcome: .refused, at: t0.addingTimeInterval(2))
        _ = admit(&limiter, 2, outcome: .connected, at: t0.addingTimeInterval(3))

        let rolled = limiter.admit(key(), outcome: .failed, now: t0.addingTimeInterval(window))
        var expected = NativeConnectLogLimiter.Suppressed()
        expected.failed = 7
        expected.refused = 3
        expected.connected = 2
        XCTAssertEqual(rolled, .logReportingSuppressed(expected, interval: window))
        XCTAssertEqual(expected.total, 12)
        // Reported once, and the new window starts logging in full again.
        XCTAssertEqual(limiter.admit(key(), outcome: .failed, now: t0.addingTimeInterval(window)), .log)
    }

    func testARolledWindowThatSuppressedNothingReportsNothing() {
        var limiter = NativeConnectLogLimiter()
        _ = admit(&limiter, linesPerWindow, at: t0)
        XCTAssertEqual(limiter.admit(key(), outcome: .connected, now: t0.addingTimeInterval(window)), .log)
    }

    /// The interval is the age of the window being closed, quiet gap included —
    /// an extension that storms, stops for an hour and tries again reports the
    /// hour, which is why the caller phrases it as "in the last Ns" from this
    /// value rather than from the window constant.
    func testTheReportedIntervalIsTheAgeOfTheClosedWindow() {
        var limiter = NativeConnectLogLimiter()
        _ = admit(&limiter, linesPerWindow + 1, at: t0)
        let rolled = limiter.admit(key(), outcome: .failed, now: t0.addingTimeInterval(3_600))
        var expected = NativeConnectLogLimiter.Suppressed()
        expected.failed = 1
        XCTAssertEqual(rolled, .logReportingSuppressed(expected, interval: 3_600))
    }

    /// One looping extension must not silence another's lines — nor the same
    /// extension's attempts to a different host, or in a different profile.
    func testTheCapIsPerProfileExtensionAndHost() {
        var limiter = NativeConnectLogLimiter()
        _ = admit(&limiter, linesPerWindow + 5, at: t0)
        XCTAssertEqual(limiter.admit(key(), outcome: .failed, now: t0), .suppress)
        XCTAssertEqual(limiter.admit(key(extensionID: "other"), outcome: .failed, now: t0), .log)
        XCTAssertEqual(limiter.admit(key(host: "com.example.other"), outcome: .failed, now: t0), .log)
        XCTAssertEqual(limiter.admit(key(profile: "Personal"), outcome: .failed, now: t0), .log)
    }

    /// A reconnect loop costs a bounded number of lines however fast it runs: the
    /// cap per window plus one summary.
    func testASustainedLoopCostsTheCapPlusOneSummaryPerWindow() {
        var limiter = NativeConnectLogLimiter()
        var logged = 0
        var summaries = 0
        var summarised = 0
        // Four attempts a second for ten windows.
        for index in 0..<Int(window * 4) * 10 {
            let time = t0.addingTimeInterval(Double(index) * 0.25)
            switch limiter.admit(key(), outcome: .failed, now: time) {
            case .log:
                logged += 1
            case .logReportingSuppressed(let suppressed, _):
                logged += 1
                summaries += 1
                summarised += suppressed.total
            case .suppress:
                break
            }
        }
        XCTAssertEqual(logged, linesPerWindow * 10)
        XCTAssertEqual(summaries, 9, "every window but the first opens with the previous one's summary")
        // Nothing is lost but the last window's tally, which the next attempt reports.
        XCTAssertEqual(logged + summarised, Int(window * 4) * 10 - (Int(window * 4) - linesPerWindow))
    }

    func testAClockGoingBackwardsRollsTheWindowRatherThanStallingTheCap() {
        var limiter = NativeConnectLogLimiter()
        _ = admit(&limiter, linesPerWindow + 2, at: t0)
        var expected = NativeConnectLogLimiter.Suppressed()
        expected.failed = 2
        XCTAssertEqual(limiter.admit(key(), outcome: .failed, now: t0.addingTimeInterval(-5)),
                       .logReportingSuppressed(expected, interval: 0))
        XCTAssertEqual(limiter.admit(key(), outcome: .failed, now: t0.addingTimeInterval(-5)), .log)
    }
}
