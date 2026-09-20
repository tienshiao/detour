import XCTest
@testable import Detour

/// The native half of the console-bridge rate limit (TASK-17, reworked into a
/// token bucket with flood detection by TASK-90). Pure and clock-injected, so
/// every boundary is exercised exactly rather than by sleeping.
final class ConsoleBridgeLimiterTests: XCTestCase {

    private let burst = ConsoleBridgeLimiter.burstCapacity
    private let rate = ConsoleBridgeLimiter.sustainedRatePerSecond
    private let reportInterval = ConsoleBridgeLimiter.dropReportInterval
    private let floodDuration = ConsoleBridgeLimiter.floodDuration
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

    /// What a run of the limiter did, so a scenario can be asserted on totals
    /// rather than on a decision at a time.
    private struct Tally {
        var admitted = 0
        var dropped = 0
        /// Every `allowReportingDropped`, as (count, when).
        var reports: [(count: Int, at: Date)] = []
        /// Every `dropReportingFlood`, as (droppedSoFar, since, when).
        var floods: [(droppedSoFar: Int, since: TimeInterval, at: Date)] = []

        var reportedTotal: Int { reports.reduce(0) { $0 + $1.count } }
    }

    /// Feed one message at `time` and fold the decision into `tally`.
    private func feed(_ limiter: inout ConsoleBridgeLimiter, _ tally: inout Tally,
                      at time: Date, id: String = "ext") {
        switch limiter.admit(id, now: time) {
        case .allow:
            tally.admitted += 1
        case .allowReportingDropped(let count, _):
            tally.admitted += 1
            tally.reports.append((count, time))
        case .drop:
            tally.dropped += 1
        case .dropReportingFlood(let droppedSoFar, let since):
            tally.dropped += 1
            tally.floods.append((droppedSoFar, since, time))
        }
    }

    // MARK: - Burst

    func testTheWholeBurstPassesAtOnce() {
        var limiter = ConsoleBridgeLimiter()
        let decisions = admit(&limiter, burst, at: t0)
        XCTAssertEqual(decisions, Array(repeating: .allow, count: burst),
                       "a worker's start-up burst must pass whole")
    }

