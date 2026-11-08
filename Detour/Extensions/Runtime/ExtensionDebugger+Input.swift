import AppKit
import Carbon.HIToolbox
import WebKit

// TASK-132.14: the CDP Input domain — `Input.dispatchMouseEvent`,
// `Input.dispatchKeyEvent`, `Input.insertText` (and `Input.cancelDragging`) —
// as real, trusted events: NSEvents sent straight to the attached tab's web
// view, parked or displayed (`BrowserTab.automationDrivableWebView()`).
//
// The rules that keep it in the tab (measured, see wiki/extensions/debugger-api.md):
//  - Events go to the view, never through `NSApp.sendEvent` or the window;
//    a key down the page declines comes back through `NSApp.sendEvent` and
//    `AutomationInput` drops it.
//  - One event at a time per session, each answered once the page has handled
//    it: WebKit queues mouse and key events and sends the next only when the
//    page acknowledged the last, so a script round trip after an event that was
//    sent at once (nothing queued) returns after the page has handled it.
//  - While an event is being handled the window refuses to make that web view
//    first responder (WebKit asks when the page focuses an element), the
//    native context menu a right click would open is not shown, and a drag
//    WebKit starts from a synthesized press never becomes an OS drag session —
//    any of which would reach the user's own focus, screen or pointer.

enum ExtensionDebuggerInput {

    /// Returns false for a method this domain does not emulate.
    static func run(_ method: String, params: [String: Any], in session: ExtensionDebuggerSession,
                    reply: ExtensionDebuggerReply) -> Bool {
        let work: Work
        switch method {
        case "Input.dispatchMouseEvent":
            switch MouseEvent.parse(params) {
            case .failure(let error):
                reply.fail(code: ExtensionDebugger.invalidParamsCode, message: error.message)
                return true
            case .success(let event):
                work = .mouse(event)
            }
        case "Input.dispatchKeyEvent":
            switch KeyEvent.parse(params) {
            case .failure(let error):
                reply.fail(code: ExtensionDebugger.invalidParamsCode, message: error.message)
                return true
            case .success(let event):
                work = .key(event)
            }
        case "Input.insertText":
            guard let text = params["text"] as? String else {
                reply.fail(code: ExtensionDebugger.invalidParamsCode, message: "Invalid parameters: text: string value expected")
                return true
            }
            work = .insertText(text)
        case "Input.cancelDragging":
            // A synthesized press never starts an OS drag here (`AutomationDragGuard`),
            // so there is never one to cancel.
            reply.succeed()
            return true
        default:
            return false
        }
        queue(for: session).enqueue(work, reply)
        return true
    }

    /// Chrome's answer when there is no page to send the event to.
    static let internalErrorCode = -32603

    // MARK: Parameters

    struct Failure: Error, Equatable {
        let message: String
    }

