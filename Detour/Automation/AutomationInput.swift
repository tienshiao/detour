import AppKit
import WebKit

/// How the automation endpoint delivers input inside the app (TASK-228.1,
/// AC #2): nothing is posted at the HID level, so Detour never comes to the
/// front and the person's pointer never moves.
///
/// What is known to work while Detour is not the active app (see the wiki's
/// in-process automation playbook):
/// - A web view takes a click handed to it directly (`mouseDown(with:)`, a
///   short pause, `mouseUp(with:)`) as a person's click. The same click posted
///   through `NSApp.postEvent` is swallowed by an inactive app (only a
///   Cmd-click gets through).
/// - A native view gets the press with the mouse-up already posted to the
///   app's event queue, where a tracking loop (`NSCell.trackMouse`, a view's
///   own `nextEvent` loop) finds it. A left press on a view that accepts a
///   first click goes through the window's own routing (`NSWindow.sendEvent`),
///   press and release: AppKit's controls track a click with gesture
///   recognizers only that routing feeds (`deliversThroughWindow`).
/// - Keys go to the target's `keyDown(with:)`; a character with no US key
///   goes as a key press with no physical key, so it stays in order.
enum AutomationInput {

    /// Posted (object: the window) with each mouse-down and key-down an input
    /// tool delivers, the event under `eventKey`. Handing events to views
    /// skips `NSApp.sendEvent`, so no local event monitor
    /// (`NSEvent.addLocalMonitorForEvents`) sees them; a component whose
    /// behaviour hangs on a monitor listens here too (the window's last web
    /// click, which places a download's flight, TASK-324).
    static let didDeliverEventNotification = Notification.Name("DetourAutomationDidDeliverEvent")
    static let eventKey = "event"

    static func announce(_ event: NSEvent, in window: NSWindow) {
        NotificationCenter.default.post(name: didDeliverEventNotification, object: window,
                                        userInfo: [eventKey: event])
    }

    // MARK: Running input from the run loop

