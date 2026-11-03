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
    /// What the host delivered, in order: "message:<n>" or "disconnect:<reason or nil>".
    private var events: [String] = []

    @MainActor override func tearDown() async throws {
        reset()
        try await super.tearDown()
    }

    @MainActor private func reset() {
        host?.disconnect()
        host = nil
        fixture?.tearDown()
        fixture = nil
        events.removeAll()
    }

    @MainActor private func connect(_ behavior: FakeNativeMessagingHost.Behavior,
                                    endTiming: NativeHostEnding.Timing = .init()) throws {
        let fixture = try FakeNativeMessagingHost(allowing: [Self.extensionID], behavior: behavior)
        self.fixture = fixture
        let host = NativeMessagingHost(hostName: fixture.name, extensionID: Self.extensionID, endTiming: endTiming)
        host.onMessage = { [weak self] in self?.events.append("message:\($0["n"] as? Int ?? -1)") }
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