    /// CDP's modifier bits: Alt=1, Ctrl=2, Meta/Command=4, Shift=8.
    static func modifierFlags(_ modifiers: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.option) }
        if modifiers & 2 != 0 { flags.insert(.control) }
        if modifiers & 4 != 0 { flags.insert(.command) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        return flags
    }

    enum MouseButton: String, Equatable {
        case none, left, middle, right, back, forward

        /// AppKit's button number (`NSEvent.buttonNumber`).
        var number: Int {
            switch self {
            case .none, .left: 0
            case .right: 1
            case .middle: 2
            case .back: 3
            case .forward: 4
            }
        }
    }

    struct MouseEvent: Equatable {
        enum Kind: String { case mousePressed, mouseReleased, mouseMoved, mouseWheel }
        var kind: Kind
        /// CSS pixels of the main frame's viewport.
        var x: Double
        var y: Double
        var modifiers = 0
        var button = MouseButton.none
        /// CDP's bitmask of held buttons: left 1, right 2, middle 4, back 8, forward 16.
        var buttons = 0
        var clickCount = 0
        var deltaX = 0.0
        var deltaY = 0.0
        var force: Double?

        static func parse(_ params: [String: Any]) -> Result<MouseEvent, Failure> {
            guard let typeName = params["type"] as? String else {
                return .failure(Failure(message: "Invalid parameters: type: string value expected"))
            }
            guard let kind = Kind(rawValue: typeName) else {
                return .failure(Failure(message: "Unexpected event type '\(typeName)'"))
            }
            guard let x = number(params["x"]), let y = number(params["y"]) else {
                return .failure(Failure(message: "Invalid parameters: x and y: double value expected"))
            }
            var event = MouseEvent(kind: kind, x: x, y: y)
            event.modifiers = integer(params["modifiers"]) ?? 0
            if let name = params["button"] as? String {
                guard let button = MouseButton(rawValue: name) else {
                    return .failure(Failure(message: "Invalid mouse button"))
                }
                event.button = button
            } else if params["button"] != nil, !(params["button"] is NSNull) {
                return .failure(Failure(message: "Invalid mouse button"))
            }
            event.buttons = integer(params["buttons"]) ?? 0
            event.clickCount = integer(params["clickCount"]) ?? 0
            if let force = number(params["force"]) {
                guard (0...1).contains(force) else {
                    return .failure(Failure(message: "'force' should be in the range of [0,1]"))
                }
                event.force = force
            }
            if kind == .mouseWheel {
                guard let deltaX = number(params["deltaX"]), let deltaY = number(params["deltaY"]) else {
                    return .failure(Failure(message: "'deltaX' and 'deltaY' are expected for mouseWheel event"))
                }
                // CGEvent wheel deltas are 32-bit.
                guard abs(deltaX) <= Double(Int32.max), abs(deltaY) <= Double(Int32.max) else {
                    return .failure(Failure(message: "Wheel deltas exceed the supported range"))
                }
                event.deltaX = deltaX
                event.deltaY = deltaY
            }
            return .success(event)
        }

        /// The AppKit event type, or nil for a press or release of no button
        /// (which reaches no page as anything).
        var eventType: NSEvent.EventType? {
            switch kind {
            case .mousePressed:
                switch button {
                case .none: return nil
                case .left: return .leftMouseDown
                case .right: return .rightMouseDown
                case .middle, .back, .forward: return .otherMouseDown
                }
            case .mouseReleased:
                switch button {
                case .none: return nil
                case .left: return .leftMouseUp
                case .right: return .rightMouseUp
                case .middle, .back, .forward: return .otherMouseUp
                }
            case .mouseMoved:
                // A move with a button held is a drag, as AppKit reports it.
                if buttons & 1 != 0 { return .leftMouseDragged }
                if buttons & 2 != 0 { return .rightMouseDragged }
                if buttons & (4 | 8 | 16) != 0 { return .otherMouseDragged }
                return .mouseMoved
            case .mouseWheel:
                return .scrollWheel
            }
        }

        /// The button a drag holds, for an `otherMouseDragged` move.
        var draggedButton: MouseButton {
            if buttons & 4 != 0 { return .middle }
            if buttons & 8 != 0 { return .back }
            if buttons & 16 != 0 { return .forward }
            return button
        }
    }

    struct KeyEvent: Equatable {
        enum Kind: String { case keyDown, keyUp, rawKeyDown, char }
        var kind: Kind
        var modifiers = 0
        var text: String?
        var unmodifiedText: String?
        var key: String?
        var code: String?
        var windowsVirtualKeyCode: Int?
        var nativeVirtualKeyCode: Int?
        var autoRepeat = false
        var isKeypad = false
        var commands: [String] = []

        static func parse(_ params: [String: Any]) -> Result<KeyEvent, Failure> {
            guard let typeName = params["type"] as? String else {
                return .failure(Failure(message: "Invalid parameters: type: string value expected"))
            }
            guard let kind = Kind(rawValue: typeName) else {
                return .failure(Failure(message: "Unexpected event type '\(typeName)'"))
            }
            var event = KeyEvent(kind: kind)
            event.modifiers = integer(params["modifiers"]) ?? 0
            if let value = params["text"], !(value is NSNull) {
                guard let text = value as? String else { return .failure(Failure(message: "Invalid 'text' parameter")) }
                event.text = text
            }
            if let value = params["unmodifiedText"], !(value is NSNull) {
                guard let text = value as? String else {
                    return .failure(Failure(message: "Invalid 'unmodifiedText' parameter"))
                }
                event.unmodifiedText = text
            }
            event.key = params["key"] as? String
            event.code = params["code"] as? String
            event.windowsVirtualKeyCode = integer(params["windowsVirtualKeyCode"])
            event.nativeVirtualKeyCode = integer(params["nativeVirtualKeyCode"])
            event.autoRepeat = params["autoRepeat"] as? Bool ?? false
            event.isKeypad = params["isKeypad"] as? Bool ?? false
            event.commands = (params["commands"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .success(event)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// An integer parameter (modifiers, buttons, a click count, a key code),
    /// or nil when it is absent or beyond any such field: `Int(Double)` traps
    /// out of range, and an extension's `1e300` must not take the app down.
    private static func integer(_ value: Any?) -> Int? {
        guard let double = number(value), abs(double) <= Double(Int32.max) else { return nil }
        return Int(double)
    }

    // MARK: Keys

    /// What an AppKit key event for a CDP key event carries.
    struct KeyFields: Equatable {
        var type: NSEvent.EventType
        var characters: String
        var charactersIgnoringModifiers: String
        var keyCode: UInt16
        var flags: NSEvent.ModifierFlags
        var isARepeat: Bool
    }

    /// The modifier a key is, for a press of the key itself (a `flagsChanged` event).
    static func modifierFlag(forKey key: String?, code: String?) -> NSEvent.ModifierFlags? {
        switch key {
        case "Shift": return .shift
        case "Control": return .control
        case "Alt": return .option
        case "Meta": return .command
        case "CapsLock": return .capsLock
        default: break
        }
        switch code {
        case "ShiftLeft", "ShiftRight": return .shift
        case "ControlLeft", "ControlRight": return .control
        case "AltLeft", "AltRight": return .option
        case "MetaLeft", "MetaRight", "OSLeft", "OSRight": return .command
        case "CapsLock": return .capsLock
        default: return nil
        }
    }

    /// The AppKit fields of `event`, or nil for a `char` event (which is text
    /// input, not a key event, here).
    static func keyFields(_ event: KeyEvent) -> KeyFields? {
        let type: NSEvent.EventType
        switch event.kind {
        case .keyDown, .rawKeyDown: type = .keyDown
        case .keyUp: type = .keyUp
        case .char: return nil
        }
        let code = event.code ?? event.windowsVirtualKeyCode.flatMap(domCode(forWindowsKeyCode:))
            ?? event.key.flatMap(domCode(forKey:))
        let keyCode = event.nativeVirtualKeyCode.map { UInt16(clamping: $0) }
            ?? code.flatMap(macKeyCode(forDOMCode:)) ?? unknownKeyCode
        var flags = modifierFlags(event.modifiers)
        if event.isKeypad { flags.insert(.numericPad) }

        if let modifier = modifierFlag(forKey: event.key, code: code) {
            // The flags after the change: held on the way down, released on the way up.
            if type == .keyDown { flags.insert(modifier) } else { flags.remove(modifier) }
            return KeyFields(type: .flagsChanged, characters: "", charactersIgnoringModifiers: "",
                             keyCode: keyCode, flags: flags, isARepeat: false)
        }

        var characters: String
        var unmodified: String
        if let special = event.key.flatMap(functionCharacters(forKey:)) {
            characters = special.characters
            unmodified = special.characters
            flags.formUnion(special.flags)
            if event.key == "Tab", flags.contains(.shift) { characters = "\u{19}" } // back tab, as AppKit reports it
            // Enter types its line break as text (Chrome's `char`), which a
            // `rawKeyDown` has none of. The other named keys act through the
            // text system's bindings on the key down, as in Chrome.
            if event.kind == .rawKeyDown, event.key == "Enter" { characters = "" }
        } else {
            // `rawKeyDown` is a key down without text: the page sees the key but
            // no character is typed.
            let typed = event.kind == .rawKeyDown ? "" : (event.text ?? "")
            let keyText = event.key.flatMap { $0.count == 1 ? $0 : nil } ?? typed
            characters = typed
            unmodified = event.unmodifiedText ?? (keyText.isEmpty ? typed : keyText)
            if flags.contains(.control), let control = controlCharacter(unmodified) {
                // What the keyboard produces for Control+letter, and what the
                // text system's bindings (Ctrl+A, Ctrl+E, …) match.
                // Also for a `rawKeyDown`: a control character is never typed,
                // and it is what makes the binding (Ctrl+K: delete to the end) run.
                characters = control
            }
            if event.kind == .keyUp { characters = event.text ?? keyText }
        }
        if event.kind == .keyUp, characters.isEmpty { characters = unmodified }
        return KeyFields(type: type, characters: characters, charactersIgnoringModifiers: unmodified,
                         keyCode: keyCode, flags: flags, isARepeat: event.autoRepeat)
    }

    /// A key code no key has, so WebKit reports the code as "Unidentified".
    static let unknownKeyCode: UInt16 = 0xFF

    private static func controlCharacter(_ text: String) -> String? {
        guard text.count == 1, let scalar = text.lowercased().unicodeScalars.first,
              ("a"..."z").contains(Character(scalar)) else { return nil }
        return String(Character(UnicodeScalar(UInt8(scalar.value - 0x60))))
    }

    /// The characters AppKit reports for a key that types none of its own.
    static func functionCharacters(forKey key: String) -> (characters: String, flags: NSEvent.ModifierFlags)? {
        func function(_ value: Int, _ flags: NSEvent.ModifierFlags = .function) -> (String, NSEvent.ModifierFlags) {
            (String(Character(UnicodeScalar(UInt16(value))!)), flags)
        }
        switch key {
        case "Enter": return ("\r", [])
        case "Tab": return ("\t", [])
        case "Backspace": return ("\u{7F}", [])
        case "Escape": return ("\u{1B}", [])
        case "Delete": return function(NSDeleteFunctionKey)
        case "Insert": return function(NSHelpFunctionKey)
        case "Home": return function(NSHomeFunctionKey)
        case "End": return function(NSEndFunctionKey)
        case "PageUp": return function(NSPageUpFunctionKey)
        case "PageDown": return function(NSPageDownFunctionKey)
        case "ArrowUp": return function(NSUpArrowFunctionKey, [.function, .numericPad])
        case "ArrowDown": return function(NSDownArrowFunctionKey, [.function, .numericPad])
        case "ArrowLeft": return function(NSLeftArrowFunctionKey, [.function, .numericPad])
        case "ArrowRight": return function(NSRightArrowFunctionKey, [.function, .numericPad])
        default:
            if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...20).contains(n) {
                return function(NSF1FunctionKey + n - 1)
            }
            return nil
        }
    }

    static func domCode(forKey key: String) -> String? {
        if key.count == 1, let c = key.uppercased().first {
            if c.isLetter, c.isASCII { return "Key\(c)" }
            if c.isNumber, c.isASCII { return "Digit\(c)" }
            if c == " " { return "Space" }
        }
        switch key {
        case "Enter", "Tab", "Backspace", "Escape", "Delete", "Insert", "Home", "End", "PageUp", "PageDown",
             "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "CapsLock":
            return key
        case "Shift": return "ShiftLeft"
        case "Control": return "ControlLeft"
        case "Alt": return "AltLeft"
        case "Meta": return "MetaLeft"
        default:
            if key.hasPrefix("F"), let n = Int(key.dropFirst()), (1...20).contains(n) { return key }
            return nil
        }
    }

    static func domCode(forWindowsKeyCode code: Int) -> String? {
        switch code {
        case 65...90: return "Key\(Character(UnicodeScalar(UInt8(code))))"
        case 48...57: return "Digit\(code - 48)"
        case 96...105: return "Numpad\(code - 96)"
        case 112...131: return "F\(code - 111)"
        default: break
        }
        return windowsKeyCodeTable[code]
    }

    private static let windowsKeyCodeTable: [Int: String] = [
        8: "Backspace", 9: "Tab", 13: "Enter", 16: "ShiftLeft", 17: "ControlLeft", 18: "AltLeft",
        20: "CapsLock", 27: "Escape", 32: "Space", 33: "PageUp", 34: "PageDown", 35: "End", 36: "Home",
        37: "ArrowLeft", 38: "ArrowUp", 39: "ArrowRight", 40: "ArrowDown", 45: "Insert", 46: "Delete",
        91: "MetaLeft", 92: "MetaRight", 93: "ContextMenu", 106: "NumpadMultiply", 107: "NumpadAdd",
        109: "NumpadSubtract", 110: "NumpadDecimal", 111: "NumpadDivide", 186: "Semicolon", 187: "Equal",
        188: "Comma", 189: "Minus", 190: "Period", 191: "Slash", 192: "Backquote", 219: "BracketLeft",
        220: "Backslash", 221: "BracketRight", 222: "Quote",
    ]

    /// The Mac virtual key code (`kVK_…`) of a DOM `code`.
    static func macKeyCode(forDOMCode code: String) -> UInt16? {
        macKeyCodes[code].map { UInt16($0) }
    }

    private static let macKeyCodes: [String: Int] = [
        "KeyA": kVK_ANSI_A, "KeyB": kVK_ANSI_B, "KeyC": kVK_ANSI_C, "KeyD": kVK_ANSI_D, "KeyE": kVK_ANSI_E,
        "KeyF": kVK_ANSI_F, "KeyG": kVK_ANSI_G, "KeyH": kVK_ANSI_H, "KeyI": kVK_ANSI_I, "KeyJ": kVK_ANSI_J,
        "KeyK": kVK_ANSI_K, "KeyL": kVK_ANSI_L, "KeyM": kVK_ANSI_M, "KeyN": kVK_ANSI_N, "KeyO": kVK_ANSI_O,
        "KeyP": kVK_ANSI_P, "KeyQ": kVK_ANSI_Q, "KeyR": kVK_ANSI_R, "KeyS": kVK_ANSI_S, "KeyT": kVK_ANSI_T,
        "KeyU": kVK_ANSI_U, "KeyV": kVK_ANSI_V, "KeyW": kVK_ANSI_W, "KeyX": kVK_ANSI_X, "KeyY": kVK_ANSI_Y,
        "KeyZ": kVK_ANSI_Z,
        "Digit0": kVK_ANSI_0, "Digit1": kVK_ANSI_1, "Digit2": kVK_ANSI_2, "Digit3": kVK_ANSI_3,
        "Digit4": kVK_ANSI_4, "Digit5": kVK_ANSI_5, "Digit6": kVK_ANSI_6, "Digit7": kVK_ANSI_7,
        "Digit8": kVK_ANSI_8, "Digit9": kVK_ANSI_9,
        "Minus": kVK_ANSI_Minus, "Equal": kVK_ANSI_Equal, "BracketLeft": kVK_ANSI_LeftBracket,
        "BracketRight": kVK_ANSI_RightBracket, "Backslash": kVK_ANSI_Backslash, "Semicolon": kVK_ANSI_Semicolon,
        "Quote": kVK_ANSI_Quote, "Backquote": kVK_ANSI_Grave, "Comma": kVK_ANSI_Comma, "Period": kVK_ANSI_Period,
        "Slash": kVK_ANSI_Slash, "IntlBackslash": kVK_ISO_Section,
        "Enter": kVK_Return, "Tab": kVK_Tab, "Space": kVK_Space, "Backspace": kVK_Delete, "Escape": kVK_Escape,
        "Delete": kVK_ForwardDelete, "Insert": kVK_Help, "Home": kVK_Home, "End": kVK_End,
        "PageUp": kVK_PageUp, "PageDown": kVK_PageDown,
        "ArrowLeft": kVK_LeftArrow, "ArrowRight": kVK_RightArrow, "ArrowUp": kVK_UpArrow, "ArrowDown": kVK_DownArrow,
        "ShiftLeft": kVK_Shift, "ShiftRight": kVK_RightShift, "ControlLeft": kVK_Control,
        "ControlRight": kVK_RightControl, "AltLeft": kVK_Option, "AltRight": kVK_RightOption,
        "MetaLeft": kVK_Command, "MetaRight": kVK_RightCommand, "OSLeft": kVK_Command, "OSRight": kVK_RightCommand,
        "CapsLock": kVK_CapsLock, "Fn": kVK_Function,
        "F1": kVK_F1, "F2": kVK_F2, "F3": kVK_F3, "F4": kVK_F4, "F5": kVK_F5, "F6": kVK_F6, "F7": kVK_F7,
        "F8": kVK_F8, "F9": kVK_F9, "F10": kVK_F10, "F11": kVK_F11, "F12": kVK_F12, "F13": kVK_F13,
        "F14": kVK_F14, "F15": kVK_F15, "F16": kVK_F16, "F17": kVK_F17, "F18": kVK_F18, "F19": kVK_F19,
        "F20": kVK_F20,
        "Numpad0": kVK_ANSI_Keypad0, "Numpad1": kVK_ANSI_Keypad1, "Numpad2": kVK_ANSI_Keypad2,
        "Numpad3": kVK_ANSI_Keypad3, "Numpad4": kVK_ANSI_Keypad4, "Numpad5": kVK_ANSI_Keypad5,
        "Numpad6": kVK_ANSI_Keypad6, "Numpad7": kVK_ANSI_Keypad7, "Numpad8": kVK_ANSI_Keypad8,
        "Numpad9": kVK_ANSI_Keypad9, "NumpadDecimal": kVK_ANSI_KeypadDecimal,
        "NumpadMultiply": kVK_ANSI_KeypadMultiply, "NumpadAdd": kVK_ANSI_KeypadPlus,
        "NumpadSubtract": kVK_ANSI_KeypadMinus, "NumpadDivide": kVK_ANSI_KeypadDivide,
        "NumpadEnter": kVK_ANSI_KeypadEnter, "NumpadEqual": kVK_ANSI_KeypadEquals, "NumLock": kVK_ANSI_KeypadClear,
    ]

    /// Editing commands (`dispatchKeyEvent`'s `commands`, Mac only in Chrome)
    /// that macOS delivers through a menu item's key equivalent rather than
    /// the text system's key bindings — the ones a key event sent to the page
    /// does not perform by itself. Every other command a client lists
    /// (`deleteBackward`, `moveLeft`, …) the key event already performs
    /// through the bindings, and running it again would do it twice.
    static let menuCommands: [String: Selector] = [
        "selectAll": #selector(NSResponder.selectAll(_:)),
        "copy": #selector(NSText.copy(_:)),
        "cut": #selector(NSText.cut(_:)),
        "paste": #selector(NSText.paste(_:)),
        "pasteAndMatchStyle": #selector(NSTextView.pasteAsPlainText(_:)),
    ]

    /// The undo commands: performed only on a parked page, whose edits have an
    /// undo manager of their own. A displayed page's edits share the window's
    /// with the browser's own actions, where "undo" could reopen a tab.
    static let undoCommands: Set<String> = ["undo", "redo"]

    // MARK: The queue

    /// Each session's events, one at a time.
    private static var queues: [ObjectIdentifier: InputQueue] = [:]
    private static let endObservation: Void = {
        ExtensionDebuggerSessionEndObservers.add { session in
            ExtensionDebuggerInput.queues[ObjectIdentifier(session)] = nil
        }
    }()

    private static func queue(for session: ExtensionDebuggerSession) -> InputQueue {
        _ = endObservation
        if let queue = queues[ObjectIdentifier(session)] { return queue }
        let queue = InputQueue(session: session)
        queues[ObjectIdentifier(session)] = queue
        return queue
    }

    enum Work {
        case mouse(MouseEvent)
        case key(KeyEvent)
        case insertText(String)
    }

    private final class InputQueue {
        weak var session: ExtensionDebuggerSession?
        private var items: [(Work, ExtensionDebuggerReply)] = []
        private var isRunning = false

        init(session: ExtensionDebuggerSession) {
            self.session = session
        }

        func enqueue(_ work: Work, _ reply: ExtensionDebuggerReply) {
            items.append((work, reply))
            guard !isRunning else { return }
            isRunning = true
            Task { await drain() }
        }

        private func drain() async {
            while !items.isEmpty {
                let (work, reply) = items.removeFirst()
                // A reply already answered was failed by the session ending.
                guard !reply.isAnswered, let session,
                      ExtensionDebugger.shared.session(forTabUUID: session.tabUUID) === session else { continue }
                guard let webView = session.tab?.automationDrivableWebView(), webView.window != nil else {
                    reply.fail(code: internalErrorCode, message: "Internal error")
                    continue
                }
                await ExtensionDebuggerInput.perform(work, on: webView, reply: reply) { [weak session] in
                    guard let session else { return false }
                    return ExtensionDebugger.shared.session(forTabUUID: session.tabUUID) === session
                }
            }
            isRunning = false
        }
    }

    // MARK: Dispatch

    private static var eventNumber = 0

    /// `isLive` says whether the session still holds the tab: checked before
    /// anything is sent after a wait, so nothing reaches a page whose
    /// debugger has detached.
    private static func perform(_ work: Work, on webView: WKWebView, reply: ExtensionDebuggerReply,
                                isLive: @escaping () -> Bool) async {
        AutomationInput.beginDispatch(to: webView)
        defer { AutomationInput.endDispatch(to: webView) }
        switch work {
        case .mouse(let event):
            await dispatchMouse(event, to: webView, isLive: isLive)
            reply.succeed()
        case .key(let event):
            await dispatchKey(event, to: webView, isLive: isLive)
            reply.succeed()
        case .insertText(let text):
            insertText(text, into: webView)
            await acknowledge(webView)
            reply.succeed()
        }
    }

    private static func insertText(_ text: String, into webView: WKWebView) {
        // `NSTextInputClient`, which WKWebView implements without declaring it.
        guard !text.isEmpty, let client = webView as? NSTextInputClient else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Where a CSS point of the viewport is in the web view's window — the same
    /// mapping a screenshot uses (`ExtensionDebuggerScreenshot.geometry`), so a
    /// point read off a screenshot lands on what it shows, at any page zoom.
    private static func locationInWindow(cssX: Double, cssY: Double, in webView: WKWebView) async -> NSPoint {
        let viewport = await ExtensionDebuggerScreenshot.readViewport(webView)
        let size = webView.bounds.size
        let scale = viewport.map { $0.width > 0 ? size.width / $0.width : 1 } ?? 1
        let inView = NSPoint(x: cssX * scale, y: webView.isFlipped ? cssY * scale : size.height - cssY * scale)
        return webView.convert(inView, to: nil)
    }

    private static func dispatchMouse(_ event: MouseEvent, to webView: WKWebView, isLive: () -> Bool) async {
        guard let type = event.eventType, webView.window != nil else { return }
        let location = await locationInWindow(cssX: event.x, cssY: event.y, in: webView)
        guard isLive(), let window = webView.window, let nsEvent = makeMouseEvent(event, type: type, location: location, windowNumber: window.windowNumber)
        else { return }
        AutomationInput.sendMouse(nsEvent, to: webView)
        await acknowledge(webView)
    }

    static func makeMouseEvent(_ event: MouseEvent, type: NSEvent.EventType, location: NSPoint,
                               windowNumber: Int) -> NSEvent? {
        eventNumber += 1
        let flags = modifierFlags(event.modifiers)
        let isPress = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        let isDrag = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type)
        let pressure = Float(event.force ?? (isPress || isDrag ? 1 : 0))
        let clicks = isPress || [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) ? max(1, event.clickCount) : 0
        switch type {
        case .scrollWheel, .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            // AppKit's factory has no wheel events and no button number; these
            // are made from a CGEvent. One with no window reports its location
            // in screen coordinates as `locationInWindow`, so the CGEvent is
            // placed where the screen point equals the window point WebKit reads.
            let cgEvent: CGEvent?
            if type == .scrollWheel {
                cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: Int32(-event.deltaY.rounded()), wheel2: Int32(-event.deltaX.rounded()),
                                  wheel3: 0)
            } else {
                let cgType: CGEventType = type == .otherMouseDown ? .otherMouseDown
                    : type == .otherMouseUp ? .otherMouseUp : .otherMouseDragged
                let button = type == .otherMouseDragged ? event.draggedButton : event.button
                cgEvent = CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: .zero,
                                  mouseButton: CGMouseButton(rawValue: UInt32(button.number)) ?? .center)
                cgEvent?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.number))
                cgEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
                cgEvent?.setDoubleValueField(.mouseEventPressure, value: Double(pressure))
            }
            guard let cgEvent else { return nil }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            cgEvent.location = CGPoint(x: location.x, y: primaryHeight - location.y)
            cgEvent.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
            return NSEvent(cgEvent: cgEvent)
        default:
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                                      context: nil, eventNumber: eventNumber, clickCount: clicks, pressure: pressure)
        }
    }

    private static func dispatchKey(_ event: KeyEvent, to webView: WKWebView, isLive: () -> Bool) async {
        guard let fields = keyFields(event) else {
            // `char`: text input, without a key down of its own.
            insertText(event.text ?? "", into: webView)
            await acknowledge(webView)
            return
        }
        guard let window = webView.window,
              let nsEvent = NSEvent.keyEvent(with: fields.type, location: .zero, modifierFlags: fields.flags,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             characters: fields.characters,
                                             charactersIgnoringModifiers: fields.charactersIgnoringModifiers,
                                             isARepeat: fields.isARepeat, keyCode: fields.keyCode) else { return }
        let commands = fields.type == .keyDown ? event.commands.filter {
            menuCommands[$0] != nil || (undoCommands.contains($0) && webView.isInAutomationParking)
        } : []
        if commands.isEmpty {
            AutomationInput.sendKey(nsEvent, to: webView)
            await acknowledge(webView)
            return
        }
        // Chrome performs the commands when the page did not cancel the key
        // down. The main frame's key downs are watched from Detour's own world
        // to learn that; a key down into a frame below is not seen, and its
        // commands run regardless.
        await watchKeyDowns(webView)
        guard isLive() else { return }
        AutomationInput.sendKey(nsEvent, to: webView)
        let prevented = await keyDownWasPrevented(webView)
        guard !prevented, isLive() else { return }
        for command in commands {
            if let selector = menuCommands[command] {
                if webView.responds(to: selector) { webView.perform(selector, with: nil) }
            } else if command == "undo" {
                webView.undoManager?.undo()
            } else if command == "redo" {
                webView.undoManager?.redo()
            }
        }
        await acknowledge(webView)
    }

    private static func watchKeyDowns(_ webView: WKWebView) async {
        let script = """
        if (!window.__detourKeyDowns) {
            window.__detourKeyDowns = { last: null };
            window.addEventListener('keydown', (event) => { window.__detourKeyDowns.last = event; }, true);
        }
        window.__detourKeyDowns.last = null;
        return 1;
        """
        _ = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                   contentWorld: ExtensionDebugger.contentWorld)
    }

    /// Also the acknowledgement of the key down.
    private static func keyDownWasPrevented(_ webView: WKWebView) async -> Bool {
        let script = "const last = window.__detourKeyDowns && window.__detourKeyDowns.last; return last ? last.defaultPrevented : false;"
        let prevented: Bool? = await withTimeout {
            let answer = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                                contentWorld: ExtensionDebugger.contentWorld)
            return (answer as? NSNumber)?.boolValue ?? false
        }
        return prevented ?? false
    }

    static let acknowledgementTimeout: Duration = .seconds(10)

    /// Returns once the page has handled the event just sent: a round trip
    /// through the page's main thread behind it. Given up on after
    /// `acknowledgementTimeout` — a page stuck in a script answers nothing, and
    /// Chrome would report the event handled when it reached the page.
    private static func acknowledge(_ webView: WKWebView) async {
        let _: Bool? = await withTimeout {
            _ = try? await webView.callAsyncJavaScript("return 1", arguments: [:], in: nil,
                                                       contentWorld: ExtensionDebugger.contentWorld)
            return true
        }
    }

    /// `body`'s result, or nil if it takes longer than `acknowledgementTimeout`.
    private static func withTimeout<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            var finished = false
            var timer: Task<Void, Never>?
            let finish: (T?) -> Void = { value in
                guard !finished else { return }
                finished = true
                timer?.cancel()
                continuation.resume(returning: value)
            }
            timer = Task {
                guard (try? await Task.sleep(for: acknowledgementTimeout)) != nil else { return }
                finish(nil)
            }
            Task { finish(await body()) }
        }
    }
}
