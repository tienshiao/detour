import AppKit
import WebKit

/// The input and menu tools of TASK-228.1 (phase 2, AC #2 and #3): clicks,
/// typing and key presses delivered inside the app, and the items of
/// whatever menu is open. See `AutomationInput` for how delivery works while
/// Detour is not the active app.
extension AutomationTools {

    var inputTools: [MCPTool] {
        [click, typeText, pressKey, listMenu, chooseMenuItem, closeMenu, hitTest]
    }

    // MARK: Targets

    /// Where input goes: a window and a point in it, or a tab's web view.
    struct InputTarget {
        let controller: BrowserWindowController
        let window: NSWindow
        let webView: WKWebView?
    }

    /// The live tab a `context` names and the browser window showing it.
    /// Input needs a window: a tab no window shows is `not_displayed`
    /// (TASK-228.6 reaches those), a sleeping one `tab_asleep`. An
    /// extension's popup (TASK-228.2) is in its popover's window, a child of
    /// the browser window it was opened from, which `controller` names.
    func resolve(context value: String) throws -> InputTarget {
        let page = try resolvePageTarget(context: value)
        let webView = page.webView
        guard let window = webView.window,
              let controller = environment.windowControllers().first(where: {
                  $0.window === window || ($0.window != nil && $0.window === window.parent)
              }) else {
            throw AutomationToolError(.notDisplayed, "\(page.label) is not shown in a window"
                                        + (page.tab == nil ? " yet" : "; select it first"))
        }
        // The one Private predicate, over the window and what it hangs off.
        let access = AutomationWindows.access(of: window)
        guard access.allows(privateAllowed) else { throw access.refusal("The window showing \(page.label)") }
        return InputTarget(controller: controller, window: window, webView: webView)
    }

    /// A point given in a window's content, top-left origin, in window
    /// coordinates (AppKit's, bottom-left).
    func windowPoint(x: Double, y: Double, in window: NSWindow) throws -> NSPoint {
        guard let content = window.contentView else {
            throw AutomationToolError(.unknownWindow, "The window has no content")
        }
        let bounds = content.bounds
        guard x >= 0, y >= 0, x <= bounds.width, y <= bounds.height else {
            throw AutomationToolError(.invalidArguments,
                                      "(\(x), \(y)) is outside the window's content (\(bounds.width) × \(bounds.height))")
        }
        let local = NSPoint(x: x, y: content.isFlipped ? y : bounds.height - y)
        return content.convert(local, to: nil)
    }

    /// The reverse of `windowPoint`, for results.
    func contentPoint(_ point: NSPoint, in window: NSWindow) -> JSONValue {
        guard let content = window.contentView else { return .null }
        let local = content.convert(point, from: nil)
        let y = content.isFlipped ? local.y : content.bounds.height - local.y
        return ["x": .double((local.x * 10).rounded() / 10), "y": .double((y * 10).rounded() / 10)]
    }

    // MARK: click

