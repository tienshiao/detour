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
        let reserved = try await code(f, "click", ["context": "popup:abcdef", "selector": "#btn"])
        XCTAssertEqual(reserved, "unknown_context")
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
        override func mouseDown(with event: NSEvent) { downs.append(event) }
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
        // The view under the point gets the mouse-down itself. Whether a
        // control's tracking loop then finds the queued mouse-up is checked in
        // the running app (an NSButton's action fires, Detour in the
        // background): in the test host a posted event comes back from the
        // queue with its location moved (wiki: in-process UI automation).
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
}