    func testTheMessageAfterTheBurstDropsInTheSameInstant() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, burst, at: t0)
        XCTAssertEqual(limiter.admit("ext", now: t0), .drop)
    }

    func testTheBucketRefillsAtTheSustainedRate() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, burst + 1, at: t0)
        // One second of quiet buys exactly `rate` more messages, no more.
        let oneSecondLater = t0.addingTimeInterval(1)
        let decisions = admit(&limiter, Int(rate) + 1, at: oneSecondLater)
        XCTAssertEqual(Array(decisions.prefix(Int(rate))), Array(repeating: .allow, count: Int(rate)))
        XCTAssertEqual(decisions.last, .drop)
    }

    // MARK: - Sustained flood

    /// The incident this rework exists for: a steady 20 messages a second, a
    /// fifth of the burst cap, which the old fixed window never touched. The
    /// bucket lets the burst through and then holds the extension to exactly the
    /// sustained rate.
    func testASustainedFloodIsCutToTheSustainedRate() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        let step = 0.05 // 20 messages a second
        let messageCount = 2_400 // 120 s of them
        for index in 0..<messageCount {
            feed(&limiter, &tally, at: t0.addingTimeInterval(Double(index) * step))
        }

        // The bucket empties 6.6 s in (the burst plus what refilled meanwhile),
        // and from there exactly one message in four gets through: 5/s.
        XCTAssertEqual(tally.admitted, 699)
        XCTAssertEqual(tally.dropped, messageCount - 699)
        // Stated as the rule rather than as a number: burst + rate × (time of
        // the last admitted message).
        let lastAdmittedAt = 2_396 * step
        XCTAssertEqual(Double(tally.admitted), Double(burst) + rate * lastAdmittedAt, accuracy: 0.001)
    }

    /// Nothing is lost: what the reports say was dropped is what was dropped.
    /// The final message comes after the flood has stopped, which is what flushes
    /// the tail — an extension that floods and then never logs again keeps its
    /// last few hundred drops unreported, and has nothing left to hide.
    func testEveryDroppedMessageIsEventuallyReported() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        let step = 0.05
        for index in 0..<2_400 {
            feed(&limiter, &tally, at: t0.addingTimeInterval(Double(index) * step))
        }
        XCTAssertGreaterThan(tally.dropped, 0)
        XCTAssertLessThan(tally.reportedTotal, tally.dropped, "the tail is still owed while the flood runs")

        // One more message once the drops have stopped, which reports the rest.
        feed(&limiter, &tally, at: t0.addingTimeInterval(200))
        XCTAssertEqual(tally.reportedTotal, tally.dropped,
                       "the reported counts must add up to every dropped message")
    }

    /// Reports cost a log write of their own, so while the flood runs they are
    /// spaced by `dropReportInterval`. The one exception is the report that ends
    /// a streak, which may come sooner — it is the tail, and nothing else will
    /// ever account for it.
    func testReportsWhileTheFloodRunsAreSpacedByTheReportInterval() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        let step = 0.05
        for index in 0..<2_400 {
            feed(&limiter, &tally, at: t0.addingTimeInterval(Double(index) * step))
        }
        XCTAssertGreaterThan(tally.reports.count, 2, "a 120 s flood reports several times")
        for (previous, next) in zip(tally.reports, tally.reports.dropFirst()) {
            // Slack of a microsecond: the timestamps are sums of 0.05 s steps,
            // and the spacing lands on the interval exactly.
            XCTAssertGreaterThanOrEqual(next.at.timeIntervalSince(previous.at), reportInterval - 1e-6,
                                        "two reports \(next.at.timeIntervalSince(previous.at))s apart")
        }
    }

    // MARK: - Flood detection

    func testTheFloodIsReportedOnceWhenTheDroppingHasRunForTheFloodDuration() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        let step = 0.05
        for index in 0..<2_400 {
            feed(&limiter, &tally, at: t0.addingTimeInterval(Double(index) * step))
        }

        XCTAssertEqual(tally.floods.count, 1, "one signal per incident, however long it runs")
        guard let flood = tally.floods.first else { return }
        // The first drop is at 6.65 s, so the incident is declared at 66.65 s.
        XCTAssertEqual(flood.at.timeIntervalSince(t0), 66.65, accuracy: 0.001)
        XCTAssertEqual(flood.since, floodDuration, accuracy: 0.001)
        XCTAssertEqual(flood.droppedSoFar, 901, "every drop of the streak so far")
    }

    /// A flood that stops for `floodIncidentIdle` and comes back is a new
    /// incident, and is reported again: a loop that returns after a quiet spell
    /// is news.
    func testAFloodAfterAQuietSpellIsANewIncident() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        let step = 0.05
        func flood(startingAt origin: TimeInterval) {
            for index in 0..<2_400 {
                feed(&limiter, &tally, at: t0.addingTimeInterval(origin + Double(index) * step))
            }
        }
        flood(startingAt: 0)
        XCTAssertEqual(tally.floods.count, 1)

        // Quiet for longer than `floodIncidentIdle`, then the same flood again.
        flood(startingAt: 120 + ConsoleBridgeLimiter.floodIncidentIdle + 1)
        XCTAssertEqual(tally.floods.count, 2, "the second incident is reported too")
        XCTAssertEqual(tally.floods[1].since, floodDuration, accuracy: 0.001)
    }

    /// Below the sustained rate nothing is dropped, so nothing is reported and no
    /// incident is ever declared, however long the extension keeps it up.
    func testTrafficBelowTheSustainedRateIsNeverDropped() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        let step = 1 / (rate - 1) // 4 messages a second
        for index in 0..<400 { // 100 s of them
            feed(&limiter, &tally, at: t0.addingTimeInterval(Double(index) * step))
        }
        XCTAssertEqual(tally.admitted, 400)
        XCTAssertEqual(tally.dropped, 0)
        XCTAssertTrue(tally.reports.isEmpty)
        XCTAssertTrue(tally.floods.isEmpty)
    }

    // MARK: - Isolation, clock, forget

    func testTheCapIsPerExtension() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, burst + 10, at: t0, id: "noisy")
        XCTAssertEqual(limiter.admit("noisy", now: t0), .drop)
        XCTAssertEqual(limiter.admit("quiet", now: t0), .allow,
                       "one extension flooding must not silence another's console")
    }

    func testAnIncidentIsPerExtension() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        for index in 0..<2_400 {
            feed(&limiter, &tally, at: t0.addingTimeInterval(Double(index) * 0.05), id: "noisy")
        }
        XCTAssertEqual(tally.floods.count, 1)

        var quiet = Tally()
        for index in 0..<400 {
            feed(&limiter, &quiet, at: t0.addingTimeInterval(Double(index) * 0.25), id: "quiet")
        }
        XCTAssertEqual(quiet.admitted, 400, "the other extension kept its own full bucket")
        XCTAssertTrue(quiet.floods.isEmpty)
    }

    /// A clock that jumps backwards counts as no elapsed time at all: it neither
    /// refills the bucket for free nor stalls the limiter until real time catches
    /// up (the stamps re-anchor, so the next second still buys `rate` messages).
    func testAClockGoingBackwardsNeitherRefillsNorStalls() {
        var limiter = ConsoleBridgeLimiter()
        _ = admit(&limiter, burst + 1, at: t0)
        let backwards = t0.addingTimeInterval(-5)
        XCTAssertEqual(limiter.admit("ext", now: backwards), .drop,
                       "jumping back must not hand out tokens")
        let decisions = admit(&limiter, Int(rate) + 1, at: backwards.addingTimeInterval(1))
        XCTAssertEqual(Array(decisions.prefix(Int(rate))), Array(repeating: .allow, count: Int(rate)),
                       "and must not stall the refill either")
        XCTAssertEqual(decisions.last, .drop)
    }

    func testForgettingAnExtensionClearsItsBucketAndItsIncident() {
        var limiter = ConsoleBridgeLimiter()
        var tally = Tally()
        for index in 0..<2_400 {
            feed(&limiter, &tally, at: t0.addingTimeInterval(Double(index) * 0.05))
        }
        XCTAssertEqual(tally.floods.count, 1)
        // Still empty a hair after the last message of the flood.
        XCTAssertEqual(limiter.admit("ext", now: t0.addingTimeInterval(119.96)), .drop)

        limiter.forget("ext")
        XCTAssertEqual(limiter.admit("ext", now: t0.addingTimeInterval(120)), .allow,
                       "a reloaded context starts from a full bucket")
        // …and its incident is gone with it: the next flood reports again.
        var second = Tally()
        for index in 0..<2_400 {
            feed(&limiter, &second, at: t0.addingTimeInterval(120 + Double(index) * 0.05))
        }
        XCTAssertEqual(second.floods.count, 1)
    }
}
