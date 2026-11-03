import XCTest
@testable import Detour

/// The shared polling helpers in `ExtensionTestSupport.swift` (TASK-245): a
/// `waitUntil` timeout fails the test at the wait and stops the body, and
/// `pollUntil` reports a timeout without failing.
nonisolated final class WaitUntilTests: XCTestCase {

    @MainActor func testWaitUntilReturnsOnceTheConditionHolds() async throws {
        var polls = 0
        try await waitUntil("the third poll", timeout: 5, pollInterval: 0.01) {
            polls += 1
            return polls == 3
        }
        XCTAssertEqual(polls, 3)
    }

    @MainActor func testWaitUntilTimeoutRecordsAFailureAndThrows() async throws {
        XCTExpectFailure("the wait is meant to time out") { issue in
            issue.compactDescription.contains("timed out after 0.05 s waiting for a condition that never holds")
        }
        do {
            try await waitUntil("a condition that never holds", timeout: 0.05, pollInterval: 0.01) { false }
            XCTFail("waitUntil returned after its timeout instead of throwing")
        } catch let timedOut as WaitTimedOut {
            XCTAssertEqual(timedOut.what, "a condition that never holds")
            XCTAssertEqual(timedOut.timeout, 0.05)
        }
    }

    @MainActor func testPollUntilReportsATimeoutWithoutFailing() async throws {
        let held = try await pollUntil(timeout: 0.05, pollInterval: 0.01) { false }
        XCTAssertFalse(held)
        let heldAtOnce = try await pollUntil(timeout: 0.05) { true }
        XCTAssertTrue(heldAtOnce)
    }
}