    /// Runs `body` from the main run loop and waits up to `wait` for it to
    /// return. True when it returned within the wait.
    ///
    /// From the run loop (`RunLoop.perform`), not from a main-queue block:
    /// input that opens a menu or a modal session spins a nested run loop, and
    /// GCD never drains the main queue inside one of its own blocks. Run from a
    /// block (a main-actor job is one), it would stall the wait below and every
    /// other main-actor job, so the endpoint could answer nothing, not even the
    /// call that chooses the open menu's item, until the menu or alert closed.
    static func runFromRunLoop(wait: Duration, _ body: @escaping @MainActor () -> Void) async -> Bool {
        final class Once {
            var continuation: CheckedContinuation<Bool, Never>?
            /// Cancelled when the body returns, so typing a long text does not
            /// leave a pending timer per key event.
            var timeout: Task<Void, Never>?
            func finish(_ value: Bool) {
                timeout?.cancel()
                timeout = nil
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            once.continuation = continuation
            // A main-actor job: the main queue drains inside a nested run loop
            // spun from the run-loop block below, so it fires during a menu.
            once.timeout = Task {
                guard (try? await Task.sleep(for: wait)) != nil else { return }
                once.finish(false)
            }
            RunLoop.main.perform(inModes: [.common]) {
                // Not a crossing: the main run loop runs this on the main thread.
                MainActor.assumeIsolated {
                    body()
                    once.finish(true)
                }
            }
        }
    }

    // MARK: Modifiers and buttons

    /// "cmd", "shift", "option", "control" (and their aliases).
    static func modifiers(_ names: [String]) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "opt", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            default: throw AutomationToolError(.invalidArguments, "Unknown modifier \"\(name)\"")
            }
        }
        return flags
    }

    enum Button: String {
        case left, right
    }

    // MARK: Mouse events

    private static var eventNumber = 1_000_000

    static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                           modifiers: NSEvent.ModifierFlags, clickCount: Int) -> NSEvent? {
        eventNumber += 1
        let pressed = type == .leftMouseDown || type == .rightMouseDown
        // Apart from the last one's by more than `sameTime` tells apart.
        let timestamp = max(ProcessInfo.processInfo.systemUptime, (syntheticTimestamps.last ?? 0) + 0.000_01)
        syntheticTimestamps.append(timestamp)
        if syntheticTimestamps.count > 32 { syntheticTimestamps.removeFirst(syntheticTimestamps.count - 32) }
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                  timestamp: timestamp,
                                  windowNumber: window.windowNumber, context: nil,
                                  eventNumber: eventNumber, clickCount: clickCount, pressure: pressed ? 1 : 0)
    }

    /// The timestamps of the latest mouse events made here: how one is told
    /// from a person's once it is current (posting renumbers an event, but
    /// keeps its time to the nanosecond, `sameTime`).
    private static var syntheticTimestamps: [TimeInterval] = []

    /// Whether `event` is a mouse event an input tool made.
    static func isSynthetic(_ event: NSEvent) -> Bool {
        syntheticTimestamps.contains { sameTime($0, event.timestamp) }
    }

    /// Whether two event timestamps are the same time. Posting keeps an
    /// event's time only to the nanosecond (the window server's clock), so
    /// the double read back is not equal to the one given
    /// (725491.8170181251 came back as 725491.817018125).
    static func sameTime(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        abs(a - b) < 0.000_001
    }

    /// The window of the person's event that an input tool's `makeCurrent`
    /// last displaced as the current event. The menu tracker asks it while
    /// a tool's event is still current: a WebKit context menu opens some
    /// time after the person's right click, and a `hit_test` run in between
    /// must not make it look as if it opened over the tool's window.
    private(set) static weak var displacedEventWindow: NSWindow?

    /// What a click hit.
    enum Target {
        case webView(WKWebView)
        case view(NSView)
    }

    /// Makes `event` the application's current event, as `NSApp.sendEvent`
    /// does while it dispatches one: posted to the front of the queue and
    /// taken off again (`nextEvent` with dequeue sets `currentEvent`).
    /// Handing an event to a view skips that, and AppKit reads the current
    /// event in places: `NSTableView.hitTest` sends a press on a row's label
    /// or icon to the table itself only while the current event is a mouse
    /// press, and otherwise to the label, whose `rightMouseDown` inside a
    /// table opens no menu (TASK-228.7).
    /// Taken off in a run-loop mode of its own (`privateMode`). The person's
    /// event it displaces is remembered (`displacedEventWindow`). Never left
    /// in the queue: dispatched later, it would be a real click that no
    /// tool's check saw. False when it did not become current.
    @discardableResult
    static func makeCurrent(_ event: NSEvent) -> Bool {
        if let current = NSApp.currentEvent, !isSynthetic(current) { displacedEventWindow = current.window }
        let mask = NSEvent.EventTypeMask(type: event.type)
        NSApp.postEvent(event, atStart: true)
        let taken = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: privateMode, dequeue: true)
        if let taken, sameTime(taken.timestamp, event.timestamp) { return true }
        // Not expected: drop what is left of this kind rather than let it be
        // dispatched.
        if let marker = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                           context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.discardEvents(matching: mask, before: marker)
        }
        return false
    }

    /// A run-loop mode with nothing else in it, for taking events off the
    /// queue inside a caller: in a common mode such as `.eventTracking`,
    /// `nextEvent` would also run pending common-mode work (another tool's
    /// `runFromRunLoop` body, main-actor jobs) inside it.
    private static let privateMode = RunLoop.Mode("DetourAutomationMakeCurrent")

    /// The deepest view under `point` (window coordinates), as the window's
    /// own hit test finds it for a press of `button` there: with that press
    /// as the current event (`makeCurrent`), as during AppKit's dispatch.
    /// Its release is made current afterwards, so no press is left current
    /// for code that reads the current event later (a context menu opened
    /// on a current press waits for its release and stops the main queue).
    static func hitView(at point: NSPoint, in window: NSWindow, button: Button = .left,
                        modifiers: NSEvent.ModifierFlags = []) -> NSView? {
        guard let frameView = window.contentView?.superview ?? window.contentView else { return nil }
        let (downType, upType): (NSEvent.EventType, NSEvent.EventType) =
            button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        guard let press = mouseEvent(downType, at: point, in: window, modifiers: modifiers, clickCount: 1),
              let release = mouseEvent(upType, at: point, in: window, modifiers: modifiers, clickCount: 1)
        else { return frameView.hitTest(point) }
        makeCurrent(press)
        let hit = frameView.hitTest(point)
        makeCurrent(release)
        return hit
    }

    /// What a click at `hit` reaches: the web view it is inside, or the view.
    static func target(for hit: NSView) -> Target {
        var view: NSView? = hit
        while let current = view {
            if let webView = current as? WKWebView { return .webView(webView) }
            view = current.superview
        }
        return .view(hit)
    }

    /// The view a press of `button` at `point` (window coordinates) reaches,
    /// or the web view it is inside.
    static func target(at point: NSPoint, in window: NSWindow, button: Button = .left,
                       modifiers: NSEvent.ModifierFlags = []) -> Target? {
        hitView(at: point, in: window, button: button, modifiers: modifiers).map(target(for:))
    }

    /// Whether a left press on `view` (the view the tool hit-tested and
    /// checked) goes through the window's own routing, `NSWindow.sendEvent`,
    /// rather than to `view.mouseDown` directly. AppKit's own controls
    /// (`NSSwitch`, `NSButton`, `NSPopUpButton`, not subclassed) track a click
    /// with gesture recognizers that only that routing feeds: their
    /// `mouseDown` returns at once and runs no tracking loop, so a switch
    /// handed the press never toggled and a pop-up never opened (TASK-228.8).
    /// A subclass that overrides `mouseDown` still tracks the old way.
    ///
    /// Only when `view` accepts a first click: the window drops a press on a
    /// view that does not while Detour is in the background or the window is
    /// not key, and the endpoint's clicks work in the background. Such views
    /// (most of Detour's own) keep getting the press directly. And only when
    /// the window's hit test, with `press` current as during dispatch, still
    /// finds `view`, so the press never reaches a view the tool did not
    /// check (Settings' Automation section). Not for a view that delays
    /// window ordering for the press (a sidebar row, so it can be dragged out
    /// of a background window): through the window, the sidebar's table ran
    /// no tracking loop for the press, so such a view keeps the direct route
    /// it had before. Never for a view whose class overrides `mouseDown`
    /// (it tracks the press itself, and some of Detour's read
    /// `acceptsFirstMouse` as "this press activates the window", so it is
    /// not asked: Quick Detour's title-bar buttons drop such a press).
    static func deliversThroughWindow(_ press: NSEvent, to view: NSView, in window: NSWindow) -> Bool {
        guard !overridesMouseDown(view), view.acceptsFirstMouse(for: press),
              !view.shouldDelayWindowOrdering(for: press),
              let frameView = window.contentView?.superview ?? window.contentView else { return false }
        return frameView.hitTest(press.locationInWindow) === view
    }

    /// Whether `view`'s class, or a class between it and AppKit's own, has a
    /// `mouseDown(with:)` of its own.
    static func overridesMouseDown(_ view: NSView) -> Bool {
        let appKit = Bundle(for: NSView.self)
        let viewClass: AnyClass = Swift.type(of: view)
        var appKitClass: AnyClass = viewClass
        while Bundle(for: appKitClass) != appKit, let superclass = class_getSuperclass(appKitClass) {
            appKitClass = superclass
        }
        let selector = #selector(NSView.mouseDown(with:))
        return class_getMethodImplementation(viewClass, selector) != class_getMethodImplementation(appKitClass, selector)
    }

    /// Moves keyboard focus to `view` as a person's left click does (NSWindow
    /// does it in `sendEvent`, which a mouse-down handed to the view skips),
    /// unless focus is already inside it.
    static func focus(_ view: NSView, in window: NSWindow) {
        if let current = window.firstResponder as? NSView, current.isDescendant(of: view) { return }
        guard view.acceptsFirstResponder else { return }
        window.makeFirstResponder(view)
    }

    /// Clicks at `point` (window coordinates) on `target`, `count` times in a
    /// row (2 is a double click). Returns false when a mouse-down was still
    /// running after `wait` (it opened a menu or a modal session).
    static func click(_ target: Target, at point: NSPoint, in window: NSWindow, button: Button,
                      modifiers: NSEvent.ModifierFlags, count: Int, wait: Duration) async -> Bool {
        let (downType, upType): (NSEvent.EventType, NSEvent.EventType) =
            button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        for clickCount in 1...max(1, count) {
            guard let down = mouseEvent(downType, at: point, in: window, modifiers: modifiers, clickCount: clickCount),
                  let up = mouseEvent(upType, at: point, in: window, modifiers: modifiers, clickCount: clickCount)
            else { return true }
            switch target {
            case .webView(let webView):
                let returned = await runFromRunLoop(wait: wait) {
                    // Before delivery, as a local monitor sees an event.
                    announce(down, in: window)
                    if button == .left {
                        focus(webView, in: window)
                        webView.mouseDown(with: down)
                    } else {
                        webView.rightMouseDown(with: down)
                    }
                }
                guard returned else { return false }
                // WebKit takes a down and an up in the same turn as no click.
                try? await Task.sleep(for: .milliseconds(60))
                let upReturned = await runFromRunLoop(wait: wait) {
                    if button == .left { webView.mouseUp(with: up) } else { webView.rightMouseUp(with: up) }
                }
                guard upReturned else { return false }
            case .view(let view):
                // A tracking loop finds the mouse-up in the queue.
                NSApp.postEvent(up, atStart: false)
                let returned = await runFromRunLoop(wait: wait) {
                    announce(down, in: window)
                    // Current while it is handled, as in AppKit's dispatch.
                    makeCurrent(down)
                    var routed = false
                    if button == .left {
                        // Decided before focus moves, which can put a field
                        // editor over the view and change the hit test.
                        routed = deliversThroughWindow(down, to: view, in: window)
                        focus(view, in: window)
                        if routed { window.sendEvent(down) } else { view.mouseDown(with: down) }
                    } else {
                        view.rightMouseDown(with: down)
                    }
                    // A press that ran no tracking loop leaves the mouse-up
                    // queued; the window would later hand it to another view.
                    // It goes where AppKit's dispatch sends a release: through
                    // the window on that route (to the view that took the
                    // press and to the gesture recognizers tracking it),
                    // otherwise to this view (a view that acts on mouseUp,
                    // such as the faux address bar's buttons). Found by its
                    // time: posting renumbers an event. Taken in
                    // `privateMode`, so no other work runs inside this body;
                    // taking it makes it the current event.
                    let mask: NSEvent.EventTypeMask = button == .left ? .leftMouseUp : .rightMouseUp
                    if let left = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: privateMode, dequeue: false),
                       sameTime(left.timestamp, up.timestamp),
                       let taken = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: privateMode, dequeue: true) {
                        if routed {
                            window.sendEvent(taken)
                        } else if button == .left {
                            view.mouseUp(with: up)
                        } else {
                            view.rightMouseUp(with: up)
                        }
                    }
                }
                guard returned else { return false }
            }
            if count > 1 { try? await Task.sleep(for: .milliseconds(30)) }
        }
        return true
    }

    // MARK: Keys

    /// US key codes, so a page's `event.code` and `keyCode` are what a person
    /// typing the character would give.
    private static let keyCodes: [Character: UInt16] = {
        var codes: [Character: UInt16] = [:]
        let letters: [(Character, UInt16)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1", 18), ("2", 19),
            ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28),
            ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38),
            ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47),
            ("`", 50), (" ", 49),
        ]
        for (character, code) in letters { codes[character] = code }
        return codes
    }()

    /// Characters typed with Shift on a US keyboard, and the key they are on.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    private static let namedKeyCodes: [String: UInt16] = [
        "\r": 36, "\t": 48, "\u{1B}": 53, "\u{8}": 51, "\u{F728}": 117,
        "\u{F700}": 126, "\u{F701}": 125, "\u{F702}": 123, "\u{F703}": 124, " ": 49,
    ]

    /// The key code for a character no US key types: not a real key, so the
    /// page sees no physical key (`event.code` is empty) but gets the text.
    static let unmappedKeyCode: UInt16 = 0xFF

    /// The key code and the modifiers a US keyboard needs for `character`, or
    /// nil when it has no key (it is inserted as text instead).
    static func key(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let code = namedKeyCodes[String(character)] { return (code, false) }
        if let code = keyCodes[character] { return (code, false) }
        if character.isUppercase, character.isASCII,
           let code = keyCodes[Character(character.lowercased())] { return (code, true) }
        if let base = shifted[character], let code = keyCodes[base] { return (code, true) }
        return nil
    }

    /// What `base` types with Shift held on a US keyboard: "A" for "a", "!"
    /// for "1", back-tab for Tab. `base` itself when Shift changes nothing.
    static func shiftedCharacters(of base: Character) -> String {
        if base == "\t" { return "\u{19}" }
        if base.isASCII, base.isLetter { return base.uppercased() }
        if let found = shifted.first(where: { $0.value == base }) { return String(found.key) }
        return String(base)
    }

    /// The key events for `key` (a character, as `AutomationMenus.parseKeyEquivalent`
    /// gives it) pressed with `modifiers`, as a US keyboard sends them. A
    /// character with no US key goes with no physical key.
    static func keyEvents(for key: Character, modifiers: NSEvent.ModifierFlags,
                          in window: NSWindow) -> (NSEvent, NSEvent)? {
        let mapped = self.key(for: key)
        var flags = modifiers
        if mapped?.shift == true { flags.insert(.shift) }
        let base = String(key)
        var typed = base
        var ignoring = base
        if flags.contains(.shift), mapped?.shift != true {
            // Shift-Tab is back-tab in both strings, as a real one is.
            if key == "\t" { ignoring = "\u{19}" }
            if !flags.contains(.command) || key == "\t" { typed = shiftedCharacters(of: key) }
        }
        return keyEvents(characters: typed, ignoringModifiers: ignoring, code: mapped?.code ?? unmappedKeyCode,
                         modifiers: flags, in: window)
    }

    static func keyEvents(characters: String, ignoringModifiers: String, code: UInt16,
                          modifiers: NSEvent.ModifierFlags, in window: NSWindow) -> (NSEvent, NSEvent)? {
        // The Delete key sends DEL (NSDeleteCharacter), not backspace, which is
        // what text input binds to deleteBackward:.
        let characters = characters == "\u{8}" ? "\u{7F}" : characters
        let ignoringModifiers = ignoringModifiers == "\u{8}" ? "\u{7F}" : ignoringModifiers
        var flags = modifiers
        if ["\u{F700}", "\u{F701}", "\u{F702}", "\u{F703}", "\u{F728}"].contains(ignoringModifiers) {
            flags.formUnion([.function, .numericPad])
        }
        func make(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
                             isARepeat: false, keyCode: code)
        }
        guard let down = make(.keyDown), let up = make(.keyUp) else { return nil }
        return (down, up)
    }

    /// Delivers one key press (down and up) to `responder` in `window`.
    static func press(_ down: NSEvent, _ up: NSEvent, to responder: NSResponder, in window: NSWindow,
                      wait: Duration) async -> Bool {
        let returned = await runFromRunLoop(wait: wait) {
            announce(down, in: window)
            responder.keyDown(with: down)
        }
        guard returned else { return false }
        return await runFromRunLoop(wait: wait) { responder.keyUp(with: up) }
    }

    /// Types `text` into `responder`, one key press per character; a character
    /// with no US key is inserted as text. `interval` paces the characters.
    static func type(_ text: String, into responder: NSResponder, in window: NSWindow,
                     interval: Duration, wait: Duration) async -> Bool {
        for character in text {
            if let (code, shift) = key(for: character) {
                let typed = String(character)
                let base = shift ? String(shifted[character] ?? Character(typed.lowercased())) : typed
                guard let (down, up) = keyEvents(characters: typed, ignoringModifiers: base, code: code,
                                                 modifiers: shift ? .shift : [], in: window) else { continue }
                guard await press(down, up, to: responder, in: window, wait: wait) else { return false }
            } else {
                // A key press carrying the character, with no US key behind it:
                // AppKit's text input inserts its characters. Not insertText
                // directly: WebKit queues key events behind the page's
                // handling of earlier ones, and a direct insert overtook them
                // ("Ab!é" arrived as "Abé!").
                let typed = String(character)
                guard let (down, up) = keyEvents(characters: typed, ignoringModifiers: typed, code: unmappedKeyCode,
                                                 modifiers: [], in: window) else { continue }
                guard await press(down, up, to: responder, in: window, wait: wait) else { return false }
            }
            if interval > .zero { try? await Task.sleep(for: interval) }
        }
        return true
    }

    // MARK: Elements in a page

    /// The page's focused element in `webView`, in window coordinates, for
    /// the agent pointer's highlight (TASK-228.11); nil when nothing but the
    /// document has the focus or the page does not answer. In the client
    /// world, which the page's own scripts do not share.
    static func focusedElementRect(in webView: WKWebView) async -> NSRect? {
        let script = """
            let element = document.activeElement;
            while (element && element.shadowRoot && element.shadowRoot.activeElement) {
                element = element.shadowRoot.activeElement;
            }
            if (!element || element === document.body || element === document.documentElement) { return null; }
            const r = element.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) { return null; }
            return { x: r.left, y: r.top, width: r.width, height: r.height };
            """
        guard let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                                                   contentWorld: .defaultClient),
              let fields = result as? [String: Any],
              let x = (fields["x"] as? NSNumber)?.doubleValue, let y = (fields["y"] as? NSNumber)?.doubleValue,
              let width = (fields["width"] as? NSNumber)?.doubleValue,
              let height = (fields["height"] as? NSNumber)?.doubleValue else { return nil }
        // WKWebView is flipped, so CSS pixels convert directly once zoomed.
        let zoom = webView.pageZoom
        let rect = NSRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
            .intersection(webView.bounds)
        return rect.isEmpty ? nil : webView.convert(rect, to: nil)
    }

    /// The centre of the element `selector` matches in `webView`'s top
    /// document, in window coordinates, after scrolling it into view.
    static func elementPoint(_ selector: String, in webView: WKWebView) async throws -> NSPoint {
        let script = """
            let element;
            try { element = document.querySelector(selector); }
            catch (e) { return { error: "invalid", message: String(e) }; }
            if (!element) { return { error: "nomatch" }; }
            element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
            const r = element.getBoundingClientRect();
            const x = r.left + r.width / 2, y = r.top + r.height / 2;
            if (r.width === 0 || r.height === 0 || x < 0 || y < 0 || x > innerWidth || y > innerHeight) {
                return { error: "hidden" };
            }
            return { x: x, y: y };
            """
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(script, arguments: ["selector": selector],
                                                           in: nil, contentWorld: .defaultClient)
        } catch {
            throw AutomationToolError(.internalError, "The page did not answer: \(error.localizedDescription)")
        }
        guard let fields = result as? [String: Any] else {
            throw AutomationToolError(.internalError, "The page returned no element position")
        }
        switch fields["error"] as? String {
        case "invalid"?:
            throw AutomationToolError(.invalidArguments, "Invalid selector: \(fields["message"] as? String ?? selector)")
        case "nomatch"?:
            throw AutomationToolError(.selectorNoMatch, "Nothing matches \(selector)")
        case "hidden"?:
            throw AutomationToolError(.elementNotVisible, "\(selector) has no visible box in the page")
        default:
            break
        }
        guard let x = (fields["x"] as? NSNumber)?.doubleValue, let y = (fields["y"] as? NSNumber)?.doubleValue else {
            throw AutomationToolError(.internalError, "The page returned no element position")
        }
        // WKWebView is flipped, so CSS pixels convert directly once zoomed.
        let zoom = webView.pageZoom
        return webView.convert(NSPoint(x: x * zoom, y: y * zoom), to: nil)
    }
}

