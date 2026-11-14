import XCTest
@testable import Detour

/// The native half of the automation channel into an extension's background
/// (TASK-228.2), driven by hand: parks, acknowledgements and results as the
/// polyfill sends them, no WebKit. The end-to-end path through a real worker
/// is in `AutomationExtensionTests`.
nonisolated final class AutomationExtensionChannelTests: XCTestCase {

    private var channel: AutomationExtensionChannel!
    private var wakes: [AutomationExtensionChannel.Key] = []
    private let key = AutomationExtensionChannel.Key(extensionID: "ext", profileID: UUID())

    @MainActor override func setUp() async throws {
        try await super.setUp()
        channel = AutomationExtensionChannel()
        // Long enough that a test acknowledges in time; the dead-park test
        // shortens it.
        channel.ackTimeout = .seconds(2)
        wakes = []
        channel.wake = { [weak self] in self?.wakes.append($0) }
        channel.isOpen = true
    }

    @MainActor override func tearDown() async throws {
        channel.isOpen = false
        channel = nil
        try await super.tearDown()
    }

    /// One park's answer, as the polyfill receives it.
    @MainActor private final class ParkReply {
        var value: [String: Any]?
        var error: String?
        var answered: Bool { value != nil || error != nil }
        var command: [String: Any]? { value?["command"] as? [String: Any] }
        var commandID: Int { command?["id"] as? Int ?? -1 }
        var stopped: Bool { value?["stop"] as? Bool == true }
    }

    @MainActor private func park(_ instance: String) -> ParkReply {
        let reply = ParkReply()
        channel.park(key: key, instance: instance) { value, error in
            reply.value = value as? [String: Any]
            reply.error = error
        }
        return reply
    }

    @MainActor private func finish(_ id: Int, value: String) {
        channel.complete(key: key, resultJSON: "{\"id\": \(id), \"ok\": true, \"type\": \"string\", \"value\": \"\(value)\"}")
    }

    @MainActor private func expectFailure(_ task: Task<JSONValue, any Error>, _ code: AutomationErrorCode,
                                          file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("the call should fail with \(code.rawValue)", file: file, line: line)
        } catch let error as AutomationToolError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    @MainActor func testAClosedChannelTellsTheBackgroundToStop() {
        channel.isOpen = false
        XCTAssertTrue(park("a").stopped)
    }

    @MainActor func testACommandGoesToTheParkAndItsResultComesBack() async throws {
        let parked = park("a")
        XCTAssertFalse(parked.answered, "a park waits for a command")
        let call = Task { try await channel.send(key, op: "call", path: "chrome.x", argumentsJSON: "[1]", limit: .seconds(5)) }
        try await waitUntil("the command reaches the park", pollInterval: 0.01) { parked.command != nil }
        let command = try XCTUnwrap(parked.command)
        XCTAssertEqual(command["op"] as? String, "call")
        XCTAssertEqual(command["path"] as? String, "chrome.x")
        XCTAssertEqual(command["args"] as? String, "[1]")
        channel.acknowledge(key: key, instance: "a", commandID: parked.commandID)
        let next = park("a")
        finish(parked.commandID, value: "done")
        let value = try await call.value
        XCTAssertEqual(value["value"], "done")
        XCTAssertFalse(next.answered, "the background parked again for the next command")
        XCTAssertTrue(wakes.isEmpty, "a live park needs no wake")
    }

    /// A call that never settles holds up nothing: the background parks again
    /// as soon as it has taken a command.
    @MainActor func testCommandsRunSideBySide() async throws {
        let first = park("a")
        let slow = Task { try await channel.send(key, op: "call", path: "never", limit: .milliseconds(600)) }
        try await waitUntil("the first command", pollInterval: 0.01) { first.command != nil }
        channel.acknowledge(key: key, instance: "a", commandID: first.commandID)
        let second = park("a")
        let quick = Task { try await channel.send(key, op: "ping", limit: .seconds(5)) }
        try await waitUntil("the second command", pollInterval: 0.01) { second.command != nil }
        channel.acknowledge(key: key, instance: "a", commandID: second.commandID)
        _ = park("a")
        finish(second.commandID, value: "pong")
        let value = try await quick.value
        XCTAssertEqual(value["value"], "pong")
        await expectFailure(slow, .timeout)
    }

    @MainActor func testWithNoParkTheBackgroundIsStartedAndTheCommandWaitsForIt() async throws {
        let call = Task { try await channel.send(key, op: "ping", limit: .seconds(5)) }
        try await waitUntil("the background to be started", pollInterval: 0.01) { wakes == [key] }
        let parked = park("b")
        XCTAssertNotNil(parked.command, "the waiting command goes to the first park")
        channel.acknowledge(key: key, instance: "b", commandID: parked.commandID)
        finish(parked.commandID, value: "pong")
        let value = try await call.value
        XCTAssertEqual(value["value"], "pong")
        XCTAssertTrue(channel.hasParked(key))
    }

    /// A park whose worker WebKit unloaded never acknowledges: the command is
    /// taken back, the background started, and the command sent to the new
    /// worker's park.
    @MainActor func testACommandADeadParkNeverTakesGoesToTheNextStart() async throws {
        channel.ackTimeout = .milliseconds(100)
        let stale = park("old")
        let call = Task { try await channel.send(key, op: "get", path: "self.x", limit: .seconds(5)) }
        try await waitUntil("the command reaches the stale park", pollInterval: 0.01) { stale.command != nil }
        let id = stale.commandID
        try await waitUntil("the missing acknowledgement to start the background", pollInterval: 0.01) { wakes == [key] }
        let fresh = park("new")
        XCTAssertEqual(fresh.commandID, id, "the same command, sent again")
        channel.acknowledge(key: key, instance: "new", commandID: id)
        channel.complete(key: key, resultJSON: "{\"id\": \(id), \"ok\": true, \"type\": \"number\", \"value\": 7}")
        let value = try await call.value
        XCTAssertEqual(value["value"], 7)
    }

    /// A result or an acknowledgement is taken only from the key (verified
    /// extension and profile) the command went to.
    @MainActor func testAnotherBackgroundCannotAnswerTheCommand() async throws {
        let parked = park("a")
        let call = Task { try await channel.send(key, op: "ping", limit: .milliseconds(800)) }
        try await waitUntil("the command reaches the park", pollInterval: 0.01) { parked.command != nil }
        let other = AutomationExtensionChannel.Key(extensionID: "other", profileID: key.profileID)
        channel.acknowledge(key: other, instance: "a", commandID: parked.commandID)
        channel.complete(key: other, resultJSON: "{\"id\": \(parked.commandID), \"ok\": true, \"value\": \"forged\"}")
        await expectFailure(call, .workerNotRunning)
    }

    @MainActor func testANewerStartSupersedesAnOlderPark() {
        let older = park("a")
        let newer = park("b")
        XCTAssertTrue(older.stopped, "the older park is told to stop")
        XCTAssertFalse(newer.answered)
    }

    /// A command the background took and then lost (it restarted while
    /// running it) is not run twice.
    @MainActor func testACommandTakenByAWorkerThatRestartedFails() async throws {
        let parked = park("a")
        let call = Task { try await channel.send(key, op: "call", path: "f", limit: .seconds(5)) }
        try await waitUntil("the command reaches the park", pollInterval: 0.01) { parked.command != nil }
        channel.acknowledge(key: key, instance: "a", commandID: parked.commandID)
        _ = park("a")
        let restarted = park("b")
        await expectFailure(call, .workerNotRunning)
        XCTAssertFalse(restarted.answered, "nothing is sent to the new start")
        finish(parked.commandID, value: "late")   // ignored: the call is over
    }

    @MainActor func testWaitingCommandsFailWhenTheContextUnloadsOrAutomationStops() async throws {
        let call = Task { try await channel.send(key, op: "ping", limit: .seconds(5)) }
        try await waitUntil("the wake", pollInterval: 0.01) { !wakes.isEmpty }
        channel.contextUnloaded(extensionID: key.extensionID, profileID: key.profileID)
        await expectFailure(call, .workerNotRunning)

        let parked = park("a")
        let second = Task { try await channel.send(key, op: "ping", limit: .seconds(5)) }
        try await waitUntil("the command reaches the park", pollInterval: 0.01) { parked.command != nil }
        let waiting = park("a")
        channel.isOpen = false
        XCTAssertTrue(waiting.stopped, "turning automation off stops every park")
        await expectFailure(second, .workerNotRunning)
    }

    @MainActor func testNoParkWithinTheLimitIsWorkerNotRunning() async throws {
        let call = Task { try await channel.send(key, op: "ping", limit: .milliseconds(200)) }
        await expectFailure(call, .workerNotRunning)
        XCTAssertFalse(channel.hasParked(key))
    }
}
