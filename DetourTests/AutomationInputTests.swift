import XCTest
import AppKit
import WebKit
@testable import Detour

/// The input and menu tools of the automation endpoint (TASK-228.1 phase 2,
/// AC #2, #3, #9): clicks, typing and keys reach a page as trusted events and
/// a native control as a click; a context menu can be listed, chosen from and
/// closed; and each tool's errors (no match, hidden element, a tab not shown,
/// no open menu).
nonisolated final class AutomationInputTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []

    @MainActor override func tearDown() async throws {
        await AutomationMenuTracker.shared.closeAll()
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for id in spaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    private static let page = """
        <!doctype html><html><head><title>Input</title></head><body style="margin:20px">
        <button id="btn" style="width:120px;height:40px">Button</button>
        <input id="field" style="width:200px">
        <a id="link" href="/other">Link</a>
        <div id="hidden" style="display:none">Hidden</div>
        <script>
        window.events = [];
        ['mousedown','mouseup','click','dblclick','contextmenu','keydown'].forEach(t =>
          document.addEventListener(t, e => window.events.push({ type: e.type, id: e.target.id, trusted: e.isTrusted,
            meta: e.metaKey, shift: e.shiftKey, key: e.key, code: e.code }), true));
        </script></body></html>
        """

    private struct Fixture {
        let tools: AutomationTools
        let server: MCPServer
        let window: BrowserWindowController
        let windowID: Int
        let tab: BrowserTab
        let space: Space
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        let http = try LoopbackHTTPServer(routes: ["/": Self.page, "/other": "<title>Other</title>"])
        servers.append(http)
        let port = try await http.start()
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Automation Input", emoji: "I", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        let tab = store.addTab(in: space, url: URL(string: "http://127.0.0.1:\(port)/")!)
        wc.selectTab(id: tab.id)
        try await waitUntil("the page to load") { tab.webView?.title == "Input" && !tab.isLoading }

        let tools = AutomationTools(environment: AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { nil },
                                                                       store: store))
        tools.inputWait = .milliseconds(400)
        tools.menuActionWait = .milliseconds(400)
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(tools: tools, server: server, window: wc, windowID: tools.windowIDs.id(for: wc), tab: tab,
                       space: space)
    }

    @MainActor private func call(_ f: Fixture, _ name: String, _ arguments: JSONValue = [:]) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(f.server.tools.first { $0.name == name }, name)
        let result = await f.server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor private func code(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> String? {
        let (content, isError) = try await call(f, name, arguments)
        XCTAssertTrue(isError, "\(name) \(arguments.jsonString) should fail")
        return content["error"]?["code"]?.stringValue
    }

    /// The events the page recorded, oldest first.
    @MainActor private func events(_ f: Fixture) async throws -> [[String: Any]] {
        let value = try await XCTUnwrap(f.tab.webView).evaluateJavaScript("window.events")
        return value as? [[String: Any]] ?? []
    }

    @MainActor private func waitForEvent(_ f: Fixture, _ type: String, count: Int = 1) async throws -> [[String: Any]] {
        var found: [[String: Any]] = []
        try await waitUntil("\(count) \(type) event(s)", timeout: 5) {
            found = ((try? await self.events(f)) ?? []).filter { $0["type"] as? String == type }
            return found.count >= count
        }
        return found
    }

    @MainActor private func context(_ f: Fixture) -> JSONValue { .string(f.tab.id.uuidString) }

    // MARK: Page input

    @MainActor func testAClickBySelectorIsATrustedClickOnTheElement() async throws {
        let f = try await makeFixture()
        let (content, isError) = try await call(f, "click", ["context": context(f), "selector": "#btn"])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(content["target"], "web_view")
        XCTAssertEqual(content["completed"], true)
        let clicks = try await waitForEvent(f, "click")
        XCTAssertEqual(clicks.first?["id"] as? String, "btn")
        XCTAssertEqual(clicks.first?["trusted"] as? Bool, true, "a person's click, not a script's")
    }

    /// A local event monitor never sees the endpoint's clicks; the window's
    /// web-click monitor hears of them through the announcement instead, so a
    /// download started by one flies from it (TASK-324).
    @MainActor func testAClickInThePageIsTheWindowsLastWebClick() async throws {
        let f = try await makeFixture()
        XCTAssertNil(f.window.lastWebContentClick)
        let (clicked, isError) = try await call(f, "click", ["context": context(f), "selector": "#btn", "button": "right"])
        // Closed before any unwrap can throw, so a failure leaves no menu open.
        await AutomationMenuTracker.shared.closeAll()
        XCTAssertFalse(isError, clicked.jsonString)
        let noted = try XCTUnwrap(f.window.lastWebContentClick)
        let content = try XCTUnwrap(f.window.window?.contentView)
        let point = try XCTUnwrap(clicked["point"])
        XCTAssertEqual(noted.point.x, point["x"]?.doubleValue ?? -1, accuracy: 1)
        XCTAssertEqual(noted.point.y, content.bounds.height - (point["y"]?.doubleValue ?? -1), accuracy: 1)
        XCTAssertEqual(noted.time, ProcessInfo.processInfo.systemUptime, accuracy: 5)
    }

    @MainActor func testModifierDoubleAndWindowPointClicks() async throws {
        let f = try await makeFixture()
        _ = try await call(f, "click", ["context": context(f), "selector": "#btn", "modifiers": ["cmd", "shift"]])
        let modified = try await waitForEvent(f, "click")
        XCTAssertEqual(modified.last?["meta"] as? Bool, true)
        XCTAssertEqual(modified.last?["shift"] as? Bool, true)

        _ = try await call(f, "click", ["context": context(f), "selector": "#btn", "count": 2])
        let doubles = try await waitForEvent(f, "dblclick")
        XCTAssertEqual(doubles.first?["id"] as? String, "btn")

        // The same button by a point in the window: where the first click went.
        let (first, _) = try await call(f, "click", ["context": context(f), "selector": "#btn"])
        let point = try XCTUnwrap(first["point"])
        let (byPoint, isError) = try await call(f, "click", ["window_id": .int(f.windowID),
                                                             "x": point["x"]!, "y": point["y"]!])
        XCTAssertFalse(isError, byPoint.jsonString)
        XCTAssertEqual(byPoint["target"], "web_view", "the hit test finds the page")
        _ = try await waitForEvent(f, "click", count: 5)
    }

    @MainActor func testTypingAndKeysReachTheFocusedField() async throws {
        let f = try await makeFixture()
        let (typed, isError) = try await call(f, "type_text", ["context": context(f), "selector": "#field", "text": "Ab!é"])
        XCTAssertFalse(isError, typed.jsonString)
        try await waitUntil("the field to hold the text", timeout: 5) {
            (try? await f.tab.webView?.evaluateJavaScript("document.getElementById('field').value")) as? String == "Ab!é"
        }
        let keys = try await waitForEvent(f, "keydown", count: 3)
        XCTAssertEqual(keys.prefix(3).map { $0["code"] as? String }, ["KeyA", "KeyB", "Digit1"], "US key codes")
        XCTAssertEqual(keys[1]["shift"] as? Bool, false)
        XCTAssertEqual(keys[2]["shift"] as? Bool, true, "! is Shift-1")

        let (pressed, pressError) = try await call(f, "press_key", ["context": context(f), "key": "return"])
        XCTAssertFalse(pressError, pressed.jsonString)
        let all = try await waitForEvent(f, "keydown", count: 4)
        XCTAssertEqual(all.last?["key"] as? String, "Enter")
    }

    @MainActor func testSelectorErrors() async throws {
        let f = try await makeFixture()
        let none = try await code(f, "click", ["context": context(f), "selector": "#nope"])
        XCTAssertEqual(none, "selector_no_match")
        let invalid = try await code(f, "click", ["context": context(f), "selector": "##"])
        XCTAssertEqual(invalid, "invalid_arguments")
        let hidden = try await code(f, "click", ["context": context(f), "selector": "#hidden"])
        XCTAssertEqual(hidden, "element_not_visible")
        let both = try await code(f, "click", ["context": context(f), "selector": "#btn", "x": 1, "y": 1])
        XCTAssertEqual(both, "invalid_arguments")
        let neither = try await code(f, "click", [:])
        XCTAssertEqual(neither, "invalid_arguments")
        let outside = try await code(f, "click", ["window_id": .int(f.windowID), "x": 99999, "y": 1])
        XCTAssertEqual(outside, "invalid_arguments")
    }

    @MainActor func testContextErrors() async throws {
        let f = try await makeFixture()
        let unknown = try await code(f, "click", ["context": .string(UUID().uuidString), "selector": "#btn"])
        XCTAssertEqual(unknown, "unknown_context")
        // An extension context (TASK-228.2) of an extension that is not installed.
        let noExtension = try await code(f, "click", ["context": "popup:abcdef", "selector": "#btn"])
        XCTAssertEqual(noExtension, "unknown_extension")
        // A tab the window is not showing has no place to take input.
        let other = TabStore.shared.addTab(in: f.space, url: nil)
        let notShown = try await code(f, "type_text", ["context": .string(other.id.uuidString), "text": "x"])
        XCTAssertEqual(notShown, "not_displayed")
        let noFocus = try await code(f, "press_key", ["key": "return"])
        XCTAssertEqual(noFocus, "invalid_arguments")
    }

    // MARK: Menus

    @MainActor func testAPagesContextMenuCanBeListedAndClosed() async throws {
        let f = try await makeFixture()
        let none = try await code(f, "list_menu", ["timeout_ms": 50])
        XCTAssertEqual(none, "no_open_menu")
        let noneToClose = try await code(f, "close_menu", [:])
        XCTAssertEqual(noneToClose, "no_open_menu")

        let (clicked, isError) = try await call(f, "click", ["context": context(f), "selector": "#link", "button": "right"])
        XCTAssertFalse(isError, clicked.jsonString)
        let menus = try await waitForEvent(f, "contextmenu")
        XCTAssertEqual(menus.first?["trusted"] as? Bool, true)

        let (listed, listError) = try await call(f, "list_menu", ["timeout_ms": 5000])
        XCTAssertFalse(listError, listed.jsonString)
        let identifiers = listed["items"]?.arrayValue?.compactMap { $0["identifier"]?.stringValue } ?? []
        XCTAssertTrue(identifiers.contains("WKMenuItemIdentifierCopyLink"), "WebKit's link menu: \(identifiers)")
        let unknown = try await code(f, "choose_menu_item", ["title": "No Such Item"])
        XCTAssertEqual(unknown, "unknown_menu_item")
        let twoLocators = try await code(f, "choose_menu_item", ["title": "Copy Link", "index": 0])
        XCTAssertEqual(twoLocators, "invalid_arguments")

        let (closed, closeError) = try await call(f, "close_menu")
        XCTAssertFalse(closeError, closed.jsonString)
        XCTAssertEqual(closed["closed"], true)
        XCTAssertNil(AutomationMenuTracker.shared.topMenu)
    }

    // MARK: Native views

    @MainActor private final class Receiver: NSObject {
        var actions: [String] = []
        @objc func chosen(_ sender: Any?) { actions.append("chosen") }
    }

    @MainActor private final class ClickView: NSView {
        var downs: [NSEvent] = []
        var ups: [NSEvent] = []
        override func mouseDown(with event: NSEvent) { downs.append(event) }
        override func mouseUp(with event: NSEvent) { ups.append(event) }
    }

    /// Takes a first click and delays window ordering, as a sidebar row does.
    @MainActor private final class DelayingView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }
    }

    /// Takes a first click and tracks its own press, as Quick Detour's
    /// title-bar buttons do; counts how often it is asked.
    @MainActor private final class TrackingFirstClickView: NSView {
        var firstMouseQueries = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            firstMouseQueries += 1
            return true
        }
        override func mouseDown(with event: NSEvent) {}
    }

    @MainActor private final class MenuView: NSView {
        var contextMenu: NSMenu?
        override func menu(for event: NSEvent) -> NSMenu? { contextMenu }
    }

    /// `view`'s centre in its window's content, top-left origin, as tools take it.
    @MainActor private func contentCentre(of view: NSView) throws -> (Double, Double) {
        let content = try XCTUnwrap(view.window?.contentView)
        let r = view.convert(view.bounds, to: content)
        return (r.midX, content.isFlipped ? r.midY : content.bounds.height - r.midY)
    }

    @MainActor func testANativeButtonTakesTheClickAndANativeMenuCanBeChosenFrom() async throws {
        let f = try await makeFixture()
        let content = try XCTUnwrap(f.window.window?.contentView)
        let receiver = Receiver()
        // A view that does not accept a first click gets the mouse-down
        // itself (the window would drop it while Detour is in the background);
        // AppKit's controls are covered by the switch and pop-up test below.
        let clickView = ClickView(frame: NSRect(x: content.bounds.midX - 60, y: content.bounds.midY - 15, width: 120, height: 30))
        content.addSubview(clickView)
        let (bx, by) = try contentCentre(of: clickView)

        let (clicked, isError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(bx), "y": .double(by),
                                                             "modifiers": ["option"]])
        XCTAssertFalse(isError, clicked.jsonString)
        XCTAssertEqual(clicked["target"], "view")
        XCTAssertEqual(clicked["view"], "ClickView")
        XCTAssertEqual(clickView.downs.count, 1)
        XCTAssertEqual(clickView.downs.first?.modifierFlags.contains(.option), true)
        XCTAssertNil(NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: false),
                     "a view that tracks nothing leaves no mouse-up queued for another view")
        XCTAssertEqual(clickView.ups.count, 1, "the release goes to the view that took the press, as in AppKit's dispatch")
        let (hit, _) = try await call(f, "hit_test", ["window_id": .int(f.windowID), "x": .double(bx), "y": .double(by)])
        XCTAssertEqual(hit["view"], "ClickView")
        XCTAssertEqual(hit["frame"]?["width"]?.doubleValue, 120)
        clickView.removeFromSuperview()
        let menuView = MenuView(frame: NSRect(x: content.bounds.midX - 60, y: content.bounds.midY + 40, width: 120, height: 40))
        let menu = NSMenu(title: "Native Menu")
        menu.addItem(NSMenuItem(title: "First", action: #selector(Receiver.chosen(_:)), keyEquivalent: ""))
        menu.items[0].target = receiver
        menuView.contextMenu = menu
        content.addSubview(menuView)
        let (mx, my) = try contentCentre(of: menuView)
        // A native context menu runs inside rightMouseDown: the click reports it
        // still running, and the endpoint keeps answering.
        let (right, rightError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(mx),
                                                              "y": .double(my), "button": "right"])
        XCTAssertFalse(rightError, right.jsonString)
        let (listed, listError) = try await call(f, "list_menu", ["timeout_ms": 3000])
        XCTAssertFalse(listError, listed.jsonString)
        XCTAssertEqual(listed["title"], "Native Menu")
        XCTAssertEqual(listed["items"]?.arrayValue?.first?["title"], "First")
        // Another click closes the open menu first, as a person's would.
        let (again, againError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(mx),
                                                              "y": .double(my), "button": "right"])
        XCTAssertFalse(againError, again.jsonString)
        XCTAssertEqual(AutomationMenuTracker.shared.openMenus.count, 1, "the earlier menu closed before this one opened")
        let (chosen, chooseError) = try await call(f, "choose_menu_item", ["title": "First"])
        XCTAssertFalse(chooseError, chosen.jsonString)
        try await waitUntil("the menu item's action", timeout: 3) { receiver.actions == ["chosen"] }
        try await waitUntil("the menu to close", timeout: 3) { AutomationMenuTracker.shared.topMenu == nil }
    }

    /// AppKit's own controls take a click as a person's (TASK-228.8): a
    /// switch toggles and a pop-up opens its menu. They track a click with
    /// gesture recognizers that only the window's routing feeds, so the press
    /// and release go through `NSWindow.sendEvent`; handed to the control's
    /// `mouseDown` they did nothing. The window is not key and the test host
    /// is not active, as with Detour in the background.
    @MainActor func testASwitchTogglesAndAPopUpOpensItsMenu() async throws {
        let f = try await makeFixture()
        let content = try XCTUnwrap(f.window.window?.contentView)
        let receiver = Receiver()
        let toggle = NSSwitch(frame: NSRect(x: content.bounds.midX - 20, y: content.bounds.midY - 60, width: 40, height: 22))
        toggle.target = receiver
        toggle.action = #selector(Receiver.chosen(_:))
        let popUp = NSPopUpButton(frame: NSRect(x: content.bounds.midX - 80, y: content.bounds.midY, width: 160, height: 26),
                                  pullsDown: false)
        popUp.addItems(withTitles: ["One", "Two", "Three"])
        let popUpReceiver = Receiver()
        popUp.target = popUpReceiver
        popUp.action = #selector(Receiver.chosen(_:))
        content.addSubview(toggle)
        content.addSubview(popUp)
        defer {
            toggle.removeFromSuperview()
            popUp.removeFromSuperview()
        }

        let (sx, sy) = try contentCentre(of: toggle)
        let (hit, _) = try await call(f, "hit_test", ["window_id": .int(f.windowID), "x": .double(sx), "y": .double(sy)])
        XCTAssertEqual(hit["view"], "NSSwitch")
        XCTAssertEqual(toggle.state, .off)
        let (clicked, isError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(sx), "y": .double(sy)])
        XCTAssertFalse(isError, clicked.jsonString)
        XCTAssertEqual(clicked["view"], "NSSwitch")
        XCTAssertEqual(clicked["completed"], true)
        XCTAssertEqual(toggle.state, .on, "the switch toggled")
        XCTAssertEqual(receiver.actions, ["chosen"], "and sent its action")
        _ = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(sx), "y": .double(sy)])
        XCTAssertEqual(toggle.state, .off, "a second click toggles it back")
        XCTAssertNil(NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: false),
                     "no mouse-up is left queued")

        // Through the window only while its hit test still finds the view
        // the tool checked, and only for a view that takes a first click.
        let window = try XCTUnwrap(f.window.window)
        let centre = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: nil)
        let press = try XCTUnwrap(AutomationInput.mouseEvent(.leftMouseDown, at: centre, in: window, modifiers: [],
                                                             clickCount: 1))
        XCTAssertTrue(AutomationInput.deliversThroughWindow(press, to: toggle, in: window))
        let cover = ClickView(frame: toggle.frame.insetBy(dx: -4, dy: -4))
        content.addSubview(cover)
        XCTAssertFalse(AutomationInput.deliversThroughWindow(press, to: toggle, in: window),
                       "a view now over it would get the press, so it goes to the checked view directly")
        XCTAssertFalse(AutomationInput.deliversThroughWindow(press, to: cover, in: window),
                       "a view that takes no first click gets the press directly")
        cover.removeFromSuperview()
        let rowLike = DelayingView(frame: toggle.frame.insetBy(dx: -4, dy: -4))
        content.addSubview(rowLike)
        XCTAssertFalse(AutomationInput.deliversThroughWindow(press, to: rowLike, in: window),
                       "a view that delays window ordering (a sidebar row) keeps the direct route")
        rowLike.removeFromSuperview()
        let tracking = TrackingFirstClickView(frame: toggle.frame.insetBy(dx: -4, dy: -4))
        content.addSubview(tracking)
        XCTAssertFalse(AutomationInput.deliversThroughWindow(press, to: tracking, in: window),
                       "a view with its own mouseDown keeps the direct route")
        XCTAssertEqual(tracking.firstMouseQueries, 0, "and is not asked whether it takes a first click")
        tracking.removeFromSuperview()

        let (px, py) = try contentCentre(of: popUp)
        let (opened, openError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(px), "y": .double(py)])
        let (listed, listError) = try await call(f, "list_menu", ["timeout_ms": 3000])
        let titles = listed["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        let (chosen, chooseError) = try await call(f, "choose_menu_item", ["title": "Two"])
        // Closed before any unwrap can throw, so a failure leaves no menu open.
        await AutomationMenuTracker.shared.closeAll()
        XCTAssertFalse(openError, opened.jsonString)
        XCTAssertEqual(opened["view"], "NSPopUpButton")
        XCTAssertEqual(opened["menu_open"], true, "the pop-up's menu is open: \(opened.jsonString)")
        XCTAssertFalse(listError, listed.jsonString)
        XCTAssertEqual(titles, ["One", "Two", "Three"])
        XCTAssertFalse(chooseError, chosen.jsonString)
        try await waitUntil("the pop-up's action", timeout: 3) { popUpReceiver.actions == ["chosen"] }
        XCTAssertEqual(popUp.titleOfSelectedItem, "Two")
        try await waitUntil("the menu to close", timeout: 3) { AutomationMenuTracker.shared.topMenu == nil }
    }

    /// A sidebar row's label and icon take a right click as the row does
    /// (TASK-228.7): the press is hit-tested while it is the current event,
    /// as AppKit's dispatch does, so `NSTableView.hitTest` gives the table
    /// itself, whose menu is the row's. Before, the stale current event sent
    /// the press to the label, which opened nothing.
    @MainActor func testARightClickOnASidebarRowsLabelOrIconOpensTheRowsMenu() async throws {
        let f = try await makeFixture()
        let table = f.window.tabSidebar.tableView
        // A point taken from a row still sliding in is no row's (a flake).
        try await waitForRowsToSettle(f)
        let cell = try XCTUnwrap((0..<table.numberOfRows).lazy.compactMap {
            table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? TabCellView
        }.first { $0.titleLabel.stringValue == "Input" })
        for view in [cell.titleLabel as NSView, cell.faviconImageView] {
            let (x, y) = try contentCentre(of: view)
            let (hit, _) = try await call(f, "hit_test", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
            XCTAssertEqual(hit["view"], "DraggableTableView", "a press there goes to the table, as a real one does")
            let (clicked, isError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(x),
                                                                 "y": .double(y), "button": "right"])
            XCTAssertFalse(isError, clicked.jsonString)
            XCTAssertEqual(clicked["view"], "DraggableTableView")
            let (listed, listError) = try await call(f, "list_menu", ["timeout_ms": 3000])
            XCTAssertFalse(listError, listed.jsonString)
            let titles = listed["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
            XCTAssertTrue(titles.contains("Copy URL"), "the row's menu: \(titles)")
            await AutomationMenuTracker.shared.closeAll()
        }
    }

    // MARK: Key mapping

    @MainActor func testCharactersMapToUSKeys() throws {
        XCTAssertEqual(AutomationInput.key(for: "a")?.code, 0)
        XCTAssertEqual(AutomationInput.key(for: "a")?.shift, false)
        XCTAssertEqual(AutomationInput.key(for: "A")?.shift, true)
        XCTAssertEqual(AutomationInput.key(for: "!")?.code, 18)
        XCTAssertEqual(AutomationInput.key(for: "!")?.shift, true)
        XCTAssertEqual(AutomationInput.key(for: "\r")?.code, 36)
        XCTAssertEqual(AutomationInput.key(for: " ")?.code, 49)
        XCTAssertNil(AutomationInput.key(for: "é"), "inserted as text")
        XCTAssertEqual(try AutomationInput.modifiers(["cmd", "Shift", "alt", "ctrl"]), [.command, .shift, .option, .control])
        XCTAssertThrowsError(try AutomationInput.modifiers(["hyper"]))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 10, height: 10), styleMask: [], backing: .buffered, defer: true)
        let (down, _) = try XCTUnwrap(AutomationInput.keyEvents(characters: "\u{F701}", ignoringModifiers: "\u{F701}",
                                                                code: 125, modifiers: [], in: window))
        XCTAssertTrue(down.modifierFlags.contains(.function), "arrows carry the function flag, as real ones do")

        // press_key's events are what a US keyboard sends.
        let shiftOne = try XCTUnwrap(AutomationInput.keyEvents(for: "1", modifiers: .shift, in: window)).0
        XCTAssertEqual(shiftOne.characters, "!")
        XCTAssertEqual(shiftOne.keyCode, 18)
        let shiftA = try XCTUnwrap(AutomationInput.keyEvents(for: "a", modifiers: .shift, in: window)).0
        XCTAssertEqual(shiftA.characters, "A")
        let cmdShiftA = try XCTUnwrap(AutomationInput.keyEvents(for: "a", modifiers: [.command, .shift], in: window)).0
        XCTAssertEqual(cmdShiftA.characters, "a", "a key equivalent keeps its base character")
        let backTab = try XCTUnwrap(AutomationInput.keyEvents(for: "\t", modifiers: .shift, in: window)).0
        XCTAssertEqual(backTab.characters, "\u{19}")
        XCTAssertEqual(backTab.keyCode, 48)
        let delete = try XCTUnwrap(AutomationInput.keyEvents(for: "\u{8}", modifiers: [], in: window)).0
        XCTAssertEqual(delete.characters, "\u{7F}", "the Delete key sends DEL")
        XCTAssertEqual(delete.keyCode, 51)
        let accented = try XCTUnwrap(AutomationInput.keyEvents(for: "é", modifiers: [], in: window)).0
        XCTAssertEqual(accented.keyCode, AutomationInput.unmappedKeyCode, "no US key, so no physical key")
    }

    // MARK: Sidebar rows (TASK-228.9)

    /// The sidebar's row views, by row.
    @MainActor private func sidebarRows(_ f: Fixture) -> [(row: Int, view: NSView?)] {
        let table = f.window.tabSidebar.tableView
        table.layoutSubtreeIfNeeded()
        return (0..<table.numberOfRows).map { ($0, table.view(atColumn: 0, row: $0, makeIfNecessary: false)) }
    }

    @MainActor private func tabCell(_ f: Fixture, titled title: String) throws -> TabCellView {
        try XCTUnwrap(sidebarRows(f).lazy.compactMap { $0.view as? TabCellView }.first { $0.titleLabel.stringValue == title },
                      "a row titled \(title)")
    }

    @MainActor private func waitForRowsToSettle(_ f: Fixture) async throws {
        let table = f.window.tabSidebar.tableView
        try await waitUntil("the sidebar's rows to settle", timeout: 3) {
            table.layoutSubtreeIfNeeded()
            var settled = true
            table.enumerateAvailableRowViews { rowView, row in
                if rowView.frame != table.rect(ofRow: row) { settled = false }
            }
            return settled
        }
    }

    @MainActor private func clickCentre(_ f: Fixture, of view: NSView) async throws -> JSONValue {
        let (x, y) = try contentCentre(of: view)
        let (clicked, isError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
        XCTAssertFalse(isError, clicked.jsonString)
        return clicked
    }

    @MainActor private func addOtherTab(_ f: Fixture) async throws -> BrowserTab {
        let port = try XCTUnwrap(f.tab.url?.port)
        let other = TabStore.shared.addTab(in: f.space, url: URL(string: "http://127.0.0.1:\(port)/other")!)
        try await waitUntil("the other page to load") { other.title == "Other" }
        try await waitForRowsToSettle(f)
        return other
    }

    /// A left click on a tab's row selects the tab, in a window that is not
    /// key and with the test host in the background, as Detour is when an
    /// agent drives it. The table gave up on the press before: in a window
    /// that is not key, `-[NSTableView mouseDown:]` only lets a drag go ahead
    /// while the table needs its panel to become key, which the list now
    /// denies for the endpoint's press only.
    @MainActor func testALeftClickOnASidebarRowSelectsItsTab() async throws {
        let f = try await makeFixture()
        let other = try await addOtherTab(f)
        let window = try XCTUnwrap(f.window.window)
        let table = f.window.tabSidebar.tableView
        XCTAssertEqual(f.window.selectedTabID, f.tab.id)
        XCTAssertFalse(window.isKeyWindow)
        let tabCount = f.space.tabs.count

        let clicked = try await clickCentre(f, of: try tabCell(f, titled: "Other").titleLabel)
        XCTAssertEqual(clicked["view"], "DraggableTableView")
        XCTAssertEqual(f.window.selectedTabID, other.id, "the row's tab is selected")
        XCTAssertEqual(f.space.tabs.count, tabCount)
        XCTAssertFalse(NSApp.isActive, "the click did not activate the app")
        XCTAssertFalse(window.isKeyWindow, "nor make the window key")
        XCTAssertTrue(table.needsPanelToBecomeKey, "outside the endpoint's press the table is as AppKit made it")
        XCTAssertNil(AutomationInput.viewTakingPress)
        XCTAssertNil(NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: false),
                     "the table's tracking took the release")

        // Back by the first tab's row, and no hover is left on either row.
        _ = try await clickCentre(f, of: try tabCell(f, titled: "Input").titleLabel)
        XCTAssertEqual(f.window.selectedTabID, f.tab.id)
        for title in ["Input", "Other"] {
            let buttons = try tabCell(f, titled: title).subviews.compactMap { $0 as? HoverButton }
            XCTAssertFalse(buttons.isEmpty)
            XCTAssertTrue(buttons.allSatisfy(\.isHidden), "\(title)'s close buttons are hidden again")
        }
    }

    /// The close button shows only while the pointer is over the row. The
    /// endpoint's click hovers the views under the point first, as a
    /// person's pointer crosses the row before the press, so a click where
    /// the button shows closes the tab.
    @MainActor func testALeftClickOnARowsCloseButtonClosesTheTab() async throws {
        let f = try await makeFixture()
        let other = try await addOtherTab(f)
        let cell = try tabCell(f, titled: "Other")
        let content = try XCTUnwrap(f.window.window?.contentView)
        let close = try XCTUnwrap(cell.subviews.compactMap { $0 as? HoverButton }.first {
            $0.image?.accessibilityDescription == "Close"
        })
        XCTAssertTrue(close.isHidden, "no hover, no button")
        // Where the button shows on hover: 16 points wide, ending where its
        // collapsed frame ends.
        let centre = cell.convert(NSPoint(x: close.frame.maxX - 8, y: cell.bounds.midY), to: content)
        let x = Double(centre.x), y = Double(content.isFlipped ? centre.y : content.bounds.height - centre.y)
        let (before, _) = try await call(f, "hit_test", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
        XCTAssertEqual(before["view"], "DraggableTableView", "hit_test shows no button there")

        let (clicked, isError) = try await call(f, "click", ["window_id": .int(f.windowID), "x": .double(x), "y": .double(y)])
        XCTAssertFalse(isError, clicked.jsonString)
        XCTAssertEqual(clicked["view"], "HoverButton", "the hover put the button under the point")
        try await waitUntil("the tab to close", timeout: 3) { !f.space.tabs.contains { $0.id == other.id } }
        XCTAssertEqual(f.window.selectedTabID, f.tab.id, "the selection stayed")
    }

    /// A pinned entry's row selects its tab; a folder's row and its
    /// disclosure button each toggle it once; the New Tab row opens the
    /// command palette, as a person's click on each does.
    @MainActor func testPinnedEntryFolderAndNewTabRowsTakeAClick() async throws {
        let f = try await makeFixture()
        let store = TabStore.shared
        let other = try await addOtherTab(f)
        store.pinTab(id: other.id, in: f.space)
        let folder = store.addPinnedFolder(name: "Folder", in: f.space)
        func collapsed() -> Bool? { f.space.pinnedFolders.first { $0.id == folder.id }?.isCollapsed }
        // The rows slide into place; a point taken meanwhile is another row's.
        try await waitForRowsToSettle(f)

        let pinnedCell = try XCTUnwrap(sidebarRows(f).lazy.compactMap { $0.view as? TabCellView }.first {
            $0.titleLabel.stringValue != "Input"
        }, "the pinned entry's row")
        _ = try await clickCentre(f, of: pinnedCell.titleLabel)
        XCTAssertEqual(f.window.selectedTabID, other.id, "the pinned entry's tab is selected")

        let folderCell = try XCTUnwrap(sidebarRows(f).lazy.compactMap { $0.view as? FolderCellView }.first)
        let label = try XCTUnwrap(folderCell.subviews.first { $0 is NSTextField })
        XCTAssertEqual(collapsed(), false)
        _ = try await clickCentre(f, of: label)
        XCTAssertEqual(collapsed(), true, "the folder's row toggles it, once")
        let disclosure = try XCTUnwrap(sidebarRows(f).lazy.compactMap { $0.view as? FolderCellView }.first?
            .subviews.first { $0 is NSButton })
        let clicked = try await clickCentre(f, of: disclosure)
        XCTAssertEqual(clicked["view"], "NSButton")
        XCTAssertEqual(collapsed(), false, "the disclosure toggles it back, once")

        let newTab = try XCTUnwrap(sidebarRows(f).first { $0.view is NewTabCellView }?.view)
        let tabCount = f.space.tabs.count
        XCTAssertNil(f.window.commandPaletteView)
        _ = try await clickCentre(f, of: newTab)
        XCTAssertNotNil(f.window.commandPaletteView, "the New Tab row opens the palette")
        XCTAssertEqual(f.space.tabs.count, tabCount)
        f.window.dismissCommandPalette()
    }
}