/// The menus being tracked right now: a page's context menu, a pop-up
/// button's, a sidebar row's, the menu bar's (TASK-228.1, AC #3). AppKit
/// announces each through `NSMenu.didBeginTrackingNotification` and
/// `didEndTrackingNotification`; the newest is what `list_menu` shows.
final class AutomationMenuTracker {

    static let shared = AutomationMenuTracker()

    private(set) var openMenus: [NSMenu] = []
    /// How reachable the window each open menu opened over is (a person's
    /// context menu in a Private window, the menu bar while one is in
    /// front), and their submenus: `list_menu` and `choose_menu_item` refuse
    /// a menu the client may not reach. Absent means open.
    private var menuAccess: [ObjectIdentifier: AutomationWindowAccess] = [:]
    /// How far into Settings each open menu reaches, the same way: on the
    /// user's endpoint `choose_menu_item` refuses a menu over Settings, and
    /// everywhere one over its Automation section (TASK-228.7). Absent: none.
    private var menuSettingsReach: [ObjectIdentifier: AutomationSettingsReach] = [:]
    private var observers: [any NSObjectProtocol] = []

    var topMenu: NSMenu? { openMenus.last }

    /// How reachable the window `menu` opened over is.
    func access(of menu: NSMenu) -> AutomationWindowAccess {
        menuAccess[ObjectIdentifier(menu)] ?? .open
    }

