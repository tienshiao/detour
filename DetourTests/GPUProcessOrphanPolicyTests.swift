import XCTest
import WebKit
@testable import Detour

/// TASK-175: which of this app's GPU processes WebKit has abandoned. A GPU
/// process WebKit "terminated" while its main thread was blocked never exits,
/// and every web process still connected to it freezes on its next synchronous
/// call to it.
final class GPUProcessOrphanPolicyTests: XCTestCase {

    private let policy = GPUProcessOrphanPolicy()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func process(_ pid: pid_t, age: TimeInterval) -> GPUProcessTable.Entry {
        .init(pid: pid, startedAt: now.addingTimeInterval(-age))
    }

    /// What two looks `confirmationDelay` apart conclude: the second look's
    /// verdict, given the first look's suspects. `now` is the second look.
    private func confirmed(_ processes: [GPUProcessTable.Entry],
                           current: GPUProcessRecycler.WebKitGPUProcess) -> GPUProcessOrphanPolicy.Verdict {
        let firstLook = now.addingTimeInterval(-policy.confirmationDelay)
        let first = policy.verdict(processes: processes, current: current, suspects: [], now: firstLook)
        XCTAssertEqual(first.orphans, [], "nothing is killed on the first look")
        return policy.verdict(processes: processes, current: current, suspects: first.suspects, now: now)
    }

    // MARK: - What is never an orphan

    func testNothingIsAnOrphanWhenWebKitCouldNotBeAsked() {
        // Not knowing is not "disowned".
        let verdict = confirmed([process(100, age: 3600)], current: .unknown)
        XCTAssertEqual(verdict.orphans, [])
        XCTAssertEqual(verdict.suspects, [])
        XCTAssertNil(verdict.recheckAt)
    }

    func testWhenWebKitHasNoGPUProcessEveryOldOneOfOursIsAnOrphan() {
        // WebKit dropped its GPU process and nothing has asked for another: the
        // one tab is frozen on the process that was dropped, so it never will.
        let young = process(300, age: 3)
        let verdict = confirmed([process(200, age: 75), young], current: .notRunning)
        XCTAssertEqual(verdict.orphans, [process(200, age: 75)])
        XCTAssertEqual(verdict.recheckAt, young.startedAt.addingTimeInterval(policy.minimumAge),
                       "one that is still launching is not named yet either")
    }

    func testTheCurrentGPUProcessIsNeverAnOrphan() {
        let verdict = confirmed([process(100, age: 3600)], current: .running(100))
        XCTAssertEqual(verdict.orphans, [])
        XCTAssertEqual(verdict.suspects, [])
        XCTAssertNil(verdict.recheckAt)
    }

    func testAYoungProcessIsLeftAloneAndLookedAtAgainWhenItIsOldEnough() {
        // Still launching, or just terminated and on its way out.
        let young = process(200, age: 59)
        let verdict = confirmed([process(100, age: 3600), young], current: .running(100))
        XCTAssertEqual(verdict.orphans, [])
        XCTAssertEqual(verdict.recheckAt, young.startedAt.addingTimeInterval(policy.minimumAge))
    }

    // MARK: - Orphans

    func testAnOldProcessThatIsNotTheCurrentOneIsAnOrphan() {
        let verdict = confirmed([process(100, age: 3600), process(200, age: 65)], current: .running(100))
        XCTAssertEqual(verdict.orphans, [process(200, age: 65)])
        XCTAssertNil(verdict.recheckAt)
    }

    func testEveryOldDisownedProcessIsAnOrphan() {
        let processes = [process(100, age: 10), process(200, age: 7200), process(300, age: 66), process(400, age: 5)]
        let verdict = confirmed(processes, current: .running(100))
        XCTAssertEqual(verdict.orphans, [process(200, age: 7200), process(300, age: 66)])
        XCTAssertEqual(verdict.recheckAt, process(400, age: 5).startedAt.addingTimeInterval(policy.minimumAge),
                       "the young one is looked at again")
    }

    func testTheEarliestYoungProcessSetsTheRecheck() {
        let processes = [process(200, age: 10), process(300, age: 40)]
        let verdict = confirmed(processes, current: .running(100))
        XCTAssertEqual(verdict.recheckAt, now.addingTimeInterval(20))
    }

    func testAStartTimeInTheFutureCountsAsYoungAndIsRecheckedWithinOneMinimumAge() {
        // The wall clock was set back after the process started.
        let verdict = confirmed([process(200, age: -3600)], current: .running(100))
        XCTAssertEqual(verdict.orphans, [])
        XCTAssertEqual(verdict.recheckAt, now.addingTimeInterval(policy.minimumAge))
    }

    // MARK: - Two looks

    func testAProcessThatLooksAbandonedIsOnlySuspectedAtFirst() {
        // Its age is wall-clock time. If the Mac slept right after WebKit
        // spawned it, it is a minute old on wake and WebKit has not named it
        // yet: one look cannot tell that from abandoned.
        let old = process(200, age: 75)
        let first = policy.verdict(processes: [old], current: .notRunning, suspects: [], now: now)
        XCTAssertEqual(first.orphans, [])
        XCTAssertEqual(first.suspects, [.init(process: old, since: now)])
        XCTAssertEqual(first.recheckAt, now.addingTimeInterval(policy.confirmationDelay))
    }

    func testASuspectWebKitAdoptsInTheMeantimeIsCleared() {
        let old = process(200, age: 75)
        let first = policy.verdict(processes: [old], current: .notRunning, suspects: [], now: now)
        let later = now.addingTimeInterval(policy.confirmationDelay)
        let second = policy.verdict(processes: [old], current: .running(200), suspects: first.suspects, now: later)
        XCTAssertEqual(second.orphans, [])
        XCTAssertEqual(second.suspects, [])
    }

