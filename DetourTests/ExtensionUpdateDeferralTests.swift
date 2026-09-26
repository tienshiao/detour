import XCTest
@testable import Detour

/// TASK-123: when a verified update waits instead of installing.
final class ExtensionUpdateDeferralTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnIdleExtensionIsNotDeferred() {
        XCTAssertFalse(ExtensionUpdateDeferral.shouldDefer(.idle, now: now))
    }

    func testOpenPagesPopupAndNativeHostsEachDefer() {
        var a = ExtensionUpdateDeferral.Activity(); a.openPages = 1
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(a, now: now))
        var b = ExtensionUpdateDeferral.Activity(); b.popupOpen = true
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(b, now: now))
        var c = ExtensionUpdateDeferral.Activity(); c.liveNativeHosts = 1
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(c, now: now))
    }

    func testRecentBackgroundTrafficDefersUntilItAges() {
        var a = ExtensionUpdateDeferral.Activity()
        a.lastBackgroundRequestAt = now.addingTimeInterval(-10)
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(a, now: now), "the worker spoke 10 s ago")
        a.lastBackgroundRequestAt = now.addingTimeInterval(-ExtensionUpdateDeferral.backgroundIdleAfter + 1)
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(a, now: now), "just inside the window")
        a.lastBackgroundRequestAt = now.addingTimeInterval(-ExtensionUpdateDeferral.backgroundIdleAfter)
        XCTAssertFalse(ExtensionUpdateDeferral.shouldDefer(a, now: now), "a minute of silence is idle")
    }
}
