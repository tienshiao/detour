import Synchronization
import XCTest
@testable import Detour

/// How a `NativeMessagingHost` connection ends, against a real host process
/// (`FakeNativeMessagingHost`).
///
/// TASK-232: a host that writes its reply and exits at once used to have its
/// exit, reported by `Process.terminationHandler` on a thread of its own,
/// race the read loop still reading the reply: the disconnect could reach
/// the owner first. The read loop's end of stream is now the disconnect,
/// joined with the exit status, so the reply always comes first.
nonisolated final class NativeMessagingHostLifecycleTests: XCTestCase {

    private static let extensionID = "abcdefghijklmnopabcdefghijklmnop"

    private var fixture: FakeNativeMessagingHost?
    private var host: NativeMessagingHost?
    /// A second host, for the quit tests; made after `fixture`, so torn down
    /// first (each fixture restores the hosts directory it replaced).
    private var otherFixture: FakeNativeMessagingHost?
    private var otherHost: NativeMessagingHost?
    /// What the host delivered, in order: "message:<n>" or "disconnect:<reason or nil>".
    private var events: [String] = []

    @MainActor override func tearDown() async throws {
        reset()
        try await super.tearDown()
    }

    @MainActor private func reset() {
        NativeMessagingHost.outgoingLimits = .standard
        otherHost?.disconnect()
        otherHost = nil
        otherFixture?.tearDown()
        otherFixture = nil
        host?.disconnect()
        host = nil
        fixture?.tearDown()
        fixture = nil
        events.removeAll()
    }

    @MainActor private func connect(_ behavior: FakeNativeMessagingHost.Behavior,
                                    endTiming: NativeHostEnding.Timing = .init(),
                                    termination: NativeMessagingHost.Termination = .init()) throws {
        let fixture = try FakeNativeMessagingHost(allowing: [Self.extensionID], behavior: behavior)
        self.fixture = fixture
        let host = NativeMessagingHost(hostName: fixture.name, extensionID: Self.extensionID,
                                       endTiming: endTiming, termination: termination)
        host.onMessage = { [weak self] in self?.events.append("message:\(($0 as? [String: Any])?["n"] as? Int ?? -1)") }
        host.onDisconnect = { [weak self] in self?.events.append("disconnect:\($0 ?? "nil")") }
        self.host = host
        try host.connect()
    }

    @MainActor private func frame(_ object: [String: Any]) throws -> Data {
        NativeMessagingHost.encodeMessage(try JSONSerialization.data(withJSONObject: object))
    }

    @MainActor private func waitForDisconnect() async throws {
        try await waitUntil("the host to report the disconnect", pollInterval: 0.01) {
            self.events.contains { $0.hasPrefix("disconnect:") }
        }
    }

    // MARK: - TASK-232: the reply comes before the exit

    /// A one-shot host: it reads the request, writes one reply and exits 0.
    /// The reply is delivered, then the disconnect, every time. The reply is
    /// large enough (256 KB, several pipe buffers) that parsing it takes the
    /// read loop longer than the exit takes to be reported, which is how the
    /// race was lost before the fix (6 of 25 iterations failed).
    @MainActor func testAReplyWrittenBeforeExitIsDeliveredBeforeTheDisconnect() async throws {
        let reply = try frame(["n": 1, "blob": String(repeating: "x", count: 256 * 1024)])
        for iteration in 1...50 {
            try connect(.answersThenExits(reply, status: 0))
            try host?.sendMessage(["request": iteration])
            try await waitForDisconnect()
            // Let anything queued behind the disconnect land too.
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(events, ["message:1", "disconnect:nil"], "iteration \(iteration)")
            reset()
        }
    }

    /// The same with a small reply, the common one-shot shape (this one did
    /// not lose the race in 25 runs before the fix: the window was too small).
    @MainActor func testASmallReplyWrittenBeforeExitIsDeliveredBeforeTheDisconnect() async throws {
        let reply = try frame(["n": 1])
        for iteration in 1...10 {
            try connect(.answersThenExits(reply, status: 0))
            try host?.sendMessage(["request": iteration])
            try await waitForDisconnect()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(events, ["message:1", "disconnect:nil"], "iteration \(iteration)")
            reset()
        }
    }

    /// A host that answers and exits with a failure status: the reply first,
    /// then the disconnect with that status, never a plain end of stream.
    @MainActor func testTheExitStatusIsJoinedToTheEndOfStream() async throws {
        let reply = try frame(["n": 1])
        for iteration in 1...10 {
            try connect(.answersThenExits(reply, status: 3))
            try host?.sendMessage(["request": iteration])
            try await waitForDisconnect()
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(events, ["message:1", "disconnect:Native host exited with status 3"], "iteration \(iteration)")
            reset()
        }
    }

    /// The host exits but a process it started keeps its stdout open, so the
    /// read loop never sees the end of stream: the exit is reported once
    /// `endOfStreamWait` runs out, after the reply.
    @MainActor func testAnExitWithStdoutStillOpenIsReportedAfterTheWait() async throws {
        try connect(.answersThenExitsLeavingStdoutOpen(try frame(["n": 1])),
                    endTiming: .init(endOfStreamWait: 0.3))
        let fixture = try XCTUnwrap(fixture)
        try host?.sendMessage(["request": 1])
        try await waitForDisconnect()
        XCTAssertEqual(events, ["message:1", "disconnect:nil"])
        XCTAssertEqual(fixture.processCount(), 1, "the child holding stdout is still running")
        XCTAssertFalse(host?.isConnected ?? true)
    }

    /// A host that closes stdout and keeps running is reported (without a
    /// status) once `exitStatusWait` runs out, and the teardown ends it.
    @MainActor func testAHostThatClosesStdoutAndKeepsRunningIsReportedAndEnded() async throws {
        try connect(.writesThenClosesStdout(try frame(["n": 1])), endTiming: .init(exitStatusWait: 0.2))
        let fixture = try XCTUnwrap(fixture)
        try await waitForDisconnect()
        XCTAssertEqual(events, ["message:1", "disconnect:nil"])
        try await waitUntil("the host process to be terminated", timeout: 5) { fixture.processCount() == 0 }
    }

    /// After `disconnect()` the owner hears nothing more: not the reply still
    /// in the pipe, not the exit the disconnect causes.
    @MainActor func testNothingIsDeliveredAfterDisconnect() async throws {
        try connect(.answersThenStaysAlive(try frame(["n": 1])))
        let fixture = try XCTUnwrap(fixture)
        try host?.sendMessage(["request": 1])
        host?.disconnect()
        try await waitUntil("the host process to be terminated", timeout: 5) { fixture.processCount() == 0 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(events, [])
    }

    // MARK: - TASK-233: releasing a live host ends its process

    /// A host that answers and then stays alive and silent: once its owner lets
    /// go of the `NativeMessagingHost`, the process is terminated, without
    /// anyone calling `disconnect()`.
    @MainActor func testReleasingALiveSilentHostTerminatesItsProcess() async throws {
        try connect(.answersThenStaysAlive(try frame(["n": 1])))
        try host?.sendMessage(["request": 1])
        try await waitUntil("the reply") { self.events == ["message:1"] }
        let fixture = try XCTUnwrap(fixture)
        try await waitUntil("the host process to be running") { fixture.processCount() == 1 }

        weak var released = host
        host = nil
        XCTAssertNil(released, "the read loop must not keep the host alive while it waits on a silent pipe")
        try await waitUntil("the host process to be terminated", timeout: 5) { fixture.processCount() == 0 }
        XCTAssertEqual(events, ["message:1"], "letting go is not the host going away: no onDisconnect")
    }

    // MARK: - TASK-241: a host that ignores SIGTERM is killed after the grace period

    /// The pids `Termination.onKill` reported, from whatever thread it ran on.
    nonisolated private final class KillLog: Sendable {
        private let pids = Mutex<[pid_t]>([])
        func append(_ pid: pid_t) { pids.withLock { $0.append(pid) } }
        var all: [pid_t] { pids.withLock { $0 } }
    }

    private let killed = KillLog()

    @MainActor private func recordingKills(grace: TimeInterval) -> NativeMessagingHost.Termination {
        .init(grace: grace) { [killed] pid in killed.append(pid) }
    }

    @MainActor private func runningHostPID() async throws -> pid_t {
        let fixture = try XCTUnwrap(fixture)
        try await waitUntil("the host process to be running") { fixture.processCount() == 1 }
        return try XCTUnwrap(fixture.processIDs().first)
    }

    /// `disconnect()` sends SIGTERM, which this host ignores: it is still
    /// running partway through the grace period, and gone, by SIGKILL, soon
    /// after it. The check comes a quarter of the way in, leaving most of the
    /// grace period as margin for a loaded machine's late wake-up.
    @MainActor func testAHostIgnoringSIGTERMIsKilledAfterTheGracePeriod() async throws {
        try connect(.silentIgnoringSIGTERM, termination: recordingKills(grace: 1))
        let fixture = try XCTUnwrap(fixture)
        let pid = try await runningHostPID()
        host?.disconnect()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(fixture.processCount(), 1, "SIGTERM alone does not end this host")
        XCTAssertEqual(killed.all, [])
        // Both: `onKill` runs just after the `kill`, on another thread, so
        // the process can be gone a moment before it is recorded.
        try await waitUntil("the host process to be killed", timeout: 5) {
            !killed.all.isEmpty && fixture.processCount() == 0
        }
        XCTAssertEqual(killed.all, [pid])
    }

    /// Releasing the host runs the teardown from `deinit`: the grace period's
    /// wait does not keep the host alive, and still kills the process.
    @MainActor func testReleasingAHostIgnoringSIGTERMKillsItsProcess() async throws {
        try connect(.silentIgnoringSIGTERM, termination: recordingKills(grace: 0.3))
        let fixture = try XCTUnwrap(fixture)
        let pid = try await runningHostPID()
        weak var released = host
        host = nil
        XCTAssertNil(released, "the SIGKILL wait must not keep the host alive")
        try await waitUntil("the host process to be killed", timeout: 5) {
            !killed.all.isEmpty && fixture.processCount() == 0
        }
        XCTAssertEqual(killed.all, [pid])
    }

    /// A host that exits on SIGTERM, as 1Password's does, is never sent
    /// SIGKILL, even once the grace period is long over.
    @MainActor func testAHostThatExitsOnSIGTERMIsNotKilled() async throws {
        try connect(.silent, termination: recordingKills(grace: 0.3))
        let fixture = try XCTUnwrap(fixture)
        _ = try await runningHostPID()
        host?.disconnect()
        try await waitUntil("the host process to exit", timeout: 5) { fixture.processCount() == 0 }
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(killed.all, [])
    }

    /// A host that has already exited when the teardown runs (it answered and
    /// went away) gets no signal at all.
    @MainActor func testAHostThatAlreadyExitedIsNotKilled() async throws {
        try connect(.answersThenExits(try frame(["n": 1]), status: 0), termination: recordingKills(grace: 0.1))
        try host?.sendMessage(["request": 1])
        try await waitForDisconnect()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(killed.all, [])
    }

    // MARK: - TASK-243: quitting ends every host

    /// The quit path: a live host that exits on SIGTERM and one that ignores
    /// it are both gone, the first by SIGTERM, the second by SIGKILL once the
    /// bounded wait is over, and the call returns soon after that wait.
    @MainActor func testQuitEndsEveryLiveHostIncludingOneIgnoringSIGTERM() async throws {
        try connect(.silent)
        let fixture = try XCTUnwrap(fixture)
        let silentPID = try await runningHostPID()
        let stubborn = try FakeNativeMessagingHost(name: "com.detour.fake_host_test_stubborn",
                                                   allowing: [Self.extensionID], behavior: .silentIgnoringSIGTERM)
        otherFixture = stubborn
        let stubbornHost = NativeMessagingHost(hostName: stubborn.name, extensionID: Self.extensionID)
        otherHost = stubbornHost
        try stubbornHost.connect()
        try await waitUntil("the second host process to be running") { stubborn.processCount() == 1 }
        let stubbornPID = try XCTUnwrap(stubborn.processIDs().first)

        let start = Date()
        let report = NativeMessagingHost.terminateAllSpawnedHosts(within: 0.5, refusingNewHosts: false)
        let elapsed = Date().timeIntervalSince(start)

        // Supersets: a process an earlier test's tearDown killed may not be
        // reaped yet.
        XCTAssertTrue(Set(report.terminated).isSuperset(of: [silentPID, stubbornPID]), "\(report)")
        XCTAssertTrue(report.killed.contains(stubbornPID), "the host ignoring SIGTERM is killed: \(report)")
        XCTAssertFalse(report.killed.contains(silentPID), "the host that exits on SIGTERM is not killed: \(report)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.45, "it waits for the host ignoring SIGTERM")
        XCTAssertLessThan(elapsed, 3, "the wait is bounded (loose: a loaded machine oversleeps)")
        try await waitUntil("both host processes to be gone", timeout: 5) {
            fixture.processCount() == 0 && stubborn.processCount() == 0
        }
        XCTAssertEqual(killed.all, [], "the teardown's own SIGKILL timer played no part")
    }

    /// A host torn down moments before the quit, still inside its SIGKILL
    /// grace period, is killed by the quit rather than left to a timer that
    /// dies with the app.
    @MainActor func testQuitKillsAHostTornDownWithinItsGracePeriod() async throws {
        try connect(.silentIgnoringSIGTERM, termination: recordingKills(grace: 30))
        let fixture = try XCTUnwrap(fixture)
        let pid = try await runningHostPID()
        host?.disconnect()
        host = nil
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(fixture.processCount(), 1, "SIGTERM alone does not end this host")

        let report = NativeMessagingHost.terminateAllSpawnedHosts(within: 0.3, refusingNewHosts: false)

        XCTAssertTrue(report.killed.contains(pid), "\(report)")
        try await waitUntil("the host process to be gone", timeout: 5) { fixture.processCount() == 0 }
        XCTAssertEqual(killed.all, [], "the 30 s timer has not fired")
    }

    /// A host that exits lets go of its SIGKILL timer, and with it the
    /// `Process` and its pipes, at once rather than once the grace period is
    /// over: the timer's handler, which holds `onKill`, is released.
    @MainActor func testAnExitedHostReleasesItsSIGKILLTimer() async throws {
        nonisolated final class Token: Sendable {}
        weak var released: Token?
        do {
            let token = Token()
            released = token
            try connect(.silent, termination: .init(grace: 30) { _ in _ = token })
        }
        let fixture = try XCTUnwrap(fixture)
        _ = try await runningHostPID()
        host?.disconnect()
        host = nil
        try await waitUntil("the host process to exit", timeout: 5) { fixture.processCount() == 0 }
        try await waitUntil("the SIGKILL timer to be released", timeout: 3) { released == nil }
    }

    // MARK: - TASK-265: writes never block the main actor

    /// A JSON string body of exactly `bytes` bytes (the quotes included).
    @MainActor private func stringBody(bytes: Int) -> String {
        String(repeating: "x", count: bytes - 2)
    }

    /// The browser-to-host limits are deliberate values: Chrome's 64 MiB for
    /// a message, room for one such message framed waiting to be written,
    /// and 1 MB from the host.
    @MainActor func testTheMessageLimitsAreChromes() {
        XCTAssertEqual(NativeMessagingHost.OutgoingLimits.standard.maxMessageSize, 64 * 1024 * 1024)
        XCTAssertEqual(NativeMessagingHost.OutgoingLimits.standard.maxPendingBytes, 64 * 1024 * 1024 + 4)
        XCTAssertEqual(NativeMessagingHost.maxIncomingMessageSize, 1024 * 1024)
    }

    /// A host that never reads its stdin (`exec sleep`), sent 4 MB, sixty
    /// times the pipe's buffer: every `sendMessage` returns at once, the
    /// bytes wait off the main actor, and `disconnect()` still ends the host.
    /// Before TASK-265 the first write past the buffer blocked the main
    /// thread for as long as the host lived.
    @MainActor func testSendingSeveralMegabytesToAHostThatNeverReadsDoesNotBlock() async throws {
        try connect(.silent)
        let fixture = try XCTUnwrap(fixture)
        let pid = try await runningHostPID()
        let safety = killing(pid, after: 10)
        defer { safety.cancel() }

        let blob = stringBody(bytes: 512 * 1024)
        let start = Date()
        for n in 1...8 {
            try host?.sendMessage(["n": n, "blob": blob])
        }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2, "queued, not written in place (loose: a loaded machine)")
        XCTAssertEqual(fixture.processCount(), 1, "the safety kill did not have to unblock a write")
        XCTAssertGreaterThan(host?.pendingWriteBytes ?? 0, 3 * 1024 * 1024,
                             "the host reads nothing, so nearly all of it is still waiting")
        XCTAssertTrue(host?.isConnected ?? false)

        host?.disconnect()
        try await waitUntil("the host process to exit", timeout: 5) { fixture.processCount() == 0 }
        XCTAssertEqual(events, [])
    }

    /// The quit sweep with writes waiting on a host that never reads and
    /// ignores SIGTERM: it returns once its bounded wait is over, having
    /// killed the host, as without the writes.
    @MainActor func testQuitEndsAHostThatNeverReadsWithWritesWaiting() async throws {
        try connect(.silentIgnoringSIGTERM)
        let fixture = try XCTUnwrap(fixture)
        let pid = try await runningHostPID()
        let safety = killing(pid, after: 10)
        defer { safety.cancel() }
        let blob = stringBody(bytes: 1024 * 1024)
        for n in 1...4 {
            try host?.sendMessage(["n": n, "blob": blob])
        }
        XCTAssertGreaterThan(host?.pendingWriteBytes ?? 0, 3 * 1024 * 1024)

        let start = Date()
        let report = NativeMessagingHost.terminateAllSpawnedHosts(within: 0.5, refusingNewHosts: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(report.killed.contains(pid), "\(report)")
        XCTAssertLessThan(elapsed, 3, "the wait is bounded (loose: a loaded machine oversleeps)")
        try await waitUntil("the host process to be gone", timeout: 5) { fixture.processCount() == 0 }
        // The waiting writes fail once the host is gone, and that ends the
        // connection like any write to a host that went away.
        try await waitForDisconnect()
        XCTAssertFalse(host?.isConnected ?? true)
    }

    /// Messages reach the host in the order they were sent: forty of them,
    /// every other one 200 KB, through a host that echoes them back.
    @MainActor func testMessagesReachTheHostInOrder() async throws {
        try connect(.echoes)
        let blob = stringBody(bytes: 200 * 1024)
        for n in 1...40 {
            let message: [String: Any] = n.isMultiple(of: 2) ? ["n": n, "blob": blob] : ["n": n]
            try host?.sendMessage(message)
        }
        try await waitUntil("every echo", timeout: 10) { self.events.count >= 40 }
        XCTAssertEqual(events, (1...40).map { "message:\($0)" })
    }

    /// A body over `maxMessageSize` is refused and nothing is written: the
    /// connection stays usable, and the next message gets through.
    @MainActor func testAMessageOverTheLimitIsRefusedAndNothingIsWritten() async throws {
        NativeMessagingHost.outgoingLimits = .init(maxMessageSize: 1000, maxPendingBytes: 10_000)
        try connect(.echoes)
        XCTAssertNoThrow(try host?.sendMessage(stringBody(bytes: 1000)), "the limit itself is allowed")
        XCTAssertThrowsError(try host?.sendMessage(stringBody(bytes: 1001))) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError, .messageTooLarge(1001))
        }
        try host?.sendMessage(["n": 7])
        try await waitUntil("both echoes") { self.events.count >= 2 }
        XCTAssertEqual(events, ["message:-1", "message:7"], "the refused message never reached the host")
        XCTAssertTrue(host?.isConnected ?? false)
    }

    /// What waits for a host that never reads is bounded: a message that
    /// would take it past `maxPendingBytes` is refused. A frame counts until
    /// it is completely written, so with a 200 KB frame stuck behind the
    /// pipe's 64 KB buffer the third is the one refused.
    @MainActor func testWhatWaitsForAHostThatNeverReadsIsBounded() async throws {
        NativeMessagingHost.outgoingLimits = .init(maxMessageSize: 300_000, maxPendingBytes: 500_000)
        try connect(.silent)
        let fixture = try XCTUnwrap(fixture)
        let pid = try await runningHostPID()
        let safety = killing(pid, after: 10)
        defer { safety.cancel() }
        let body = stringBody(bytes: 200_000)
        try host?.sendMessage(body)
        try host?.sendMessage(body)
        XCTAssertEqual(host?.pendingWriteBytes, 2 * 200_004)
        XCTAssertThrowsError(try host?.sendMessage(body)) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError, .sendQueueFull)
        }
        XCTAssertEqual(host?.pendingWriteBytes, 2 * 200_004, "nothing of the refused one is queued")
        XCTAssertEqual(fixture.processCount(), 1)
        host?.disconnect()
        try await waitUntil("the host process to exit", timeout: 5) { fixture.processCount() == 0 }
    }

    /// A host that closed its stdin and is still running: the write fails
    /// with EPIPE off the main actor, which ends the connection with that
    /// reason and the process with it. SIGPIPE is set back to its default
    /// (death) for the write, so the test host itself shows the write does
    /// not raise it: the descriptor has F_SETNOSIGPIPE, beside `main.swift`
    /// ignoring the signal process-wide.
    @MainActor func testAWriteToAHostThatClosedItsStdinEndsTheConnectionWithoutSIGPIPE() async throws {
        try connect(.closesStdin)
        let fixture = try XCTUnwrap(fixture)
        _ = try await runningHostPID()
        let previous = signal(SIGPIPE, SIG_DFL)
        defer { signal(SIGPIPE, previous) }
        try host?.sendMessage(["n": 1])
        try await waitForDisconnect()
        XCTAssertEqual(events, ["disconnect:Native host write failed: \(String(cString: strerror(EPIPE)))"])
        try await waitUntil("the host process to be terminated", timeout: 5) { fixture.processCount() == 0 }
        XCTAssertThrowsError(try host?.sendMessage(["n": 2])) { error in
            XCTAssertEqual(error as? NativeMessagingHost.NativeMessagingError, .notConnected)
        }
    }

    // MARK: - The join, without a process

    @MainActor func testTheEndOfStreamWaitsForTheExitStatus() {
        var ending = NativeHostEnding()
        XCTAssertEqual(ending.handle(.endOfStream), .wait(0.5))
        XCTAssertEqual(ending.handle(.processExited(status: 2)), .report("Native host exited with status 2"))
        XCTAssertEqual(ending.handle(.waitExpired), .none, "a reported end is final")
    }

    @MainActor func testTheExitWaitsForTheEndOfStream() {
        var ending = NativeHostEnding()
        XCTAssertEqual(ending.handle(.processExited(status: 0)), .wait(5))
        XCTAssertEqual(ending.handle(.endOfStream), .report(nil))
        XCTAssertEqual(ending.handle(.waitExpired), .none)
    }

    @MainActor func testAnExpiredWaitReportsWhatItHas() {
        var exitOnly = NativeHostEnding()
        _ = exitOnly.handle(.processExited(status: 9))
        XCTAssertEqual(exitOnly.handle(.waitExpired), .report("Native host exited with status 9"))
        XCTAssertEqual(exitOnly.handle(.endOfStream), .none)

        var endOnly = NativeHostEnding()
        _ = endOnly.handle(.endOfStream)
        XCTAssertEqual(endOnly.handle(.waitExpired), .report(nil))
        XCTAssertEqual(endOnly.handle(.processExited(status: 15)), .none,
                       "the teardown's SIGTERM is not the host's own exit")
    }

    @MainActor func testAFailureIsReportedAtOnceAndWins() {
        var ending = NativeHostEnding()
        XCTAssertEqual(ending.handle(.failed("Incomplete message read")), .report("Incomplete message read"))
        XCTAssertEqual(ending.handle(.processExited(status: 1)), .none)
        XCTAssertEqual(ending.handle(.endOfStream), .none)

        var afterExit = NativeHostEnding()
        _ = afterExit.handle(.processExited(status: 1))
        XCTAssertEqual(afterExit.handle(.failed("Invalid message length: 0")), .report("Invalid message length: 0"))
    }

    /// A failed write means the host is gone, not that the stream is done:
    /// it waits for the end of stream like an exit, so a reply still in the
    /// pipe is delivered first, and its reason wins over the exit status.
    @MainActor func testAFailedWriteWaitsForTheEndOfStream() {
        var ending = NativeHostEnding()
        XCTAssertEqual(ending.handle(.processExited(status: 0)), .wait(5))
        XCTAssertEqual(ending.handle(.writeFailed("Native host write failed: x")), .wait(5))
        XCTAssertEqual(ending.handle(.endOfStream), .report("Native host write failed: x"))
        XCTAssertEqual(ending.handle(.waitExpired), .none)

        var exitAfter = NativeHostEnding()
        XCTAssertEqual(exitAfter.handle(.writeFailed("w")), .wait(5))
        XCTAssertEqual(exitAfter.handle(.processExited(status: 15)), .wait(5),
                       "the teardown's SIGTERM still waits for the end of stream")
        XCTAssertEqual(exitAfter.handle(.endOfStream), .report("w"))

        var afterEnd = NativeHostEnding()
        _ = afterEnd.handle(.endOfStream)
        XCTAssertEqual(afterEnd.handle(.writeFailed("w")), .report("w"))

        var neverEnds = NativeHostEnding()
        _ = neverEnds.handle(.writeFailed("w"))
        XCTAssertEqual(neverEnds.handle(.waitExpired), .report("w"))
    }

    @MainActor func testAWaitThatExpiresBeforeEitherSignalDoesNothing() {
        var ending = NativeHostEnding(timing: .init(exitStatusWait: 1, endOfStreamWait: 2))
        XCTAssertEqual(ending.handle(.waitExpired), .none)
        XCTAssertEqual(ending.handle(.endOfStream), .wait(1))
        XCTAssertFalse(ending.isReported)
    }
}
