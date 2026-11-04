import WebKit
import XCTest
@testable import Detour

/// `SchemeTaskTable` answers a scheme task at most once, never after WebKit
/// stopped it, and never a newer task that happens to have the old one's
/// identity (WebKit can allocate the next task at a freed task's address).
nonisolated final class SchemeTaskTableTests: XCTestCase {

    @MainActor private final class FakeTask: NSObject, WKURLSchemeTask {
        let request = URLRequest(url: URL(string: "detour://history/")!)
        func didReceive(_ response: URLResponse) {}
        func didReceive(_ data: Data) {}
        func didFinish() {}
        func didFailWithError(_ error: any Error) {}
    }

    @MainActor func testATaskIsTakenOnce() {
        var table = SchemeTaskTable()
        let task = FakeTask()
        let ticket = table.insert(task)
        XCTAssertTrue(table.take(ticket) === task)
        XCTAssertNil(table.take(ticket), "a second answer finds nothing")
    }

    @MainActor func testAStoppedTaskIsNotTaken() {
        var table = SchemeTaskTable()
        let task = FakeTask()
        let ticket = table.insert(task)
        table.remove(task)
        XCTAssertNil(table.take(ticket))
    }

    /// The same object inserted again stands for a new task WebKit allocated
    /// at a stopped task's address: the old request's ticket must not reach it.
    @MainActor func testAnOldTicketDoesNotReachANewTaskWithTheSameIdentity() {
        var table = SchemeTaskTable()
        let task = FakeTask()
        let old = table.insert(task)
        table.remove(task)
        let new = table.insert(task)
        XCTAssertNil(table.take(old), "the stopped request's late answer is dropped")
        XCTAssertTrue(table.take(new) === task, "the new request is still answered")
    }

    /// Also when the old answer arrives before WebKit stopped the old task
    /// and the new one replaced it without a stop in between.
    @MainActor func testAnOldTicketDoesNotReachATaskThatReplacedItWithoutAStop() {
        var table = SchemeTaskTable()
        let task = FakeTask()
        let old = table.insert(task)
        let new = table.insert(task)
        XCTAssertNil(table.take(old))
        XCTAssertTrue(table.take(new) === task)
    }

    @MainActor func testTasksAreIndependent() {
        var table = SchemeTaskTable()
        let first = FakeTask(), second = FakeTask()
        let firstTicket = table.insert(first)
        let secondTicket = table.insert(second)
        table.remove(first)
        XCTAssertNil(table.take(firstTicket))
        XCTAssertTrue(table.take(secondTicket) === second)
    }
}
