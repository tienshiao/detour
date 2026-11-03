import XCTest
import UserNotifications
@testable import Detour

/// A notification center that holds every `add` until the test releases it,
/// so a test decides when the center answers. A notification shows only when
/// its `add` is released: the worst case, where a removal issued while the
/// `add` was in flight reached the center before the notification did.
@MainActor
final class HeldNotificationCenter: ExtensionNotificationCenter {
    struct AddFailed: Error {}

    private struct HeldAdd {
        let request: UNNotificationRequest
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var held: [HeldAdd] = []
    /// Identifier → title of what is on screen.
    private(set) var shown: [String: String] = [:]
    /// Every identifier passed to `removeNotifications`, in order.
    private(set) var removals: [String] = []
    /// Every identifier passed to `add`, in order.
    private(set) var addedIdentifiers: [String] = []

    var heldCount: Int { held.count }

    func add(_ request: UNNotificationRequest) async throws {
        addedIdentifiers.append(request.identifier)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            held.append(HeldAdd(request: request, continuation: continuation))
        }
    }

    func removeNotifications(withIdentifiers identifiers: [String]) {
        removals.append(contentsOf: identifiers)
        for identifier in identifiers {
            shown.removeValue(forKey: identifier)
        }
    }

    /// Answers the held `add` at `index` (in call order among those still
    /// held), showing its notification unless `failing`.
    func release(at index: Int = 0, failing: Bool = false) {
        let add = held.remove(at: index)
        if failing {
            add.continuation.resume(throwing: AddFailed())
        } else {
            shown[add.request.identifier] = add.request.content.title
            add.continuation.resume()
        }
    }

    /// Answers every held `add` in call order.
    func releaseAll() {
        while !held.isEmpty { release() }
    }
}

