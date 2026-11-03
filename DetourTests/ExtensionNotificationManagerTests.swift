import XCTest
import UserNotifications
import WebKit
import GRDB
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
    /// Every request passed to `add`, in order.
    private(set) var addedRequests: [UNNotificationRequest] = []

    var heldCount: Int { held.count }

    /// False: every `add` answers at once and shows its notification, for a
    /// test about who sees what rather than about ordering.
    var holdsAdds = true

    func add(_ request: UNNotificationRequest) async throws {
        addedIdentifiers.append(request.identifier)
        addedRequests.append(request)
        if !holdsAdds {
            shown[request.identifier] = request.content.title
            return
        }
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
/// TASK-238: one manager serves every profile, and the same extension in two
/// profiles is two owners that never see or touch each other's notifications;
/// identifiers are opaque; an owner's notifications go with its extension,
/// its profile, and (for Private) the Private session.
nonisolated final class ExtensionNotificationManagerTests: XCTestCase {

    private static let extA = "notif-ext-a"
    private static let extB = "notif-ext-b"
    private static let profile1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let profile2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    /// extA in profile 1: the owner the ordering tests act as.
    private static let ownerA = ExtensionNotificationManager.Owner(profileID: profile1, extensionID: extA)
    /// Another extension in the same profile.
    private static let ownerB = ExtensionNotificationManager.Owner(profileID: profile1, extensionID: extB)
    /// The same extension as `ownerA` in another profile (TASK-238).
    private static let ownerA2 = ExtensionNotificationManager.Owner(profileID: profile2, extensionID: extA)

    private var center: HeldNotificationCenter!
    private var manager: ExtensionNotificationManager!
    /// The identifier each (owner, id) was last created under, by `startCreate`.
    private var createdIdentifiers: [String: String] = [:]

    @MainActor override func setUp() async throws {
        try await super.setUp()
        center = HeldNotificationCenter()
        manager = ExtensionNotificationManager(center: center)
    }

    @MainActor override func tearDown() async throws {
        center.releaseAll()
        manager = nil
        center = nil
        createdIdentifiers.removeAll()
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Calls `create` and returns an expectation fulfilled by its completion,
    /// the id it answered, and the identifier the manager recorded it under.
    @MainActor private func startCreate(_ id: String, title: String, owner: ExtensionNotificationManager.Owner = ownerA)
        -> (done: XCTestExpectation, answeredID: () -> String?, identifier: String) {
        let done = expectation(description: "create \(id) answers")
        var answered: String?
        manager.create(owner: owner, notificationID: id, options: ["title": title, "message": "m"]) {
            answered = $0
            done.fulfill()
        }
        // The entry is recorded synchronously, before the add.
        let identifier = manager.identifier(for: owner, notificationID: id) ?? "missing \(id)"
        createdIdentifiers[Self.key(id, owner)] = identifier
        return (done, { answered }, identifier)
    }

    @MainActor private static func key(_ id: String, _ owner: ExtensionNotificationManager.Owner) -> String {
        "\(owner.profileID.uuidString)|\(owner.extensionID)|\(id)"
    }

    @MainActor private func startUpdate(_ id: String, title: String, owner: ExtensionNotificationManager.Owner = ownerA)
        -> (done: XCTestExpectation, result: () -> Bool?) {
        let done = expectation(description: "update \(id) answers")
        var result: Bool?
        manager.update(owner: owner, notificationID: id, options: ["title": title, "message": "m"]) {
            result = $0
            done.fulfill()
        }
        return (done, { result })
    }

    @MainActor private func clear(_ id: String, owner: ExtensionNotificationManager.Owner = ownerA) -> Bool? {
        var result: Bool?
        manager.clear(owner: owner, notificationID: id) { result = $0 }
        return result
    }

    /// The manager calls `add` from a task, so wait for it to reach the center.
    @MainActor private func waitForHeldAdds(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("\(count) add(s) held by the center", timeout: 5, pollInterval: 0.01,
                            file: file, line: line) { center.heldCount >= count }
    }

    /// The identifier `owner`'s `id` was last created under. Identifiers are
    /// opaque, so a test can only learn them from the manager.
    @MainActor private func identifier(_ id: String, owner: ExtensionNotificationManager.Owner = ownerA) -> String {
        createdIdentifiers[Self.key(id, owner)] ?? "never created \(id)"
    }

    // MARK: - The test host never posts to the system center (TASK-249)

    /// `shared` is what every handler without an override uses. In the test
    /// host it must be the bundle-start fake, or a run delivers real banners.
    @MainActor func testTestHostSharedManagerPostsToTheTestCenter() async throws {
        let shared = ExtensionNotificationManager.shared
        XCTAssertTrue(shared.centerForTesting === TestHostNotificationCenter.shared,
                      "shared must use the test-host center installed at bundle start")
        XCTAssertFalse(shared.centerForTesting is SystemExtensionNotificationCenter)

        let owner = ExtensionNotificationManager.Owner(profileID: UUID(), extensionID: "task249")
        let done = expectation(description: "create answers")
        shared.create(owner: owner, notificationID: "probe", options: ["title": "T", "message": "m"]) { _ in
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
        let identifier = try XCTUnwrap(shared.identifier(for: owner, notificationID: "probe"))
        XCTAssertNotNil(TestHostNotificationCenter.shared.shown[identifier])
        shared.removeAll(for: owner)
        XCTAssertNil(TestHostNotificationCenter.shared.shown[identifier])
    }

    // MARK: - Clear while the create is in flight

    @MainActor func testClearWhileCreateInFlightRemovesTheNotification() async throws {
        let create = startCreate("x", title: "Hello")
        try await waitForHeldAdds(1)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["x": true],
                       "a notification whose add is in flight is listed")

        XCTAssertEqual(clear("x"), true)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:], "the clear takes effect at once")

        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(create.answeredID(), "x", "create still answers with its id")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
        XCTAssertTrue(center.shown.isEmpty)
    }

    /// Regression: the ordinary order still works, and a clear after the add
    /// returned removes the notification.
    @MainActor func testClearAfterCreateFinishedRemovesTheNotification() async throws {
        let create = startCreate("done", title: "Hello")
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["done": true])
        XCTAssertEqual(center.shown[identifier("done")], "Hello")

        XCTAssertEqual(clear("done"), true)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["u": true])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["late": true])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["again": true],
                       "the second create owns the id; the first add returning must not clear it")
        XCTAssertNotEqual(first.identifier, second.identifier, "a re-created notification gets a new identifier")
        XCTAssertEqual(center.shown, [second.identifier: "Second"])
        XCTAssertEqual(center.removals, [first.identifier, first.identifier],
                       "the clear, then the first add returning takes away only what it showed")
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["swap": true])
        XCTAssertEqual(center.shown, [second.identifier: "Second"])
        XCTAssertEqual(center.removals, [first.identifier, first.identifier])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["seq": true])
        XCTAssertEqual(center.shown[identifier("seq")], "Second")
    }

    // MARK: - What clear answers (TASK-240)

    /// Chrome's clear "resolves to indicate whether a matching notification
    /// existed": false for an id the owner never created or already cleared.
    @MainActor func testClearOfAMissingNotificationAnswersFalse() async throws {
        XCTAssertEqual(clear("never"), false)
        XCTAssertTrue(center.removals.isEmpty, "nothing to take away")

        let create = startCreate("once", title: "Hello")
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(clear("once"), true, "the notification existed")
        XCTAssertEqual(clear("once"), false, "the second clear finds nothing")
    }

    /// A notification whose add the center refused no longer exists.
    @MainActor func testClearAfterAFailedAddAnswersFalse() async throws {
        let create = startCreate("refused", title: "Hello")
        try await waitForHeldAdds(1)
        center.release(failing: true)
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(clear("refused"), false)
    }

    /// The owner's clear answers true for its own in-flight notification while
    /// another extension's and another profile's copy's clear of the same id
    /// answer false.
    @MainActor func testClearAnswersOnlyForTheOwnersNotification() async throws {
        let create = startCreate("mine", title: "A's")
        XCTAssertEqual(clear("mine", owner: Self.ownerB), false)
        XCTAssertEqual(clear("mine", owner: Self.ownerA2), false)
        XCTAssertEqual(clear("mine"), true, "in flight counts as existing")
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [create.done], timeout: 5)
    }

    // MARK: - Update merges (TASK-240)

    /// An update that gives only some fields keeps the rest, as Chrome's
    /// `UpdateNotification` applies only the fields passed.
    @MainActor func testUpdateMergesTheGivenFieldsIntoTheNotification() async throws {
        center.holdsAdds = false
        let created = expectation(description: "create answers")
        manager.create(owner: Self.ownerA, notificationID: "m",
                       options: ["type": "basic", "title": "Title", "message": "First",
                                 "contextMessage": "Context", "iconUrl": "icon.png"]) { _ in created.fulfill() }
        await fulfillment(of: [created], timeout: 5)

        let updated = expectation(description: "update answers")
        var result: Bool?
        manager.update(owner: Self.ownerA, notificationID: "m", options: ["message": "Second"]) {
            result = $0
            updated.fulfill()
        }
        await fulfillment(of: [updated], timeout: 5)
        XCTAssertEqual(result, true)
        let content = try XCTUnwrap(center.addedRequests.last?.content)
        XCTAssertEqual(content.title, "Title", "a field the update did not give is kept")
        XCTAssertEqual(content.body, "Second", "a field the update gave replaces the old one")
        XCTAssertEqual(content.subtitle, "Context")

        let again = expectation(description: "second update answers")
        manager.update(owner: Self.ownerA, notificationID: "m",
                       options: ["title": "New title", "contextMessage": NSNull()]) { _ in again.fulfill() }
        await fulfillment(of: [again], timeout: 5)
        let last = try XCTUnwrap(center.addedRequests.last?.content)
        XCTAssertEqual(last.title, "New title")
        XCTAssertEqual(last.body, "Second", "updates compose: the first update's message is kept")
        XCTAssertEqual(last.subtitle, "Context", "a null field counts as not given")
        let shownUnder = try XCTUnwrap(manager.identifier(for: Self.ownerA, notificationID: "m"))
        XCTAssertEqual(Set(center.addedIdentifiers), [shownUnder], "every update replaces the same banner")
    }

    /// An update issued while the create is in flight merges into the
    /// create's options, not into nothing.
    @MainActor func testUpdateWhileCreateInFlightMergesIntoTheCreatesOptions() async throws {
        let create = startCreate("inflight", title: "Kept")
        let updated = expectation(description: "update answers")
        manager.update(owner: Self.ownerA, notificationID: "inflight", options: ["message": "Changed"]) { _ in
            updated.fulfill()
        }
        try await waitForHeldAdds(2)
        center.releaseAll()
        await fulfillment(of: [create.done, updated], timeout: 5)
        let content = try XCTUnwrap(center.addedRequests.last?.content)
        XCTAssertEqual(content.title, "Kept")
        XCTAssertEqual(content.body, "Changed")
    }

    // MARK: - Content mapping (TASK-240)

    /// title → title, message → body, contextMessage → subtitle (Chrome's
    /// macOS bridge shows contextMessage there); iconUrl is not shown, and
    /// in particular never as the subtitle.
    @MainActor func testOptionsMapToTheNotificationContent() {
        let full = ExtensionNotificationManager.content(for: [
            "type": "basic", "title": "T", "message": "M", "contextMessage": "C", "iconUrl": "icons/48.png",
        ])
        XCTAssertEqual(full.title, "T")
        XCTAssertEqual(full.body, "M")
        XCTAssertEqual(full.subtitle, "C")
        XCTAssertTrue(full.attachments.isEmpty)

        let noContext = ExtensionNotificationManager.content(for: ["title": "T", "message": "M", "iconUrl": "icons/48.png"])
        XCTAssertEqual(noContext.subtitle, "", "the icon URL is never shown as the subtitle")
        XCTAssertNil(noContext.sound)
        XCTAssertTrue(noContext.userInfo.isEmpty, "nothing that could name the profile")
        XCTAssertEqual(noContext.threadIdentifier, "")
    }

    // MARK: - Failures

    @MainActor func testFailedAddDropsTheEntry() async throws {
        let create = startCreate("fails", title: "Hello")
        try await waitForHeldAdds(1)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["fails": true])

        center.release(failing: true)
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(create.answeredID(), "fails", "create answers with its id even when the center refuses")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
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
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["mixed": true])
        center.release()
        await fulfillment(of: [second.done], timeout: 5)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["mixed": true])
        XCTAssertEqual(center.shown[identifier("mixed")], "Second")
    }

    // MARK: - Isolation

    /// Another extension clearing the same notification id while A's create is
    /// in flight touches neither A's entry nor A's notification.
    @MainActor func testAnotherExtensionsClearDoesNotCancelTheCreate() async throws {
        let create = startCreate("shared-id", title: "A's")
        try await waitForHeldAdds(1)
        XCTAssertEqual(clear("shared-id", owner: Self.ownerB), false,
                       "B has no notification shared-id, so its clear answers false (TASK-240)")
        XCTAssertEqual(manager.getAll(owner: Self.ownerB), [:])

        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["shared-id": true])
        XCTAssertEqual(center.shown[identifier("shared-id")], "A's")
        XCTAssertEqual(center.removals, [], "B has no such notification, so nothing is taken away")
    }

    @MainActor func testAnotherExtensionsUpdateDoesNotApply() async throws {
        let create = startCreate("shared-id", title: "A's")
        try await waitForHeldAdds(1)
        let update = startUpdate("shared-id", title: "B's", owner: Self.ownerB)
        await fulfillment(of: [update.done], timeout: 5)
        XCTAssertEqual(update.result(), false)

        center.releaseAll()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(center.shown[identifier("shared-id")], "A's")
        XCTAssertEqual(manager.getAll(owner: Self.ownerB), [:])
    }

    // MARK: - Profile isolation (TASK-238)

    /// The same extension in another profile is another owner: each lists only
    /// its own notifications, and the same id is two notifications on screen.
    @MainActor func testTheSameExtensionInAnotherProfileListsOnlyItsOwn() async throws {
        let createdA = startCreate("x", title: "A's")
        let onlyA = startCreate("only-a", title: "A's only")
        let createdA2 = startCreate("x", title: "A2's", owner: Self.ownerA2)
        try await waitForHeldAdds(3)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), ["x": true], "in flight, A2 sees only its own")

        center.releaseAll()
        await fulfillment(of: [createdA.done, onlyA.done, createdA2.done], timeout: 5)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["x": true, "only-a": true])
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), ["x": true])
        XCTAssertEqual(manager.getAll(owner: Self.ownerB), [:])
        XCTAssertNotEqual(identifier("x"), identifier("x", owner: Self.ownerA2))
        XCTAssertEqual(center.shown[identifier("x")], "A's", "A2's create must not replace A's banner")
        XCTAssertEqual(center.shown[identifier("x", owner: Self.ownerA2)], "A2's")
    }

    /// Another profile's copy of the extension clearing the same id while A's
    /// create is in flight cancels nothing, and removes only its own identifier.
    @MainActor func testAnotherProfilesClearDoesNotCancelTheCreate() async throws {
        let create = startCreate("x", title: "A's")
        try await waitForHeldAdds(1)
        XCTAssertEqual(clear("x", owner: Self.ownerA2), false,
                       "A2 has no notification x, so its clear answers false (TASK-240)")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["x": true])

        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["x": true])
        XCTAssertEqual(center.shown[identifier("x")], "A's")
        XCTAssertEqual(center.removals, [], "A2 has no such notification, so nothing is taken away")
    }

    @MainActor func testAnotherProfilesUpdateDoesNotApply() async throws {
        let create = startCreate("x", title: "A's")
        try await waitForHeldAdds(1)
        center.release()
        await fulfillment(of: [create.done], timeout: 5)

        let update = startUpdate("x", title: "A2's", owner: Self.ownerA2)
        await fulfillment(of: [update.done], timeout: 5)
        XCTAssertEqual(update.result(), false, "A2 has no notification x")
        XCTAssertEqual(center.addedIdentifiers, [identifier("x")], "the refused update added nothing")
        XCTAssertEqual(center.shown[identifier("x")], "A's")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), [:])
    }

    /// A click or close resolves to the one owner whose identifier it carries,
    /// and a close drops only that owner's entry.
    @MainActor func testResponsesResolveOnlyToTheCreatingProfile() async throws {
        center.holdsAdds = false
        let createdA = startCreate("x", title: "A's")
        let createdA2 = startCreate("x", title: "A2's", owner: Self.ownerA2)
        await fulfillment(of: [createdA.done, createdA2.done], timeout: 5)

        XCTAssertEqual(manager.handleResponse(identifier: identifier("x", owner: Self.ownerA2),
                                              action: UNNotificationDefaultActionIdentifier),
                       .init(owner: Self.ownerA2, notificationID: "x", kind: .clicked))
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), ["x": true], "a click keeps the notification")

        XCTAssertEqual(manager.handleResponse(identifier: identifier("x"),
                                              action: UNNotificationDismissActionIdentifier),
                       .init(owner: Self.ownerA, notificationID: "x", kind: .closed))
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:], "the close drops A's entry")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), ["x": true], "and only A's")
    }

    /// Identifiers earlier builds delivered (`<extensionID>:<id>` before
    /// TASK-238, then the v2 form that named the profile), one with no entry,
    /// and an action other than click or close resolve to nothing and change
    /// nothing.
    @MainActor func testLegacyAndUnknownIdentifiersAreIgnored() async throws {
        center.holdsAdds = false
        let created = startCreate("x", title: "A's")
        await fulfillment(of: [created.done], timeout: 5)

        XCTAssertNil(manager.handleResponse(identifier: "\(Self.extA):x", action: UNNotificationDismissActionIdentifier))
        XCTAssertNil(manager.handleResponse(
            identifier: "detour-ext-notification.v2|\(Self.profile1.uuidString)|\(Self.extA)|x",
            action: UNNotificationDismissActionIdentifier))
        XCTAssertNil(manager.handleResponse(identifier: ExtensionNotificationManager.identifierPrefix + UUID().uuidString,
                                            action: UNNotificationDismissActionIdentifier))
        XCTAssertNil(manager.handleResponse(identifier: identifier("x"), action: "some-custom-action"))
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["x": true])
    }

    /// The identifier is a fixed prefix and a random UUID: nothing in it, or in
    /// the content handed to the center, names the profile, the extension or
    /// the notification id, and each owner's notification has its own.
    @MainActor func testIdentifiersAreOpaque() async throws {
        center.holdsAdds = false
        let private_ = ExtensionNotificationManager.Owner(profileID: TabStore.incognitoProfileID, extensionID: Self.extA)
        let owners = [Self.ownerA, Self.ownerA2, Self.ownerB, private_]
        var created: [XCTestExpectation] = []
        var identifiers: [String] = []
        for owner in owners {
            let create = startCreate("same-id", title: "t", owner: owner)
            created.append(create.done)
            identifiers.append(create.identifier)
        }
        await fulfillment(of: created, timeout: 5)

        XCTAssertEqual(Set(identifiers).count, owners.count, "one identifier per owner")
        XCTAssertEqual(center.addedIdentifiers, identifiers)
        for (identifier, owner) in zip(identifiers, owners) {
            XCTAssertTrue(identifier.hasPrefix("detour-ext-notification.v3|"), identifier)
            let rest = String(identifier.dropFirst(ExtensionNotificationManager.identifierPrefix.count))
            XCTAssertNotNil(UUID(uuidString: rest), "the rest is a random UUID: \(identifier)")
            XCTAssertNotEqual(UUID(uuidString: rest), owner.profileID, identifier)
            XCTAssertFalse(identifier.contains(owner.extensionID) || identifier.contains("same-id"), identifier)
        }
        for request in center.addedRequests {
            XCTAssertEqual(request.content.threadIdentifier, "", "no thread groups by profile")
            XCTAssertTrue(request.content.userInfo.isEmpty, "no userInfo names the owner")
        }

        // An update keeps the identifier, so the center replaces the banner.
        let update = startUpdate("same-id", title: "t2", owner: private_)
        await fulfillment(of: [update.done], timeout: 5)
        XCTAssertEqual(center.addedIdentifiers.last, identifiers[3])
        XCTAssertEqual(manager.handleResponse(identifier: identifiers[3], action: UNNotificationDefaultActionIdentifier),
                       .init(owner: private_, notificationID: "same-id", kind: .clicked),
                       "only the manager maps an identifier back to its owner")
    }

    // MARK: - Removal with the owner's scope (TASK-238)

    /// `removeAll(for:)` takes the owner's notifications off screen and out of
    /// `getAll`, and nobody else's: not another extension's in the profile,
    /// not the same extension's in another profile.
    @MainActor func testRemoveAllForAnOwnerTakesOnlyItsNotifications() async throws {
        center.holdsAdds = false
        let x = startCreate("x", title: "A's x")
        let y = startCreate("y", title: "A's y")
        let b = startCreate("x", title: "B's", owner: Self.ownerB)
        let a2 = startCreate("x", title: "A2's", owner: Self.ownerA2)
        await fulfillment(of: [x.done, y.done, b.done, a2.done], timeout: 5)

        manager.removeAll(for: Self.ownerA)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
        XCTAssertEqual(Set(center.removals), [x.identifier, y.identifier])
        XCTAssertEqual(center.shown, [b.identifier: "B's", a2.identifier: "A2's"])
        XCTAssertEqual(manager.getAll(owner: Self.ownerB), ["x": true])
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), ["x": true])
        XCTAssertNil(manager.handleResponse(identifier: x.identifier, action: UNNotificationDefaultActionIdentifier),
                     "a removed notification's click resolves to nothing")

        manager.removeAll(for: Self.ownerA)
        XCTAssertEqual(center.removals.count, 2, "nothing left to remove asks the center for nothing")
    }

    /// `removeAll(profileID:)` takes every extension's notifications in the
    /// profile and leaves other profiles'.
    @MainActor func testRemoveAllForAProfileTakesEveryExtensionsNotificationsInIt() async throws {
        center.holdsAdds = false
        let a = startCreate("x", title: "A's")
        let b = startCreate("x", title: "B's", owner: Self.ownerB)
        let a2 = startCreate("x", title: "A2's", owner: Self.ownerA2)
        await fulfillment(of: [a.done, b.done, a2.done], timeout: 5)

        manager.removeAll(profileID: Self.profile1)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
        XCTAssertEqual(manager.getAll(owner: Self.ownerB), [:])
        XCTAssertEqual(manager.getAll(owner: Self.ownerA2), ["x": true])
        XCTAssertEqual(Set(center.removals), [a.identifier, b.identifier])
        XCTAssertEqual(center.shown, [a2.identifier: "A2's"])
    }

    /// A notification whose `add` is still in flight when its owner goes is
    /// taken away when the add returns, as after a `clear`.
    @MainActor func testRemoveAllWhileCreateInFlightTakesTheNotificationAway() async throws {
        let create = startCreate("late", title: "Hello")
        try await waitForHeldAdds(1)
        manager.removeAll(profileID: Self.profile1)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])

        center.release()
        await fulfillment(of: [create.done], timeout: 5)
        XCTAssertTrue(center.shown.isEmpty)
        XCTAssertEqual(center.removals, [create.identifier, create.identifier])
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
    }

    // MARK: - Lifecycle hooks (TASK-238)

    /// The Private profile with a handler on `manager`, in a store of its own.
    @MainActor private func privateSessionStore() throws -> (store: TabStore, privateProfile: Profile) {
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()))
        let privateProfile = store.ensureIncognitoProfile()
        // The controller builds the handler (a page opened later would build
        // it, replacing one set by hand); a Private one is non-persistent.
        _ = privateProfile.extensionController
        try XCTUnwrap(privateProfile.polyfillHandler).notificationManagerOverride = manager
        return (store, privateProfile)
    }

    private static let privateOwner = ExtensionNotificationManager.Owner(
        profileID: TabStore.incognitoProfileID, extensionID: extA)

    /// The Private profile's id is a constant, so its notifications would carry
    /// over into the next Private session: they go when the last Private
    /// window closes, and only then.
    @MainActor func testThePrivateSessionEndingTakesThePrivateProfilesNotifications() async throws {
        center.holdsAdds = false
        let (store, _) = try privateSessionStore()
        let first = store.addIncognitoSpace()
        let second = store.addIncognitoSpace()
        let privateCreate = startCreate("p", title: "Private", owner: Self.privateOwner)
        let normalCreate = startCreate("p", title: "Normal")
        await fulfillment(of: [privateCreate.done, normalCreate.done], timeout: 5)

        store.removeIncognitoSpace(id: first.id)
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), ["p": true], "a Private window is still open")
        XCTAssertTrue(center.removals.isEmpty)

        store.removeIncognitoSpace(id: second.id)
        XCTAssertFalse(store.hasLivePrivateSession)
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), [:], "the session ended")
        XCTAssertEqual(center.removals, [privateCreate.identifier])
        XCTAssertEqual(center.shown, [normalCreate.identifier: "Normal"], "another profile's stay")
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), ["p": true])
    }

    /// A Private Quick Detour keeps the session, and its notifications, until
    /// it closes too.
    @MainActor func testAPrivateQuickDetourClosingLastEndsTheSession() async throws {
        center.holdsAdds = false
        let (store, privateProfile) = try privateSessionStore()
        let space = store.addIncognitoSpace()
        let quick = store.openQuickDetourTab(profile: privateProfile)
        let create = startCreate("q", title: "Private", owner: Self.privateOwner)
        await fulfillment(of: [create.done], timeout: 5)

        store.removeIncognitoSpace(id: space.id)
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), ["q": true], "the Quick Detour still uses it")

        store.closeQuickDetourTab(quick, disposition: .discard)
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), [:])
        XCTAssertTrue(center.shown.isEmpty)
    }

    /// Quitting ends the Private session with its windows still open, so the
    /// quit path takes the Private profile's notifications itself
    /// (`applicationWillTerminate`), and only those.
    @MainActor func testTheQuitRemovalTakesThePrivateProfilesNotificationsWithASessionLive() async throws {
        center.holdsAdds = false
        let (store, _) = try privateSessionStore()
        _ = store.addIncognitoSpace()
        let privateCreate = startCreate("p", title: "Private", owner: Self.privateOwner)
        let normalCreate = startCreate("p", title: "Normal")
        await fulfillment(of: [privateCreate.done, normalCreate.done], timeout: 5)

        store.removePrivateProfileNotifications()
        XCTAssertTrue(store.hasLivePrivateSession, "precondition: a Private window is still open")
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), [:])
        XCTAssertEqual(center.shown, [normalCreate.identifier: "Normal"])
    }

    /// The Private profile's contexts stay loaded between sessions, so a worker
    /// can create a notification while no Private page is open. The next
    /// session starts without it, whether a Private window or a Private Quick
    /// Detour starts it; a second user joining a live session clears nothing.
    @MainActor func testANotificationCreatedBetweenSessionsGoesWhenTheNextStarts() async throws {
        center.holdsAdds = false
        let (store, privateProfile) = try privateSessionStore()
        XCTAssertFalse(store.hasLivePrivateSession, "precondition")

        let betweenSessions = startCreate("alarm", title: "Between", owner: Self.privateOwner)
        let normalCreate = startCreate("alarm", title: "Normal")
        await fulfillment(of: [betweenSessions.done, normalCreate.done], timeout: 5)
        let window = store.addIncognitoSpace()
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), [:], "a Private window starts the session clean")
        XCTAssertEqual(center.shown, [normalCreate.identifier: "Normal"])

        let inSession = startCreate("in-session", title: "In session", owner: Self.privateOwner)
        await fulfillment(of: [inSession.done], timeout: 5)
        let joining = store.openQuickDetourTab(profile: privateProfile)
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), ["in-session": true],
                       "a Quick Detour joining the live session clears nothing")
        store.closeQuickDetourTab(joining, disposition: .discard)
        store.removeIncognitoSpace(id: window.id)
        XCTAssertFalse(store.hasLivePrivateSession)

        let again = startCreate("alarm", title: "Between again", owner: Self.privateOwner)
        await fulfillment(of: [again.done], timeout: 5)
        let quick = store.openQuickDetourTab(profile: privateProfile)
        XCTAssertEqual(manager.getAll(owner: Self.privateOwner), [:], "a Private Quick Detour starts it clean too")
        store.closeQuickDetourTab(quick, disposition: .discard)
    }

    /// Deleting a profile takes every extension's notifications in it.
    @MainActor func testDeletingAProfileTakesItsNotifications() async throws {
        center.holdsAdds = false
        let remover = ProfileDataRemoval.Remover(removeExtensionData: { _ in }, removeWebsiteDataStore: { _ in })
        let store = TabStore(appDB: try AppDatabase(dbQueue: try DatabaseQueue()), profileDataRemover: remover,
                             profileDataRemovalRetryDelays: [0.01])
        let keeper = store.addProfile(name: "Keeper")
        _ = store.addSpace(name: "Home", emoji: "H", colorHex: "007AFF", profileID: keeper.id)
        var doomed: Profile? = store.addProfile(name: "Doomed")
        let doomedID = try XCTUnwrap(doomed?.id)
        doomed?.dataStore = .nonPersistent()
        doomed?.extensionController = WKWebExtensionController(configuration: .nonPersistent())
        let handler = ExtensionPolyfillHandler(profile: try XCTUnwrap(doomed))
        handler.notificationManagerOverride = manager
        doomed?.polyfillHandler = handler
        doomed = nil

        let doomedA = ExtensionNotificationManager.Owner(profileID: doomedID, extensionID: Self.extA)
        let doomedB = ExtensionNotificationManager.Owner(profileID: doomedID, extensionID: Self.extB)
        let keeperA = ExtensionNotificationManager.Owner(profileID: keeper.id, extensionID: Self.extA)
        let a = startCreate("x", title: "Doomed A", owner: doomedA)
        let b = startCreate("y", title: "Doomed B", owner: doomedB)
        let kept = startCreate("x", title: "Keeper", owner: keeperA)
        await fulfillment(of: [a.done, b.done, kept.done], timeout: 5)

        let removal = store.deleteProfile(id: doomedID)
        XCTAssertNotNil(removal, "precondition: the profile was deleted")
        XCTAssertEqual(manager.getAll(owner: doomedA), [:])
        XCTAssertEqual(manager.getAll(owner: doomedB), [:])
        XCTAssertEqual(manager.getAll(owner: keeperA), ["x": true])
        XCTAssertEqual(center.shown, [kept.identifier: "Keeper"])
        _ = await removal?.value
    }

    /// The handler's removal for an extension unloaded from its profile —
    /// what `Profile.unloadExtension` calls on disable, uninstall, update or
    /// reload — takes that extension's notifications in the handler's profile,
    /// and nobody else's. The unload itself, from a loaded context, is in
    /// `ExtensionNotificationOrderingTests`.
    @MainActor func testTheHandlersExtensionRemovalTakesOnlyThatExtensionsNotificationsInItsProfile() async throws {
        center.holdsAdds = false
        let profile = Profile(id: Self.profile1, name: "Unload")
        let handler = ExtensionPolyfillHandler(profile: profile)
        handler.notificationManagerOverride = manager
        let a = startCreate("x", title: "A's")
        let b = startCreate("x", title: "B's", owner: Self.ownerB)
        let a2 = startCreate("x", title: "A2's", owner: Self.ownerA2)
        await fulfillment(of: [a.done, b.done, a2.done], timeout: 5)

        handler.removeNotifications(ofExtension: Self.extA)
        XCTAssertEqual(manager.getAll(owner: Self.ownerA), [:])
        XCTAssertEqual(center.shown, [b.identifier: "B's", a2.identifier: "A2's"])
    }
}
