import XCTest
import WebKit
@testable import Detour

/// TASK-132.16: Runtime.consoleAPICalled / exceptionThrown and the Network
/// events through `chrome.debugger`, from a real extension's service worker and
/// from one of its pages, against real tabs in a real (never shown) window.
nonisolated final class ExtensionDebuggerEventsTests: XCTestCase {

    private typealias Via = SidePanelTestWorld.Via
    private var world: SidePanelTestWorld!

    private static let routes: [String: String] = [
        "/errors": """
            <html><head><title>errors</title><script>
            function boom() { null.x; }
            window.later = () => { setTimeout(boom, 0); };
            window.rejectLater = () => { Promise.reject(new Error('nope')); };
            </script></head><body>errors</body></html>
            """,
        "/early": """
            <html><head><title>early</title><script>console.log('early', 42); console.warn('early warning');</script>
            </head><body>early</body></html>
            """,
        "/image": """
            <html><head><title>image</title></head><body><img src="/one"><img src="http://127.0.0.1:1/x.png"></body></html>
            """,
    ]

    @MainActor override func setUp() async throws {
        try await super.setUp()
        world = SidePanelTestWorld(opJS: DebuggerFixture.opJS, workerJS: TabGroupsFixture.workerJS,
                                   extraRoutes: Self.routes)
        try await world.setUp()
    }

    @MainActor override func tearDown() async throws {
        ExtensionDebugger.shared.resetForTesting()
        ExtensionDebuggerInstrumentation.resetForTesting()
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

    /// One profile, one space, one window, three tabs (the first selected).
    @MainActor private func makeScene(_ name: String) async throws -> Scene {
        let ext = try await world.makeExtension(name: "Events Test", permissions: ["debugger", "tabs"], defaultPath: nil)
        let profile = world.makeProfile(name)
        let space = world.makeSpace(name, in: profile)
        let window = world.makeWindow(on: space)
        var tabs: [BrowserTab] = []
        for page in ["one", "two", "three"] { tabs.append(try await world.addTab(page, in: space)) }
        window.selectTab(id: tabs[0].id)
        let loaded = try await world.load(ext, in: profile)
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

    @MainActor private func load(_ tab: BrowserTab, _ path: String) async throws {
        tab.load(world.url(path))
        try await waitUntil("\(path) to commit", timeout: 20) { tab.webView?.url == self.world.url(path) }
        try await waitForLoad(tab)
    }

    @MainActor private func send(_ via: Via, _ scene: Scene, _ id: Int, _ method: String,
                                 _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let value = try await world.run(via, in: scene.loaded, ["op": "call", "method": "sendCommand",
                                                                "args": [["tabId": id], method, params]])
        return try XCTUnwrap(value as? [String: Any], "\(method) answered \(value)")
    }

    @MainActor private func attach(_ tab: BrowserTab, _ via: Via, _ scene: Scene) async throws -> Int {
        let id = try await world.tabID(of: tab, via, in: scene.loaded)
        _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "attach", "args": [["tabId": id], "1.3"]])
        return id
    }

    @MainActor private func detach(_ id: Int, _ via: Via, _ scene: Scene) async throws {
        _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "detach", "args": [["tabId": id]]])
    }

    @MainActor private func clearEvents(_ via: Via, _ scene: Scene) async throws {
        _ = try await world.run(via, in: scene.loaded, ["op": "clearEvents"])
    }

    @MainActor private func events(_ via: Via, _ scene: Scene, _ method: String, tabID: Int) async throws -> [[String: Any]] {
        let value = try await world.run(via, in: scene.loaded, ["op": "events"])
        return (value as? [[String: Any]] ?? []).compactMap {
            guard $0["event"] as? String == "onEvent", $0["method"] as? String == method,
                  $0["tabId"] as? Int == tabID else { return nil }
            return $0["params"] as? [String: Any]
        }
    }

    @MainActor private func waitForEvents(_ via: Via, _ scene: Scene, _ method: String, tabID: Int, count: Int,
                                          where matches: @escaping ([String: Any]) -> Bool = { _ in true })
        async throws -> [[String: Any]] {
        var found: [[String: Any]] = []
        try await waitUntil("\(count) × \(method) in the \(via)", timeout: 15) {
            found = ((try? await self.events(via, scene, method, tabID: tabID)) ?? []).filter(matches)
            return found.count >= count
        }
        return found
    }

    /// Runs `body` in the tab's page world; returns what it returns, as JSON.
    @MainActor private func page(_ tab: BrowserTab, _ body: String) async throws -> Any? {
        let webView = try XCTUnwrap(tab.webView)
        let text = try await webView.callAsyncJavaScript("return JSON.stringify(await (async () => { \(body) })());",
                                                         arguments: [:], contentWorld: .page) as? String
        return try text.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
    }

    private static func string(_ value: Any?, _ key: String) -> String? {
        (value as? [String: Any])?[key] as? String
    }

    // MARK: - Console and exceptions (AC #1)

    @MainActor func testConsoleMessagesAndUncaughtErrorsReachTheExtension() async throws {
        let scene = try await makeScene("Events Console")
        for (index, via) in [(1, Via.worker), (2, Via.page)] {
            let tab = scene.tabs[index]
            try await load(tab, "errors")
            let id = try await attach(tab, via, scene)
            _ = try await send(via, scene, id, "Runtime.enable")
            try await clearEvents(via, scene)
            _ = try await page(tab, """
                console.log('hello', 42, { a: 1 }, null, undefined, true, [1, 2]);
                console.warn('careful'); console.error('bad'); console.info('fyi'); console.debug('detail');
                console.count(); console.count(); console.assert(1 === 2, 'not equal'); console.assert(true, 'never');
                return true;
                """)
            let messages = try await waitForEvents(via, scene, "Runtime.consoleAPICalled", tabID: id, count: 8)
            XCTAssertEqual(messages.map { $0["type"] as? String },
                           ["log", "warning", "error", "info", "debug", "count", "count", "assert"], "[\(via)]")
            let args = try XCTUnwrap(messages[0]["args"] as? [[String: Any]], "[\(via)]")
            XCTAssertEqual(args.count, 7, "[\(via)]")
            XCTAssertEqual(args[0]["type"] as? String, "string")
            XCTAssertEqual(args[0]["value"] as? String, "hello")
            XCTAssertEqual(args[1]["type"] as? String, "number")
            XCTAssertEqual(args[1]["value"] as? Int, 42)
            XCTAssertEqual(args[2]["type"] as? String, "object")
            XCTAssertEqual(args[2]["description"] as? String, "Object")
            XCTAssertNil(args[2]["value"], "an object is described, as V8 does, not sent by value")
            XCTAssertEqual(args[3]["subtype"] as? String, "null")
            XCTAssertEqual(args[4]["type"] as? String, "undefined")
            XCTAssertEqual(args[5]["value"] as? Bool, true)
            XCTAssertEqual(args[6]["description"] as? String, "Array(2)")
            XCTAssertNotNil(messages[0]["timestamp"] as? Double)
            XCTAssertEqual(Self.string(messages[5]["args"].flatMap { ($0 as? [Any])?.first }, "value"), "default: 1")
            XCTAssertEqual(Self.string(messages[6]["args"].flatMap { ($0 as? [Any])?.first }, "value"), "default: 2")
            XCTAssertEqual(Self.string(messages[7]["args"].flatMap { ($0 as? [Any])?.first }, "value"), "not equal")

            // An uncaught error and an unhandled rejection, from the page's own script.
            _ = try await page(tab, "later(); rejectLater(); return true;")
            let exceptions = try await waitForEvents(via, scene, "Runtime.exceptionThrown", tabID: id, count: 2)
            let byText = Dictionary(exceptions.compactMap { params -> (String, [String: Any])? in
                guard let details = params["exceptionDetails"] as? [String: Any], let text = details["text"] as? String
                else { return nil }
                return (text, details)
            }, uniquingKeysWith: { first, _ in first })
            let uncaught = try XCTUnwrap(byText["Uncaught"], "[\(via)] \(exceptions)")
            let thrown = try XCTUnwrap(uncaught["exception"] as? [String: Any])
            XCTAssertEqual(thrown["subtype"] as? String, "error", "[\(via)]")
            XCTAssertEqual(thrown["className"] as? String, "TypeError", "[\(via)]")
            let description = try XCTUnwrap(thrown["description"] as? String)
            XCTAssertTrue(description.hasPrefix("TypeError: "), "[\(via)] \(description)")
            XCTAssertTrue(description.contains("at boom (\(world.url("errors").absoluteString):"), "[\(via)] \(description)")
            XCTAssertEqual(uncaught["url"] as? String, world.url("errors").absoluteString, "[\(via)]")
            XCTAssertEqual(uncaught["lineNumber"] as? Int, 1, "[\(via)] 0-based: the line of `boom`")
            let frames = try XCTUnwrap((uncaught["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]])
            XCTAssertEqual(frames.first?["functionName"] as? String, "boom", "[\(via)]")
            let rejected = try XCTUnwrap(byText["Uncaught (in promise)"], "[\(via)] \(exceptions)")
            XCTAssertTrue(Self.string(rejected["exception"], "description")?.hasPrefix("Error: nope") == true, "[\(via)]")

            // The page's console still works, and its functions read as native.
            let checkValue = try await page(tab, """
                return [console.log('x') === undefined, String(console.log), console.log.name, console.log.length,
                        String(fetch), fetch.name, fetch.length, String(Function.prototype.toString),
                        XMLHttpRequest.prototype.open.length, String(XMLHttpRequest.prototype.send),
                        'prototype' in fetch];
                """)
            let checks = try XCTUnwrap(checkValue as? [Any])
            XCTAssertEqual(checks[0] as? Bool, true)
            XCTAssertEqual(checks[1] as? String, "function log() {\n    [native code]\n}", "[\(via)]")
            XCTAssertEqual(checks[2] as? String, "log")
            XCTAssertEqual(checks[3] as? Int, 0)
            XCTAssertEqual(checks[4] as? String, "function fetch() {\n    [native code]\n}", "[\(via)]")
            XCTAssertEqual(checks[5] as? String, "fetch")
            XCTAssertEqual(checks[6] as? Int, 1)
            XCTAssertEqual(checks[7] as? String, "function toString() {\n    [native code]\n}", "[\(via)]")
            XCTAssertEqual(checks[8] as? Int, 2)
            XCTAssertEqual(checks[9] as? String, "function send() {\n    [native code]\n}", "[\(via)]")
            XCTAssertEqual(checks[10] as? Bool, false)
            try await detach(id, via, scene)
        }
    }

    // MARK: - Early messages and replay (AC #2, #4)

    @MainActor func testEarlyMessagesAreKeptAndReplayedAndNothingFlowsWhenDisabledOrDetached() async throws {
        let scene = try await makeScene("Events Early")
        for (index, via) in [(1, Via.worker), (2, Via.page)] {
            let tab = scene.tabs[index]
            _ = try await page(tab, "window.__nativeLog = console.log; window.__nativeFetch = fetch; return true;")
            let id = try await attach(tab, via, scene)
            try await clearEvents(via, scene)
            // Logged before Runtime.enable, by the page's first script, after a navigation.
            try await load(tab, "early")
            try await Task.sleep(for: .milliseconds(300))
            let none = try await events(via, scene, "Runtime.consoleAPICalled", tabID: id)
            XCTAssertTrue(none.isEmpty, "[\(via)] nothing before Runtime.enable: \(none)")
            _ = try await send(via, scene, id, "Runtime.enable")
            let replayed = try await waitForEvents(via, scene, "Runtime.consoleAPICalled", tabID: id, count: 2)
            XCTAssertEqual(Self.string((replayed[0]["args"] as? [Any])?.first, "value"), "early", "[\(via)]")
            XCTAssertEqual(replayed[1]["type"] as? String, "warning", "[\(via)]")
            let frame = ((replayed[0]["stackTrace"] as? [String: Any])?["callFrames"] as? [[String: Any]])?.first
            XCTAssertEqual(frame?["url"] as? String, world.url("early").absoluteString,
                           "[\(via)] the page's script, not Detour's wrapper")

            // Disabled: nothing more.
            _ = try await send(via, scene, id, "Runtime.disable")
            try await clearEvents(via, scene)
            _ = try await page(tab, "console.log('while disabled'); return true;")
            try await Task.sleep(for: .milliseconds(300))
            let afterDisable = try await events(via, scene, "Runtime.consoleAPICalled", tabID: id)
            XCTAssertTrue(afterDisable.isEmpty, "[\(via)] \(afterDisable)")

            // Detached: the wrappers are gone from the document, and the next
            // document is not instrumented.
            _ = try await send(via, scene, id, "Runtime.enable")
            try await detach(id, via, scene)
            try await clearEvents(via, scene)
            try await load(tab, "one")
            _ = try await page(tab, "window.__nativeLog = console.log; window.__nativeFetch = fetch; return true;")
            let id2 = try await attach(tab, via, scene)
            let wrapped = try await page(tab, "return console.log !== window.__nativeLog && fetch !== window.__nativeFetch;")
            XCTAssertEqual(wrapped as? Bool, true, "[\(via)] wrapped while attached")
            try await detach(id2, via, scene)
            try await waitUntil("the wrappers to be taken out") {
                let restored = try? await self.page(tab, "return console.log === window.__nativeLog && fetch === window.__nativeFetch;")
                return restored as? Bool == true
            }
            let sources = tab.webView?.configuration.userContentController.userScripts.map(\.source) ?? []
            XCTAssertFalse(sources.contains { $0.contains("__detourDebuggerInstrumentation") }, "[\(via)] scripts removed")
            _ = try await page(tab, "console.log('after detach'); return true;")
            try await Task.sleep(for: .milliseconds(300))
            let afterDetach = try await events(via, scene, "Runtime.consoleAPICalled", tabID: id2)
            XCTAssertTrue(afterDetach.isEmpty, "[\(via)] \(afterDetach)")
        }
    }

    // MARK: - Network (AC #3, #4)

    @MainActor func testFetchAndXHRRequestsReachTheExtension() async throws {
        let scene = try await makeScene("Events Network")
        for (index, via) in [(1, Via.worker), (2, Via.page)] {
            let tab = scene.tabs[index]
            let id = try await attach(tab, via, scene)
            // Before Network.enable: nothing.
            _ = try await page(tab, "await fetch('/one'); return true;")
            _ = try await send(via, scene, id, "Network.enable", ["maxPostDataSize": 65536])
            try await clearEvents(via, scene)
            let resultValue = try await page(tab, """
                const out = [];
                out.push((await fetch('/one')).status);
                out.push((await fetch('/missing', { method: 'post', body: 'a=1' })).status);
                try { await fetch('http://127.0.0.1:1/'); out.push('no'); } catch (e) { out.push(e.name); }
                const xhr = (method, url, body) => new Promise((resolve) => {
                    const request = new XMLHttpRequest();
                    request.open(method, url);
                    request.setRequestHeader('X-Test', 'yes');
                    request.onloadend = () => resolve(request.status);
                    request.send(body);
                });
                out.push(await xhr('GET', '/two'));
                out.push(await xhr('POST', '/missing', 'b=2'));
                out.push(await xhr('GET', 'http://127.0.0.1:1/'));
                return out;
                """)
            let results = try XCTUnwrap(resultValue as? [Any])
            XCTAssertEqual(results.count, 6)
            XCTAssertEqual(results[0] as? Int, 200, "[\(via)] the page's fetch behaves as before")
            XCTAssertEqual(results[1] as? Int, 404)
            XCTAssertEqual(results[2] as? String, "TypeError")
            XCTAssertEqual(results[3] as? Int, 200)
            XCTAssertEqual(results[4] as? Int, 404)
            XCTAssertEqual(results[5] as? Int, 0)

            let sent = try await waitForEvents(via, scene, "Network.requestWillBeSent", tabID: id, count: 6)
            let received = try await waitForEvents(via, scene, "Network.responseReceived", tabID: id, count: 4)
            let failed = try await waitForEvents(via, scene, "Network.loadingFailed", tabID: id, count: 2)
            let requests = sent.compactMap { $0["request"] as? [String: Any] }
            XCTAssertEqual(requests.map { $0["url"] as? String },
                           [world.url("one"), world.url("missing"), URL(string: "http://127.0.0.1:1/")!,
                            world.url("two"), world.url("missing"), URL(string: "http://127.0.0.1:1/")!]
                            .map(\.absoluteString), "[\(via)]")
            XCTAssertEqual(requests.map { $0["method"] as? String }, ["GET", "POST", "GET", "GET", "POST", "GET"], "[\(via)]")
            XCTAssertEqual(sent.map { $0["type"] as? String }, ["Fetch", "Fetch", "Fetch", "XHR", "XHR", "XHR"])
            XCTAssertEqual(requests[1]["postData"] as? String, "a=1", "[\(via)]")
            XCTAssertEqual(requests[4]["postData"] as? String, "b=2", "[\(via)]")
            XCTAssertEqual((requests[3]["headers"] as? [String: Any])?["X-Test"] as? String, "yes", "[\(via)]")
            XCTAssertEqual(sent[0]["documentURL"] as? String, tab.webView?.url?.absoluteString, "[\(via)]")
            XCTAssertEqual(sent[0]["frameId"] as? String, ExtensionDebuggerFrames.frameID(for: tab))

            let ids = sent.compactMap { $0["requestId"] as? String }
            XCTAssertEqual(Set(ids).count, 6, "[\(via)] one id per request")
            let statuses = Dictionary(received.compactMap { params -> (String, Int)? in
                guard let id = params["requestId"] as? String,
                      let status = (params["response"] as? [String: Any])?["status"] as? Int else { return nil }
                return (id, status)
            }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(statuses[ids[0]], 200, "[\(via)]")
            XCTAssertEqual(statuses[ids[1]], 404, "[\(via)]")
            XCTAssertEqual(statuses[ids[3]], 200, "[\(via)]")
            XCTAssertEqual(statuses[ids[4]], 404, "[\(via)]")
            XCTAssertEqual(Self.string(received.first, "type"), "Fetch")
            XCTAssertEqual(Self.string(received.first?["response"], "mimeType"), "text/html", "[\(via)]")
            XCTAssertEqual(Set(failed.compactMap { $0["requestId"] as? String }), [ids[2], ids[5]], "[\(via)]")
            XCTAssertEqual(failed.first?["errorText"] as? String, "net::ERR_FAILED")

            // An unhandled failed fetch still reaches the page's own handler.
            let unhandled = try await page(tab, """
                return await new Promise((resolve) => {
                    window.addEventListener('unhandledrejection', (e) => resolve(e.reason && e.reason.name), { once: true });
                    fetch('http://127.0.0.1:1/');
                    setTimeout(() => resolve('none'), 3000);
                });
                """)
            XCTAssertEqual(unhandled as? String, "TypeError", "[\(via)]")

            // A body past what the page reports is left out, not cut short.
            _ = try await send(via, scene, id, "Network.enable", ["maxPostDataSize": 1_000_000])
            _ = try await page(tab, "await fetch('/missing', { method: 'PUT', body: 'x'.repeat(70000) }); return true;")
            let long = try await waitForEvents(via, scene, "Network.requestWillBeSent", tabID: id, count: 1) {
                Self.string($0["request"], "method") == "PUT"
            }
            let longRequest = try XCTUnwrap(long[0]["request"] as? [String: Any])
            XCTAssertEqual(longRequest["hasPostData"] as? Bool, true, "[\(via)]")
            XCTAssertNil(longRequest["postData"], "[\(via)] a cut body would read as the whole one")

            // Network.disable: nothing more.
            _ = try await send(via, scene, id, "Network.disable")
            try await clearEvents(via, scene)
            _ = try await page(tab, "await fetch('/one'); return true;")
            try await Task.sleep(for: .milliseconds(300))
            let afterDisable = try await events(via, scene, "Network.requestWillBeSent", tabID: id)
            XCTAssertTrue(afterDisable.isEmpty, "[\(via)] \(afterDisable)")
            try await detach(id, via, scene)
        }
    }

    @MainActor func testTheDocumentAndItsSubresourcesAreReported() async throws {
        let scene = try await makeScene("Events Document")
        let via = Via.worker
        let tab = scene.tabs[1]
        let id = try await attach(tab, via, scene)
        _ = try await send(via, scene, id, "Page.enable")
        _ = try await send(via, scene, id, "Network.enable")
        try await clearEvents(via, scene)
        try await load(tab, "image")
        let navigated = try await waitForEvents(via, scene, "Page.frameNavigated", tabID: id, count: 1)
        let loaderID = try XCTUnwrap((navigated[0]["frame"] as? [String: Any])?["loaderId"] as? String)
        let documents = try await waitForEvents(via, scene, "Network.requestWillBeSent", tabID: id, count: 1) {
            $0["type"] as? String == "Document"
        }
        XCTAssertEqual(documents[0]["requestId"] as? String, loaderID, "the document's request id is its loader id")
        XCTAssertEqual(Self.string(documents[0]["request"], "url"), world.url("image").absoluteString)
        XCTAssertEqual(Self.string(documents[0]["request"], "method"), "GET")
        let responses = try await waitForEvents(via, scene, "Network.responseReceived", tabID: id, count: 1) {
            $0["requestId"] as? String == loaderID
        }
        XCTAssertEqual((responses[0]["response"] as? [String: Any])?["status"] as? Int, 200)
        XCTAssertEqual(Self.string(responses[0]["response"], "mimeType"), "text/html")
        _ = try await waitForEvents(via, scene, "Network.loadingFinished", tabID: id, count: 1) {
            $0["requestId"] as? String == loaderID
        }

        // The image that loaded, from resource timing, and the one that failed.
        let images = try await waitForEvents(via, scene, "Network.requestWillBeSent", tabID: id, count: 2) {
            $0["type"] as? String == "Image"
        }
        let byURL = Dictionary(images.compactMap { params -> (String, String)? in
            guard let url = Self.string(params["request"], "url"), let id = params["requestId"] as? String else { return nil }
            return (url, id)
        }, uniquingKeysWith: { first, _ in first })
        let loadedID = try XCTUnwrap(byURL[world.url("one").absoluteString], "\(images)")
        let failedID = try XCTUnwrap(byURL["http://127.0.0.1:1/x.png"], "\(images)")
        _ = try await waitForEvents(via, scene, "Network.loadingFinished", tabID: id, count: 1) {
            $0["requestId"] as? String == loadedID
        }
        _ = try await waitForEvents(via, scene, "Network.loadingFailed", tabID: id, count: 1) {
            $0["requestId"] as? String == failedID
        }

        // A document the server does not have: its status.
        try await clearEvents(via, scene)
        try await load(tab, "nowhere")
        let missing = try await waitForEvents(via, scene, "Network.responseReceived", tabID: id, count: 1) {
            $0["type"] as? String == "Document"
        }
        XCTAssertEqual((missing[0]["response"] as? [String: Any])?["status"] as? Int, 404)
        try await detach(id, via, scene)
    }

    @MainActor func testNetworkEnableRefusesBadParameters() async throws {
        let scene = try await makeScene("Events Params")
        let expected = #"{"code":-32602,"message":"Invalid parameters: maxPostDataSize: integer value expected"}"#
        for (index, via) in [(1, Via.worker), (2, Via.page)] {
            let id = try await attach(scene.tabs[index], via, scene)
            let args: [Any] = [["tabId": id], "Network.enable", ["maxPostDataSize": "big"]]
            let promise = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "sendCommand", "args": args])
            XCTAssertEqual(promise, expected, "[\(via)] promise form")
            let callback = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "sendCommand",
                                                                           "args": args])
            XCTAssertEqual(callback["lastError"] as? String, expected, "[\(via)] callback form")
            let session = try XCTUnwrap(ExtensionDebugger.shared.session(forTabUUID: scene.tabs[index].id))
            XCTAssertFalse(session.enabledDomains.contains("Network"), "[\(via)] a refused enable enables nothing")
            try await detach(id, via, scene)
        }
    }

    // MARK: - The tab's web view and the back/forward cache

    @MainActor func testATabWokenWithANewWebViewStaysInstrumented() async throws {
        let scene = try await makeScene("Events Wake")
        let tab = scene.tabs[1]
        let id = try await attach(tab, .worker, scene)
        _ = try await send(.worker, scene, id, "Runtime.enable")
        let before = tab.webView
        // A forced sleep (a profile swap, a retarget) keeps the attachment and
        // wakes the tab with a new web view.
        tab.sleep(force: true)
        try await waitUntil("the attached tab to wake with a new web view", timeout: 20) {
            tab.webView != nil && tab.webView !== before
        }
        try await waitForLoad(tab)
        _ = try await page(tab, "console.log('after the wake'); return true;")
        _ = try await waitForEvents(.worker, scene, "Runtime.consoleAPICalled", tabID: id, count: 1) {
            (($0["args"] as? [[String: Any]])?.first?["value"] as? String) == "after the wake"
        }
        try await detach(id, .worker, scene)
    }

    @MainActor func testADocumentBackFromTheCacheFollowsTheSession() async throws {
        let scene = try await makeScene("Events Cache")
        let tab = scene.tabs[1]
        let instrumentationToken = { () async throws -> String? in
            try await tab.webView?.callAsyncJavaScript(
                "const i = window.__detourDebuggerInstrumentation; return i ? i.token : null;",
                arguments: [:], in: nil, contentWorld: ExtensionDebugger.contentWorld) as? String
        }
        let back = { () async throws in
            tab.webView?.goBack()
            try await waitUntil("back on /two", timeout: 20) { tab.webView?.url == self.world.url("two") }
            try await self.waitForLoad(tab)
        }
        // /two, instrumented for a first session, goes into the cache.
        var id = try await attach(tab, .worker, scene)
        _ = try await page(tab, "window.__cached = true; return true;")
        try await load(tab, "three")
        try await detach(id, .worker, scene)

        // Back under a later session: the first session's halves make way for
        // this one's.
        id = try await attach(tab, .worker, scene)
        _ = try await send(.worker, scene, id, "Runtime.enable")
        let current = try XCTUnwrap(ExtensionDebuggerInstrumentation.install(for: tab.id)).token
        try await back()
        let cached = try await page(tab, "return window.__cached === true;")
        try XCTSkipUnless(cached as? Bool == true, "/two did not come back from the back/forward cache")
        try await waitUntil("the later session's halves in the restored document", timeout: 10) {
            (try? await instrumentationToken()) == current
        }
        _ = try await page(tab, "console.log('back from the cache'); return true;")
        _ = try await waitForEvents(.worker, scene, "Runtime.consoleAPICalled", tabID: id, count: 1) {
            (($0["args"] as? [[String: Any]])?.first?["value"] as? String) == "back from the cache"
        }

        // Back with no session at all: the halves take themselves out.
        try await load(tab, "three")
        try await detach(id, .worker, scene)
        try await back()
        try await waitUntil("no halves left in the restored document", timeout: 10) {
            (try? await instrumentationToken()) == nil
        }
    }

    // MARK: - Unattached tabs (AC #5)

    @MainActor func testOnlyTheAttachedTabIsInstrumented() async throws {
        let scene = try await makeScene("Events Isolation")
        let attached = scene.tabs[1], other = scene.tabs[2]
        _ = try await page(other, "window.__nativeLog = console.log; window.__nativeFetch = fetch; return true;")
        let id = try await attach(attached, .worker, scene)
        _ = try await send(.worker, scene, id, "Runtime.enable")
        _ = try await send(.worker, scene, id, "Network.enable")
        let untouched = try await page(other, """
            return console.log === window.__nativeLog && fetch === window.__nativeFetch;
            """)
        XCTAssertEqual(untouched as? Bool, true, "another tab of the space keeps its own console and fetch")
        let otherSources = other.webView?.configuration.userContentController.userScripts.map(\.source) ?? []
        XCTAssertFalse(otherSources.contains { $0.contains("__detourDebuggerInstrumentation") })
        let otherWorld = try await other.webView?.callAsyncJavaScript(
            "return typeof window.__detourDebuggerInstrumentation;", arguments: [:], in: nil,
            contentWorld: ExtensionDebugger.contentWorld)
        XCTAssertEqual(otherWorld as? String, "undefined")
        try await clearEvents(.worker, scene)
        _ = try await page(other, "console.log('elsewhere'); await fetch('/one'); return true;")
        try await Task.sleep(for: .milliseconds(300))
        let all = try await world.run(.worker, in: scene.loaded, ["op": "events"]) as? [[String: Any]] ?? []
        XCTAssertTrue(all.isEmpty, "nothing from a tab the extension did not attach to: \(all)")
        try await detach(id, .worker, scene)
    }
}
