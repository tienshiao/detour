import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// The Control+Tab switcher's event monitor must swallow the keys it acts on
/// (TASK-133): a key it handled that also reaches the first responder is
/// typed into the page.
nonisolated final class RecentTabSwitcherMonitorTests: XCTestCase {

    private var window: NSWindow!
    private var switcher: RecentTabSwitcher!

    @MainActor override func setUp() async throws {
        try await super.setUp()
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

    @MainActor override func tearDown() async throws {
        switcher?.invalidate()
        switcher = nil
        window.close()
        window = nil
        try await super.tearDown()
    }

    @MainActor func testControlTabIsSwallowed() throws {
        let event = try keyDown(kVK_Tab, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertTrue(switcher.isActive)
    }

    @MainActor func testControlShiftTabIsSwallowed() throws {
        let event = try keyDown(kVK_Tab, modifiers: [.control, .shift])
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertTrue(switcher.isActive)
    }

    @MainActor func testControlTabIsSwallowedWithNothingToSwitchTo() throws {
        switcher.entries = { [] }
        let event = try keyDown(kVK_Tab, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertFalse(switcher.isActive)
    }

    @MainActor func testKeysTypedWhileSwitchingAreSwallowed() throws {
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

    @MainActor func testEscapeCancelsAndIsSwallowed() throws {
        try begin()
        let event = try keyDown(kVK_Escape, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertFalse(switcher.isActive)
    }

    @MainActor func testReturnCommitsAndIsSwallowed() throws {
        var chosen: RecentTabSwitcher.Entry?
        switcher.didChoose = { chosen = $0 }
        try begin()
        let event = try keyDown(kVK_Return, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher))
        XCTAssertFalse(switcher.isActive)
        XCTAssertNotNil(chosen)
    }

    @MainActor func testKeysTheSwitcherDoesNotHandlePassThrough() throws {
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

    @MainActor func testEventsForAnotherWindowPassThrough() throws {
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let event = try keyDown(kVK_Tab, modifiers: .control, in: other)
        XCTAssertTrue(RecentTabSwitcher.monitorResult(for: event, switcher: switcher) === event)
        XCTAssertFalse(switcher.isActive)
    }

    @MainActor func testReleasingControlCommitsAndPassesTheEventOn() throws {
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

    @MainActor func testADeallocatedSwitcherPassesEverythingThrough() throws {
        let event = try keyDown(kVK_Tab, modifiers: .control)
        XCTAssertTrue(RecentTabSwitcher.monitorResult(for: event, switcher: nil) === event)
    }

    // MARK: - Control+W (TASK-308)

    @MainActor func testControlWClosesTheHighlightedCardAndKeepsSwitching() throws {
        let ids = (0..<4).map { _ in UUID() }
        switcher.entries = {
            ids.enumerated().map { RecentTabSwitcher.Entry(tabs: [], focusTabID: $1, isCurrent: $0 == 0) }
        }
        var closed: [UUID] = []
        switcher.closeEntry = { closed.append($0.focusTabID); return true }
        switcher.currentTabID = { ids[0] }
        try begin()
        XCTAssertEqual(switcher.highlightedIndex, 1)

        let event = try keyDown(kVK_ANSI_W, modifiers: .control)
        XCTAssertNil(RecentTabSwitcher.monitorResult(for: event, switcher: switcher), "swallowed")
        XCTAssertEqual(closed, [ids[1]])
        XCTAssertTrue(switcher.isActive, "the switcher stays open")
        XCTAssertEqual(switcher.listedEntries.map(\.focusTabID), [ids[0], ids[2], ids[3]])
        XCTAssertEqual(switcher.highlightedIndex, 1, "the next card is highlighted")

        var chosen: RecentTabSwitcher.Entry?
        switcher.didChoose = { chosen = $0 }
        let release = try XCTUnwrap(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: UInt16(kVK_Control)))
        _ = RecentTabSwitcher.monitorResult(for: release, switcher: switcher)
        XCTAssertEqual(chosen?.focusTabID, ids[2], "releasing Control selects the highlighted card")
    }

    @MainActor func testControlWOnTheLastOtherCardEndsTheSwitcher() throws {
        let ids = [UUID(), UUID()]
        switcher.entries = {
            [RecentTabSwitcher.Entry(tabs: [], focusTabID: ids[0], isCurrent: true),
             RecentTabSwitcher.Entry(tabs: [], focusTabID: ids[1])]
        }
        switcher.closeEntry = { _ in true }
        switcher.currentTabID = { ids[0] }
        var chosen: RecentTabSwitcher.Entry?
        switcher.didChoose = { chosen = $0 }
        try begin()

        _ = RecentTabSwitcher.monitorResult(for: try keyDown(kVK_ANSI_W, modifiers: .control), switcher: switcher)

        XCTAssertFalse(switcher.isActive, "nothing is left to switch to")
        XCTAssertNil(chosen, "ending after a close chooses nothing")
    }

    @MainActor func testControlWThatClosesNothingKeepsTheCard() throws {
        switcher.closeEntry = { _ in false }
        try begin()
        let before = switcher.listedEntries.count
        _ = RecentTabSwitcher.monitorResult(for: try keyDown(kVK_ANSI_W, modifiers: .control), switcher: switcher)
        XCTAssertTrue(switcher.isActive)
        XCTAssertEqual(switcher.listedEntries.count, before)
    }

    @MainActor func testWWithOtherModifiersClosesNothing() throws {
        var closed = 0
        switcher.closeEntry = { _ in closed += 1; return true }
        try begin()
        for modifiers: NSEvent.ModifierFlags in [[.control, .shift], [.control, .command], [.control, .option]] {
            _ = RecentTabSwitcher.monitorResult(for: try keyDown(kVK_ANSI_W, modifiers: modifiers), switcher: switcher)
        }
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(switcher.isActive)
    }

    @MainActor func testControlWFollowsTheLayoutNotTheKeyPosition() throws {
        var closed = 0
        switcher.closeEntry = { _ in closed += 1; return true }
        let ids = (0..<4).map { _ in UUID() }
        switcher.entries = {
            ids.enumerated().map { RecentTabSwitcher.Entry(tabs: [], focusTabID: $1, isCurrent: $0 == 0) }
        }
        switcher.currentTabID = { ids[0] }
        try begin()
        // AZERTY: the ANSI W position types "z", and W sits on the ANSI Z key.
        _ = RecentTabSwitcher.monitorResult(
            for: try keyDown(kVK_ANSI_W, modifiers: .control, characters: "z"), switcher: switcher)
        XCTAssertEqual(closed, 0, "the key that types z closes nothing")
        _ = RecentTabSwitcher.monitorResult(
            for: try keyDown(kVK_ANSI_Z, modifiers: .control, characters: "w"), switcher: switcher)
        XCTAssertEqual(closed, 1, "the key that types w closes the card")
        // Dvorak: the ANSI W position types a comma.
        _ = RecentTabSwitcher.monitorResult(
            for: try keyDown(kVK_ANSI_W, modifiers: .control, characters: ","), switcher: switcher)
        XCTAssertEqual(closed, 1, "the key that types a comma closes nothing")
        // A non-Latin layout falls back to the key position.
        _ = RecentTabSwitcher.monitorResult(
            for: try keyDown(kVK_ANSI_W, modifiers: .control, characters: "\u{0446}"), switcher: switcher)
        XCTAssertEqual(closed, 2)
    }

    // MARK: - Helpers

    @MainActor private func begin() throws {
        let event = try keyDown(kVK_Tab, modifiers: .control)
        _ = RecentTabSwitcher.monitorResult(for: event, switcher: switcher)
        XCTAssertTrue(switcher.isActive)
    }

    @MainActor private func keyDown(_ keyCode: Int, modifiers: NSEvent.ModifierFlags, characters: String? = nil,
                                    in target: NSWindow? = nil) throws -> NSEvent {
        // The character the key types on a US layout, unless a test names one.
        let characters = characters ?? (keyCode == kVK_ANSI_W ? "w" : keyCode == kVK_ANSI_Z ? "z" : "\t")
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: (target ?? window).windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: UInt16(keyCode)))
    }
}
