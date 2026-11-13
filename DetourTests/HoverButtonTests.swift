import XCTest
@testable import Detour

/// TASK-323: a disabled `HoverButton` shows no hover background, as AppKit's
/// own controls show no rollover while disabled; the background follows the
/// pointer and `isEnabled` together.
nonisolated final class HoverButtonTests: XCTestCase {

    @MainActor private func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                               context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    @MainActor func testAnEnabledButtonShowsHoverWhileThePointerIsInside() {
        let button = HoverButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        XCTAssertFalse(button.isShowingHover)

        button.mouseEntered(with: event(.mouseEntered))
        XCTAssertTrue(button.isShowingHover)

        button.mouseExited(with: event(.mouseExited))
        XCTAssertFalse(button.isShowingHover)
    }

    @MainActor func testADisabledButtonShowsNoHover() {
        let button = HoverButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        button.isEnabled = false

        button.mouseEntered(with: event(.mouseEntered))

        XCTAssertFalse(button.isShowingHover)
    }

    /// Going back to the first page with the pointer on the back button
    /// disables it under the pointer; navigating on enables it there.
    @MainActor func testTheHoverFollowsIsEnabledUnderARestingPointer() {
        let button = HoverButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        button.mouseEntered(with: event(.mouseEntered))

        button.isEnabled = false
        XCTAssertFalse(button.isShowingHover, "disabled under the pointer: the background goes")

        button.isEnabled = true
        XCTAssertTrue(button.isShowingHover, "enabled under the pointer: it comes back")

        button.mouseExited(with: event(.mouseExited))
        button.isEnabled = false
        button.isEnabled = true
        XCTAssertFalse(button.isShowingHover, "enabling with the pointer elsewhere shows nothing")
    }

    /// A button hidden under the pointer gets no `mouseExited`; it forgets the
    /// pointer, so neither unhiding nor re-enabling it brings the background back.
    @MainActor func testHidingTheButtonForgetsThePointer() {
        let button = HoverButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        button.mouseEntered(with: event(.mouseEntered))
        XCTAssertTrue(button.isShowingHover)

        button.isHidden = true
        button.isHidden = false
        XCTAssertFalse(button.isShowingHover)

        button.isEnabled = false
        button.isEnabled = true
        XCTAssertFalse(button.isShowingHover)
    }
}
