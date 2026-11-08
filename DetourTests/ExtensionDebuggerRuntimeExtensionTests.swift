import XCTest
import WebKit
@testable import Detour

/// TASK-132.15: Runtime.evaluate, JavaScript dialogs, Page.frameNavigated and
/// Page.getFrameTree through `chrome.debugger`, from a real extension's
/// service worker and from one of its pages, against real tabs in a real
/// (never shown) browser window.
nonisolated final class ExtensionDebuggerRuntimeExtensionTests: XCTestCase {

    private typealias Via = SidePanelTestWorld.Via
    private var world: SidePanelTestWorld!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        world = SidePanelTestWorld(opJS: DebuggerFixture.opJS, workerJS: TabGroupsFixture.workerJS)
        try await world.setUp()
    }

    @MainActor override func tearDown() async throws {
        ExtensionDebugger.shared.resetForTesting()
        ExtensionDebuggerDialogs.resetForTesting()
        await world.tearDown()
        world = nil
        try await super.tearDown()
    }

    @MainActor private struct Scene {
        let loaded: SidePanelTestWorld.Loaded
        let space: Space
        let window: BrowserWindowController
        let tabs: [BrowserTab]
    }

    /// One profile, one space, one window, four tabs (the first selected).
    @MainActor private func makeScene(_ name: String) async throws -> Scene {
        let ext = try await world.makeExtension(name: "Runtime Test", permissions: ["debugger", "tabs"], defaultPath: nil)
        let profile = world.makeProfile(name)
        let space = world.makeSpace(name, in: profile)
        let window = world.makeWindow(on: space)
        var tabs: [BrowserTab] = []
        for page in ["one", "two", "three", "four"] { tabs.append(try await world.addTab(page, in: space)) }
        window.selectTab(id: tabs[0].id)
        let loaded = try await world.load(ext, in: profile)
        // Tabs opened before the extension loaded are reported to it by a move,
        // as in ExtensionDebuggerTests.
        for tab in tabs {
            TabStore.shared.moveTab(id: tab.id, toGapIndex: space.tabs.count, in: space)
        }
        for tab in space.tabs { try await waitForLoad(tab) }
        let scene = Scene(loaded: loaded, space: space, window: window, tabs: space.tabs)
        for via in Via.allCases { _ = try await world.run(via, in: loaded, ["op": "listen"]) }
        return scene
    }

    @MainActor private func waitForLoad(_ tab: BrowserTab) async throws {
        try await waitUntil("the tab's page to load", timeout: 20) {
            guard let webView = tab.webView, !webView.isLoading else { return false }
            let ready = try? await webView.callAsyncJavaScript("return document.readyState === 'complete';",
                                                               arguments: [:], contentWorld: .page)
            return ready as? Bool == true
        }
    }

    @MainActor private func send(_ via: Via, _ scene: Scene, _ id: Int, _ method: String,
                                 _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await world.run(via, in: scene.loaded, ["op": "call", "method": "sendCommand",
                                                                "args": [["tabId": id], method, params]])
        return try XCTUnwrap(value as? [String: Any], "\(method) answered \(value)")
    }

    @MainActor private func sendFailure(_ via: Via, _ scene: Scene, _ id: Int, _ method: String,
                                        _ params: [String: Any] = [:]) async throws -> (promise: String?, lastError: String?) {
        let promise = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "sendCommand",
                                                                      "args": [["tabId": id], method, params]])
        let callback = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "sendCommand",
                                                                       "args": [["tabId": id], method, params]])
        return (promise, callback["lastError"] as? String)
    }

    @MainActor private func attach(_ tab: BrowserTab, _ via: Via, _ scene: Scene, page: Bool = true) async throws -> Int {
        let id = try await world.tabID(of: tab, via, in: scene.loaded)
        _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "attach", "args": [["tabId": id], "1.3"]])
        if page { _ = try await send(via, scene, id, "Page.enable") }
        return id
    }

    @MainActor private func detach(_ id: Int, _ via: Via, _ scene: Scene) async throws {
        _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "detach", "args": [["tabId": id]]])
    }

    @MainActor private func events(_ via: Via, _ scene: Scene, _ method: String, tabID: Int) async throws -> [[String: Any]] {
        let value = try await world.run(via, in: scene.loaded, ["op": "events"])
        return (value as? [[String: Any]] ?? []).filter {
            $0["event"] as? String == "onEvent" && $0["method"] as? String == method && $0["tabId"] as? Int == tabID
        }
    }

    @MainActor private func waitForEvents(_ via: Via, _ scene: Scene, _ method: String, tabID: Int, count: Int,
                                          file: StaticString = #filePath, line: UInt = #line) async throws -> [[String: Any]] {
        var found: [[String: Any]] = []
        try await waitUntil("\(count) × \(method) in the \(via)", timeout: 15) {
            found = (try? await self.events(via, scene, method, tabID: tabID)) ?? []
            return found.count >= count
        }
        return found
    }

    /// Starts a dialog in the page without waiting for it: the page is stuck
    /// in it until it is answered. Answers collect in `__answers`.
    @MainActor private func openDialog(_ tab: BrowserTab, _ call: String) throws {
        // Not awaited: WebKit may hold the script's own answer until the
        // dialog it opens has been answered.
        let webView = try XCTUnwrap(tab.webView)
        webView.evaluateJavaScript("setTimeout(() => { (window.__answers = window.__answers || []).push(\(call)); }, 20); 0",
                                   completionHandler: nil)
    }

    private struct PageHeld: Error, CustomStringConvertible {
        var description: String { "the page is still held by a dialog" }
    }

    /// A script in the tab's page, as JSON text. A page still held by a
    /// dialog cannot run script until it is answered: after 5 s this throws
    /// instead of waiting.
    @MainActor private func pageScript(_ tab: BrowserTab, _ body: String) async throws -> String {
        let webView = try XCTUnwrap(tab.webView)
        let text: String? = await withCheckedContinuation { continuation in
            var finished = false
            let finish: (String?) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                finish(nil)
            }
            webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                finish(((try? result.get()) as? String) ?? "null")
            }
        }
        guard let text else { throw PageHeld() }
        return text
    }

    /// The page's answers so far.
    @MainActor private func answers(_ tab: BrowserTab) async throws -> [Any] {
        let text = try await pageScript(tab, "return JSON.stringify(window.__answers || []);")
        return (try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] ?? []
    }

    // MARK: - Runtime.evaluate through the API (AC #1, #2)

    @MainActor func testEvaluateFromBothContextsAndItsErrors() async throws {
        let scene = try await makeScene("Runtime Evaluate")
        for via in Via.allCases {
            let tab = scene.tabs[1]
            let id = try await attach(tab, via, scene, page: false)
            XCTAssertEqual(tab.automationHosting, .parked, "[\(via)]")
            let awaited1 = try await send(via, scene, id, "Runtime.enable")
            XCTAssertEqual(awaited1.isEmpty, true, "[\(via)]")
            let title = try await send(via, scene, id, "Runtime.evaluate",
                                       ["expression": "{const t = document.title;\nt + '!'\n}", "returnByValue": true,
                                        "awaitPromise": true, "replMode": true, "timeout": 10000])
            XCTAssertEqual((title["result"] as? [String: Any])?["value"] as? String, "two!", "[\(via)] \(title)")
            let promise = try await send(via, scene, id, "Runtime.evaluate",
                                         ["expression": "new Promise(r => setTimeout(() => r([1, 2]), 5))",
                                          "returnByValue": true, "awaitPromise": true])
            XCTAssertEqual((promise["result"] as? [String: Any])?["value"] as? [Int], [1, 2], "[\(via)]")
            let undefinedResult = try await send(via, scene, id, "Runtime.evaluate", ["expression": "void 0"])
            XCTAssertEqual((undefinedResult["result"] as? [String: Any])?["type"] as? String, "undefined", "[\(via)]")
            let thrown = try await send(via, scene, id, "Runtime.evaluate",
                                        ["expression": "{ throw new TypeError('nope') }", "returnByValue": true, "replMode": true])
            let exception = (thrown["exceptionDetails"] as? [String: Any])?["exception"] as? [String: Any]
            XCTAssertEqual(exception?["className"] as? String, "TypeError", "[\(via)]")
            XCTAssertTrue((exception?["description"] as? String ?? "").hasPrefix("TypeError: nope"), "[\(via)]")

            // Errors, in both forms.
            let invalid = try await sendFailure(via, scene, id, "Runtime.evaluate", ["returnByValue": true])
            let expected = #"{"code":-32602,"message":"Invalid parameters: expression: string value expected"}"#
            XCTAssertEqual(invalid.promise, expected, "[\(via)]")
            XCTAssertEqual(invalid.lastError, expected, "[\(via)] callback form")
            let unknown = try await sendFailure(via, scene, id, "Runtime.callFunctionOn")
            XCTAssertEqual(unknown.promise, #"{"code":-32601,"message":"'Runtime.callFunctionOn' wasn't found"}"#, "[\(via)]")
            let awaited2 = try await send(via, scene, id, "Runtime.disable")
            XCTAssertEqual(awaited2.isEmpty, true, "[\(via)]")
            try await detach(id, via, scene)
            let notAttached = try await sendFailure(via, scene, id, "Runtime.evaluate", ["expression": "1"])
            XCTAssertEqual(notAttached.promise, "Debugger is not attached to the tab with id: \(id).", "[\(via)]")
            XCTAssertEqual(notAttached.lastError, "Debugger is not attached to the tab with id: \(id).", "[\(via)]")
        }
    }

    /// The Claude extension's two calls, from its worker, as it makes them.
    @MainActor func testTheClaudeExtensionsRetryPathThroughTheAPI() async throws {
        let scene = try await makeScene("Runtime Retry")
        let id = try await attach(scene.tabs[2], .worker, scene)
        let code = "const n = document.title.length;\nreturn n * 2"
        let parameters: (String, Bool) -> [String: Any] = { expression, repl in
            ["expression": expression, "returnByValue": true, "awaitPromise": true, "replMode": repl, "timeout": 10000]
        }
        let first = try await send(.worker, scene, id, "Runtime.evaluate", parameters("{\(code)\n}", true))
        let details = try XCTUnwrap(first["exceptionDetails"] as? [String: Any])
        let exception = try XCTUnwrap(details["exception"] as? [String: Any])
        XCTAssertEqual(exception["className"] as? String, "SyntaxError")
        XCTAssertNil(details["stackTrace"])
        XCTAssertNotNil(details["scriptId"])
        XCTAssertTrue((exception["description"] as? String ?? "").contains("Illegal return statement"))
        let second = try await send(.worker, scene, id, "Runtime.evaluate", parameters("(async()=>{\n\(code)\n})()", false))
        XCTAssertEqual((second["result"] as? [String: Any])?["value"] as? Int, 10, "\(second)")
    }

    // MARK: - Dialogs (AC #5)

    @MainActor func testDialogsAreReportedAndAnsweredByTheExtension() async throws {
        let scene = try await makeScene("Runtime Dialogs")
        for (index, via) in [(1, Via.worker), (2, Via.page)] {
            let tab = scene.tabs[index]
            let id = try await attach(tab, via, scene)
            // Never displayed by any window: only parking gave it a UI delegate.
            XCTAssertEqual(tab.automationHosting, .parked, "[\(via)]")
            XCTAssertTrue(tab.webView?.uiDelegate is AutomationUIDelegate, "[\(via)] \(String(describing: tab.webView?.uiDelegate))")
            var opened = 0
            var closed = 0
            for (call, type, answer, expected) in [
                ("alert('hello')", "alert", ["accept": true] as [String: Any], NSNull() as Any),
                ("confirm('sure?')", "confirm", ["accept": true], true),
                ("confirm('really?')", "confirm", ["accept": false], false),
                ("prompt('name?', 'def')", "prompt", ["accept": true, "promptText": "typed"], "typed"),
                ("prompt('again?', 'def')", "prompt", ["accept": false], NSNull()),
            ] {
                try openDialog(tab, call)
                opened += 1
                let opening = try await waitForEvents(via, scene, "Page.javascriptDialogOpening", tabID: id, count: opened)
                let params = try XCTUnwrap(opening.last?["params"] as? [String: Any])
                XCTAssertEqual(params["type"] as? String, type, "[\(via)] \(call)")
                XCTAssertEqual(params["message"] as? String, String(call.split(separator: "'")[1]), "[\(via)]")
                XCTAssertEqual(params["url"] as? String, world.url(index == 1 ? "two" : "three").absoluteString, "[\(via)]")
                XCTAssertEqual(params["frameId"] as? String, ExtensionDebuggerFrames.frameID(for: tab), "[\(via)]")
                XCTAssertEqual(params["hasBrowserHandler"] as? Bool, false, "[\(via)]")
                XCTAssertEqual(params["defaultPrompt"] as? String, type == "prompt" ? "def" : "", "[\(via)]")
                XCTAssertNil(scene.window.window?.attachedSheet, "[\(via)] no sheet on the user's window")
                XCTAssertNotNil(ExtensionDebuggerDialogs.pendingDialog(forTabUUID: tab.id), "[\(via)]")

                let awaited3 = try await send(via, scene, id, "Page.handleJavaScriptDialog", answer)
                XCTAssertEqual(awaited3.isEmpty, true, "[\(via)]")
                closed += 1
                let closedEvents = try await waitForEvents(via, scene, "Page.javascriptDialogClosed", tabID: id, count: closed)
                let closedParams = try XCTUnwrap(closedEvents.last?["params"] as? [String: Any])
                XCTAssertEqual(closedParams["result"] as? Bool, answer["accept"] as? Bool, "[\(via)] \(call)")
                XCTAssertEqual(closedParams["userInput"] as? String, answer["promptText"] as? String ?? "", "[\(via)]")
                XCTAssertEqual(closedParams["frameId"] as? String, ExtensionDebuggerFrames.frameID(for: tab), "[\(via)]")
                let recorded = try await answers(tab)
                XCTAssertEqual(recorded.count, opened, "[\(via)] \(recorded)")
                XCTAssertEqual(recorded.last as? NSObject, expected as? NSObject, "[\(via)] \(call) answered \(recorded)")
            }
            // No dialog showing: Chromium's error, in both forms.
            let none = try await sendFailure(via, scene, id, "Page.handleJavaScriptDialog", ["accept": true])
            XCTAssertEqual(none.promise, #"{"code":-32602,"message":"No dialog is showing"}"#, "[\(via)]")
            XCTAssertEqual(none.lastError, #"{"code":-32602,"message":"No dialog is showing"}"#, "[\(via)]")
            let bad = try await sendFailure(via, scene, id, "Page.handleJavaScriptDialog", ["accept": "yes"])
            XCTAssertEqual(bad.promise, #"{"code":-32602,"message":"Invalid parameters: accept: boolean value expected"}"#)
            try await detach(id, via, scene)
        }
    }

    /// A tab no debugger holds keeps Detour's sheet; so does a tab held
    /// without Page enabled while a window shows it. Held without Page while
    /// parked, nothing pops over the user's tab: Chromium's background rule.
    @MainActor func testDialogsWithoutTheExtensionAnsweringKeepDetoursBehaviour() async throws {
        let scene = try await makeScene("Runtime Dialog Panel")
        let selected = scene.tabs[0]
        let window = try XCTUnwrap(scene.window.window)
        // Not attached: the window's sheet.
        try openDialog(selected, "confirm('panel?')")
        try await waitUntil("Detour's sheet", timeout: 10) { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertFirstButtonReturn)
        try await waitUntil("the page to have its answer", timeout: 10) {
            ((try? await self.answers(selected)) ?? []).count == 1
        }
        let awaited4 = try await answers(selected)
        XCTAssertEqual(awaited4.first as? Bool, true)

        // Attached without Page, displayed: still the sheet.
        let id = try await attach(selected, .page, scene, page: false)
        XCTAssertEqual(selected.automationHosting, .displayed)
        try openDialog(selected, "confirm('still a panel?')")
        try await waitUntil("Detour's sheet again", timeout: 10) { window.attachedSheet != nil }
        window.endSheet(try XCTUnwrap(window.attachedSheet), returnCode: .alertSecondButtonReturn)
        try await waitUntil("the second answer", timeout: 10) { ((try? await self.answers(selected)) ?? []).count == 2 }
        let awaited5 = try await answers(selected)
        XCTAssertEqual(awaited5.last as? Bool, false)
        try await detach(id, .page, scene)

        // Attached without Page, parked: answered at once, no sheet.
        let parked = scene.tabs[3]
        let parkedID = try await attach(parked, .page, scene, page: false)
        XCTAssertEqual(parked.automationHosting, .parked)
        try openDialog(parked, "confirm('nobody sees this')")
        try await waitUntil("the parked page's answer", timeout: 10) { ((try? await self.answers(parked)) ?? []).count == 1 }
        let awaited6 = try await answers(parked)
        XCTAssertEqual(awaited6.first as? Bool, false)
        XCTAssertNil(window.attachedSheet)
        try await detach(parkedID, .page, scene)
    }

    // MARK: - Release (AC #6)

    @MainActor func testAPendingDialogIsReleasedOnDetachAndOnClose() async throws {
        let scene = try await makeScene("Runtime Dialog Release")
        let tab = scene.tabs[1]
        let id = try await attach(tab, .worker, scene)
        try openDialog(tab, "confirm('left hanging')")
        _ = try await waitForEvents(.worker, scene, "Page.javascriptDialogOpening", tabID: id, count: 1)
        let released = ExtensionDebuggerDialogs.releasedCount
        try await detach(id, .worker, scene)
        XCTAssertNil(ExtensionDebuggerDialogs.pendingDialog(forTabUUID: tab.id))
        XCTAssertEqual(ExtensionDebuggerDialogs.releasedCount, released + 1)
        try await waitUntil("the page to go on", timeout: 10) { ((try? await self.answers(tab)) ?? []).count == 1 }
        let awaited7 = try await answers(tab)
        XCTAssertEqual(awaited7.first as? Bool, false, "dismissed, as Chromium does with no browser handler")

        let closing = scene.tabs[2]
        let closingID = try await attach(closing, .page, scene)
        try openDialog(closing, "alert('closing')")
        _ = try await waitForEvents(.page, scene, "Page.javascriptDialogOpening", tabID: closingID, count: 1)
        TabStore.shared.closeTab(id: closing.id, in: scene.space, undoable: false, registersUndo: false)
        XCTAssertNil(ExtensionDebuggerDialogs.pendingDialog(forTabUUID: closing.id))
        XCTAssertEqual(ExtensionDebuggerDialogs.releasedCount, released + 2, "WebKit's handler was called")
    }

    /// Page.disable dismisses a waiting dialog without a report; a load
    /// cancels one and reports it closed (a process held by the dialog would
    /// never read the load otherwise). Page.getFrameTree answers while one
    /// waits.
    @MainActor func testAPendingDialogIsReleasedOnPageDisableAndOnALoad() async throws {
        let scene = try await makeScene("Runtime Dialog Disable")
        let tab = scene.tabs[1]
        let id = try await attach(tab, .worker, scene)
        let released = ExtensionDebuggerDialogs.releasedCount

        try openDialog(tab, "confirm('disabled away')")
        _ = try await waitForEvents(.worker, scene, "Page.javascriptDialogOpening", tabID: id, count: 1)
        let tree = try await send(.worker, scene, id, "Page.getFrameTree")
        XCTAssertNotNil((tree["frameTree"] as? [String: Any])?["frame"], "answered while the page is held")
        _ = try await send(.worker, scene, id, "Page.disable")
        XCTAssertNil(ExtensionDebuggerDialogs.pendingDialog(forTabUUID: tab.id))
        XCTAssertEqual(ExtensionDebuggerDialogs.releasedCount, released + 1)
        try await waitUntil("the page to go on", timeout: 10) { ((try? await self.answers(tab)) ?? []).count == 1 }
        let awaited = try await answers(tab)
        XCTAssertEqual(awaited.first as? Bool, false, "dismissed")

        _ = try await send(.worker, scene, id, "Page.enable")
        try openDialog(tab, "alert('navigated away')")
        _ = try await waitForEvents(.worker, scene, "Page.javascriptDialogOpening", tabID: id, count: 2)
        tab.load(world.url("four"))
        XCTAssertNil(ExtensionDebuggerDialogs.pendingDialog(forTabUUID: tab.id))
        XCTAssertEqual(ExtensionDebuggerDialogs.releasedCount, released + 2)
        let closed = try await waitForEvents(.worker, scene, "Page.javascriptDialogClosed", tabID: id, count: 1)
        XCTAssertEqual((closed.first?["params"] as? [String: Any])?["result"] as? Bool, false)
        _ = try await waitForEvents(.worker, scene, "Page.frameNavigated", tabID: id, count: 1)
        try await detach(id, .worker, scene)
    }

    // MARK: - Frames (AC #7)

    @MainActor func testFrameNavigatedFiresOncePerNavigationAndTheLoaderIDChanges() async throws {
        let scene = try await makeScene("Runtime Frames")
        for (index, via) in [(1, Via.worker), (2, Via.page)] {
            let tab = scene.tabs[index]
            let id = try await attach(tab, via, scene)
            let tree8 = try await send(via, scene, id, "Page.getFrameTree")
            let before = try XCTUnwrap((tree8["frameTree"]
                                        as? [String: Any])?["frame"] as? [String: Any])
            XCTAssertEqual(before["url"] as? String, tab.url?.absoluteString, "[\(via)]")
            XCTAssertEqual(before["id"] as? String, ExtensionDebuggerFrames.frameID(for: tab), "[\(via)]")
            XCTAssertEqual(before["mimeType"] as? String, "text/html", "[\(via)]")
            XCTAssertEqual(before["securityOrigin"] as? String, "http://127.0.0.1:\(world.serverPort)", "[\(via)]")
            XCTAssertNil(before["parentId"], "[\(via)]")

            let target = world.url("four")
            tab.load(target)
            let navigated = try await waitForEvents(via, scene, "Page.frameNavigated", tabID: id, count: 1)
            let frame = try XCTUnwrap(navigated.first?["params"] as? [String: Any])["frame"] as? [String: Any]
            XCTAssertEqual(frame?["url"] as? String, target.absoluteString, "[\(via)]")
            XCTAssertEqual(frame?["id"] as? String, before["id"] as? String, "[\(via)] the main frame keeps its id")
            XCTAssertNotEqual(frame?["loaderId"] as? String, before["loaderId"] as? String, "[\(via)] a new document")
            XCTAssertNil(frame?["parentId"], "[\(via)]")
            XCTAssertEqual((navigated.first?["params"] as? [String: Any])?["type"] as? String, "Navigation", "[\(via)]")
            try await waitForLoad(tab)
            let tree9 = try await send(via, scene, id, "Page.getFrameTree")
            let after = try XCTUnwrap((tree9["frameTree"]
                                       as? [String: Any])?["frame"] as? [String: Any])
            XCTAssertEqual(after["loaderId"] as? String, frame?["loaderId"] as? String, "[\(via)]")

            // A same-document navigation commits nothing; neither does a
            // navigation with Page disabled report one.
            _ = try await tab.webView?.callAsyncJavaScript("location.hash = 'here';", arguments: [:], contentWorld: .page)
            _ = try await send(via, scene, id, "Page.disable")
            tab.load(world.url("one"))
            try await waitForLoad(tab)
            try await Task.sleep(for: .milliseconds(300))
            let count = try await events(via, scene, "Page.frameNavigated", tabID: id).count
            XCTAssertEqual(count, 1, "[\(via)] once per main-frame navigation, with Page enabled")
            try await detach(id, via, scene)
        }
    }
}