    /// How far into Settings `menu` reaches.
    func settingsReach(of menu: NSMenu) -> AutomationSettingsReach {
        menuSettingsReach[ObjectIdentifier(menu)] ?? .none
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addMainObserver(forName: NSMenu.didBeginTrackingNotification, object: nil) { [weak self] note in
            guard let self, let menu = note.object as? NSMenu else { return }
            // Input tools deliver to a Private window only while allowed, so a
            // menu that opens with one under the person's last event, or in
            // front while Detour is active, is the person's own there. Errs
            // towards refusing: an agent's menu opened meanwhile is refused
            // too. The strictest of those and of the menus already open. While
            // a tool's event is current (a `hit_test` since the person's
            // right click), the person's last event's window counts too.
            let event = NSApp.currentEvent
            let displaced = event.flatMap { AutomationInput.isSynthetic($0) ? AutomationInput.displacedEventWindow : nil }
            let key = NSApp.isActive ? NSApp.keyWindow : nil
            let access = (openMenus.map { self.access(of: $0) } + [
                AutomationWindows.access(of: event?.window),
                AutomationWindows.access(of: displaced),
                AutomationWindows.access(of: key),
            ]).max() ?? .open
            let reach = (openMenus.map { self.settingsReach(of: $0) } + [
                // Not the displaced event's window: Settings shows no web
                // view, so its menus open while the person's press is current.
                AutomationWindows.settingsReach(of: event?.window, event: event),
                AutomationWindows.settingsReach(of: key),
            ]).max() ?? .none
            openMenus.removeAll { $0 === menu }
            openMenus.append(menu)
            menuAccess[ObjectIdentifier(menu)] = access == .open ? nil : access
            menuSettingsReach[ObjectIdentifier(menu)] = reach == .none ? nil : reach
        })
        observers.append(center.addMainObserver(forName: NSMenu.didEndTrackingNotification, object: nil) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            self?.openMenus.removeAll { $0 === menu }
            self?.menuAccess[ObjectIdentifier(menu)] = nil
            self?.menuSettingsReach[ObjectIdentifier(menu)] = nil
        })
    }

    /// Closes every open menu, newest first, and waits up to a second for
    /// AppKit to say they ended. True when none is left open.
    @discardableResult
    func closeAll() async -> Bool {
        guard !openMenus.isEmpty else { return true }
        for menu in openMenus.reversed() { menu.cancelTracking() }
        let deadline = ContinuousClock.now + .seconds(1)
        while !openMenus.isEmpty && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return openMenus.isEmpty
    }

    /// A menu's items as `list_menu` reports them.
    /// A Private window's Window-menu entry is left out (its index skipped)
    /// unless Private is allowed.
    static func describe(_ menu: NSMenu, allowPrivate: Bool) -> [JSONValue] {
        menu.items.enumerated().compactMap { index, item in
            if AutomationMenus.namesUnreachableWindow(item, allowPrivate: allowPrivate) { return nil }
            if item.isSeparatorItem {
                return ["index": .int(index), "separator": true, "title": ""]
            }
            return [
                "index": .int(index),
                "title": .string(AutomationMenus.displayTitle(item)),
                "enabled": .bool(item.isEnabled),
                "hidden": .bool(item.isHidden),
                "checked": .bool(item.state == .on),
                "has_submenu": .bool(item.submenu != nil),
                "identifier": .nullable(item.identifier?.rawValue),
                "key_equivalent": .string(item.keyEquivalent),
                "separator": false,
            ]
        }
    }
}
