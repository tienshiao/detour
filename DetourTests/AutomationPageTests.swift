import XCTest
import AppKit
import WebKit
@testable import Detour

/// The page inspection tools of the automation endpoint (TASK-228.4):
/// evaluate_js, read_page, console_messages, network_requests, wait_for and
/// wake_tab, on a selected tab and on one no window shows, and their errors
/// (unknown, closed, sleeping and Private tabs, bad arguments, a script that
/// throws, timeouts); and console and network capture, which runs only while
/// it is started and never in a Private profile.
nonisolated final class AutomationPageTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []

    @MainActor override func tearDown() async throws {
        AutomationPageCapture.shared.stop()
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
        <!doctype html><html><head><title>Page</title></head><body>
        <h1>Hello page</h1>
        <button id="go">Go</button>
        <label>Query <input name="q" placeholder="Search"></label>
        <a href="/other">Other link</a>
        <div style="display:none"><button>Hidden</button></div>
        <iframe src="/frame"></iframe>
        <script>
        window.pageValue = 42;
        console.log('hello', { a: 1 });
        console.warn('careful');
        setTimeout(() => { throw new Error('boom'); }, 0);
        Promise.reject(new Error('nope'));
        fetch('/missing').then((response) => console.info('fetched ' + response.status));
        </script></body></html>
        """

    private struct Fixture {
        let server: MCPServer
        let window: BrowserWindowController
        let space: Space
        /// Selected in the window.
        let tab: BrowserTab
        /// Loaded in the background: no window shows it.
        let background: BrowserTab
        let port: UInt16
    }

    /// A window showing `tab`, and `background` in the same space, never
    /// selected. Capture starts first unless `capturing` is false.
    @MainActor private func makeFixture(capturing: Bool = true) async throws -> Fixture {
        let http = try LoopbackHTTPServer(routes: [
            "/": Self.page,
            "/frame": "<title>Frame</title><script>console.warn('from frame')</script>",
            "/other": "<title>Other</title>",
        ])
        servers.append(http)
        let port = try await http.start()
        let store = TabStore.shared
        if capturing { AutomationPageCapture.shared.start(store: store) }
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Automation Page", emoji: "P", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let tab = store.addTab(in: space, url: url)
        wc.selectTab(id: tab.id)
        let background = store.addTab(in: space, url: url)
        try await waitUntil("both pages to load") {
            tab.webView?.title == "Page" && !tab.isLoading && background.webView?.title == "Page" && !background.isLoading
        }
        XCTAssertNil(background.webView?.window, "the background tab is in no window")
        let tools = AutomationTools(environment: AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { nil },
                                                                       store: store))
        tools.inputWait = .milliseconds(400)
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(server: server, window: wc, space: space, tab: tab, background: background, port: port)
    }

    @MainActor private func call(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(f.server.tools.first { $0.name == name }, name)
        let result = await f.server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor private func ok(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let (content, isError) = try await call(f, name, arguments)
        XCTAssertFalse(isError, "\(name) \(arguments.jsonString): \(content.jsonString)")
        return content
    }

    @MainActor private func error(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let (content, isError) = try await call(f, name, arguments)
        XCTAssertTrue(isError, "\(name) \(arguments.jsonString) should fail: \(content.jsonString)")
        return content["error"] ?? .null
    }

    @MainActor private func code(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> String? {
        try await error(f, name, arguments)["code"]?.stringValue
    }

    @MainActor private func context(_ tab: BrowserTab) -> JSONValue { .string(tab.id.uuidString) }

    // MARK: evaluate_js

    @MainActor func testEvaluateReturnsJSONAwaitsPromisesAndPicksTheWorld() async throws {
        let f = try await makeFixture()
        let title = try await ok(f, "evaluate_js", ["context": context(f.tab), "expression": "document.title"])
        XCTAssertEqual(title["value"], "Page")
        XCTAssertEqual(title["type"], "string")
        XCTAssertEqual(title["world"], "page")

        let script = try await ok(f, "evaluate_js", ["context": context(f.tab),
                                                     "script": "const n = await Promise.resolve(20); return { n: n + 1, list: [1, 'two'] };"])
        XCTAssertEqual(script["value"], ["n": 21, "list": [1, "two"]])
        XCTAssertEqual(script["type"], "object")

        let page = try await ok(f, "evaluate_js", ["context": context(f.tab), "expression": "window.pageValue"])
        XCTAssertEqual(page["value"], 42)
        let isolated = try await ok(f, "evaluate_js", ["context": context(f.tab), "expression": "window.pageValue",
                                                       "world": "isolated"])
        XCTAssertEqual(isolated["value"], .null, "the isolated world does not see the page's globals")
        XCTAssertEqual(isolated["type"], "undefined")
        let dom = try await ok(f, "evaluate_js", ["context": context(f.tab), "world": "isolated",
                                                  "expression": "document.querySelector('h1').textContent"])
        XCTAssertEqual(dom["value"], "Hello page", "but it shares the DOM")
    }

    @MainActor func testEvaluateConvertsWhatJSONCannotHold() async throws {
        let f = try await makeFixture()
        let cycle = try await ok(f, "evaluate_js", ["context": context(f.tab),
                                                    "script": "const o = { name: 'o' }; o.self = o; return o;"])
        XCTAssertEqual(cycle["value"], ["name": "o", "self": "[Circular]"])
        let node = try await ok(f, "evaluate_js", ["context": context(f.tab), "expression": "document.getElementById('go')"])
        XCTAssertEqual(node["value"], "<button#go>")
        XCTAssertEqual(node["type"], "node")
        let mixed = try await ok(f, "evaluate_js", ["context": context(f.tab),
                                                    "expression": "[undefined, NaN, () => 1, 10n, new Set([1])]"])
        XCTAssertEqual(mixed["value"], [.null, "NaN", "[Function]", "10n", [1]])
        let nothing = try await ok(f, "evaluate_js", ["context": context(f.tab), "script": "document.title;"])
        XCTAssertEqual(nothing["value"], .null)
        XCTAssertEqual(nothing["type"], "undefined")
        let window = try await ok(f, "evaluate_js", ["context": context(f.tab), "expression": "window"])
        XCTAssertEqual(window["value"], "[Window]")
    }

    @MainActor func testEvaluateReportsWhatTheScriptThrew() async throws {
        let f = try await makeFixture()
        let thrown = try await error(f, "evaluate_js", ["context": context(f.tab),
                                                        "script": "throw new TypeError('bad thing');"])
        XCTAssertEqual(thrown["code"], "script_error")
        XCTAssertEqual(thrown["details"]?["name"], "TypeError")
        XCTAssertEqual(thrown["details"]?["message"], "bad thing")
        XCTAssertNotNil(thrown["details"]?["stack"]?.stringValue)

        let rejected = try await error(f, "evaluate_js", ["context": context(f.tab),
                                                          "expression": "Promise.reject(new RangeError('later'))"])
        XCTAssertEqual(rejected["code"], "script_error")
        XCTAssertEqual(rejected["details"]?["name"], "RangeError")

        let notAnError = try await error(f, "evaluate_js", ["context": context(f.tab), "script": "throw 'plain';"])
        XCTAssertEqual(notAnError["code"], "script_error")
        XCTAssertEqual(notAnError["details"]?["message"], "\"plain\"")
        XCTAssertEqual(notAnError["details"]?["thrown_type"], "string")

        let syntax = try await error(f, "evaluate_js", ["context": context(f.tab), "expression": "1 +* 2"])
        XCTAssertEqual(syntax["code"], "script_error")
        XCTAssertEqual(syntax["details"]?["name"], "SyntaxError", syntax.jsonString)
    }

    @MainActor func testEvaluateTimesOutAndRefusesBadArguments() async throws {
        let f = try await makeFixture()
        let slow = try await code(f, "evaluate_js", ["context": context(f.tab), "expression": "new Promise(() => {})",
                                                     "timeout_ms": 200])
        XCTAssertEqual(slow, "timeout")
        let both = try await code(f, "evaluate_js", ["context": context(f.tab), "expression": "1", "script": "return 1"])
        XCTAssertEqual(both, "invalid_arguments")
        let neither = try await code(f, "evaluate_js", ["context": context(f.tab)])
        XCTAssertEqual(neither, "invalid_arguments")
        let world = try await code(f, "evaluate_js", ["context": context(f.tab), "expression": "1", "world": "main"])
        XCTAssertEqual(world, "invalid_arguments")
        let timeout = try await code(f, "evaluate_js", ["context": context(f.tab), "expression": "1", "timeout_ms": 0])
        XCTAssertEqual(timeout, "invalid_arguments")
        let missing = try await code(f, "evaluate_js", ["expression": "1"])
        XCTAssertEqual(missing, "invalid_arguments")
    }

    // MARK: Which tabs

    @MainActor func testUnknownClosedSleepingAndPrivateTabs() async throws {
        let f = try await makeFixture()
        let unknown = try await code(f, "evaluate_js", ["context": .string(UUID().uuidString), "expression": "1"])
        XCTAssertEqual(unknown, "unknown_context")

        let closing = TabStore.shared.addTab(in: f.space, url: nil)
        let closingID = context(closing)
        TabStore.shared.closeTab(id: closing.id, in: f.space, undoable: false, registersUndo: false)
        let closed = try await code(f, "read_page", ["context": closingID])
        XCTAssertEqual(closed, "unknown_context")

        f.background.sleep()
        XCTAssertNil(f.background.webView)
        for (name, arguments) in [
            ("evaluate_js", ["expression": "1"]), ("read_page", [:]), ("console_messages", [:]),
            ("network_requests", [:]), ("wait_for", ["load": true]), ("screenshot", [:]),
            ("click", ["selector": "#go"]), ("type_text", ["text": "x"]), ("press_key", ["key": "a"]),
        ] as [(String, [String: JSONValue])] {
            var all = arguments
            all["context"] = context(f.background)
            let asleep = try await code(f, name, .object(all))
            XCTAssertEqual(asleep, "tab_asleep", name)
        }

        let privateWindow = BrowserWindowController(incognito: true)
        privateWindow.sidebarSplitView.autosaveName = nil
        windows.append(privateWindow)
        let privateSpace = try XCTUnwrap(privateWindow.activeSpace)
        let privateTab = TabStore.shared.addTab(in: privateSpace, url: URL(string: "http://127.0.0.1:\(f.port)/other")!)
        for name in ["read_page", "console_messages", "network_requests", "wake_tab", "screenshot"] {
            let refused = try await code(f, name, ["context": context(privateTab)])
            XCTAssertEqual(refused, "private_unreachable", name)
        }
        let evaluate = try await code(f, "evaluate_js", ["context": context(privateTab), "expression": "1"])
        XCTAssertEqual(evaluate, "private_unreachable")
        let ucc = try XCTUnwrap(privateTab.webView?.configuration.userContentController)
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: ucc), "no capture in a Private profile")
    }

    @MainActor func testATabNoWindowShowsWorksForEveryPageTool() async throws {
        let f = try await makeFixture()
        let context = context(f.background)
        let value = try await ok(f, "evaluate_js", ["context": context, "expression": "document.title"])
        XCTAssertEqual(value["value"], "Page")
        let read = try await ok(f, "read_page", ["context": context])
        XCTAssertTrue(read["text"]?.stringValue?.contains("Hello page") == true, read.jsonString)
        try await waitUntil("the background page's console") {
            let messages = try await self.ok(f, "console_messages", ["context": context])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"] == "careful" }
        }
        try await waitUntil("the background page's navigation record") {
            let network = try await self.ok(f, "network_requests", ["context": context, "sources": ["navigation"]])
            return network["requests"]?.arrayValue?.contains { $0["main_frame"] == true } == true
        }
        let waited = try await ok(f, "wait_for", ["context": context, "load": true, "timeout_ms": 5000])
        XCTAssertEqual(waited["matched"], true)

        // A web view that was never shown has no size, so WebKit draws no
        // picture of it: said plainly, not as an internal error.
        XCTAssertEqual(read["viewport"]?["width"], 0, read.jsonString)
        let never = try await code(f, "screenshot", ["context": context, "include_image": false])
        XCTAssertEqual(never, "not_displayed")
        // Once shown, it keeps its size after the window moves on, and the
        // screenshot needs no window.
        f.window.selectTab(id: f.background.id)
        f.window.selectTab(id: f.tab.id)
        XCTAssertNil(f.background.webView?.window)
        let shot = try await ok(f, "screenshot", ["context": context, "include_image": false])
        XCTAssertGreaterThan(shot["pixel_width"]?.intValue ?? 0, 0, shot.jsonString)
        XCTAssertEqual(f.window.selectedTabID, f.tab.id, "nothing changed which tab the window shows")
    }

    // MARK: wake_tab

    @MainActor func testWakeTabLoadsASleepingTabWithoutSelectingIt() async throws {
        let f = try await makeFixture()
        f.background.sleep()
        XCTAssertTrue(f.background.isSleeping)
        let woken = try await ok(f, "wake_tab", ["context": context(f.background)])
        XCTAssertEqual(woken["woken"], true)
        XCTAssertFalse(f.background.isSleeping)
        XCTAssertNotNil(f.background.webView)
        XCTAssertEqual(f.window.selectedTabID, f.tab.id, "the window still shows its tab")
        _ = try await ok(f, "wait_for", ["context": context(f.background), "load": true, "timeout_ms": 10_000])
        let title = try await ok(f, "evaluate_js", ["context": context(f.background), "expression": "document.title"])
        XCTAssertEqual(title["value"], "Page")

        let again = try await ok(f, "wake_tab", ["context": context(f.background)])
        XCTAssertEqual(again["woken"], false, "already awake")
        let unknown = try await code(f, "wake_tab", ["context": .string(UUID().uuidString)])
        XCTAssertEqual(unknown, "unknown_context")
    }

    // MARK: read_page

    @MainActor func testReadPageGivesTextHTMLAndSummary() async throws {
        let f = try await makeFixture()
        let text = try await ok(f, "read_page", ["context": context(f.tab)])
        XCTAssertTrue(text["url"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        XCTAssertEqual(text["title"], "Page")
        XCTAssertEqual(text["ready_state"], "complete")
        XCTAssertTrue(text["text"]?.stringValue?.contains("Hello page") == true)
        XCTAssertFalse(text["text"]?.stringValue?.contains("Hidden") == true, "visible text only")
        XCTAssertEqual(text["truncated"], false)

        let html = try await ok(f, "read_page", ["context": context(f.tab), "mode": "html", "selector": "h1"])
        XCTAssertEqual(html["html"], "<h1>Hello page</h1>")
        let cut = try await ok(f, "read_page", ["context": context(f.tab), "mode": "html", "max_length": 10])
        XCTAssertEqual(cut["html"]?.stringValue?.count, 10)
        XCTAssertEqual(cut["truncated"], true)
        XCTAssertGreaterThan(cut["length"]?.intValue ?? 0, 10)
        let summary = try await ok(f, "read_page", ["context": context(f.tab), "mode": "summary"])
        XCTAssertNil(summary["text"])
        XCTAssertEqual(summary["title"], "Page")

        let none = try await code(f, "read_page", ["context": context(f.tab), "selector": "#nope"])
        XCTAssertEqual(none, "selector_no_match")
        let invalid = try await code(f, "read_page", ["context": context(f.tab), "selector": "##"])
        XCTAssertEqual(invalid, "invalid_arguments")
        let format = try await code(f, "read_page", ["context": context(f.tab), "mode": "pdf"])
        XCTAssertEqual(format, "invalid_arguments")
    }

    @MainActor func testReadPageListsElementsWithSelectorsClickAccepts() async throws {
        let f = try await makeFixture()
        let read = try await ok(f, "read_page", ["context": context(f.tab), "mode": "elements"])
        let elements = try XCTUnwrap(read["elements"]?.arrayValue)
        let button = try XCTUnwrap(elements.first { $0["name"] == "Go" }, read.jsonString)
        XCTAssertEqual(button["role"], "button")
        XCTAssertEqual(button["selector"], "#go")
        XCTAssertEqual(button["visible"], true)
        XCTAssertGreaterThan(button["rect"]?["width"]?.doubleValue ?? 0, 0)
        let field = try XCTUnwrap(elements.first { $0["tag"] == "input" })
        XCTAssertEqual(field["role"], "textbox")
        XCTAssertEqual(field["name"], "Query", "its label")
        XCTAssertEqual(field["selector"], "input[name=\"q\"]")
        let link = try XCTUnwrap(elements.first { $0["role"] == "link" })
        XCTAssertEqual(link["name"], "Other link")
        XCTAssertTrue(link["href"]?.stringValue?.hasSuffix("/other") == true)
        let hidden = try XCTUnwrap(elements.first { $0["name"] == "Hidden" })
        XCTAssertEqual(hidden["visible"], false)
        let hiddenSelector = try XCTUnwrap(hidden["selector"]?.stringValue)
        let found = try await ok(f, "evaluate_js", ["context": context(f.tab),
                                                    "expression": .string("document.querySelector(\(JSONValue.string(hiddenSelector).jsonString)).textContent")])
        XCTAssertEqual(found["value"], "Hidden", "a path selector finds its element again")

        // The selector is one click and type_text take.
        _ = try await ok(f, "evaluate_js", ["context": context(f.tab),
                                            "script": "window.clicked = 0; document.getElementById('go').onclick = () => window.clicked++;"])
        _ = try await ok(f, "click", ["context": context(f.tab), "selector": try XCTUnwrap(button["selector"])])
        try await waitUntil("the click") {
            (try? await self.ok(f, "evaluate_js", ["context": self.context(f.tab), "expression": "window.clicked"]))?["value"] == 1
        }
        let one = try await ok(f, "read_page", ["context": context(f.tab), "mode": "elements", "max_elements": 1])
        XCTAssertEqual(one["elements"]?.arrayValue?.count, 1)
        XCTAssertEqual(one["truncated"], true)
    }

    // MARK: console_messages

    @MainActor func testConsoleRecordsCallsErrorsAndRejectionsFromEveryFrame() async throws {
        let f = try await makeFixture()
        var messages: [JSONValue] = []
        try await waitUntil("the page's console records") {
            messages = try await self.ok(f, "console_messages", ["context": self.context(f.tab)])["messages"]?.arrayValue ?? []
            return messages.contains { $0["source"] == "unhandledrejection" } && messages.contains { $0["source"] == "uncaught" }
                && messages.contains { $0["text"] == "from frame" } && messages.contains { $0["text"] == "fetched 404" }
        }
        let hello = try XCTUnwrap(messages.first { $0["level"] == "log" })
        XCTAssertEqual(hello["text"], "hello {\"a\":1}")
        XCTAssertEqual(hello["main_frame"], true)
        XCTAssertEqual(hello["source"], "console")
        let uncaught = try XCTUnwrap(messages.first { $0["source"] == "uncaught" })
        XCTAssertEqual(uncaught["level"], "error")
        XCTAssertTrue(uncaught["text"]?.stringValue?.contains("boom") == true, uncaught.jsonString)
        let rejection = try XCTUnwrap(messages.first { $0["source"] == "unhandledrejection" })
        XCTAssertTrue(rejection["text"]?.stringValue?.contains("nope") == true, rejection.jsonString)
        let frame = try XCTUnwrap(messages.first { $0["text"] == "from frame" })
        XCTAssertEqual(frame["main_frame"], false)
        XCTAssertTrue(frame["frame_url"]?.stringValue?.hasSuffix("/frame") == true, frame.jsonString)
        let seqs = messages.compactMap { $0["seq"]?.intValue }
        XCTAssertEqual(seqs, seqs.sorted(), "in order")

        // A cursor reads only what came after it; levels filter.
        let all = try await ok(f, "console_messages", ["context": context(f.tab)])
        let next = try XCTUnwrap(all["next_seq"]?.intValue)
        XCTAssertEqual(next, seqs.last)
        _ = try await ok(f, "evaluate_js", ["context": context(f.tab), "script": "console.error('after'); console.debug('quiet');"])
        let newer = try await ok(f, "console_messages", ["context": context(f.tab), "after_seq": .int(next)])
        XCTAssertEqual(newer["messages"]?.arrayValue?.compactMap { $0["text"]?.stringValue }, ["after", "quiet"])
        XCTAssertEqual(newer["dropped"], 0)
        let errors = try await ok(f, "console_messages", ["context": context(f.tab), "after_seq": .int(next),
                                                          "levels": ["error"]])
        XCTAssertEqual(errors["messages"]?.arrayValue?.compactMap { $0["text"]?.stringValue }, ["after"])
        let limited = try await ok(f, "console_messages", ["context": context(f.tab), "limit": 1])
        XCTAssertEqual(limited["has_more"], true)
        XCTAssertEqual(limited["next_seq"], limited["messages"]?.arrayValue?.first?["seq"])
        let badLevel = try await code(f, "console_messages", ["context": context(f.tab), "levels": ["verbose"]])
        XCTAssertEqual(badLevel, "invalid_arguments")
        let badCursor = try await code(f, "console_messages", ["context": context(f.tab), "after_seq": -1])
        XCTAssertEqual(badCursor, "invalid_arguments")

        // The page still logs to its own console as before: the wrapper calls through.
        let wrapped = try await ok(f, "evaluate_js", ["context": context(f.tab),
                                                      "expression": "typeof console.log('x') === 'undefined'"])
        XCTAssertEqual(wrapped["value"], true)
    }

    @MainActor func testCaptureIsOffUntilStartedAndReachesPagesLoadedBefore() async throws {
        let f = try await makeFixture(capturing: false)
        let ucc = try XCTUnwrap(f.tab.webView?.configuration.userContentController)
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: ucc))
        let scripts = ucc.userScripts.count
        let off = try await ok(f, "console_messages", ["context": context(f.tab)])
        XCTAssertEqual(off["capturing"], false)
        XCTAssertEqual(off["messages"], [])
        let hooked = try await ok(f, "evaluate_js", ["context": context(f.tab),
                                                     "expression": "window[Symbol.for('detour.automation.capture')] === true"])
        XCTAssertEqual(hooked["value"], false, "the page was never touched")

        // Started later: the loaded page gets the script once.
        AutomationPageCapture.shared.start(store: TabStore.shared)
        XCTAssertTrue(AutomationPageCapture.isInstalled(on: ucc))
        _ = try await ok(f, "evaluate_js", ["context": context(f.tab), "script": "console.log('late one');"])
        try await waitUntil("the late page's record") {
            let messages = try await self.ok(f, "console_messages", ["context": self.context(f.tab)])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"] == "late one" }
        }
        // Run again (as for a page whose user script already ran): one record per call.
        _ = try await f.tab.webView?.evaluateJavaScript(AutomationPageCapture.captureScript)
        _ = try await ok(f, "evaluate_js", ["context": context(f.tab), "script": "console.log('once');"])
        try await waitUntil("the second record") {
            let messages = try await self.ok(f, "console_messages", ["context": self.context(f.tab)])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"] == "once" }
        }
        let messages = try await ok(f, "console_messages", ["context": context(f.tab)])["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.filter { $0["text"] == "once" }.count, 1, "installed once")

        AutomationPageCapture.shared.stop()
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: ucc), "removed when the endpoint stops")
        XCTAssertEqual(ucc.userScripts.count, scripts, "and the web view's other scripts stay")
        _ = try await ok(f, "evaluate_js", ["context": context(f.tab), "script": "console.log('unheard');"])
        let after = try await ok(f, "console_messages", ["context": context(f.tab)])
        XCTAssertEqual(after["capturing"], false)
        XCTAssertEqual(after["messages"], [], "records go with it")
    }

    @MainActor func testTheRingBufferKeepsTheNewestAndCountsWhatACursorMissed() {
        var buffer = AutomationRingBuffer(capacity: 3)
        XCTAssertEqual(buffer.dropped(after: 0), 0)
        for index in 1...5 { buffer.append(category: "log", fields: ["n": .int(index)]) }
        XCTAssertEqual(buffer.entries.map(\.seq), [3, 4, 5])
        XCTAssertEqual(buffer.lastSeq, 5)
        XCTAssertEqual(buffer.dropped(after: 0), 2)
        XCTAssertEqual(buffer.dropped(after: 2), 0)
        XCTAssertEqual(buffer.entries(after: 3).map(\.seq), [4, 5])
        XCTAssertEqual(buffer.entries.first?.json["n"], 3)
    }

    // MARK: network_requests

    @MainActor func testNetworkRecordsTheNavigationResourcesAndAFailedFetch() async throws {
        let f = try await makeFixture()
        var requests: [JSONValue] = []
        try await waitUntil("the page's network records") {
            requests = try await self.ok(f, "network_requests", ["context": self.context(f.tab)])["requests"]?.arrayValue ?? []
            return requests.contains { $0["source"] == "fetch" } && requests.contains { $0["source"] == "navigation" }
                && requests.contains { $0["source"] == "resource" && $0["initiator_type"] == "iframe" }
        }
        let fetch = try XCTUnwrap(requests.first { $0["source"] == "fetch" })
        XCTAssertEqual(fetch["method"], "GET")
        XCTAssertEqual(fetch["status"], 404)
        XCTAssertEqual(fetch["ok"], false)
        XCTAssertTrue(fetch["url"]?.stringValue?.hasSuffix("/missing") == true)
        let navigation = try XCTUnwrap(requests.first { $0["source"] == "navigation" && $0["main_frame"] == true })
        XCTAssertTrue(navigation["url"]?.stringValue?.hasPrefix("http://127.0.0.1:") == true)
        XCTAssertNotNil(navigation["duration_ms"]?.doubleValue)

        _ = try await ok(f, "evaluate_js", ["context": context(f.tab), "script": """
            const xhr = new XMLHttpRequest();
            xhr.open('post', '/other');
            await new Promise((resolve) => { xhr.onloadend = resolve; xhr.send('x'); });
            await fetch('http://127.0.0.1:1/refused').catch(() => {});
            """])
        try await waitUntil("the XHR and the refused fetch") {
            requests = try await self.ok(f, "network_requests", ["context": self.context(f.tab)])["requests"]?.arrayValue ?? []
            return requests.contains { $0["source"] == "xhr" } && requests.contains { $0["error"]?.stringValue != nil }
        }
        let xhr = try XCTUnwrap(requests.first { $0["source"] == "xhr" })
        XCTAssertEqual(xhr["method"], "POST")
        XCTAssertNotNil(xhr["status"]?.intValue)
        let failed = try await ok(f, "network_requests", ["context": context(f.tab), "failed_only": true])
        let failures = try XCTUnwrap(failed["requests"]?.arrayValue)
        XCTAssertTrue(failures.contains { $0["status"] == 404 })
        XCTAssertTrue(failures.contains { $0["error"]?.stringValue != nil })
        XCTAssertFalse(failures.contains { $0["source"] == "navigation" && $0["status"] == 200 })
        let fetchesOnly = try await ok(f, "network_requests", ["context": context(f.tab), "sources": ["fetch"]])
        XCTAssertTrue(fetchesOnly["requests"]?.arrayValue?.allSatisfy { $0["source"] == "fetch" } == true)
        let bad = try await code(f, "network_requests", ["context": context(f.tab), "sources": ["websocket"]])
        XCTAssertEqual(bad, "invalid_arguments")
    }

    // MARK: wait_for

    @MainActor func testWaitForASelectorAnExpressionAURLAndLoad() async throws {
        let f = try await makeFixture()
        _ = try await ok(f, "evaluate_js", ["context": context(f.tab), "script": """
            setTimeout(() => {
              const element = document.createElement('div');
              element.id = 'late';
              element.textContent = 'late';
              element.style.display = 'none';
              document.body.appendChild(element);
              setTimeout(() => { element.style.display = 'block'; window.ready = 'yes'; }, 200);
            }, 200);
            """])
        let present = try await ok(f, "wait_for", ["context": context(f.tab), "selector": "#late", "timeout_ms": 5000])
        XCTAssertEqual(present["matched"], true)
        XCTAssertEqual(present["condition"], "selector")
        let shown = try await ok(f, "wait_for", ["context": context(f.tab), "selector": "#late", "visible": true,
                                                 "timeout_ms": 5000])
        XCTAssertEqual(shown["matched"], true)
        let truthy = try await ok(f, "wait_for", ["context": context(f.tab), "expression": "window.ready",
                                                  "timeout_ms": 5000])
        XCTAssertEqual(truthy["value"], "yes")
        let url = try await ok(f, "wait_for", ["context": context(f.tab), "url": "127.0.0.1", "timeout_ms": 1000])
        XCTAssertEqual(url["matched"], true)
        let load = try await ok(f, "wait_for", ["context": context(f.background), "load": true, "timeout_ms": 1000])
        XCTAssertEqual(load["condition"], "load")

        let never = try await error(f, "wait_for", ["context": context(f.tab), "selector": "#never", "timeout_ms": 300])
        XCTAssertEqual(never["code"], "timeout")
        let throwing = try await error(f, "wait_for", ["context": context(f.tab),
                                                       "expression": "document.querySelector('#never').id",
                                                       "timeout_ms": 300])
        XCTAssertEqual(throwing["code"], "timeout")
        XCTAssertTrue(throwing["message"]?.stringValue?.contains("TypeError") == true, throwing.jsonString)
        let wrongURL = try await code(f, "wait_for", ["context": context(f.tab), "url": "example.org", "timeout_ms": 200])
        XCTAssertEqual(wrongURL, "timeout")

        let two = try await code(f, "wait_for", ["context": context(f.tab), "selector": "a", "url": "x"])
        XCTAssertEqual(two, "invalid_arguments")
        let none = try await code(f, "wait_for", ["context": context(f.tab)])
        XCTAssertEqual(none, "invalid_arguments")
        let visibleAlone = try await code(f, "wait_for", ["context": context(f.tab), "url": "x", "visible": true])
        XCTAssertEqual(visibleAlone, "invalid_arguments")
        let invalid = try await code(f, "wait_for", ["context": context(f.tab), "selector": "##"])
        XCTAssertEqual(invalid, "invalid_arguments")
        let syntax = try await code(f, "wait_for", ["context": context(f.tab), "expression": "1 +* 2"])
        XCTAssertEqual(syntax, "script_error")
    }
}
