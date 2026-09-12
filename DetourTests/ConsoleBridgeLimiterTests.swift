import XCTest
@testable import Detour

/// The native half of the console-bridge rate limit (TASK-17). Pure and
/// clock-injected, so every window boundary is exercised exactly rather than by
/// sleeping.
final class ConsoleBridgeLimiterTests: XCTestCase {

    private let cap = ConsoleBridgeLimiter.messagesPerWindow
    private let window = ConsoleBridgeLimiter.windowDuration
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    /// Admit `count` messages at the same instant, returning the decisions.
    private func admit(
        _ limiter: inout ConsoleBridgeLimiter,
        _ count: Int,
        at time: Date,
        id: String = "ext"
    ) -> [ConsoleBridgeLimiter.Decision] {
        (0..<count).map { _ in limiter.admit(id, now: time) }
    }

    func testForwardsEveryMessageUpToTheCap() {
        var limiter = ConsoleBridgeLimiter()
        let decisions = admit(&limiter, cap, at: t0)
        XCTAssertEqual(decisions, Array(repeating: .allow, count: cap))
    }

    func testDropsEveryMessageBeyondTheCapInTheSameWindow() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, cap, at: t0)
        let overflow = admit(&limiter, 5, at: t0.addingTimeInterval(window / 2))
        XCTAssertEqual(overflow, Array(repeating: .drop, count: 5))
    }

    func testTheFirstMessageOfTheNextWindowReportsWhatWasDropped() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, cap + 150, at: t0)
        let next = limiter.admit("ext", now: t0.addingTimeInterval(window))
        XCTAssertEqual(next, .allowReportingDropped(count: 150, interval: window))
        // Reported once, not on every message after it.
        XCTAssertEqual(limiter.admit("ext", now: t0.addingTimeInterval(window)), .allow)
    }

    func testRollingAWindowWithNoDropsReportsNothing() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, cap, at: t0)
        XCTAssertEqual(limiter.admit("ext", now: t0.addingTimeInterval(window)), .allow)
    }

    /// The interval is the age of the window being closed, quiet gap included —
    /// an extension that floods then goes quiet for a minute reports 60s, which
    /// is why the caller phrases it as "window opened Ns ago", never as a rate.
    func testTheReportedIntervalIsTheAgeOfTheClosedWindow() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, cap + 1, at: t0)
        let next = limiter.admit("ext", now: t0.addingTimeInterval(60))
        XCTAssertEqual(next, .allowReportingDropped(count: 1, interval: 60))
    }

    func testTheCapIsPerExtension() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, cap + 10, at: t0, id: "noisy")
        XCTAssertEqual(limiter.admit("noisy", now: t0), .drop)
        XCTAssertEqual(limiter.admit("quiet", now: t0), .allow,
                       "one extension flooding must not silence another's console")
    }

    func testSustainedFloodForwardsTheCapEachWindow() {
        var limiter = ConsoleBridgeLimiter()
        var forwarded = 0
        var reported = 0
        // Ten windows of 1000 messages each: the cap per window gets through, and
        // each window after the first opens with one report of the previous one.
        for windowIndex in 0..<10 {
            let start = t0.addingTimeInterval(window * Double(windowIndex))
            for messageIndex in 0..<1000 {
                // Spread within the window so nothing depends on identical timestamps.
                let time = start.addingTimeInterval(window * Double(messageIndex) / 1000)
                switch limiter.admit("ext", now: time) {
                case .allow: forwarded += 1
                case .allowReportingDropped(let count, _):
                    forwarded += 1
                    reported += count
                case .drop: break
                }
            }
        }
        XCTAssertEqual(forwarded, cap * 10)
        // Every window but the last has had its drops reported by then.
        XCTAssertEqual(reported, (1000 - cap) * 9)
    }

    func testAClockGoingBackwardsRollsTheWindowRatherThanStallingTheCap() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, cap + 3, at: t0)
        let next = limiter.admit("ext", now: t0.addingTimeInterval(-5))
        XCTAssertEqual(next, .allowReportingDropped(count: 3, interval: 0))
        XCTAssertEqual(limiter.admit("ext", now: t0.addingTimeInterval(-5)), .allow)
    }

    func testForgettingAnExtensionClearsItsWindow() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, cap + 4, at: t0)
        XCTAssertEqual(limiter.admit("ext", now: t0), .drop)
        limiter.forget("ext")
        XCTAssertEqual(limiter.admit("ext", now: t0), .allow,
                       "a reloaded context starts from a fresh window")
    }
}
