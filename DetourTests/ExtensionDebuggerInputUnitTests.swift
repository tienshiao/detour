import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Detour

/// TASK-132.14: the pure parts of the Input domain — parameter parsing in
/// Chrome's words, and the mapping from CDP events to AppKit events.
nonisolated final class ExtensionDebuggerInputUnitTests: XCTestCase {

    private typealias Input = ExtensionDebuggerInput

    @MainActor private func mouse(_ params: [String: Any]) -> Input.MouseEvent? {
        try? Input.MouseEvent.parse(params).get()
    }

    @MainActor private func mouseError(_ params: [String: Any]) -> String? {
        if case .failure(let failure) = Input.MouseEvent.parse(params) { return failure.message }
        return nil
    }

    @MainActor private func key(_ params: [String: Any]) throws -> Input.KeyEvent {
        try Input.KeyEvent.parse(params).get()
    }

    @MainActor private func fields(_ params: [String: Any]) throws -> Input.KeyFields {
        try XCTUnwrap(Input.keyFields(try key(params)))
    }

    // MARK: Mouse

    @MainActor func testMouseParametersFailInChromesWords() {
        XCTAssertEqual(mouseError(["type": "mouseSqueezed", "x": 0, "y": 0]), "Unexpected event type 'mouseSqueezed'")
        XCTAssertEqual(mouseError(["type": "mousePressed", "x": 0, "y": 0, "button": "thumb"]), "Invalid mouse button")
        XCTAssertEqual(mouseError(["type": "mouseWheel", "x": 0, "y": 0, "deltaY": 5]),
                       "'deltaX' and 'deltaY' are expected for mouseWheel event")
        XCTAssertEqual(mouseError(["type": "mouseWheel", "x": 0, "y": 0, "deltaX": 0, "deltaY": 1e12]),
                       "Wheel deltas exceed the supported range")
        XCTAssertEqual(mouseError(["type": "mousePressed", "x": 0, "y": 0, "force": 2]),
                       "'force' should be in the range of [0,1]")
        XCTAssertNotNil(mouseError(["type": "mousePressed", "y": 0]), "x is required")
        XCTAssertNotNil(mouseError(["type": "mousePressed", "x": true, "y": 0]), "a boolean is not a number")
        XCTAssertNotNil(mouseError(["x": 0, "y": 0]), "type is required")
    }

    /// `Int(Double)` traps out of range: an extension's huge number is ignored, not a crash.
    @MainActor func testOutOfRangeIntegersAreIgnored() throws {
        let press = try XCTUnwrap(mouse(["type": "mousePressed", "x": 1, "y": 1, "button": "left",
                                         "modifiers": 1e300, "buttons": -1e19, "clickCount": 1e19]))
        XCTAssertEqual(press.modifiers, 0)
        XCTAssertEqual(press.buttons, 0)
        XCTAssertEqual(press.clickCount, 0)
        let down = try key(["type": "keyDown", "key": "a", "modifiers": 1e20,
                            "windowsVirtualKeyCode": 1e30, "nativeVirtualKeyCode": -1e30])
        XCTAssertEqual(down.modifiers, 0)
        XCTAssertNil(down.windowsVirtualKeyCode)
        XCTAssertNil(down.nativeVirtualKeyCode)
    }

    @MainActor func testMouseEventTypes() {
        func type(_ params: [String: Any]) -> NSEvent.EventType? {
            mouse(params.merging(["x": 1, "y": 2]) { $1 })?.eventType
        }
        XCTAssertEqual(type(["type": "mousePressed", "button": "left"]), .leftMouseDown)
        XCTAssertEqual(type(["type": "mouseReleased", "button": "left"]), .leftMouseUp)
        XCTAssertEqual(type(["type": "mousePressed", "button": "right"]), .rightMouseDown)
        XCTAssertEqual(type(["type": "mouseReleased", "button": "middle"]), .otherMouseUp)
        XCTAssertEqual(type(["type": "mousePressed", "button": "back"]), .otherMouseDown)
        XCTAssertNil(type(["type": "mousePressed", "button": "none"]), "a press of no button sends nothing")
        XCTAssertNil(type(["type": "mousePressed"]))
        XCTAssertEqual(type(["type": "mouseMoved"]), .mouseMoved)
        XCTAssertEqual(type(["type": "mouseMoved", "button": "none", "buttons": 0]), .mouseMoved)
        XCTAssertEqual(type(["type": "mouseMoved", "button": "left", "buttons": 1]), .leftMouseDragged,
                       "a move with the left button held is a drag")
        XCTAssertEqual(type(["type": "mouseMoved", "buttons": 2]), .rightMouseDragged)
        XCTAssertEqual(type(["type": "mouseMoved", "buttons": 4]), .otherMouseDragged)
        XCTAssertEqual(type(["type": "mouseWheel", "deltaX": 0, "deltaY": 3]), .scrollWheel)
        XCTAssertEqual(mouse(["type": "mouseMoved", "x": 1, "y": 1, "buttons": 4])?.draggedButton, .middle)
    }

    @MainActor func testTheClaudeExtensionsMouseEventsParse() throws {
        // As its dispatchMouseEvent builds them (1.0.105).
        let press = try XCTUnwrap(mouse(["type": "mousePressed", "x": 120, "y": 80, "modifiers": 0, "button": "left",
                                         "clickCount": 2, "buttons": 1, "force": 0.5]))
        XCTAssertEqual(press.clickCount, 2)
        XCTAssertEqual(press.force, 0.5)
        XCTAssertEqual(press.eventType, .leftMouseDown)
        let wheel = try XCTUnwrap(mouse(["type": "mouseWheel", "x": 10, "y": 10, "modifiers": 0,
                                         "deltaX": 0, "deltaY": 300]))
        XCTAssertEqual(wheel.deltaY, 300)
    }

    @MainActor func testModifierBits() {
        XCTAssertEqual(Input.modifierFlags(0), [])
        XCTAssertEqual(Input.modifierFlags(1), .option)
        XCTAssertEqual(Input.modifierFlags(2), .control)
        XCTAssertEqual(Input.modifierFlags(4), .command)
        XCTAssertEqual(Input.modifierFlags(8), .shift)
        XCTAssertEqual(Input.modifierFlags(15), [.option, .control, .command, .shift])
    }

    @MainActor func testOtherButtonsAndTheWheelCarryTheirButtonAndLocation() throws {
        let location = NSPoint(x: 140, y: 333)
        let middle = try XCTUnwrap(mouse(["type": "mousePressed", "x": 0, "y": 0, "button": "middle", "clickCount": 1]))
        let middleEvent = try XCTUnwrap(Input.makeMouseEvent(middle, type: .otherMouseDown, location: location,
                                                             windowNumber: 0))
        XCTAssertEqual(middleEvent.type, .otherMouseDown)
        XCTAssertEqual(middleEvent.buttonNumber, 2)
        XCTAssertEqual(middleEvent.clickCount, 1)
        XCTAssertEqual(middleEvent.locationInWindow, location)
        let back = try XCTUnwrap(mouse(["type": "mouseReleased", "x": 0, "y": 0, "button": "back"]))
        XCTAssertEqual(try XCTUnwrap(Input.makeMouseEvent(back, type: .otherMouseUp, location: location,
                                                          windowNumber: 0)).buttonNumber, 3)

        let wheel = try XCTUnwrap(mouse(["type": "mouseWheel", "x": 0, "y": 0, "deltaX": -20, "deltaY": 120,
                                         "modifiers": 8]))
        let wheelEvent = try XCTUnwrap(Input.makeMouseEvent(wheel, type: .scrollWheel, location: location,
                                                            windowNumber: 0))
        XCTAssertEqual(wheelEvent.type, .scrollWheel)
        XCTAssertEqual(wheelEvent.locationInWindow, location)
        XCTAssertEqual(wheelEvent.scrollingDeltaY, -120, "CDP's down is AppKit's negative")
        XCTAssertEqual(wheelEvent.scrollingDeltaX, 20)
        XCTAssertTrue(wheelEvent.hasPreciseScrollingDeltas, "pixels, not lines")
        XCTAssertTrue(wheelEvent.modifierFlags.contains(.shift))

        let left = try XCTUnwrap(mouse(["type": "mousePressed", "x": 0, "y": 0, "button": "left", "modifiers": 4]))
        let leftEvent = try XCTUnwrap(Input.makeMouseEvent(left, type: .leftMouseDown, location: location,
                                                           windowNumber: 7))
        XCTAssertEqual(leftEvent.clickCount, 1, "a press with no clickCount is a single click")
        XCTAssertEqual(leftEvent.pressure, 1)
        XCTAssertTrue(leftEvent.modifierFlags.contains(.command))
    }

    // MARK: Keys

    @MainActor func testKeyParametersFailInChromesWords() {
        func error(_ params: [String: Any]) -> String? {
            if case .failure(let failure) = Input.KeyEvent.parse(params) { return failure.message }
            return nil
        }
        XCTAssertEqual(error(["type": "keyPress"]), "Unexpected event type 'keyPress'")
        XCTAssertEqual(error(["type": "keyDown", "text": 3]), "Invalid 'text' parameter")
        XCTAssertEqual(error(["type": "keyDown", "unmodifiedText": [1]]), "Invalid 'unmodifiedText' parameter")
        XCTAssertNotNil(error([:]))
        XCTAssertNil(error(["type": "char", "text": "x"]))
    }

    @MainActor func testATypedLetter() throws {
        let down = try fields(["type": "keyDown", "key": "H", "code": "KeyH", "text": "H", "unmodifiedText": "H",
                               "windowsVirtualKeyCode": 72, "modifiers": 8])
        XCTAssertEqual(down.type, .keyDown)
        XCTAssertEqual(down.characters, "H")
        XCTAssertEqual(down.keyCode, UInt16(kVK_ANSI_H))
        XCTAssertEqual(down.flags, .shift)
        let up = try fields(["type": "keyUp", "key": "H", "code": "KeyH", "windowsVirtualKeyCode": 72, "modifiers": 8])
        XCTAssertEqual(up.type, .keyUp)
        XCTAssertEqual(up.characters, "H", "a key up carries the key's characters")
    }

    @MainActor func testARawKeyDownTypesNothing() throws {
        let raw = try fields(["type": "rawKeyDown", "key": "q", "code": "KeyQ", "text": "q"])
        XCTAssertEqual(raw.characters, "")
        XCTAssertEqual(raw.charactersIgnoringModifiers, "q")
        XCTAssertEqual(raw.keyCode, UInt16(kVK_ANSI_Q))
    }

    @MainActor func testARawKeyDownEnterTypesNoLineBreakButOtherNamedKeysStillAct() throws {
        let enter = try fields(["type": "rawKeyDown", "key": "Enter", "code": "Enter"])
        XCTAssertEqual(enter.characters, "")
        XCTAssertEqual(enter.charactersIgnoringModifiers, "\r", "the page still sees Enter")
        XCTAssertEqual(try fields(["type": "rawKeyDown", "key": "Backspace", "code": "Backspace"]).characters, "\u{7F}")
        // Control+letter keeps its control character, so its binding (Ctrl+K) runs.
        let controlK = try fields(["type": "rawKeyDown", "key": "k", "code": "KeyK", "modifiers": 2,
                                   "commands": ["deleteToEndOfParagraph"]])
        XCTAssertEqual(controlK.characters, "\u{0B}")
    }

    @MainActor func testKeysThatTypeNoCharacterOfTheirOwn() throws {
        let enter = try fields(["type": "keyDown", "key": "Enter", "code": "Enter", "text": "\r"])
        XCTAssertEqual(enter.characters, "\r")
        XCTAssertEqual(enter.keyCode, UInt16(kVK_Return))
        let tab = try fields(["type": "rawKeyDown", "key": "Tab", "code": "Tab"])
        XCTAssertEqual(tab.characters, "\t")
        XCTAssertEqual(try fields(["type": "rawKeyDown", "key": "Tab", "code": "Tab", "modifiers": 8]).characters,
                       "\u{19}", "Shift+Tab is a back tab")
        let backspace = try fields(["type": "rawKeyDown", "key": "Backspace", "code": "Backspace"])
        XCTAssertEqual(backspace.characters, "\u{7F}")
        XCTAssertEqual(backspace.keyCode, UInt16(kVK_Delete))
        let left = try fields(["type": "rawKeyDown", "key": "ArrowLeft", "code": "ArrowLeft"])
        XCTAssertEqual(left.characters.unicodeScalars.first?.value, UInt32(NSLeftArrowFunctionKey))
        XCTAssertEqual(left.flags, [.function, .numericPad])
        XCTAssertEqual(left.keyCode, UInt16(kVK_LeftArrow))
        let delete = try fields(["type": "rawKeyDown", "key": "Delete", "code": "Delete"])
        XCTAssertEqual(delete.characters.unicodeScalars.first?.value, UInt32(NSDeleteFunctionKey))
        XCTAssertEqual(delete.keyCode, UInt16(kVK_ForwardDelete))
        let f5 = try fields(["type": "rawKeyDown", "key": "F5", "code": "F5"])
        XCTAssertEqual(f5.characters.unicodeScalars.first?.value, UInt32(NSF5FunctionKey))
        XCTAssertEqual(try fields(["type": "rawKeyDown", "key": "Escape", "code": "Escape"]).characters, "\u{1B}")
    }

    @MainActor func testControlLetterIsTheControlCharacter() throws {
        let control = try fields(["type": "keyDown", "key": "a", "code": "KeyA", "text": "a", "modifiers": 2])
        XCTAssertEqual(control.characters, "\u{01}", "what the text system's Ctrl+A binding matches")
        XCTAssertEqual(control.charactersIgnoringModifiers, "a")
        XCTAssertEqual(control.flags, .control)
        let command = try fields(["type": "keyDown", "key": "a", "code": "KeyA", "text": "a", "modifiers": 4])
        XCTAssertEqual(command.characters, "a")
        XCTAssertEqual(command.flags, .command)
    }

    @MainActor func testAModifierKeyIsAFlagsChange() throws {
        let down = try fields(["type": "rawKeyDown", "key": "Shift", "code": "ShiftLeft", "modifiers": 8])
        XCTAssertEqual(down.type, .flagsChanged)
        XCTAssertEqual(down.flags, .shift)
        XCTAssertEqual(down.keyCode, UInt16(kVK_Shift))
        let up = try fields(["type": "keyUp", "key": "Shift", "code": "ShiftLeft", "modifiers": 8])
        XCTAssertEqual(up.type, .flagsChanged)
        XCTAssertEqual(up.flags, [], "released on the way up")
        let meta = try fields(["type": "keyDown", "key": "Meta", "code": "MetaRight"])
        XCTAssertEqual(meta.flags, .command)
        XCTAssertEqual(meta.keyCode, UInt16(kVK_RightCommand))
    }

    @MainActor func testTheKeyCodeComesFromTheCodeTheWindowsKeyCodeOrTheKey() throws {
        XCTAssertEqual(try fields(["type": "keyDown", "windowsVirtualKeyCode": 66, "text": "b"]).keyCode,
                       UInt16(kVK_ANSI_B))
        XCTAssertEqual(try fields(["type": "keyDown", "key": "7", "text": "7"]).keyCode, UInt16(kVK_ANSI_7))
        XCTAssertEqual(try fields(["type": "keyDown", "code": "KeyZ", "nativeVirtualKeyCode": 12, "text": "z"]).keyCode,
                       12, "the native key code wins")
        XCTAssertEqual(try fields(["type": "keyDown", "text": "é"]).keyCode, Input.unknownKeyCode)
        XCTAssertTrue(try fields(["type": "keyDown", "key": "1", "code": "Numpad1", "text": "1", "isKeypad": true])
            .flags.contains(.numericPad))
        XCTAssertTrue(try fields(["type": "keyDown", "key": "a", "text": "a", "autoRepeat": true]).isARepeat)
        XCTAssertEqual(Input.domCode(forWindowsKeyCode: 186), "Semicolon")
        XCTAssertEqual(Input.domCode(forWindowsKeyCode: 115), "F4")
        XCTAssertEqual(Input.macKeyCode(forDOMCode: "Period"), UInt16(kVK_ANSI_Period))
        XCTAssertNil(Input.macKeyCode(forDOMCode: "Bogus"))
    }

    @MainActor func testACharEventIsTextInput() throws {
        XCTAssertNil(Input.keyFields(try key(["type": "char", "text": "x"])))
    }

    @MainActor func testOnlyMenuKeyEquivalentCommandsRunExplicitly() {
        // The text system's bindings already perform these from the key event.
        for command in ["deleteBackward", "moveLeft", "insertNewline", "moveToBeginningOfParagraph",
                        "deleteToBeginningOfLine"] {
            XCTAssertNil(Input.menuCommands[command], command)
        }
        for command in ["selectAll", "copy", "cut", "paste"] {
            XCTAssertNotNil(Input.menuCommands[command], command)
        }
        XCTAssertEqual(Input.undoCommands, ["undo", "redo"])
    }
}
