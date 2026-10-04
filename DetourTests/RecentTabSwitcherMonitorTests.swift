import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// The Control+Tab switcher's event monitor must swallow the keys it acts on
/// (TASK-133): a key it handled that also reaches the first responder is
/// typed into the page.
@MainActor
final class RecentTabSwitcherMonitorTests: XCTestCase {

    private var window: NSWindow!
    private var switcher: RecentTabSwitcher!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        switcher = RecentTabSwitcher(window: window)
        switcher.entries = {
            [RecentTabSwitcher.Entry(tabs: [], focusTabID: UUID(), isCurrent: true),
             RecentTabSwitcher.Entry(tabs: [], focusTabID: UUID()),
             RecentTabSwitcher.Entry(tabs: [], focusTabID: UUID())]
        }
    }

    override func tearDown() {
        switcher?.invalidate()
        switcher = nil
        window.close()
        window = nil
        super.tearDown()
    }

    func testControlTabIsSwallowed() throws {
        let event = try keyDown(kVK_Tab, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertTrue(switcher.isActive)
    }

    func testControlShiftTabIsSwallowed() throws {
        let event = try keyDown(kVK_Tab, modifiers: [.control, .shift])
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertTrue(switcher.isActive)
    }

    func testControlTabIsSwallowedWithNothingToSwitchTo() throws {
        switcher.entries = { [] }
        let event = try keyDown(kVK_Tab, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertFalse(switcher.isActive)
    }

    func testKeysTypedWhileSwitchingAreSwallowed() throws {
        let keys: [(Int, String)] = [
            (kVK_RightArrow, "right arrow"), (kVK_LeftArrow, "left arrow"),
            (kVK_ANSI_A, "a letter"), (kVK_Space, "space"),
        ]
        for (keyCode, name) in keys {
            try begin()
            let event = try keyDown(keyCode, modifiers: .control)
            XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher), name)
            XCTAssertTrue(switcher.isActive, name)
            switcher.cancel()
        }
    }

    func testEscapeCancelsAndIsSwallowed() throws {
        try begin()
        let event = try keyDown(kVK_Escape, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertFalse(switcher.isActive)
    }

    func testReturnCommitsAndIsSwallowed() throws {
        var chosen: RecentTabSwitcher.Entry?
        switcher.didChoose = { chosen = $0 }
        try begin()
        let event = try keyDown(kVK_Return, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertFalse(switcher.isActive)
        XCTAssertNotNil(chosen)
    }

    func testKeysTheSwitcherDoesNotHandlePassThrough() throws {
        let keys: [(Int, NSEvent.ModifierFlags)] = [
            (kVK_ANSI_A, []), (kVK_Return, []), (kVK_Escape, []), (kVK_Tab, []), (kVK_Tab, .shift),
            (kVK_Tab, [.control, .command]), (kVK_Tab, [.control, .option]),
        ]
        for (keyCode, modifiers) in keys {
            let event = try keyDown(keyCode, modifiers: modifiers)
            XCTAssertTrue(RecentTabSwitcher.monitorResult(for: event, switcher: switcher) === event,
                          "keyCode \(keyCode) modifiers \(modifiers.rawValue)")
            XCTAssertFalse(switcher.isActive)
        }
    }

    func testEventsForAnotherWindowPassThrough() throws {
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let event = try keyDown(kVK_Tab, modifiers: .control, in: other)
        XCTAssertTrue(RecentTabSwitcher.monitorResult(for: event, switcher: switcher) === event)
        XCTAssertFalse(switcher.isActive)
    }

    func testReleasingControlCommitsAndPassesTheEventOn() throws {
        var chosen: RecentTabSwitcher.Entry?
        switcher.didChoose = { chosen = $0 }
        try begin()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(kVK_Control)))
        XCTAssertTrue(RecentTabSwitcher.monitorResult(for: event, switcher: switcher) === event)
        XCTAssertFalse(switcher.isActive)
        XCTAssertNotNil(chosen)
    }

    func testADeallocatedSwitcherPassesEverythingThrough() throws {
        let event = try keyDown(kVK_Tab, modifiers: .control)
        XCTAssertTrue(RecentTabSwitcher.monitorResult(for: event, switcher: nil) === event)
    }

    // MARK: - Helpers

    private func begin() throws {
        let event = try keyDown(kVK_Tab, modifiers: .control)
        _ = RecentTabSwitcher.monitorResult(for: event, switcher: switcher)
        XCTAssertTrue(switcher.isActive)
    }

    private func keyDown(_ keyCode: Int, modifiers: NSEvent.ModifierFlags, in target: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: (target ?? window).windowNumber, context: nil,
            characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false,
            keyCode: UInt16(keyCode)))
    }
}