    private var click: MCPTool {
        MCPTool(
            name: "click",
            title: "Click",
            description: "Clicks inside Detour without bringing it to the front or moving the pointer. With Detour "
                + "already active, a click in a window that is not key makes it key, as a person's click does (a tab "
                + "shown in two windows then moves its live page there); in the background it never does. Target an "
                + "element with context (a tab_id or tab:<id> from list_tabs) and selector (CSS, top document), or "
                + "a point: x and y in the window's content (top-left origin, points) with window_id (any kind of "
                + "window from list_windows), or in the "
                + "page's viewport (CSS pixels) with context. button right opens a context menu; then use "
                + "list_menu and choose_menu_item. A menu that is open is closed first, as a person's click elsewhere "
                + "closes it. A left click at a window point first hovers the views under it, as a person's "
                + "pointer does, so a control shown only on hover takes it (a sidebar tab row's close button, "
                + "at the row's right end); hit_test and screenshots do not show such a control. "
                + "completed is false when the click opened a menu or an alert that is still open.",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("A window from list_windows, with x and y")),
                ("context", .string("A tab_id or tab:<id>, popup:<ext> or options:<ext>, with selector or x and y")),
                ("selector", .string("A CSS selector for the element to click (its centre is clicked)")),
                ("x", .number("Horizontal position")),
                ("y", .number("Vertical position")),
                ("button", .enumeration(["left", "right"], "Mouse button (default left)")),
                ("modifiers", .stringArray("Held keys: cmd, shift, option, control")),
                ("count", .integer("Clicks in a row: 2 is a double click (default 1)")),
            ]),
            outputSchema: MCPSchema.output([
                "window_id": MCPSchema.integerType,
                "target": MCPSchema.stringType,
                "view": MCPSchema.stringType,
                "point": MCPSchema.objectType,
                "completed": MCPSchema.booleanType,
                "menu_open": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                try await inArrivalOrder {
                    guard let button = AutomationInput.Button(rawValue: try arguments.string("button") ?? "left") else {
                        throw AutomationToolError(.invalidArguments, "button is left or right")
                    }
                    let modifiers = try AutomationInput.modifiers(arguments.stringArray("modifiers") ?? [])
                    let count = try arguments.int("count") ?? 1
                    guard (1...3).contains(count) else {
                        throw AutomationToolError(.invalidArguments, "count is 1, 2 or 3")
                    }
                    let x = try arguments.number("x"), y = try arguments.number("y")
                    guard (x == nil) == (y == nil) else { throw AutomationToolError(.invalidArguments, "Give x and y together") }

                    let controller: NSWindowController
                    let window: NSWindow
                    let point: NSPoint
                    var target: AutomationInput.Target
                    if let context = try arguments.string("context") {
                        guard !arguments.has("window_id") else {
                            throw AutomationToolError(.invalidArguments, "Give context or window_id, not both")
                        }
                        let resolved = try resolve(context: context)
                        guard let webView = resolved.webView else { throw AutomationToolError(.notDisplayed, "No web view") }
                        controller = resolved.controller
                        window = resolved.window
                        if let selector = try arguments.string("selector") {
                            guard x == nil else { throw AutomationToolError(.invalidArguments, "Give selector or x and y, not both") }
                            point = try await AutomationInput.elementPoint(selector, in: webView)
                        } else if let x, let y {
                            let zoom = webView.pageZoom
                            let width = webView.bounds.width / zoom, height = webView.bounds.height / zoom
                            guard x >= 0, y >= 0, x <= width, y <= height else {
                                throw AutomationToolError(.invalidArguments,
                                                          "(\(x), \(y)) is outside the page's viewport (\(width) × \(height))")
                            }
                            point = webView.convert(NSPoint(x: x * zoom, y: y * zoom), to: nil)
                        } else {
                            throw AutomationToolError(.invalidArguments, "With context, give selector or x and y")
                        }
                        // Straight to the page, as a person's click on it would go.
                        target = .webView(webView)
                    } else if let windowID = try arguments.int("window_id") {
                        guard !arguments.has("selector") else {
                            throw AutomationToolError(.invalidArguments, "selector needs context")
                        }
                        let addressed = try inputWindow(id: windowID)
                        controller = addressed.controller
                        window = addressed.window
                        guard let x, let y else { throw AutomationToolError(.invalidArguments, "With window_id, give x and y") }
                        point = try windowPoint(x: x, y: y, in: window)
                        guard let hit = AutomationInput.target(at: point, in: window, button: button,
                                                               modifiers: modifiers) else {
                            throw AutomationToolError(.invalidArguments, "Nothing is under that point")
                        }
                        if case .view(let view) = hit { try refuseAutomationSettings(view) }
                        target = hit
                    } else {
                        throw AutomationToolError(.invalidArguments, "Give context and selector, or window_id with x and y")
                    }

                    // A person's click elsewhere dismisses an open menu; so does this
                    // one, once its arguments are known to be good.
                    await AutomationMenuTracker.shared.closeAll()
                    let byWindowPoint = !arguments.has("context")
                    // Checked again after the glide before the window is made
                    // key (the Private setting can change during it), and again
                    // after: the web view may have moved in.
                    if await glidePointer(to: point, in: window) {
                        target = try retarget(target, at: point, in: window, button: button, modifiers: modifiers,
                                              byWindowPoint: byWindowPoint)
                    }
                    if bringForward(window) {
                        target = try retarget(target, at: point, in: window, button: button, modifiers: modifiers,
                                              byWindowPoint: byWindowPoint)
                    }
                    // The pointer arrives before the press, as a person's
                    // does, so what shows on hover (a tab row's close button)
                    // takes it; the hit test and the gates run again. A left
                    // click on a native view only: a right click's menu runs
                    // until it closes, with no point to say the pointer left.
                    var hovered: [NSView] = []
                    defer { AutomationInput.pointerLeft(hovered, at: point, in: window) }
                    if byWindowPoint, button == .left, case .view(let view) = target {
                        hovered = AutomationInput.pointerArrived(at: point, in: window, over: view)
                        if !hovered.isEmpty {
                            target = try retarget(target, at: point, in: window, button: button, modifiers: modifiers,
                                                  byWindowPoint: true)
                        }
                    }
                    let completed = await AutomationInput.click(target, at: point, in: window, button: button,
                                                                modifiers: modifiers, count: count, wait: inputWait)
                    let (kind, view): (String, NSView) = switch target {
                    case .webView(let webView): ("web_view", webView)
                    case .view(let view): ("view", view)
                    }
                    return [
                        "window_id": .int(windowIDs.id(for: controller)),
                        "target": .string(kind),
                        "view": .string(String(describing: type(of: view))),
                        "point": contentPoint(point, in: window),
                        "completed": .bool(completed),
                        "menu_open": .bool(AutomationMenuTracker.shared.topMenu != nil),
                    ]
                }
            })
    }

    // MARK: The agent pointer (TASK-228.11)

    /// Runs an input tool's call after the input calls that came before it
    /// have delivered their events, while the agent pointer is on: a click
    /// then waits for its glide, and another client's call arriving
    /// meanwhile must not overtake it. `click`, `type_text`, `press_key`
    /// (TASK-228.11), `choose_menu_item` and `close_menu` (TASK-228.13): a
    /// menu choice sent during a click's glide acts on the menu that click
    /// opens. Off, calls run as they always did (an uncontended call never
    /// waits either way).
    func inArrivalOrder<T>(_ body: () async throws -> T) async throws -> T {
        guard environment.showsAgentPointer() else { return try await body() }
        return try await inputOrder.run(body)
    }

    /// Glides the agent pointer to `point` in `window` before a click there,
    /// when it is on and can be seen there. True when it was shown, and the
    /// click's target needs checking again (`retarget`): the glide is a wait
    /// between the checks and the delivery. With the pointer off this returns
    /// at once with nothing awaited, so the click gains no delay.
    func glidePointer(to point: NSPoint, in window: NSWindow) async -> Bool {
        guard environment.showsAgentPointer(), agentPointer.canShow(in: window) else { return false }
        await agentPointer.glide(to: point, in: window, slow: stagingInUse)
        return true
    }

    /// Makes `window` key before a click in it while Detour is the active
    /// app and it is not key, as a person's click does; between two browser
    /// windows showing one tab that moves the web view there
    /// (`windowDidBecomeKey` claims it; the other window shows the snapshot).
    /// With Detour in the background a click never activates Detour or
    /// changes the key window. Both are the user's decision (TASK-228.10,
    /// 2026-11-15). A press routed through the window would make it key by
    /// itself; this does it for every click, page and direct ones included,
    /// before the target is checked again. True when it asked, so the caller
    /// checks the target again (`retarget`): the view tree changes when the
    /// web view moves in.
    func bringForward(_ window: NSWindow) -> Bool {
        // Not a window on another Space: no person could click it from
        // where they are, and making it key would switch their desktop.
        guard environment.isAppActive(), !window.isKeyWindow, window.canBecomeKey, window.isVisible,
              window.isOnActiveSpace else { return false }
        environment.makeKey(window)
        return true
    }

    /// A click's target checked again after the pointer's glide, as it was
    /// before it: the window still open and reachable (the Private setting
    /// can change meanwhile), a page still in it, and for a window point what
    /// is under the point now, with the gate on Settings' Automation section.
    func retarget(_ target: AutomationInput.Target, at point: NSPoint, in window: NSWindow,
                  button: AutomationInput.Button, modifiers: NSEvent.ModifierFlags,
                  byWindowPoint: Bool) throws -> AutomationInput.Target {
        guard window.isVisible else { throw AutomationToolError(.notDisplayed, "The window closed") }
        let access = AutomationWindows.access(of: window)
        guard access.allows(privateAllowed) else { throw access.refusal("The window") }
        if !byWindowPoint {
            guard case .webView(let webView) = target, webView.window === window else {
                throw AutomationToolError(.notDisplayed, "The page left the window; select it first")
            }
            return target
        } else {
            guard let hit = AutomationInput.target(at: point, in: window, button: button, modifiers: modifiers) else {
                throw AutomationToolError(.invalidArguments, "Nothing is under that point")
            }
            if case .view(let view) = hit { try refuseAutomationSettings(view) }
            return hit
        }
    }

    /// Outlines what keys are about to go to, while the agent pointer is on:
    /// a control (a field editor's field), or the page's focused element (the
    /// web view when it has none). Never waits: a page's answer comes in
    /// while the keys are typed.
    func highlightKeyTarget(_ responder: NSResponder, in window: NSWindow) {
        guard environment.showsAgentPointer(), agentPointer.canShow(in: window) else { return }
        let pointer = agentPointer
        if let webView = responder as? WKWebView {
            Task { [self] in
                let rect = await AutomationInput.focusedElementRect(in: webView)
                    ?? webView.convert(webView.visibleRect, to: nil)
                // The setting can turn off while the page answers.
                guard environment.showsAgentPointer() else { return }
                pointer.highlight(rect, in: window)
            }
            return
        }
        guard let view = AutomationWindows.view(for: responder), view.window === window else { return }
        pointer.highlight(view.convert(view.visibleRect, to: nil), in: window)
    }

    // MARK: hit_test

    private var hitTest: MCPTool {
        MCPTool(
            name: "hit_test",
            title: "What is at a point",
            description: "Says what a click at x, y (the window's content, top-left origin, points) would reach: "
                + "the view's class, its accessibility role, label and title, and its frame in the same "
                + "coordinates. Changes nothing; use it to aim click.",
            inputSchema: MCPSchema.input([
                ("window_id", .integer("A window from list_windows")),
                ("x", .number("Horizontal position")),
                ("y", .number("Vertical position")),
            ], required: ["window_id", "x", "y"]),
            outputSchema: MCPSchema.output([
                "target": MCPSchema.stringType,
                "view": MCPSchema.stringType,
                "role": MCPSchema.nullableString,
                "label": MCPSchema.nullableString,
                "frame": MCPSchema.objectType,
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                let window = try anyWindow(id: try arguments.requiredInt("window_id")).window
                guard let content = window.contentView else {
                    throw AutomationToolError(.unknownWindow, "No window")
                }
                guard let x = try arguments.number("x"), let y = try arguments.number("y") else {
                    throw AutomationToolError(.invalidArguments, "Give x and y")
                }
                let point = try windowPoint(x: x, y: y, in: window)
                guard let hit = AutomationInput.hitView(at: point, in: window) else {
                    throw AutomationToolError(.invalidArguments, "Nothing is under that point")
                }
                let rect = hit.convert(hit.bounds, to: content)
                let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
                let kind = if case .webView = AutomationInput.target(for: hit) { "web_view" } else { "view" }
                let label = hit.accessibilityLabel() ?? (hit as? NSControl)?.stringValue
                return [
                    "target": .string(kind),
                    "view": .string(String(describing: type(of: hit))),
                    "role": .nullable(hit.accessibilityRole()?.rawValue),
                    "label": .nullable(label?.isEmpty == false ? label : (hit as? NSButton)?.title),
                    "frame": ["x": .double(rect.minX), "y": .double(top), "width": .double(rect.width),
                              "height": .double(rect.height)],
                ]
            })
    }

    // MARK: Keyboard targets

    /// The responder keys go to: a tab's web view (made its window's first
    /// responder, which does not activate Detour), or a window's first
    /// responder.
    private func keyTarget(_ arguments: ToolArguments) throws -> (NSWindowController, NSWindow, NSResponder) {
        if let context = try arguments.string("context") {
            guard !arguments.has("window_id") else {
                throw AutomationToolError(.invalidArguments, "Give context or window_id, not both")
            }
            let resolved = try resolve(context: context)
            guard let webView = resolved.webView else { throw AutomationToolError(.notDisplayed, "No web view") }
            AutomationInput.focus(webView, in: resolved.window)
            return (resolved.controller, resolved.window, webView)
        }
        guard let windowID = try arguments.int("window_id") else {
            throw AutomationToolError(.invalidArguments, "Give context or window_id")
        }
        let addressed = try inputWindow(id: windowID)
        let window = addressed.window
        guard let responder = window.firstResponder, responder !== window else {
            throw AutomationToolError(.invalidArguments, "Nothing in window \(windowID) has keyboard focus")
        }
        try refuseAutomationSettings(responder)
        return (addressed.controller, window, responder)
    }

    // MARK: type_text

    private var typeText: MCPTool {
        MCPTool(
            name: "type_text",
            title: "Type text",
            description: "Types text as key presses (US layout; other characters are inserted as text). With "
                + "context it goes to that tab's page, after clicking selector if one is given; with window_id it "
                + "goes to whatever has keyboard focus in the window (for example the command palette's field). "
                + "interval_ms paces the characters.",
            inputSchema: MCPSchema.input([
                ("text", .string("What to type")),
                ("context", .string("A tab_id or tab:<id>, popup:<ext> or options:<ext>")),
                ("selector", .string("With context: an element to click first, to focus it")),
                ("window_id", .integer("A window, to type into its focused control")),
                ("interval_ms", .integer("Pause between characters in milliseconds (default 0)")),
            ], required: ["text"]),
            outputSchema: MCPSchema.output([
                "window_id": MCPSchema.integerType,
                "typed": MCPSchema.integerType,
                "target": MCPSchema.stringType,
                "completed": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                try await inArrivalOrder {
                    let text = try arguments.requiredString("text")
                    let interval = try arguments.int("interval_ms") ?? 0
                    guard (0...5000).contains(interval) else {
                        throw AutomationToolError(.invalidArguments, "interval_ms is 0 to 5000")
                    }
                    let selector = try arguments.string("selector")
                    guard selector == nil || arguments.has("context") else {
                        throw AutomationToolError(.invalidArguments, "selector needs context")
                    }
                    // Every argument is checked before anything is clicked or closed.
                    let (controller, window, responder) = try keyTarget(arguments)
                    await AutomationMenuTracker.shared.closeAll()
                    if let selector, let webView = responder as? WKWebView {
                        let point = try await AutomationInput.elementPoint(selector, in: webView)
                        if await glidePointer(to: point, in: window) {
                            _ = try retarget(.webView(webView), at: point, in: window, button: .left, modifiers: [],
                                             byWindowPoint: false)
                        }
                        if bringForward(window) {
                            _ = try retarget(.webView(webView), at: point, in: window, button: .left, modifiers: [],
                                             byWindowPoint: false)
                        }
                        _ = await AutomationInput.click(.webView(webView), at: point, in: window, button: .left,
                                                        modifiers: [], count: 1, wait: inputWait)
                    }
                    highlightKeyTarget(responder, in: window)
                    let completed = await AutomationInput.type(text, into: responder, in: window,
                                                               interval: .milliseconds(interval), wait: inputWait)
                    return [
                        "window_id": .int(windowIDs.id(for: controller)),
                        "typed": .int(text.count),
                        "target": .string(String(describing: type(of: responder))),
                        "completed": .bool(completed),
                    ]
                }
            })
    }

    // MARK: press_key

    private var pressKey: MCPTool {
        MCPTool(
            name: "press_key",
            title: "Press a key",
            description: "Presses one key with optional modifiers, for example \"return\", \"escape\", \"down\", "
                + "\"tab\", \"shift+tab\" or \"cmd+a\", in a tab's page (context) or a window's focused control "
                + "(window_id). A key with cmd goes through the target's key equivalents; handled says whether "
                + "something took it. For a menu command use run_menu_item.",
            inputSchema: MCPSchema.input([
                ("key", .string("Modifiers and a key joined by +")),
                ("context", .string("A tab_id or tab:<id>, popup:<ext> or options:<ext>")),
                ("window_id", .integer("A window, for its focused control")),
            ], required: ["key"]),
            outputSchema: MCPSchema.output([
                "window_id": MCPSchema.integerType,
                "target": MCPSchema.stringType,
                "handled": MCPSchema.booleanType,
                "completed": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                try await inArrivalOrder {
                    let (characters, modifiers) = try AutomationMenus.parseKeyEquivalent(try arguments.requiredString("key"))
                    let (controller, window, responder) = try keyTarget(arguments)
                    guard let (down, up) = AutomationInput.keyEvents(for: characters.first ?? " ", modifiers: modifiers,
                                                                     in: window) else {
                        throw AutomationToolError(.internalError, "Could not make the key event")
                    }
                    await AutomationMenuTracker.shared.closeAll()
                    highlightKeyTarget(responder, in: window)
                    var handled = true
                    let completed: Bool
                    if down.modifierFlags.contains(.command) {
                        let view = (responder as? NSView) ?? window.contentView
                        completed = await AutomationInput.runFromRunLoop(wait: inputWait) {
                            AutomationInput.announce(down, in: window)
                            handled = view?.performKeyEquivalent(with: down) ?? false
                        }
                    } else {
                        completed = await AutomationInput.press(down, up, to: responder, in: window, wait: inputWait)
                    }
                    return [
                        "window_id": .int(windowIDs.id(for: controller)),
                        "target": .string(String(describing: type(of: responder))),
                        "handled": .bool(handled),
                        "completed": .bool(completed),
                    ]
                }
            })
    }

    // MARK: list_menu

    private var listMenu: MCPTool {
        MCPTool(
            name: "list_menu",
            title: "List the open menu",
            description: "Lists the items of the menu that is open now: a page's context menu after a right "
                + "click, a pop-up button's, a sidebar row's. Waits up to timeout_ms (default 2000) for one to "
                + "open. path lists a submenu instead. Fails with no_open_menu when none opens.",
            inputSchema: MCPSchema.input([
                ("timeout_ms", .integer("How long to wait for a menu to open (default 2000)")),
                ("path", .stringArray("Titles of submenus to descend into")),
            ]),
            outputSchema: MCPSchema.output([
                "title": MCPSchema.stringType,
                "items": MCPSchema.arrayOfObjects("Index, title, enabled, checked, has_submenu, identifier"),
            ]),
            annotations: ["readOnlyHint": true],
            handler: { [self] arguments in
                let menu = try await openMenu(timeout: try arguments.int("timeout_ms") ?? 2000)
                let target = try submenu(of: menu, path: try arguments.stringArray("path") ?? [])
                return ["title": .string(target.title),
                        "items": .array(AutomationMenuTracker.describe(target, allowPrivate: privateAllowed))]
            })
    }

    func openMenu(timeout milliseconds: Int) async throws -> NSMenu {
        let deadline = ContinuousClock.now + .milliseconds(max(0, min(milliseconds, 30_000)))
        while true {
            if let menu = AutomationMenuTracker.shared.topMenu {
                // Whether the menu opened over a Private window was noted when
                // it opened; whether that matters is asked now.
                let access = AutomationMenuTracker.shared.access(of: menu)
                guard access.allows(privateAllowed) else { throw access.refusal("The window the open menu is over") }
                return menu
            }
            if ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw AutomationToolError(.noOpenMenu, "No menu is open")
    }

    private func submenu(of menu: NSMenu, path: [String]) throws -> NSMenu {
        var current = menu
        for title in path {
            guard let item = current.items.first(where: { AutomationMenus.titlesMatch(AutomationMenus.displayTitle($0), title) }),
                  let next = item.submenu else {
                throw AutomationToolError(.unknownMenuItem, "No submenu \"\(title)\" in \(current.title)")
            }
            current = next
        }
        return current
    }

    // MARK: close_menu

    private var closeMenu: MCPTool {
        MCPTool(
            name: "close_menu",
            title: "Close the open menu",
            description: "Closes the menu that is open (as Escape would) without choosing anything. Fails with "
                + "no_open_menu when none is open. click, type_text and press_key also close an open menu first.",
            inputSchema: MCPSchema.input([]),
            outputSchema: MCPSchema.output(["closed": MCPSchema.booleanType]),
            annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true],
            handler: { [self] _ in
                // In the input order while the agent pointer is on
                // (TASK-228.13): a menu an earlier click opens is there to close.
                try await inArrivalOrder {
                    guard AutomationMenuTracker.shared.topMenu != nil else {
                        throw AutomationToolError(.noOpenMenu, "No menu is open")
                    }
                    return ["closed": .bool(await AutomationMenuTracker.shared.closeAll())]
                }
            })
    }

    // MARK: choose_menu_item

    private var chooseMenuItem: MCPTool {
        MCPTool(
            name: "choose_menu_item",
            title: "Choose an item of the open menu",
            description: "Chooses an item of the menu that is open now (see list_menu), by title, index or "
                + "identifier, inside path's submenu if given, and closes the menu. WebKit's own context-menu "
                + "items (Download Linked File, Copy Link) run their real actions.",
            inputSchema: MCPSchema.input([
                ("title", .string("The item's title")),
                ("index", .integer("The item's index from list_menu")),
                ("identifier", .string("The item's identifier from list_menu")),
                ("path", .stringArray("Titles of submenus to descend into first")),
                ("timeout_ms", .integer("How long to wait for a menu to open (default 2000)")),
            ]),
            outputSchema: MCPSchema.output([
                "title": MCPSchema.stringType,
                "completed": MCPSchema.booleanType,
            ]),
            annotations: ["readOnlyHint": false, "destructiveHint": true],
            handler: { [self] arguments in
                // In the input order while the agent pointer is on
                // (TASK-228.13): it runs once every earlier click and key is
                // delivered, so it chooses from the menu an earlier click
                // opened; timeout_ms counts from then.
                try await inArrivalOrder {
                    let locators = ["title", "index", "identifier"].filter { arguments.has($0) }
                    guard locators.count == 1 else {
                        throw AutomationToolError(.invalidArguments, "Give exactly one of title, index or identifier")
                    }
                    let root = try await openMenu(timeout: try arguments.int("timeout_ms") ?? 2000)
                    // Choosing is input: the gates on Settings apply (TASK-228.7).
                    switch AutomationMenuTracker.shared.settingsReach(of: root) {
                    case .automationSection:
                        throw AutomationToolError(.gateClosed,
                                                  "The open menu is over Settings' Automation section, which is the user's; "
                                                    + "no tool changes it")
                    case .settings where !environment.isTestRun:
                        throw AutomationToolError(.gateClosed,
                                                  "The open menu is over Settings, which takes menu choices only in a test run")
                    case .settings, .none:
                        break
                    }
                    let menu = try submenu(of: root, path: try arguments.stringArray("path") ?? [])
                    let allowPrivate = privateAllowed
                    let index: Int
                    if let title = try arguments.string("title") {
                        guard let found = menu.items.firstIndex(where: {
                            !$0.isSeparatorItem && !AutomationMenus.namesUnreachableWindow($0, allowPrivate: allowPrivate)
                                && AutomationMenus.titlesMatch(AutomationMenus.displayTitle($0), title)
                        }) else {
                            throw AutomationToolError(.unknownMenuItem, "No \"\(title)\" in the menu")
                        }
                        index = found
                    } else if let identifier = try arguments.string("identifier") {
                        guard let found = menu.items.firstIndex(where: { $0.identifier?.rawValue == identifier }) else {
                            throw AutomationToolError(.unknownMenuItem, "No item \(identifier) in the menu")
                        }
                        index = found
                    } else {
                        let wanted = try arguments.requiredInt("index")
                        guard menu.items.indices.contains(wanted) else {
                            throw AutomationToolError(.unknownMenuItem, "No item at index \(wanted)")
                        }
                        index = wanted
                    }
                    let item = menu.items[index]
                    guard !AutomationMenus.namesUnreachableWindow(item, allowPrivate: allowPrivate) else {
                        throw AutomationMenus.refusal(for: item)
                    }
                    guard !item.isSeparatorItem, item.submenu == nil else {
                        throw AutomationToolError(.unknownMenuItem, "\"\(AutomationMenus.displayTitle(item))\" is not an item that can be chosen")
                    }
                    guard item.isEnabled, !item.isHidden else {
                        throw AutomationToolError(.menuItemDisabled, "\"\(item.title)\" is disabled")
                    }
                    // While the menu is still tracking: WebKit's items need their live menu.
                    let completed = await AutomationInput.runFromRunLoop(wait: menuActionWait) {
                        menu.performActionForItem(at: index)
                        root.cancelTracking()
                    }
                    return ["title": .string(AutomationMenus.displayTitle(item)), "completed": .bool(completed)]
                }
            })
    }
}