    func testASecondLookTooSoonConfirmsNothing() {
        // Two web processes reported unresponsive a moment apart: two sweeps.
        let old = process(200, age: 75)
        let first = policy.verdict(processes: [old], current: .notRunning, suspects: [], now: now)
        let second = policy.verdict(processes: [old], current: .notRunning, suspects: first.suspects,
                                    now: now.addingTimeInterval(1))
        XCTAssertEqual(second.orphans, [])
        XCTAssertEqual(second.suspects, first.suspects, "the suspicion keeps its date")
        XCTAssertEqual(second.recheckAt, now.addingTimeInterval(policy.confirmationDelay))
    }

    func testASuspicionIsAboutOneProcessNotOnePid() {
        // The pid was reused by a new GPU process between the looks.
        let first = policy.verdict(processes: [process(200, age: 75)], current: .notRunning, suspects: [], now: now)
        let later = now.addingTimeInterval(policy.confirmationDelay)
        let reused = GPUProcessTable.Entry(pid: 200, startedAt: now.addingTimeInterval(-70))
        let second = policy.verdict(processes: [reused], current: .notRunning, suspects: first.suspects, now: later)
        XCTAssertEqual(second.orphans, [])
        XCTAssertEqual(second.suspects, [.init(process: reused, since: later)])
    }

    func testNotBeingAbleToAskForgetsTheSuspects() {
        let first = policy.verdict(processes: [process(200, age: 75)], current: .notRunning, suspects: [], now: now)
        let second = policy.verdict(processes: [process(200, age: 75)], current: .unknown, suspects: first.suspects,
                                    now: now.addingTimeInterval(policy.confirmationDelay))
        XCTAssertEqual(second.orphans, [])
        XCTAssertEqual(second.suspects, [])
    }

    // MARK: - Kill allowance

    func testThreeKillsAnHourAndNoMore() {
        func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
        XCTAssertEqual(policy.killAllowance(earlierKills: [], now: now), 3)
        XCTAssertEqual(policy.killAllowance(earlierKills: [ago(10), ago(600)], now: now), 1)
        XCTAssertEqual(policy.killAllowance(earlierKills: [ago(10), ago(600), ago(3599)], now: now), 0)
        XCTAssertEqual(policy.killAllowance(earlierKills: [ago(10), ago(600), ago(3600)], now: now), 1,
                       "a kill an hour old no longer counts")
        XCTAssertEqual(policy.killAllowance(earlierKills: [ago(1), ago(2), ago(3), ago(4)], now: now), 0)
    }

    // MARK: - Environment overrides

    func testEnvironmentOverridesTheMinimumAge() {
        XCTAssertEqual(GPUProcessOrphanPolicy.fromEnvironment(["DETOUR_GPU_ORPHAN_MIN_AGE_SECONDS": "5"]).minimumAge, 5)
    }

    func testEnvironmentIgnoresNonsense() {
        for raw in ["", "abc", "-1", "nan", "inf"] {
            XCTAssertEqual(GPUProcessOrphanPolicy.fromEnvironment(["DETOUR_GPU_ORPHAN_MIN_AGE_SECONDS": raw]),
                           GPUProcessOrphanPolicy(), raw)
        }
    }

    // MARK: - The process table

    func testThisProcessIsNotAGPUProcess() {
        XCTAssertNil(GPUProcessTable.entry(pid: getpid(), owner: getpid()))
    }

    func testAMissingProcessHasNoEntry() {
        XCTAssertNil(GPUProcessTable.entry(pid: 999_999, owner: getpid()))
    }

    func testStartTimeOfThisProcessIsInThePast() throws {
        let started = try XCTUnwrap(GPUProcessTable.startTime(of: getpid()))
        XCTAssertLessThan(started, Date())
        XCTAssertGreaterThan(started, Date().addingTimeInterval(-7 * 24 * 3600))
    }

    func testTheResponsibilityLookupResolves() {
        // The reaper tells this app's GPU processes from another app's by the
        // process the system holds responsible for them. If the lookup ever
        // stops resolving, the reaper finds nothing and the freeze of TASK-175
        // is back: fail here first.
        XCTAssertNotNil(GPUProcessTable.responsiblePID(for: getpid()))
    }

    /// The GPU process a live web view reports is found in the process table
    /// and attributed to this process. Skipped when WebKit launches no GPU
    /// process for a plain page in this environment.
    @MainActor
    func testTheGPUProcessOfALiveWebViewIsListedAsOurs() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        webView.loadHTMLString("<canvas id=c></canvas><script>document.getElementById('c').getContext('webgl')</script>",
                               baseURL: nil)
        var pid: pid_t?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            pid = GPUProcessRecycler.gpuProcessIdentifier(of: [webView])
        }
        guard let pid else { throw XCTSkip("no GPU process was launched for the page") }

        let own = GPUProcessTable.ownGPUProcesses()
        XCTAssertTrue(own.contains { $0.pid == pid }, "GPU process \(pid) is not among \(own)")
        let verdict = GPUProcessOrphanPolicy().verdict(processes: own.filter { $0.pid == pid },
                                                       current: .running(pid),
                                                       suspects: [], now: Date().addingTimeInterval(3600))
        XCTAssertEqual(verdict.orphans, [], "the live GPU process is never an orphan, however old")

        // With no web view to ask, the app-wide answer still names it: this is
        // what lets the reaper tell "WebKit has none" from "nobody could say".
        XCTAssertEqual(GPUProcessRecycler.webKitGPUProcess(askedOf: []), .running(pid))
        XCTAssertEqual(GPUProcessRecycler.webKitGPUProcess(askedOf: [webView]), .running(pid))
    }
}
