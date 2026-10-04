import XCTest
import WebKit
@testable import Detour

/// TASK-132.6: `chrome.runtime` on the web pages an extension lists in
/// `externally_connectable.matches`, end to end — real extension contexts (a
/// service worker, and an extension page as the second receiver), real tabs
/// built by `TabStore` (so the page gets exactly the configuration a browser
/// tab gets), and pages served by a loopback HTTP server. Nothing here talks to
/// a real site.
///
/// WebKit puts a `browser` global with `runtime.sendMessage` / `runtime.connect`
/// on *every* web page of a profile and never a `chrome` one; it decides in the
/// UI process whether a message is delivered and answers a refused one with
/// `undefined` after a random delay. Detour's page shim
/// (`ExternallyConnectable`) adds `chrome.runtime` on the pages an enabled
/// extension of the profile lists, forwards to WebKit's functions, and reports
/// Chrome's error for an id the page may not reach. The two canary tests pin the
/// WebKit behaviour that design rests on.
///
/// 127.0.0.1 and localhost stand in for two sites: the server listens on the
/// loopback interface and a match pattern's host ignores the port.
@MainActor
final class ExtensionExternallyConnectableTests: XCTestCase {

    private static var retainedProfiles: [Profile] = []
    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var incognitoSpaceIDs: [UUID] = []
    private var loadedInPrivate: [String] = []
    private var pages: [WKWebView] = []
    private var server: LoopbackHTTPServer!
    private var port: UInt16 = 0
    private var previousLastActiveSpaceID: UUID?

    private static let noReceiver = "Could not establish connection. Receiving end does not exist."