/// TASK-234: `notifications.clear` and `notifications.update` issued while the
/// `create` is still adding the notification take effect. These run the
/// manager against `HeldNotificationCenter`; the same orderings from a real
/// extension page and service worker are in `ExtensionNotificationOrderingTests`.
nonisolated final class ExtensionNotificationManagerTests: XCTestCase {

    private static let extA = "notif-ext-a"
    private static let extB = "notif-ext-b"

    private var center: HeldNotificationCenter!
    private var manager: ExtensionNotificationManager!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        center = HeldNotificationCenter()
        manager = ExtensionNotificationManager(center: center)
    }

    @MainActor override func tearDown() async throws {
        center.releaseAll()
        manager = nil
        center = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Calls `create` and returns an expectation fulfilled by its completion,
    /// with the id it answered.
    @MainActor private func startCreate(_ id: String, title: String, extensionID: String = extA)
        -> (done: XCTestExpectation, answeredID: () -> String?) {
        let done = expectation(description: "create \(id) answers")
        var answered: String?
        manager.create(extensionID: extensionID, notificationID: id, options: ["title": title, "message": "m"]) {
            answered = $0
            done.fulfill()
        }
        return (done, { answered })
    }

    @MainActor private func startUpdate(_ id: String, title: String, extensionID: String = extA)
        -> (done: XCTestExpectation, result: () -> Bool?) {
        let done = expectation(description: "update \(id) answers")
        var result: Bool?
        manager.update(extensionID: extensionID, notificationID: id, options: ["title": title, "message": "m"]) {
            result = $0
            done.fulfill()
        }
        return (done, { result })
    }

    @MainActor private func clear(_ id: String, extensionID: String = extA) -> Bool? {
        var result: Bool?
        manager.clear(extensionID: extensionID, notificationID: id) { result = $0 }
        return result
    }

    /// The manager calls `add` from a task, so wait for it to reach the center.
    @MainActor private func waitForHeldAdds(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("\(count) add(s) held by the center", timeout: 5, pollInterval: 0.01,
                            file: file, line: line) { center.heldCount >= count }
    }

    @MainActor private func identifier(_ id: String, extensionID: String = extA) -> String {
        "\(extensionID):\(id)"
    }

    // MARK: - Clear while the create is in flight

    @MainActor func testClearWhileCreateInFlightRemovesTheNotification() async throws {
        let create = startCreate("x", title: "Hello")
        try await waitForHeldAdds(1)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["x": true],
                       "a notification whose add is in flight is listed")

        XCTAssertEqual(clear("x"), true)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), [:], "the clear takes effect at once")

        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(create.answeredID(), "x", "create still answers with its id")
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), [:])
        XCTAssertNil(center.shown[identifier("x")], "the notification the cleared add showed is taken away")
        XCTAssertEqual(center.removals, [identifier("x"), identifier("x")],
                       "once by the clear, once more when the add returns")
    }

    /// The clear is issued before the task that calls `add` has even run.
    @MainActor func testClearBeforeAddIsCalledRemovesTheNotification() async throws {
        let create = startCreate("early", title: "Hello")
        XCTAssertEqual(clear("early"), true)
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), [:])
        XCTAssertTrue(center.shown.isEmpty)
    }

    /// Regression: the ordinary order still works, and a clear after the add
    /// returned removes the notification.
    @MainActor func testClearAfterCreateFinishedRemovesTheNotification() async throws {
        let create = startCreate("done", title: "Hello")
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["done": true])
        XCTAssertEqual(center.shown[identifier("done")], "Hello")

        XCTAssertEqual(clear("done"), true)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), [:])
        XCTAssertTrue(center.shown.isEmpty)
    }

    // MARK: - Update while the create is in flight

    @MainActor func testUpdateWhileCreateInFlightTakesEffect() async throws {
        let create = startCreate("u", title: "Before")
        try await waitForHeldAdds(1)
        let update = startUpdate("u", title: "After")
        try await waitForHeldAdds(2)

        center.releaseAll()
        await fulfillment(of: [create.done, update.done], timeout: 5)
        XCTAssertEqual(update.result(), true, "the in-flight notification exists, so the update applies")
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["u": true])
        XCTAssertEqual(center.shown[identifier("u")], "After")
        XCTAssertTrue(center.removals.isEmpty, "the superseded add must not take the updated notification away")
    }

    /// The first add answering last must not undo the update's bookkeeping.
    /// What ends up on screen is not asserted: the fake shows in answer order,
    /// while the manager relies on the real center applying adds in call order
    /// (the main actor starts the add tasks FIFO), so the newer content wins.
    @MainActor func testUpdateWhileCreateInFlightSurvivesTheFirstAddAnsweringLast() async throws {
        let create = startCreate("late", title: "Before")
        try await waitForHeldAdds(1)
        let update = startUpdate("late", title: "After")
        try await waitForHeldAdds(2)

        center.release(at: 1)
        await fulfillment(of: [update.done], timeout: 5)
        center.release(at: 0)
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["late": true])
        XCTAssertTrue(center.removals.isEmpty)
    }

    @MainActor func testUpdateAfterClearWhileCreateInFlightAnswersFalse() async throws {
        let create = startCreate("gone", title: "Before")
        XCTAssertEqual(clear("gone"), true)
        let update = startUpdate("gone", title: "After")
        await fulfillment(of: [update.done], timeout: 5)
        XCTAssertEqual(update.result(), false, "a cleared notification cannot be updated")

        try await waitForHeldAdds(1)
        center.releaseAll()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(center.addedIdentifiers, [identifier("gone")], "the update added nothing")
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), [:])
        XCTAssertTrue(center.shown.isEmpty)
    }

    @MainActor func testUpdateOfUnknownNotificationAnswersFalse() async throws {
        let update = startUpdate("never", title: "After")
        await fulfillment(of: [update.done], timeout: 5)
        XCTAssertEqual(update.result(), false)
        XCTAssertTrue(center.addedIdentifiers.isEmpty)
    }

    // MARK: - Create, clear, create again

    @MainActor func testCreateClearCreateShowsTheSecondNotification() async throws {
        let first = startCreate("again", title: "First")
        XCTAssertEqual(clear("again"), true)
        let second = startCreate("again", title: "Second")
        try await waitForHeldAdds(2)

        center.releaseAll()
        await fulfillment(of: [first.done, second.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["again": true],
                       "the second create owns the id; the first add returning must not clear it")
        XCTAssertEqual(center.shown[identifier("again")], "Second")
        XCTAssertEqual(center.removals, [identifier("again")], "only the clear removed anything")
    }

    @MainActor func testCreateClearCreateWithTheFirstAddAnsweringLast() async throws {
        let first = startCreate("swap", title: "First")
        XCTAssertEqual(clear("swap"), true)
        try await waitForHeldAdds(1)
        let second = startCreate("swap", title: "Second")
        try await waitForHeldAdds(2)

        center.release(at: 1)
        await fulfillment(of: [second.done], timeout: 5)
        center.release(at: 0)
        await fulfillment(of: [first.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["swap": true])
        XCTAssertEqual(center.removals, [identifier("swap")])
    }

    /// The first add answers before the second create is even made.
    @MainActor func testCreateClearSettleThenCreateAgain() async throws {
        let first = startCreate("seq", title: "First")
        XCTAssertEqual(clear("seq"), true)
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [first.done], timeout: 5)
        XCTAssertTrue(center.shown.isEmpty)

        let second = startCreate("seq", title: "Second")
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [second.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["seq": true])
        XCTAssertEqual(center.shown[identifier("seq")], "Second")
    }

    // MARK: - Failures

    @MainActor func testFailedAddDropsTheEntry() async throws {
        let create = startCreate("fails", title: "Hello")
        try await waitForHeldAdds(1)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["fails": true])

        center.release(failing: true)
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(create.answeredID(), "fails", "create answers with its id even when the center refuses")
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), [:])
    }

    /// An update whose add the center refuses answers false: the failure drops
    /// the notification, so the extension must not be told it was updated.
    @MainActor func testFailedUpdateAnswersFalseAndDropsTheEntry() async throws {
        let create = startCreate("upd-fails", title: "Before")
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [create.done], timeout: 5)

        let update = startUpdate("upd-fails", title: "After")
        try await waitForHeldAdds(1)
        center.release(failing: true)
        await fulfillment(of: [update.done], timeout: 5)
        XCTAssertEqual(update.result(), false)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), [:])
        XCTAssertTrue(center.shown.isEmpty)
    }

    /// A failed add for a superseded create leaves the newer entry alone.
    @MainActor func testFailedSupersededAddLeavesTheNewerEntry() async throws {
        let first = startCreate("mixed", title: "First")
        try await waitForHeldAdds(1)
        let second = startCreate("mixed", title: "Second")
        try await waitForHeldAdds(2)

        center.release(at: 0, failing: true)
        await fulfillment(of: [first.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["mixed": true])
        center.release()
        await fulfillment(of: [second.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["mixed": true])
        XCTAssertEqual(center.shown[identifier("mixed")], "Second")
    }

    // MARK: - Isolation

    /// Another extension clearing the same notification id while A's create is
    /// in flight touches neither A's entry nor A's notification.
    @MainActor func testAnotherExtensionsClearDoesNotCancelTheCreate() async throws {
        let create = startCreate("shared-id", title: "A's")
        try await waitForHeldAdds(1)
        XCTAssertEqual(clear("shared-id", extensionID: Self.extB), true)
        XCTAssertEqual(manager.getAll(extensionID: Self.extB), [:])

        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(manager.getAll(extensionID: Self.extA), ["shared-id": true])
        XCTAssertEqual(center.shown[identifier("shared-id")], "A's")
        XCTAssertEqual(center.removals, [identifier("shared-id", extensionID: Self.extB)])
    }

    @MainActor func testAnotherExtensionsUpdateDoesNotApply() async throws {
        let create = startCreate("shared-id", title: "A's")
        try await waitForHeldAdds(1)
        let update = startUpdate("shared-id", title: "B's", extensionID: Self.extB)
        await fulfillment(of: [update.done], timeout: 5)
        XCTAssertEqual(update.result(), false)

        center.releaseAll()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(center.shown[identifier("shared-id")], "A's")
        XCTAssertEqual(manager.getAll(extensionID: Self.extB), [:])
    }
}