    override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        server = try LoopbackHTTPServer(routes: [
            "/page": "<html><head><title>page</title></head><body>page</body></html>",
            "/other": "<html><head><title>other</title></head><body>other</body></html>",
            // A page that replaces `window.chrome` outright.
            "/own-chrome-replace": """
                <html><head><script>
                window.__before = typeof window.chrome;
                window.__beforeRuntime = typeof (window.chrome && window.chrome.runtime);
                window.chrome = { mine: 1, loadTimes: function() { return 'page'; } };
                </script></head><body>own chrome</body></html>
                """,
            // A page that extends whatever `window.chrome` it finds.
            "/own-chrome-extend": """
                <html><head><script>
                window.chrome = window.chrome || {};
                window.chrome.mine = 2;
                var chrome;
                </script></head><body>own chrome</body></html>
                """,
            // A page declaring `chrome` lexically: a non-configurable global
            // property of that name would make this a SyntaxError.
            "/own-chrome-let": """
                <html><head><script>let chrome = { mine: 3 }; window.__lexical = chrome.mine;</script>
                <script>window.__lexicalSeen = typeof chrome.mine;</script></head><body>own chrome</body></html>
                """,
            // A top page on one host framing a page on the other.
            "/frame-host": """
                <html><body><script>
                const frame = document.createElement('iframe');
                frame.src = 'http://127.0.0.1:' + location.port + '/frame-child';
                document.body.appendChild(frame);
                window.__fromFrame = new Promise((resolve) => window.addEventListener('message', (e) => resolve(e.data)));
                </script></body></html>
                """,
            "/frame-child": """
                <html><body><script>
                (async () => {
                    const out = { chrome: typeof window.chrome, runtime: typeof (window.chrome && chrome.runtime) };
                    try {
                        const id = new URLSearchParams(await new Promise((resolve) =>
                            window.addEventListener('message', (e) => resolve(e.data), { once: true }))).get('id');
                        out.reply = await chrome.runtime.sendMessage(id, { type: 'hello', from: 'frame' });
                    } catch (e) { out.error = String(e && e.message ? e.message : e); }
                    parent.postMessage(JSON.stringify(out), '*');
                })();
                </script></body></html>
                """,
        ])
        port = try await server.start()
    }

    override func tearDown() async throws {
        for page in pages { page.stopLoading() }
        pages.removeAll()
        for id in createdSpaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs {
                TabStore.shared.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        for id in incognitoSpaceIDs { TabStore.shared.removeIncognitoSpace(id: id) }
        if !createdSpaceIDs.isEmpty || !incognitoSpaceIDs.isEmpty {
            TabStore.shared.undoManager.removeAllActions()
            TabStore.shared.saveNow()
        }
        createdSpaceIDs.removeAll()
        incognitoSpaceIDs.removeAll()
        if !loadedInPrivate.isEmpty, let privateProfile = TabStore.shared.profiles.first(where: { $0.id == TabStore.incognitoProfileID }) {
            for id in loadedInPrivate { privateProfile.unloadExtension(id: id) }
        }
        loadedInPrivate.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            TabStore.shared.forceRemoveProfile(id: profile.id)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        server.stop()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        try await super.tearDown()
    }

    // MARK: - Fixture extensions

    /// An id shaped like Chrome's: 32 letters a–p.
    private func chromeStyleID() -> String {
        String((0..<32).map { _ in "abcdefghijklmnop".randomElement()! })
    }

    private enum Listener { case worker, page, none }

    /// What every receiver does with an external message or port: record it,
    /// and answer with who it is, what it got and how the sender looked.
    private static func receiverJS(name: String) -> String {
        """
        const NAME = '\(name)';
        const received = [];
        const describe = (sender) => ({
            keys: Object.keys(sender || {}).sort(),
            id: sender && sender.id === undefined ? null : sender && sender.id,
            origin: sender && sender.origin, url: sender && sender.url,
            frameId: sender && sender.frameId,
            tabId: sender && sender.tab ? sender.tab.id : null
        });
        chrome.runtime.onMessageExternal.addListener((message, sender, sendResponse) => {
            received.push({ kind: 'message', message: message, sender: describe(sender) });
            if (message && message.type === 'noReply') return false;
            const reply = { who: NAME, echo: message, sender: describe(sender) };
            if (message && message.type === 'asyncReply') { setTimeout(() => sendResponse(reply), 50); return true; }
            sendResponse(reply);
            return false;
        });
        chrome.runtime.onConnectExternal.addListener((port) => {
            received.push({ kind: 'connect', name: port.name, sender: describe(port.sender) });
            port.onMessage.addListener((m) => {
                if (m && m.type === 'hangUp') { port.disconnect(); return; }
                port.postMessage({ who: NAME, echo: m, name: port.name, sender: describe(port.sender) });
            });
        });
        """
    }

    /// An MV3 extension with a service worker and one page. `listener` says
    /// which of them listens on `onMessageExternal` / `onConnectExternal`; the
    /// worker always answers `received` (what reached this extension's
    /// listeners in the worker) and `tabURL` (the URL of a tab id) for the test.
    private func makeExtension(name: String, connectable: [String]?,
                               hostPermissions: [String] = ["<all_urls>"],
                               listener: Listener = .worker) async throws -> WebExtension {
        let id = chromeStyleID()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        var manifestObject: [String: Any] = [
            "manifest_version": 3, "name": name, "version": "1.0.0",
            "permissions": ["tabs"], "host_permissions": hostPermissions,
            "background": ["service_worker": "background.js"],
        ]
        if let connectable { manifestObject["externally_connectable"] = ["matches": connectable] }
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        try """
            <html><body>test page<script src="page.js"></script></body></html>
            """.write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try (listener == .page ? Self.receiverJS(name: name + "-page") + "\nwindow.__received = received;" : "")
            .write(to: dir.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        try (ExtensionAPIPolyfill.polyfillJS + "\n\n"
            + (listener == .worker ? Self.receiverJS(name: name) : "const NAME = '\(name)'; const received = [];") + """


        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'received') { sendResponse({ who: NAME, received: received }); return false; }
            if (message && message.type === 'tabURL') {
                chrome.tabs.get(message.tabId).then((tab) => sendResponse({ url: tab.url }),
                                                    (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
                return true;
            }
            return false;
        });
        """).write(to: dir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        installTestExtension(ext, in: AppDatabase.shared, manifestJSON: manifestData)
        AppDatabase.shared.recordDeclaredPermissions(
            [ExtensionPermissionRecord(extensionID: id, key: "tabs", type: .apiPermission, status: .granted)]
            + hostPermissions.map { ExtensionPermissionRecord(extensionID: id, key: $0, type: .matchPattern, status: .granted) })
        return ext
    }

    /// One extension loaded into one profile: its page and its started worker.
    private struct Loaded {
        let ext: WebExtension
        let context: WKWebExtensionContext
        let page: WKWebView
    }

    private func load(_ ext: WebExtension, in profile: Profile) async throws -> Loaded {
        let context = try loadTestContext(ext, in: profile)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        pages.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { error in
            if let error { print("loadBackgroundContent failed: \(error)") }
        }
        let loaded = Loaded(ext: ext, context: context, page: page)
        try await waitUntil("the worker of \(ext.manifest.name) to answer", timeout: 30) {
            (try? await self.receivedByWorker(loaded)) != nil
        }
        return loaded
    }

    private struct WorkerSilent: Error {}

    /// Everything that reached the `onMessageExternal` / `onConnectExternal`
    /// listeners in `loaded`'s worker so far.
    private func receivedByWorker(_ loaded: Loaded) async throws -> [[String: Any]] {
        let asked = try await askWorker(from: loaded.page, message: ["type": "received"], timeout: 5)
        guard let reply = asked["reply"] as? [String: Any],
              let received = reply["received"] as? [[String: Any]] else { throw WorkerSilent() }
        return received
    }

    // MARK: - Profiles, spaces and tabs

    private func makeProfile(_ name: String) -> (Profile, Space) {
        let profile = TabStore.shared.addProfile(name: "EC \(name) \(UUID().uuidString.prefix(4))")
        createdProfiles.append(profile)
        _ = profile.extensionController
        let space = TabStore.shared.addSpace(name: "EC \(name)", emoji: "E", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return (profile, space)
    }

    private func url(_ host: String, _ path: String = "/page") -> String { "http://\(host):\(port)\(path)" }

    /// Opens a tab the way the app does and waits for its page.
    private func openTab(_ url: String, in space: Space) async throws -> WKWebView {
        let tab = TabStore.shared.addTab(in: space, url: URL(string: url)!)
        let view = try XCTUnwrap(tab.webView, "a tab added through the store has a web view")
        try await waitUntil("the tab to load \(url)", timeout: 30, pollInterval: 0.25) {
            !view.isLoading && view.url?.absoluteString == url
        }
        return view
    }

    // MARK: - Running page script

    private func evaluate(_ view: WKWebView, _ body: String, _ arguments: [String: Any] = [:],
                          file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let raw = try await view.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page", file: file, line: line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], file: file, line: line)
    }

    /// What a page sees of the two globals.
    private func globals(_ view: WKWebView) async throws -> [String: Any] {
        try await evaluate(view, """
            const c = globalThis.chrome;
            return JSON.stringify({
                chrome: typeof c,
                runtime: typeof (c && c.runtime),
                sendMessage: typeof (c && c.runtime && c.runtime.sendMessage),
                connect: typeof (c && c.runtime && c.runtime.connect),
                runtimeKeys: c && c.runtime ? Object.keys(c.runtime).sort() : null,
                chromeKeys: c ? Object.keys(c).sort() : null,
                lastError: c && c.runtime ? (c.runtime.lastError === undefined ? 'undefined' : String(c.runtime.lastError)) : null,
                browser: typeof globalThis.browser,
                browserRuntime: typeof (globalThis.browser && browser.runtime)
            });
            """)
    }

    /// `chrome.runtime.sendMessage(id, message[, options], callback)` and what
    /// the callback saw: `{ argc, reply, lastError, returned, lastErrorAfter }`,
    /// or `{ missing: true }` when the page has no `chrome.runtime`, `{ threw }`
    /// when the call itself threw, `{ timedOut: true }` when it never ran.
    private func sendWithCallback(_ view: WKWebView, to id: String, _ message: [String: Any],
                                  options: [String: Any]? = nil) async throws -> [String: Any] {
        var arguments: [String: Any] = ["id": id, "message": message]
        if let options { arguments["options"] = options }
        return try await evaluate(view, """
            if (typeof chrome === 'undefined' || !chrome.runtime) return JSON.stringify({ missing: true });
            return await new Promise((resolve) => {
                const timer = setTimeout(() => resolve(JSON.stringify({ timedOut: true })), 8000);
                const callback = function() {
                    clearTimeout(timer);
                    const lastError = chrome.runtime.lastError;
                    const out = { argc: arguments.length, reply: arguments.length ? arguments[0] : null,
                                  lastError: lastError ? lastError.message : null };
                    setTimeout(() => {
                        out.returned = typeof returned;
                        out.lastErrorAfter = chrome.runtime.lastError === undefined ? null : 'still set';
                        resolve(JSON.stringify(out));
                    }, 0);
                };
                let returned;
                try {
                    returned = \(options == nil ? "chrome.runtime.sendMessage(id, message, callback)"
                                                : "chrome.runtime.sendMessage(id, message, options, callback)");
                } catch (e) {
                    clearTimeout(timer);
                    resolve(JSON.stringify({ threw: String(e && e.message ? e.message : e) }));
                }
            });
            """, arguments)
    }

    /// The promise form: `{ settled: 'resolved' | 'rejected', value, message }`,
    /// or `{ missing: true }` / `{ threw }`.
    private func sendWithPromise(_ view: WKWebView, to id: String, _ message: [String: Any]) async throws -> [String: Any] {
        try await evaluate(view, """
            if (typeof chrome === 'undefined' || !chrome.runtime) return JSON.stringify({ missing: true });
            let promise;
            try { promise = chrome.runtime.sendMessage(id, message); }
            catch (e) { return JSON.stringify({ threw: String(e && e.message ? e.message : e) }); }
            if (!promise || typeof promise.then !== 'function') return JSON.stringify({ notAPromise: typeof promise });
            try {
                const value = await Promise.race([promise,
                    new Promise((resolve) => setTimeout(() => resolve('TIMED OUT'), 8000))]);
                return JSON.stringify({ settled: 'resolved', value: value === undefined ? null : value });
            } catch (e) {
                return JSON.stringify({ settled: 'rejected', isError: e instanceof Error,
                                        message: String(e && e.message ? e.message : e) });
            }
            """, ["id": id, "message": message])
    }

    /// `chrome.runtime.connect(id, { name })`, one message posted, and what
    /// happened within `wait` seconds: `{ events: [...], name }`. An event is
    /// `{ message }` or `{ disconnect: true, lastError, samePort }`.
    private func connect(_ view: WKWebView, to id: String, name: String = "test-port",
                         post: [String: Any] = ["hi": 1], wait: TimeInterval = 4) async throws -> [String: Any] {
        try await evaluate(view, """
            if (typeof chrome === 'undefined' || !chrome.runtime) return JSON.stringify({ missing: true });
            const out = { events: [] };
            let port;
            try { port = chrome.runtime.connect(id, { name: name }); }
            catch (e) { return JSON.stringify({ threw: String(e && e.message ? e.message : e) }); }
            out.name = port.name;
            out.shape = ['postMessage', 'disconnect'].map((k) => typeof port[k]).concat(
                ['onMessage', 'onDisconnect'].map((k) => typeof (port[k] && port[k].addListener))).join(',');
            await new Promise((resolve) => {
                const timer = setTimeout(() => { out.events.push('nothing'); resolve(); }, waitMS);
                port.onMessage.addListener((m) => { out.events.push({ message: m }); clearTimeout(timer); resolve(); });
                port.onDisconnect.addListener((p) => {
                    const lastError = chrome.runtime.lastError;
                    out.events.push({ disconnect: true, samePort: p === port, lastError: lastError ? lastError.message : null });
                    clearTimeout(timer); resolve();
                });
                try { port.postMessage(post); } catch (e) { out.postThrew = String(e && e.message ? e.message : e); }
            });
            await new Promise((resolve) => setTimeout(resolve, 0));
            out.lastErrorAfter = chrome.runtime.lastError === undefined ? null : 'still set';
            window.__port = port;
            return JSON.stringify(out);
            """, ["id": id, "name": name, "post": post, "waitMS": Int(wait * 1000)])
    }

    private func assertFailsLikeChrome(_ view: WKWebView, to id: String, _ what: String,
                                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let viaCallback = try await sendWithCallback(view, to: id, ["type": "hello", "via": "callback"])
        XCTAssertEqual(viaCallback["lastError"] as? String, Self.noReceiver,
                       "\(what): the callback must see runtime.lastError, got \(viaCallback)", file: file, line: line)
        XCTAssertEqual(viaCallback["argc"] as? Int, 0, "\(what): a failed call runs the callback without arguments",
                       file: file, line: line)
        XCTAssertNil(viaCallback["lastErrorAfter"] as? String, "\(what): lastError is only set during the callback",
                     file: file, line: line)
        let viaPromise = try await sendWithPromise(view, to: id, ["type": "hello", "via": "promise"])
        XCTAssertEqual(viaPromise["settled"] as? String, "rejected",
                       "\(what): the promise must reject, got \(viaPromise)", file: file, line: line)
        XCTAssertEqual(viaPromise["message"] as? String, Self.noReceiver, file: file, line: line)
        XCTAssertEqual(viaPromise["isError"] as? Bool, true, "\(what): the rejection is an Error", file: file, line: line)
    }

    // MARK: - 1. A listed page reaches the extension

    /// POSITIVE: from a page the extension lists, `chrome.runtime.sendMessage
    /// (id, message)` reaches `runtime.onMessageExternal` in the service worker
    /// with the page's origin, URL and tab, and the reply comes back — callback
    /// form, promise form, an asynchronous reply, and with an options argument.
    func testListedPageReachesOnMessageExternalInTheWorkerAndGetsTheReply() async throws {
        let (profile, space) = makeProfile("positive")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        let loaded = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)

        let seen = try await globals(view)
        XCTAssertEqual(seen["sendMessage"] as? String, "function", "a listed page gets chrome.runtime.sendMessage: \(seen)")
        XCTAssertEqual(seen["connect"] as? String, "function", "…and chrome.runtime.connect: \(seen)")
        XCTAssertEqual(seen["lastError"] as? String, "undefined", "lastError is undefined outside a failing callback")
        XCTAssertEqual(seen["chromeKeys"] as? [String], ["runtime"], "nothing but runtime is added to chrome: \(seen)")
        XCTAssertEqual(Set(seen["runtimeKeys"] as? [String] ?? []), ["connect", "lastError", "sendMessage"],
                       "nothing but messaging is on chrome.runtime: \(seen)")

        let viaCallback = try await sendWithCallback(view, to: ext.id, ["type": "hello", "n": 1])
        XCTAssertNil(viaCallback["lastError"] as? String, "\(viaCallback)")
        XCTAssertEqual(viaCallback["argc"] as? Int, 1)
        XCTAssertEqual(viaCallback["returned"] as? String, "undefined", "the callback form returns nothing")
        let reply = try XCTUnwrap(viaCallback["reply"] as? [String: Any], "the worker's reply: \(viaCallback)")
        XCTAssertEqual(reply["who"] as? String, "A")
        XCTAssertEqual((reply["echo"] as? [String: Any])?["n"] as? Int, 1)
        let sender = try XCTUnwrap(reply["sender"] as? [String: Any])
        XCTAssertEqual(sender["origin"] as? String, "http://127.0.0.1:\(port)", "sender.origin is the page's origin")
        XCTAssertEqual(sender["url"] as? String, url("127.0.0.1"))
        XCTAssertEqual(sender["frameId"] as? Int, 0)
        XCTAssertTrue(sender["id"] is NSNull, "a web page has no extension id: \(sender)")
        let tabID = try XCTUnwrap(sender["tabId"] as? Int, "sender.tab is the tab the page is in: \(sender)")
        let tab = try await askWorker(from: loaded.page, message: ["type": "tabURL", "tabId": tabID])
        XCTAssertEqual((tab["reply"] as? [String: Any])?["url"] as? String, url("127.0.0.1"),
                       "sender.tab.id is the id chrome.tabs knows that tab by: \(tab)")

        let viaPromise = try await sendWithPromise(view, to: ext.id, ["type": "hello", "n": 2])
        XCTAssertEqual(viaPromise["settled"] as? String, "resolved", "\(viaPromise)")
        XCTAssertEqual(((viaPromise["value"] as? [String: Any])?["echo"] as? [String: Any])?["n"] as? Int, 2)

        let asyncReply = try await sendWithPromise(view, to: ext.id, ["type": "asyncReply"])
        XCTAssertEqual((asyncReply["value"] as? [String: Any])?["who"] as? String, "A",
                       "a reply sent later (listener returned true) arrives: \(asyncReply)")

        let withOptions = try await sendWithCallback(view, to: ext.id, ["type": "hello", "n": 3], options: [:])
        XCTAssertEqual(((withOptions["reply"] as? [String: Any])?["echo"] as? [String: Any])?["n"] as? Int, 3,
                       "sendMessage(id, message, options, callback): \(withOptions)")

        // A listener that answers nothing: the callback still runs.
        let noReply = try await sendWithCallback(view, to: ext.id, ["type": "noReply"])
        XCTAssertNil(noReply["timedOut"], "\(noReply)")
        XCTAssertTrue(noReply["reply"] is NSNull || noReply["reply"] == nil)

        let received = try await receivedByWorker(loaded)
        XCTAssertEqual(received.count, 5, "every message was delivered exactly once: \(received)")
    }

    /// POSITIVE, the second receiver: a listener in an open extension *page*
    /// (not the worker) is reached the same way.
    func testListedPageReachesOnMessageExternalInAnExtensionPage() async throws {
        let (profile, space) = makeProfile("page-listener")
        let ext = try await makeExtension(name: "P", connectable: ["http://127.0.0.1/*"], listener: .page)
        let loaded = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)

        let viaCallback = try await sendWithCallback(view, to: ext.id, ["type": "hello", "n": 7])
        let reply = try XCTUnwrap(viaCallback["reply"] as? [String: Any], "the page's reply: \(viaCallback)")
        XCTAssertEqual(reply["who"] as? String, "P-page")
        XCTAssertEqual((reply["sender"] as? [String: Any])?["origin"] as? String, "http://127.0.0.1:\(port)")
        let viaPromise = try await sendWithPromise(view, to: ext.id, ["type": "hello", "n": 8])
        XCTAssertEqual((viaPromise["value"] as? [String: Any])?["who"] as? String, "P-page", "\(viaPromise)")

        let count = try await loaded.page.callAsyncJavaScript("return window.__received.length;", contentWorld: .page)
        XCTAssertEqual(count as? Int, 2, "both messages reached the listener in the extension page")
    }

    /// POSITIVE: `chrome.runtime.connect(id, { name })` opens a port to
    /// `runtime.onConnectExternal`, messages go both ways, and a disconnect by
    /// the extension is reported without an error.
    func testListedPageConnectsToOnConnectExternal() async throws {
        let (profile, space) = makeProfile("connect")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        let loaded = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)

        let outcome = try await connect(view, to: ext.id, name: "claude-port", post: ["hi": 1])
        XCTAssertEqual(outcome["name"] as? String, "claude-port")
        XCTAssertEqual(outcome["shape"] as? String, "function,function,function,function", "\(outcome)")
        let events = try XCTUnwrap(outcome["events"] as? [Any])
        let message = try XCTUnwrap((events.first as? [String: Any])?["message"] as? [String: Any],
                                    "the extension's answer on the port: \(outcome)")
        XCTAssertEqual(message["who"] as? String, "A")
        XCTAssertEqual(message["name"] as? String, "claude-port")
        XCTAssertEqual((message["echo"] as? [String: Any])?["hi"] as? Int, 1)
        let sender = try XCTUnwrap(message["sender"] as? [String: Any])
        XCTAssertEqual(sender["origin"] as? String, "http://127.0.0.1:\(port)")
        XCTAssertNotNil(sender["tabId"] as? Int, "port.sender.tab is the page's tab: \(sender)")

        // The extension hangs up: onDisconnect, no error.
        let hungUp = try await evaluate(view, """
            return await new Promise((resolve) => {
                const timer = setTimeout(() => resolve(JSON.stringify({ timedOut: true })), 5000);
                window.__port.onDisconnect.addListener(() => {
                    clearTimeout(timer);
                    resolve(JSON.stringify({ disconnected: true,
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null }));
                });
                window.__port.postMessage({ type: 'hangUp' });
            });
            """)
        XCTAssertEqual(hungUp["disconnected"] as? Bool, true, "\(hungUp)")
        XCTAssertTrue(hungUp["lastError"] is NSNull, "an ordinary disconnect sets no lastError: \(hungUp)")

        let received = try await receivedByWorker(loaded)
        XCTAssertEqual(received.filter { $0["kind"] as? String == "connect" }.count, 1)
    }

    /// POSITIVE: a listed page in a *frame* gets `chrome.runtime` too, even
    /// under a top page that is not listed, and the extension sees the frame as
    /// the sender. (The top page gets nothing.)
    func testListedFrameUnderAnUnlistedPageReachesTheExtension() async throws {
        let (profile, space) = makeProfile("frame")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        _ = try await load(ext, in: profile)
        let view = try await openTab(url("localhost", "/frame-host"), in: space)

        let top = try await globals(view)
        XCTAssertEqual(top["chrome"] as? String, "undefined", "the unlisted top page gets nothing: \(top)")
        let fromFrame = try await evaluate(view, """
            document.querySelector('iframe').contentWindow.postMessage('id=' + id, '*');
            return await Promise.race([window.__fromFrame,
                new Promise((resolve) => setTimeout(() => resolve(JSON.stringify({ timedOut: true })), 8000))]);
            """, ["id": ext.id])
        XCTAssertEqual(fromFrame["runtime"] as? String, "object", "the listed frame gets chrome.runtime: \(fromFrame)")
        let reply = try XCTUnwrap(fromFrame["reply"] as? [String: Any], "\(fromFrame)")
        let sender = try XCTUnwrap(reply["sender"] as? [String: Any])
        XCTAssertEqual(sender["url"] as? String, url("127.0.0.1", "/frame-child"))
        XCTAssertEqual(sender["origin"] as? String, "http://127.0.0.1:\(port)")
        XCTAssertNotEqual(sender["frameId"] as? Int, 0, "the sender is the frame, not the top page: \(sender)")
    }

    // MARK: - 2. A page no enabled extension lists gets nothing

    /// NEGATIVE: with an extension that lists another site, with one that lists
    /// nothing, and with no extension at all, a page gets no `chrome` from
    /// Detour — while WebKit's own `browser.runtime` is there regardless.
    func testPageNoEnabledExtensionListsGetsNoChromeRuntime() async throws {
        let (profile, space) = makeProfile("unlisted")
        let before = try await openTab(url("127.0.0.1", "/other"), in: space)
        let nothingLoaded = try await globals(before)
        XCTAssertEqual(nothingLoaded["chrome"] as? String, "undefined", "no extension: \(nothingLoaded)")

        let listsLoopback = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        let listsNothing = try await makeExtension(name: "C", connectable: nil)
        _ = try await load(listsLoopback, in: profile)
        _ = try await load(listsNothing, in: profile)

        let unlisted = try await openTab(url("localhost"), in: space)
        let seen = try await globals(unlisted)
        XCTAssertEqual(seen["chrome"] as? String, "undefined",
                       "a page on a host no enabled extension lists gets no chrome: \(seen)")
        XCTAssertEqual(seen["browserRuntime"] as? String, "object",
                       "canary: WebKit's browser.runtime is on every page, listed or not")

        // The same profile, a listed host: there it is.
        let listed = try await openTab(url("127.0.0.1"), in: space)
        let listedSeen = try await globals(listed)
        XCTAssertEqual(listedSeen["sendMessage"] as? String, "function", "\(listedSeen)")

        // And a profile with only the extension that lists nothing.
        let (otherProfile, otherSpace) = makeProfile("unlisted-2")
        _ = try await load(try await makeExtension(name: "C2", connectable: nil), in: otherProfile)
        let inOther = try await openTab(url("127.0.0.1"), in: otherSpace)
        let otherSeen = try await globals(inOther)
        XCTAssertEqual(otherSeen["chrome"] as? String, "undefined",
                       "an extension without externally_connectable exposes nothing: \(otherSeen)")
    }

    /// NEGATIVE: a path pattern is honoured — the same host, another path, no
    /// `chrome.runtime`.
    func testPathOfThePatternIsHonoured() async throws {
        let (profile, space) = makeProfile("path")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/page*"])
        _ = try await load(ext, in: profile)
        let listed = try await globals(try await openTab(url("127.0.0.1", "/page"), in: space))
        XCTAssertEqual(listed["sendMessage"] as? String, "function", "\(listed)")
        let unlisted = try await globals(try await openTab(url("127.0.0.1", "/other"), in: space))
        XCTAssertEqual(unlisted["chrome"] as? String, "undefined", "\(unlisted)")
    }

    /// The documented limit of matching once per document: after a
    /// same-document navigation to a path the pattern does not cover, the page
    /// still has `chrome.runtime`, and WebKit — which matches the frame's URL
    /// for every message — delivers nothing and reports nothing.
    func testSameDocumentNavigationOffThePatternIsRefusedByWebKit() async throws {
        let (profile, space) = makeProfile("pushstate")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/page*"])
        let loaded = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1", "/page"), in: space)
        let before = try await sendWithPromise(view, to: ext.id, ["type": "hello", "n": 1])
        XCTAssertEqual((before["value"] as? [String: Any])?["who"] as? String, "A", "precondition: \(before)")

        _ = try await view.callAsyncJavaScript("history.pushState({}, '', '/other'); return location.pathname;",
                                               contentWorld: .page)
        let after = try await sendWithCallback(view, to: ext.id, ["type": "hello", "n": 2])
        XCTAssertNil(after["timedOut"], "\(after)")
        XCTAssertTrue(after["reply"] is NSNull || after["reply"] == nil,
                      "WebKit must not deliver from a URL the extension does not list: \(after)")
        let received = try await receivedByWorker(loaded)
        XCTAssertEqual(received.count, 1, "only the message sent from the listed URL arrived: \(received)")
    }

    // MARK: - 3. An id the page may not reach fails as in Chrome

    /// NEGATIVE: an id that is not installed fails with Chrome's error —
    /// `runtime.lastError` in the callback, a rejection from the promise, an
    /// `onDisconnect` with `lastError` for `connect` — and reaches no extension.
    func testMessageToAnIDThatIsNotInstalledFailsLikeChrome() async throws {
        let (profile, space) = makeProfile("unknown-id")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        let loaded = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)
        let unknown = chromeStyleID()

        try await assertFailsLikeChrome(view, to: unknown, "an id that is not installed")

        let port = try await connect(view, to: unknown)
        let events = try XCTUnwrap(port["events"] as? [Any])
        let disconnect = try XCTUnwrap(events.first as? [String: Any], "the port must disconnect: \(port)")
        XCTAssertEqual(disconnect["disconnect"] as? Bool, true)
        XCTAssertEqual(disconnect["lastError"] as? String, Self.noReceiver)
        XCTAssertEqual(disconnect["samePort"] as? Bool, true)
        XCTAssertNil(port["lastErrorAfter"] as? String)
        XCTAssertNil(port["postThrew"], "posting before the disconnect is reported does not throw: \(port)")

        let received = try await receivedByWorker(loaded)
        XCTAssertTrue(received.isEmpty, "nothing may reach the installed extension: \(received)")
    }

    /// NEGATIVE: an installed, enabled extension that does not list this page
    /// (it lists another host, or nothing) is not reachable from it, and gets
    /// nothing.
    func testMessageToAnExtensionThatDoesNotListThePageFailsLikeChrome() async throws {
        let (profile, space) = makeProfile("not-listed")
        let listsLoopback = try await load(try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"]), in: profile)
        let listsLocalhost = try await load(try await makeExtension(name: "B", connectable: ["http://localhost/*"]), in: profile)
        let listsNothing = try await load(try await makeExtension(name: "C", connectable: nil), in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)

        try await assertFailsLikeChrome(view, to: listsLocalhost.ext.id, "an extension that lists another host")
        try await assertFailsLikeChrome(view, to: listsNothing.ext.id, "an extension without externally_connectable")

        // Positive control in the same page, so the failures above are about
        // the target and not the page.
        let ok = try await sendWithPromise(view, to: listsLoopback.ext.id, ["type": "hello"])
        XCTAssertEqual((ok["value"] as? [String: Any])?["who"] as? String, "A", "\(ok)")

        let toLocalhost = try await receivedByWorker(listsLocalhost)
        XCTAssertTrue(toLocalhost.isEmpty, "\(toLocalhost)")
        let toNothing = try await receivedByWorker(listsNothing)
        XCTAssertTrue(toNothing.isEmpty, "\(toNothing)")
        let toLoopback = try await receivedByWorker(listsLoopback)
        XCTAssertEqual(toLoopback.count, 1, "only the message addressed to it: \(toLoopback)")
    }

    /// NEGATIVE, isolation across profiles: an extension enabled in one profile
    /// is not reachable from a listed page in another — neither where another
    /// extension lists that page (Chrome's error) nor where none does (no
    /// `chrome.runtime` at all).
    func testExtensionNotEnabledInThePagesProfileIsNotReachable() async throws {
        let (homeProfile, homeSpace) = makeProfile("home")
        let (otherProfile, otherSpace) = makeProfile("other")
        let (emptyProfile, emptySpace) = makeProfile("empty")
        _ = emptyProfile
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        let home = try await load(ext, in: homeProfile)
        let neighbour = try await load(try await makeExtension(name: "N", connectable: ["http://127.0.0.1/*"]), in: otherProfile)

        let inOther = try await openTab(url("127.0.0.1"), in: otherSpace)
        try await assertFailsLikeChrome(inOther, to: ext.id, "an extension that is not enabled in this profile")
        let toNeighbour = try await sendWithPromise(inOther, to: neighbour.ext.id, ["type": "hello"])
        XCTAssertEqual((toNeighbour["value"] as? [String: Any])?["who"] as? String, "N",
                       "positive control: the profile's own extension answers: \(toNeighbour)")

        let inEmpty = try await openTab(url("127.0.0.1"), in: emptySpace)
        let seen = try await globals(inEmpty)
        XCTAssertEqual(seen["chrome"] as? String, "undefined", "a profile without the extension: \(seen)")

        // Positive control: in its own profile it answers.
        let inHome = try await openTab(url("127.0.0.1"), in: homeSpace)
        let ok = try await sendWithPromise(inHome, to: ext.id, ["type": "hello"])
        XCTAssertEqual((ok["value"] as? [String: Any])?["who"] as? String, "A", "\(ok)")

        let atHome = try await receivedByWorker(home)
        XCTAssertEqual(atHome.count, 1, "only its own profile's page reached it: \(atHome)")
        let atNeighbour = try await receivedByWorker(neighbour)
        XCTAssertEqual(atNeighbour.count, 1, "the other profile's extension got only its own message: \(atNeighbour)")
    }

    /// NEGATIVE: disabling the extension in the profile (its context unloads)
    /// stops it being reachable — from a page that was already open, which
    /// keeps its `chrome.runtime` and gets Chrome's error, and from a page
    /// loaded afterwards, which gets no `chrome.runtime`. Enabling it again
    /// makes both work again.
    func testDisablingTheExtensionMakesItUnreachableAndEnablingBringsItBack() async throws {
        let (profile, space) = makeProfile("disable")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        _ = try await load(ext, in: profile)
        // Two marker scripts on the tab's controller, one per kind of world,
        // added before the page loads.
        let blank = TabStore.shared.addTab(in: space, url: URL(string: url("127.0.0.1", "/other"))!)
        let open = try XCTUnwrap(blank.webView)
        let controller = open.configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: "window.__detourTestPageWorld = true; document.documentElement.dataset.detourTestPage = 'page world';",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(
            source: "window.__detourTestIsolatedWorld = true; document.documentElement.dataset.detourTestIsolated = 'isolated world';",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: WKContentWorld.world(name: "DetourECTest")))
        open.load(URLRequest(url: URL(string: url("127.0.0.1"))!))
        try await waitUntil("the tab to load /page", timeout: 30, pollInterval: 0.25) {
            !open.isLoading && open.url?.path == "/page"
        }
        let ok = try await sendWithPromise(open, to: ext.id, ["type": "hello"])
        XCTAssertEqual((ok["value"] as? [String: Any])?["who"] as? String, "A", "precondition: \(ok)")

        // Off for this profile, the way Settings does it.
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: false)
        XCTAssertNil(profile.extensionContext(for: ext.id), "precondition: the context is unloaded")

        try await assertFailsLikeChrome(open, to: ext.id, "a page that was open when the extension was disabled")
        let after = try await openTab(url("127.0.0.1", "/other"), in: space)
        let seen = try await globals(after)
        XCTAssertEqual(seen["chrome"] as? String, "undefined",
                       "a page loaded after the extension was disabled gets no chrome: \(seen)")

        // On again: the new context is told about the profile's open tabs.
        ExtensionManager.shared.setEnabled(id: ext.id, profileID: profile.id, enabled: true)
        XCTAssertNotNil(profile.extensionContext(for: ext.id), "precondition: the context is loaded again")
        let again = try await load(ext, in: profile)
        let reopened = try await openTab(url("127.0.0.1"), in: space)
        let back = try await sendWithPromise(reopened, to: ext.id, ["type": "hello", "n": 2])
        XCTAssertEqual((back["value"] as? [String: Any])?["who"] as? String, "A", "a new page reaches it again: \(back)")
        let stale = try await sendWithPromise(open, to: ext.id, ["type": "hello", "n": 3])
        XCTAssertEqual((stale["value"] as? [String: Any])?["who"] as? String, "A",
                       "and so does the page that stayed open: \(stale)")
        let received = try await receivedByWorker(again)
        XCTAssertEqual(received.count, 2, "\(received)")

        // Replacing the script twice must have left the tab's other user
        // scripts working, each in its own content world.
        let markerBefore = try await pageWorldMarker(open)
        XCTAssertEqual(markerBefore, "page world", "precondition: the marker scripts ran before the replacements")
        open.load(URLRequest(url: URL(string: url("127.0.0.1", "/other"))!))
        try await waitUntil("the open tab to load /other", timeout: 30, pollInterval: 0.25) {
            !open.isLoading && open.url?.path == "/other"
        }
        let markers = try await evaluate(open, """
            return JSON.stringify({ page: document.documentElement.dataset.detourTestPage || null,
                                    isolated: document.documentElement.dataset.detourTestIsolated || null,
                                    pageGlobal: typeof window.__detourTestPageWorld,
                                    isolatedGlobal: typeof window.__detourTestIsolatedWorld,
                                    send: typeof chrome.runtime.sendMessage });
            """)
        XCTAssertEqual(markers["page"] as? String, "page world", "a page-world script still runs: \(markers)")
        XCTAssertEqual(markers["isolated"] as? String, "isolated world", "a script in another world still runs: \(markers)")
        XCTAssertEqual(markers["pageGlobal"] as? String, "boolean")
        XCTAssertEqual(markers["isolatedGlobal"] as? String, "undefined", "…and is still in its own world: \(markers)")
        XCTAssertEqual(markers["send"] as? String, "function")
        XCTAssertTrue(open.configuration.userContentController.userScripts.contains { $0.source == FaviconLinkBridge.userScriptSource },
                      "Detour's own content-world scripts are still installed")
    }

    private func pageWorldMarker(_ view: WKWebView) async throws -> String? {
        try await view.callAsyncJavaScript("return document.documentElement.dataset.detourTestPage || null;",
                                           contentWorld: .page) as? String
    }

    /// The argument forms Chrome refuses from a web page: no extension id.
    func testSendMessageAndConnectWithoutAnExtensionIDThrow() async throws {
        let (profile, space) = makeProfile("arguments")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        let loaded = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)
        let outcome = try await evaluate(view, """
            const attempt = (run) => { try { run(); return 'no throw'; } catch (e) { return (e instanceof TypeError ? 'TypeError: ' : 'Error: ') + e.message; } };
            return JSON.stringify({
                messageOnly: attempt(() => chrome.runtime.sendMessage({ type: 'hello' })),
                messageAndCallback: attempt(() => chrome.runtime.sendMessage({ type: 'hello' }, () => {})),
                noArguments: attempt(() => chrome.runtime.sendMessage()),
                connectNoArguments: attempt(() => chrome.runtime.connect()),
                connectInfoOnly: attempt(() => chrome.runtime.connect({ name: 'x' }))
            });
            """)
        for (form, result) in outcome {
            let text = try XCTUnwrap(result as? String)
            XCTAssertTrue(text.hasPrefix("TypeError: "), "\(form) must throw a TypeError, got \(text)")
            XCTAssertTrue(text.contains("called from a webpage must specify an Extension ID (string) for its first argument"),
                          "\(form): \(text)")
        }
        let received = try await receivedByWorker(loaded)
        XCTAssertTrue(received.isEmpty, "a refused call sends nothing: \(received)")
    }

    // MARK: - 4. The page's own window.chrome

    /// A page that defines `window.chrome` itself keeps exactly what it
    /// defined: an assignment replaces Detour's object, an extension of it
    /// keeps both, and a lexical `let chrome` is not a redeclaration error.
    func testPagesOwnChromeIsNotClobbered() async throws {
        let (profile, space) = makeProfile("own-chrome")
        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        _ = try await load(ext, in: profile)

        let replaced = try await openTab(url("127.0.0.1", "/own-chrome-replace"), in: space)
        let afterReplace = try await evaluate(replaced, """
            return JSON.stringify({ before: window.__before, beforeRuntime: window.__beforeRuntime,
                mine: chrome.mine, loadTimes: chrome.loadTimes(), runtime: typeof chrome.runtime,
                keys: Object.keys(chrome).sort() });
            """)
        XCTAssertEqual(afterReplace["before"] as? String, "object", "Detour's chrome was there before the page ran")
        XCTAssertEqual(afterReplace["beforeRuntime"] as? String, "object")
        XCTAssertEqual(afterReplace["mine"] as? Int, 1, "the page's own object is what window.chrome is: \(afterReplace)")
        XCTAssertEqual(afterReplace["loadTimes"] as? String, "page")
        XCTAssertEqual(afterReplace["keys"] as? [String], ["loadTimes", "mine"],
                       "Detour does not put runtime back on an object the page assigned: \(afterReplace)")

        let extended = try await openTab(url("127.0.0.1", "/own-chrome-extend"), in: space)
        let afterExtend = try await evaluate(extended, """
            return JSON.stringify({ mine: chrome.mine, send: typeof chrome.runtime.sendMessage });
            """)
        XCTAssertEqual(afterExtend["mine"] as? Int, 2, "\(afterExtend)")
        XCTAssertEqual(afterExtend["send"] as? String, "function", "the page's additions and runtime coexist")
        let ok = try await sendWithPromise(extended, to: ext.id, ["type": "hello"])
        XCTAssertEqual((ok["value"] as? [String: Any])?["who"] as? String, "A", "\(ok)")

        let lexical = try await openTab(url("127.0.0.1", "/own-chrome-let"), in: space)
        let afterLet = try await evaluate(lexical, """
            return JSON.stringify({ lexical: window.__lexical === undefined ? null : window.__lexical,
                                    seen: window.__lexicalSeen === undefined ? null : window.__lexicalSeen });
            """)
        XCTAssertEqual(afterLet["lexical"] as? Int, 3, "`let chrome` in a page script must still work: \(afterLet)")
        XCTAssertEqual(afterLet["seen"] as? String, "number")
    }

    // MARK: - Other extensions' content scripts survive the script replacement

    /// An extension with no `externally_connectable` at all, whose content
    /// scripts are what must keep working: one declared in the manifest and
    /// one the worker registers with `scripting.registerContentScripts`. Each
    /// marks the document and relays a page `postMessage` to the worker.
    private func makeContentScriptExtension() async throws -> WebExtension {
        let id = chromeStyleID()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let manifestObject: [String: Any] = [
            "manifest_version": 3, "name": "CS", "version": "1.0.0",
            "permissions": ["tabs", "scripting"], "host_permissions": ["<all_urls>"],
            "background": ["service_worker": "background.js"],
            "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_end"]],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        try "<html><body>test page<script src=\"page.js\"></script></body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        func contentScript(_ which: String) -> String {
            """
            document.documentElement.setAttribute('data-cs-\(which)',
                String(Number(document.documentElement.getAttribute('data-cs-\(which)') || 0) + 1));
            window.addEventListener('message', (event) => {
                const data = event.data;
                if (!data || data.__csTest !== 'ask-\(which)') return;
                chrome.runtime.sendMessage({ type: 'fromContentScript', which: '\(which)', n: data.n }, (reply) => {
                    window.postMessage({ __csTest: 'answer', id: data.id, reply: reply === undefined ? null : reply,
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null }, '*');
                });
            });
            """
        }
        try contentScript("manifest").write(to: dir.appendingPathComponent("content.js"), atomically: true, encoding: .utf8)
        try contentScript("registered").write(to: dir.appendingPathComponent("registered.js"), atomically: true, encoding: .utf8)
        try (ExtensionAPIPolyfill.polyfillJS + """


        const registered = chrome.scripting.registerContentScripts([
            { id: 'registered', matches: ['http://127.0.0.1/*'], js: ['registered.js'], runAt: 'document_end' }
        ]).then(() => 'registered', (e) => 'failed: ' + String(e && e.message ? e.message : e));
        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (message && message.type === 'fromContentScript') {
                sendResponse({ who: 'CS', which: message.which, n: message.n,
                               tabId: sender.tab ? sender.tab.id : null, url: sender.url });
                return false;
            }
            if (message && message.type === 'received') {
                registered.then((state) => sendResponse({ who: 'CS', received: [], registered: state }));
                return true;
            }
            return false;
        });
        """).write(to: dir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        installTestExtension(ext, in: AppDatabase.shared, manifestJSON: manifestData)
        AppDatabase.shared.recordDeclaredPermissions([
            ExtensionPermissionRecord(extensionID: id, key: "tabs", type: .apiPermission, status: .granted),
            ExtensionPermissionRecord(extensionID: id, key: "scripting", type: .apiPermission, status: .granted),
            ExtensionPermissionRecord(extensionID: id, key: "<all_urls>", type: .matchPattern, status: .granted),
        ])
        return ext
    }

    /// What the two content scripts did in the page `view` shows now: whether
    /// each marked the document, and what the worker answered each through it.
    private func contentScriptState(_ view: WKWebView, n: Int) async throws -> [String: Any] {
        try await evaluate(view, """
            const ask = (which) => new Promise((resolve) => {
                const id = which + ':' + Math.random();
                const onAnswer = (event) => {
                    const data = event.data;
                    if (!data || data.__csTest !== 'answer' || data.id !== id) return;
                    clearTimeout(timer); window.removeEventListener('message', onAnswer);
                    resolve(data.lastError ? 'lastError: ' + data.lastError
                        : data.reply ? data.reply.who + ':' + data.reply.which + ':' + data.reply.n + ':' + (data.reply.tabId === null ? 'no tab' : 'tab') + ':' + data.reply.url
                        : 'no reply');
                };
                const timer = setTimeout(() => { window.removeEventListener('message', onAnswer); resolve('no answer from the content script'); }, 5000);
                window.addEventListener('message', onAnswer);
                window.postMessage({ __csTest: 'ask-' + which, id: id, n: n }, '*');
            });
            const root = document.documentElement;
            return JSON.stringify({
                manifestRan: root.getAttribute('data-cs-manifest'), registeredRan: root.getAttribute('data-cs-registered'),
                manifest: await ask('manifest'), registered: await ask('registered'),
                chrome: typeof globalThis.chrome
            });
            """, ["n": n])
    }

    private func assertContentScriptsWork(_ view: WKWebView, n: Int, _ when: String,
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        // A content script at document_end may land a moment after the load ends.
        try await waitUntil("the content scripts to mark the page \(when)", timeout: 10, file: file, line: line) {
            let raw = try await view.callAsyncJavaScript(
                "return document.documentElement.getAttribute('data-cs-manifest') !== null && document.documentElement.getAttribute('data-cs-registered') !== null;",
                contentWorld: .page)
            return raw as? Bool == true
        }
        let state = try await contentScriptState(view, n: n)
        let pageURL = view.url?.absoluteString ?? "?"
        XCTAssertEqual(state["manifestRan"] as? String, "1",
                       "\(when): the manifest content script must run, and run once: \(state)", file: file, line: line)
        XCTAssertEqual(state["registeredRan"] as? String, "1",
                       "\(when): the registered content script must run, and run once: \(state)", file: file, line: line)
        XCTAssertEqual(duplicatedScripts(view), [:], "\(when): no script may be on the controller twice", file: file, line: line)
        XCTAssertEqual(state["manifest"] as? String, "CS:manifest:\(n):tab:\(pageURL)",
                       "\(when): the manifest content script must still reach its worker: \(state)", file: file, line: line)
        XCTAssertEqual(state["registered"] as? String, "CS:registered:\(n):tab:\(pageURL)",
                       "\(when): the registered content script must still reach its worker: \(state)", file: file, line: line)
    }

    private func navigate(_ view: WKWebView, to target: String) async throws {
        view.load(URLRequest(url: URL(string: target)!))
        try await waitUntil("the tab to load \(target)", timeout: 30, pollInterval: 0.25) {
            !view.isLoading && view.url?.absoluteString == target
        }
    }

    private func reload(_ view: WKWebView) async throws {
        let marker = "reload-\(UUID().uuidString)"
        _ = try await view.callAsyncJavaScript("window.__beforeReload = marker; return true;", arguments: ["marker": marker], contentWorld: .page)
        view.reload()
        try await waitUntil("the tab to reload", timeout: 30, pollInterval: 0.25) {
            guard !view.isLoading else { return false }
            let raw = try? await view.callAsyncJavaScript("return window.__beforeReload === undefined;", contentWorld: .page)
            return raw as? Bool == true
        }
    }

    /// The scripts that are on `view`'s content controller more than once
    /// (the same script object, or the same source), by the start of their
    /// source, with how often.
    private func duplicatedScripts(_ view: WKWebView) -> [String: Int] {
        var counts: [String: Int] = [:]
        for script in view.configuration.userContentController.userScripts {
            counts[script.source, default: 0] += 1
        }
        return Dictionary(counts.filter { $0.value > 1 }.map { (String($0.key.prefix(60)), $0.value) },
                          uniquingKeysWith: +)
    }

    private func shimCount(_ view: WKWebView) -> Int {
        view.configuration.userContentController.userScripts
            .filter { $0.source.hasPrefix(ExternallyConnectable.scriptMarker) }.count
    }

    /// GUARD for how the shim is replaced on a live tab: WebKit keeps the
    /// content scripts of *every* extension on the same content controller
    /// Detour's script lives on, and `removeAllUserScripts()` empties that
    /// controller. Loading, unloading, enabling and disabling an extension
    /// that lists a page must leave another extension's content scripts — one
    /// from its manifest, one registered with `scripting.registerContentScripts`
    /// — running in that tab's later documents and still talking to their
    /// worker. If this fails, every extension's content scripts die in open
    /// tabs whenever any listing extension is toggled.
    func testOtherExtensionsContentScriptsSurviveTheScriptReplacement() async throws {
        let (profile, space) = makeProfile("content-scripts")
        let contentScripts = try await makeContentScriptExtension()
        let loadedCS = try await load(contentScripts, in: profile)
        let state = try await askWorker(from: loadedCS.page, message: ["type": "received"], timeout: 10)
        XCTAssertEqual((state["reply"] as? [String: Any])?["registered"] as? String, "registered",
                       "precondition: scripting.registerContentScripts succeeded: \(state)")

        let view = try await openTab(url("127.0.0.1"), in: space)
        try await assertContentScriptsWork(view, n: 1, "before anything is replaced")
        XCTAssertEqual(shimCount(view), 0, "precondition: no listing extension, no shim")
        let scriptsBefore = view.configuration.userContentController.userScripts.count

        // 1. A listing extension loads: the shim is added.
        let listing = try await makeExtension(name: "B", connectable: ["http://127.0.0.1/*"])
        _ = try await load(listing, in: profile)
        XCTAssertEqual(shimCount(view), 1)
        try await reload(view)
        try await assertContentScriptsWork(view, n: 2, "after a listing extension loaded")
        let withShim = try await globals(view)
        XCTAssertEqual(withShim["sendMessage"] as? String, "function", "and the listed page has chrome.runtime: \(withShim)")

        // 2. A second listing extension loads: the shim is REPLACED — the
        //    controller is emptied and refilled.
        let second = try await makeExtension(name: "C", connectable: ["http://localhost/*"])
        _ = try await load(second, in: profile)
        XCTAssertEqual(shimCount(view), 1)
        XCTAssertTrue(view.configuration.userContentController.userScripts.last?.source.contains(second.id) == true,
                      "precondition: the script on the tab was replaced with one that knows the new extension")
        try await reload(view)
        try await assertContentScriptsWork(view, n: 3, "after the shim was replaced")
        try await navigate(view, to: url("127.0.0.1", "/other"))
        try await assertContentScriptsWork(view, n: 4, "on a second page after the shim was replaced")

        // 3. Both unload: replaced again, then removed.
        profile.unloadExtension(id: second.id)
        profile.unloadExtension(id: listing.id)
        XCTAssertEqual(shimCount(view), 0)
        try await reload(view)
        try await assertContentScriptsWork(view, n: 5, "after the listing extensions unloaded")
        try await navigate(view, to: url("127.0.0.1"))
        try await assertContentScriptsWork(view, n: 6, "on a second page after the listing extensions unloaded")
        XCTAssertEqual(view.configuration.userContentController.userScripts.count, scriptsBefore,
                       "the controller holds exactly the scripts it held before any listing extension loaded")

        // 4. The Settings path: enable, then disable, in this profile.
        ExtensionManager.shared.setEnabled(id: listing.id, profileID: profile.id, enabled: true)
        XCTAssertNotNil(profile.extensionContext(for: listing.id), "precondition: enabled")
        XCTAssertEqual(shimCount(view), 1)
        try await reload(view)
        try await assertContentScriptsWork(view, n: 7, "after the listing extension was enabled")
        ExtensionManager.shared.setEnabled(id: listing.id, profileID: profile.id, enabled: false)
        XCTAssertNil(profile.extensionContext(for: listing.id), "precondition: disabled")
        XCTAssertEqual(shimCount(view), 0)
        try await assertContentScriptsWork(view, n: 8, "in the document that was open across the disable")
        try await reload(view)
        try await assertContentScriptsWork(view, n: 9, "after the listing extension was disabled")
        try await navigate(view, to: url("127.0.0.1", "/other"))
        try await assertContentScriptsWork(view, n: 10, "on a second page after the listing extension was disabled")
        let finalGlobals = try await globals(view)
        XCTAssertEqual(finalGlobals["chrome"] as? String, "undefined", "and no chrome is left behind: \(finalGlobals)")
    }

    // MARK: - Private

    /// The Private profile follows the same rule: a context loaded there (the
    /// user allowed the extension in Private) is reachable from a listed page
    /// in a Private tab; without it the page gets nothing.
    func testPrivateTabReachesAnExtensionLoadedInPrivateOnly() async throws {
        let space = TabStore.shared.addIncognitoSpace()
        incognitoSpaceIDs.append(space.id)
        let profile = try XCTUnwrap(space.profile)
        XCTAssertTrue(profile.isIncognito)
        _ = profile.extensionController

        let ext = try await makeExtension(name: "A", connectable: ["http://127.0.0.1/*"])
        let before = try await globals(try await openTab(url("127.0.0.1", "/other"), in: space))
        XCTAssertEqual(before["chrome"] as? String, "undefined",
                       "an extension that is not loaded in Private exposes nothing there: \(before)")

        loadedInPrivate.append(ext.id)
        _ = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)
        let ok = try await sendWithCallback(view, to: ext.id, ["type": "hello"])
        let reply = try XCTUnwrap(ok["reply"] as? [String: Any], "\(ok)")
        XCTAssertEqual(reply["who"] as? String, "A")
        XCTAssertEqual((reply["sender"] as? [String: Any])?["origin"] as? String, "http://127.0.0.1:\(port)")
    }

    // MARK: - Canaries: the WebKit behaviour the shim rests on

    /// WebKit's own `browser.runtime.sendMessage` answers an id it will not
    /// deliver to — unknown, not listing the page, not loaded — with
    /// `undefined` and no error. If this starts failing loudly by itself, the
    /// shim's own check may no longer be needed.
    func testCanaryWebKitAnswersARefusedMessageWithUndefined() async throws {
        let (profile, space) = makeProfile("canary")
        let listsLocalhost = try await load(try await makeExtension(name: "B", connectable: ["http://localhost/*"]), in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)
        for (what, id) in [("an extension that lists another host", listsLocalhost.ext.id), ("an unknown id", chromeStyleID())] {
            let outcome = try await evaluate(view, """
                try {
                    const value = await browser.runtime.sendMessage(id, { type: 'hello' });
                    return JSON.stringify({ settled: 'resolved', undefined: value === undefined });
                } catch (e) { return JSON.stringify({ settled: 'rejected', message: String(e && e.message ? e.message : e) }); }
                """, ["id": id])
            XCTAssertEqual(outcome["settled"] as? String, "resolved", "WebKit changed: \(what) now fails by itself: \(outcome)")
            XCTAssertEqual(outcome["undefined"] as? Bool, true, "\(what): \(outcome)")
        }
        let received = try await receivedByWorker(listsLocalhost)
        XCTAssertTrue(received.isEmpty, "WebKit must not deliver a message from a page the extension does not list")
    }

    /// A listed, loaded extension with no `onMessageExternal` /
    /// `onConnectExternal` listener: WebKit answers the message with nothing
    /// (Chrome reports "Receiving end does not exist"), and reports the port
    /// it could not connect as `port.error`, which the shim turns into
    /// `runtime.lastError` in `onDisconnect`.
    func testCanaryListedExtensionWithoutAListener() async throws {
        let (profile, space) = makeProfile("no-listener")
        let ext = try await makeExtension(name: "Q", connectable: ["http://127.0.0.1/*"], listener: .none)
        _ = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)

        let message = try await sendWithCallback(view, to: ext.id, ["type": "hello"])
        XCTAssertNil(message["timedOut"], "\(message)")
        XCTAssertTrue(message["reply"] is NSNull || message["reply"] == nil, "\(message)")
        XCTAssertNil(message["lastError"] as? String,
                     "WebKit changed: a message nobody listens for now fails by itself: \(message)")

        let port = try await connect(view, to: ext.id)
        let events = try XCTUnwrap(port["events"] as? [Any])
        let disconnect = try XCTUnwrap(events.first as? [String: Any], "the port must disconnect: \(port)")
        XCTAssertEqual(disconnect["disconnect"] as? Bool, true, "\(port)")
        XCTAssertEqual(disconnect["lastError"] as? String, Self.noReceiver, "\(port)")
        XCTAssertNil(port["lastErrorAfter"] as? String)
    }

    /// WebKit only delivers when the extension also has host access to the
    /// page — Chrome does not ask for that. An extension that lists a page it
    /// has no access to is therefore *not* reachable in Detour: the page gets
    /// `chrome.runtime`, and the message is answered with nothing (no reply, no
    /// `lastError`). If this test fails because the reply arrives, WebKit
    /// dropped the requirement and the limit can come out of the docs.
    func testCanaryWebKitNeedsHostAccessToThePage() async throws {
        let (profile, space) = makeProfile("no-access")
        let ext = try await makeExtension(name: "D", connectable: ["http://127.0.0.1/*"], hostPermissions: [])
        let loaded = try await load(ext, in: profile)
        let view = try await openTab(url("127.0.0.1"), in: space)
        let seen = try await globals(view)
        XCTAssertEqual(seen["sendMessage"] as? String, "function", "\(seen)")
        let outcome = try await sendWithCallback(view, to: ext.id, ["type": "hello"])
        XCTAssertNil(outcome["timedOut"], "\(outcome)")
        XCTAssertTrue(outcome["reply"] is NSNull || outcome["reply"] == nil,
                      "WebKit changed: an extension without host access now receives the message: \(outcome)")
        let received = try await receivedByWorker(loaded)
        XCTAssertTrue(received.isEmpty, "\(received)")
    }
}
