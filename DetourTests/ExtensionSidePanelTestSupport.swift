import XCTest
import WebKit
@testable import Detour

// Shared by the `chrome.sidePanel` (TASK-132.8) and `runtime.getContexts`
// (TASK-132.9) suites: a bare web view with a recording bridge for the
// polyfill's own logic, and a real-extension world — production profiles,
// `TabStore.shared`, real `BrowserWindowController`s that are never shown — for
// everything WebKit and the windows take part in.

// MARK: - The polyfill against a recording bridge

/// Stands in for `ExtensionPolyfillHandler` behind `webkit.messageHandlers
/// .detourPolyfill`: records every request and answers from `replies`.
@MainActor
final class RecordingPolyfillBridge: NSObject, WKScriptMessageHandlerWithReply {
    struct Call {
        let type: String
        let params: [String: Any]
    }

    private(set) var calls: [Call] = []
    /// The answer per request type: a value, or an error text. A type with no
    /// entry is answered `true`.
    var replies: [String: (Call) -> (Any?, String?)] = [:]

    var types: [String] { calls.map(\.type) }

    func calls(ofType type: String) -> [Call] { calls.filter { $0.type == type } }

    func reset() { calls.removeAll() }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "bad message")
            return
        }
        // The console bridge posts through the same handler; it is not what a
        // test is counting.
        guard type != "log" else { replyHandler(true, nil); return }
        let call = Call(type: type, params: body["params"] as? [String: Any] ?? [:])
        calls.append(call)
        let (value, error) = replies[type]?(call) ?? (true, nil)
        replyHandler(value, error)
    }
}

/// A plain web view running the whole polyfill against `bridge`, with just
/// enough of an extension environment for it: `chrome.runtime.id`,
/// `getManifest()` answering `manifest`, and whatever `shim` adds — which runs
/// *before* the polyfill. `afterPolyfill` runs after it, for the fakes that
/// replace what an earlier module installed (`__detourResolveTab`).
@MainActor
func makeRecordingPolyfillWebView(bridge: RecordingPolyfillBridge, manifest: [String: Any],
                                  shim: String = "", afterPolyfill: String = "",
                                  baseURL: URL = URL(string: "https://polyfill.fixture.test/page.html")!) async throws -> WKWebView {
    let manifestJSON = String(decoding: try JSONSerialization.data(withJSONObject: manifest), as: UTF8.self)
    let configuration = WKWebViewConfiguration()
    let ucc = configuration.userContentController
    ucc.addScriptMessageHandler(bridge, contentWorld: .page, name: ExtensionPolyfillHandler.handlerName)
    let sources = [
        """
        if (!globalThis.chrome) globalThis.chrome = {};
        if (!globalThis.chrome.runtime) globalThis.chrome.runtime = {};
        globalThis.chrome.runtime.id = 'recording-fixture';
        globalThis.chrome.runtime.getManifest = () => (\(manifestJSON));
        \(shim)
        """,
        ExtensionAPIPolyfill.polyfillJS,
        afterPolyfill,
    ]
    for source in sources where !source.isEmpty {
        ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    try await loadHTMLStringAndWait(webView, html: "<html><body>fixture</body></html>", baseURL: baseURL)
    return webView
}

/// Runs an async JS function body in the page and returns its JSON-encoded
/// result, decoded.
@MainActor
func evaluateJSON(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> Any {
    let raw = try await webView.callAsyncJavaScript(
        "const __value = await (async () => { \(body) })(); return JSON.stringify(__value === undefined ? null : __value);",
        arguments: arguments, contentWorld: .page)
    let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
    return try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
}

/// `evaluateJSON` for a body that returns an object.
@MainActor
func evaluateJSONObject(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
    let value = try await evaluateJSON(body, arguments: arguments, in: webView)
    return try XCTUnwrap(value as? [String: Any], "expected an object, got \(value)", file: file, line: line)
}

// MARK: - A real extension with side panels

/// The JS every context of the fixture extension carries: one function that
/// runs what a test asks for, in the worker (through `runtime.sendMessage`) or
/// in a page (through `callAsyncJavaScript`).
enum SidePanelFixture {

    static let opJS = """
    async function __detourTestPanelOp(message) {
        const orNull = (value) => value === undefined ? null : value;
        switch (message.op) {
        case 'install':
            return {
                type: typeof chrome.sidePanel,
                install: orNull(globalThis.__detourSidePanelInstall),
                keys: chrome.sidePanel ? Object.keys(chrome.sidePanel).sort() : [],
                viaBrowser: !!(globalThis.browser && browser.sidePanel && browser.sidePanel === chrome.sidePanel),
                contextKind: orNull(globalThis.__detourContextKind),
                closeWrapped: !!(globalThis.window && window.close && window.close._detourSidePanelClose === true),
                getContextsInstall: orNull(globalThis.__detourRuntimeGetContextsInstall),
                getContextsType: typeof chrome.runtime.getContexts,
                contextType: orNull(chrome.runtime.ContextType)
            };
        case 'call': {
            // One sidePanel call, promise form.
            const value = await chrome.sidePanel[message.method].apply(chrome.sidePanel, message.args || []);
            return orNull(value);
        }
        case 'callback':
            // One sidePanel call, callback form.
            return await new Promise((resolve) => {
                const returned = chrome.sidePanel[message.method].apply(chrome.sidePanel, (message.args || []).concat([function() {
                    resolve({
                        argc: arguments.length,
                        arg0: arguments.length ? orNull(arguments[0]) : null,
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null,
                        returnedType: typeof returned
                    });
                }]));
            });
        case 'setOptionsThenOpen': {
            // As the Claude extension does it: neither call awaited.
            const first = chrome.sidePanel.setOptions(message.options);
            const second = chrome.sidePanel.open(message.target);
            const settled = await Promise.allSettled([first, second]);
            return settled.map((s) => s.status === 'fulfilled' ? 'ok' : String(s.reason && s.reason.message ? s.reason.message : s.reason));
        }
        case 'tabs': {
            // Every tab WebKit lists, with the handle the bridge gives it.
            const all = await chrome.windows.getAll({ populate: true });
            const out = [];
            for (const w of all) {
                for (const t of (w.tabs || [])) {
                    out.push({ id: t.id, windowId: w.id, active: t.active, handle: await __detourResolveTab(t.id) });
                }
            }
            return { tabs: out, windows: all.map((w) => ({ id: w.id, tabCount: (w.tabs || []).length })) };
        }
        case 'queryCount':
            return { count: (await chrome.tabs.query({})).length };
        case 'getCurrent': {
            const kind = (value) => value === undefined ? 'undefined' : (value === null ? 'null' : 'tab');
            const viaCallback = await new Promise((resolve) => chrome.tabs.getCurrent(function(tab) {
                resolve({ argc: arguments.length, kind: kind(tab), lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
            }));
            return { promise: kind(await chrome.tabs.getCurrent()), callback: viaCallback,
                     native: chrome.tabs.getCurrent._detourNative
                        ? kind(await chrome.tabs.getCurrent._detourNative.call(chrome.tabs)) : 'unwrapped' };
        }
        case 'getContexts':
            return await chrome.runtime.getContexts(message.filter === undefined ? {} : message.filter);
        case 'getContextsCallback':
            return await new Promise((resolve) => {
                chrome.runtime.getContexts(message.filter, function(contexts) {
                    resolve({
                        argc: arguments.length,
                        contexts: orNull(contexts),
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
                    });
                });
            });
        case 'events':
            return { events: (globalThis.__detourTestEvents || []).slice() };
        case 'clearEvents':
            globalThis.__detourTestEvents = [];
            return true;
        case 'ports':
            return { connected: globalThis.__detourTestPortsConnected || 0, disconnected: globalThis.__detourTestPortsDisconnected || 0 };
        }
        throw new Error('unknown op ' + message.op);
    }
    """

    /// The worker: answers ops, counts ports, and handles the toolbar action
    /// and the command the way the Claude extension's worker does.
    static let workerJS = """

    globalThis.__detourTestEvents = [];
    globalThis.__detourTestPortsConnected = 0;
    globalThis.__detourTestPortsDisconnected = 0;

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message || message.type !== 'panelOp') return false;
        __detourTestPanelOp(message.payload).then(
            (value) => sendResponse({ ok: true, value: value === undefined ? null : value }),
            (error) => sendResponse({ ok: false, error: String(error && error.message ? error.message : error) }));
        return true;
    });

    chrome.runtime.onConnect.addListener((port) => {
        globalThis.__detourTestPortsConnected += 1;
        port.onDisconnect.addListener(() => { globalThis.__detourTestPortsDisconnected += 1; });
    });

    const __detourTestPanelPath = (tabId) => 'tabpanel.html?tabId=' + encodeURIComponent(tabId);

    if (chrome.action && chrome.action.onClicked) {
        chrome.action.onClicked.addListener((tab) => {
            globalThis.__detourTestEvents.push({ event: 'action.onClicked', tabId: tab ? tab.id : null });
            if (!chrome.sidePanel || !tab) return;
            chrome.sidePanel.setOptions({ tabId: tab.id, path: __detourTestPanelPath(tab.id), enabled: true });
            chrome.sidePanel.open({ tabId: tab.id });
        });
    }

    if (chrome.commands && chrome.commands.onCommand) {
        chrome.commands.onCommand.addListener((command) => {
            globalThis.__detourTestEvents.push({ event: 'commands.onCommand', command: command });
            if (command !== 'toggle-side-panel') return;
            chrome.tabs.query({ active: true }, (tabs) => {
                const tab = tabs[0];
                if (!tab || !tab.id) return;
                (async function(tabId) {
                    if (!chrome.runtime.getContexts) {
                        // Without getContexts the shortcut can only open.
                        chrome.sidePanel.setOptions({ tabId: tabId, path: __detourTestPanelPath(tabId), enabled: true });
                        chrome.sidePanel.open({ tabId: tabId });
                        return;
                    }
                    // The Claude extension's toggle, call for call.
                    const contexts = chrome.runtime.getContexts({ contextTypes: [chrome.runtime.ContextType.SIDE_PANEL] });
                    chrome.sidePanel.setOptions({ tabId: tabId, path: __detourTestPanelPath(tabId), enabled: true });
                    const opened = chrome.sidePanel.open({ tabId: tabId }).catch(() => {});
                    if ((await contexts).some((c) => !!c.documentUrl && new URL(c.documentUrl).searchParams.get('tabId') === String(tabId))) {
                        chrome.runtime.sendMessage({ type: 'close_side_panel', tabId: tabId }).catch(() => {});
                        return;
                    }
                    await opened;
                })(tab.id);
            });
        });
    }
    """

    /// A panel page: closes itself when told to, as the Claude panel does, and
    /// keeps a port to the worker open.
    static func panelHTML(title: String) -> String {
        """
        <html><head><title>\(title)</title></head><body>
        <div id="panel">\(title)</div>
        <input id="field" type="text" autofocus>
        <script src="panel.js"></script>
        </body></html>
        """
    }

    static let panelJS = """
    globalThis.__detourTestLoadedAt = Date.now() + ':' + Math.random();
    (function() {
        const tabId = Number(new URLSearchParams(window.location.search).get('tabId'));
        chrome.runtime.onMessage.addListener((message) => {
            if (message && message.type === 'close_side_panel' && message.tabId === tabId) window.close();
        });
        try { globalThis.__detourTestPort = chrome.runtime.connect({ name: 'panel' }); } catch (e) {}
    })();
    """

    static func manifest(name: String, permissions: [String], defaultPath: String?,
                         withAction: Bool = true) -> [String: Any] {
        var manifest: [String: Any] = [
            "manifest_version": 3, "name": name, "version": "1.0.0",
            "permissions": permissions,
            "background": ["service_worker": "background.js", "type": "module"],
            "commands": [
                "toggle-side-panel": [
                    "suggested_key": ["default": "Alt+Shift+Y", "mac": "Alt+Shift+Y"],
                    "description": "Toggle the side panel",
                ],
            ],
        ]
        if withAction { manifest["action"] = ["default_title": name] }
        if let defaultPath { manifest["side_panel"] = ["default_path": defaultPath] }
        return manifest
    }
}

/// Builds the real-extension world and tears it down again.
@MainActor
final class SidePanelTestWorld {

    struct Loaded {
        let ext: WebExtension
        let profile: Profile
        let context: WKWebExtensionContext
        /// An ordinary extension page, for running ops in a page context.
        let page: WKWebView
    }

    enum Via: String, CaseIterable { case page, worker }

    struct OpFailed: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    struct WorkerSilent: Error, CustomStringConvertible {
        let envelope: [String: Any]
        var description: String { "the worker did not answer: \(envelope)" }
    }

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private(set) var windows: [BrowserWindowController] = []
    private var pages: [WKWebView] = []
    private var server: LoopbackHTTPServer?
    private(set) var serverPort: UInt16 = 0
    private var previousLastActiveSpaceID: UUID?
    private var previousExtensionLastActiveSpaceID: UUID?
    private var previousWidthDefaults: UserDefaults?
    private let widthSuiteName = "detour-sidepanel-tests-\(UUID().uuidString)"

    /// Profiles whose controller hosted a web view stay alive for the rest of
    /// the test process (the hazard `ExtensionTabResolveTests` documents).
    private static var retainedProfiles: [Profile] = []

    func setUp() async throws {
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        previousExtensionLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
        // The remembered width goes to a throwaway suite.
        previousWidthDefaults = SidePanelWidthStore.defaults
        SidePanelWidthStore.defaults = UserDefaults(suiteName: widthSuiteName) ?? .standard
        let server = try LoopbackHTTPServer(routes: Dictionary(uniqueKeysWithValues:
            ["one", "two", "three", "four"].map {
                ("/\($0)", "<html><head><title>\($0)</title></head><body><input id=\"f\">\($0)</body></html>")
            }))
        serverPort = try await server.start()
        self.server = server
    }

    func tearDown() async {
        let store = TabStore.shared
        for wc in windows { wc.window?.close() }
        windows.removeAll()
        for page in pages { page.stopLoading() }
        pages.removeAll()

        for id in createdSpaceIDs {
            guard let space = store.space(withID: id) else { continue }
            for tab in space.tabs {
                store.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
        }
        for id in createdSpaceIDs { store.forceRemoveSpace(id: id) }
        createdSpaceIDs.removeAll()
        store.undoManager.removeAllActions()
        store.saveNow()

        for profile in createdProfiles {
            profile.unloadAllExtensions()
            if !profile.isIncognito {
                AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
                store.forceRemoveProfile(id: profile.id)
            }
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()

        store.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.lastActiveSpaceID = previousExtensionLastActiveSpaceID
        if let previousWidthDefaults { SidePanelWidthStore.defaults = previousWidthDefaults }
        UserDefaults().removePersistentDomain(forName: widthSuiteName)
        server?.stop()
        server = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    // MARK: Building

    /// An MV3 extension with a module worker, an ordinary page and two panel
    /// pages. The worker carries the polyfill itself.
    func makeExtension(name: String = "Side Panel Test", permissions: [String] = ["sidePanel"],
                       defaultPath: String? = "panel.html", withAction: Bool = true) async throws -> WebExtension {
        let id = "sidepanel-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let manifest = SidePanelFixture.manifest(name: name, permissions: permissions,
                                                 defaultPath: defaultPath, withAction: withAction)
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let files: [String: String] = [
            "test.html": "<html><body><div id=\"test\">side panel test page</div></body></html>",
            "panel.html": SidePanelFixture.panelHTML(title: "default panel"),
            "tabpanel.html": SidePanelFixture.panelHTML(title: "tab panel"),
            "other.html": SidePanelFixture.panelHTML(title: "other panel"),
            "panel.js": SidePanelFixture.panelJS,
            "background.js": ExtensionAPIPolyfill.polyfillJS + "\n\n" + SidePanelFixture.opJS + SidePanelFixture.workerJS,
        ]
        for (file, contents) in files {
            try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let parsed = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: parsed, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        _ = profile.extensionController
        return profile
    }

    func makeSpace(_ name: String, in profile: Profile) -> Space {
        let space = TabStore.shared.addSpace(name: name, emoji: "P", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    /// A browser window on `space` that is never shown, so never key.
    func makeWindow(on space: Space, width: CGFloat = 1100) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        windows.append(wc)
        wc.sidebarSplitView.autosaveName = nil
        wc.window?.setFrame(NSRect(x: 60, y: 60, width: width, height: 700), display: false)
        wc.setActiveSpace(id: space.id)
        wc.window?.layoutIfNeeded()
        return wc
    }

    func track(_ window: BrowserWindowController) {
        windows.append(window)
    }

    /// Loads `ext` into `profile`, opens an ordinary page of it and starts its
    /// worker. Make the windows first: WebKit asks for the open windows when a
    /// context loads.
    func load(_ ext: WebExtension, in profile: Profile) async throws -> Loaded {
        if profile.isIncognito, !createdProfiles.contains(where: { $0 === profile }) {
            createdProfiles.append(profile)
        }
        let context = try loadTestContext(ext, in: profile)
        let configuration = try XCTUnwrap(context.webViewConfiguration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        pages.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { error in
            if let error { print("loadBackgroundContent failed: \(error)") }
        }
        let loaded = Loaded(ext: ext, profile: profile, context: context, page: page)
        try await waitUntil("the worker to answer", timeout: 30) {
            (try? await self.run(.worker, in: loaded, ["op": "install"])) != nil
        }
        return loaded
    }

    func url(_ name: String) -> URL {
        URL(string: "http://127.0.0.1:\(serverPort)/\(name)")!
    }

    /// A tab added through the store, with its page loading.
    func addTab(_ name: String, in space: Space) async throws -> BrowserTab {
        let tab = TabStore.shared.addTab(in: space, url: url(name))
        try await waitUntil("the tab to have its URL") { tab.url != nil }
        return tab
    }

    // MARK: Running ops

    /// Runs one op in the page or the worker; throws `OpFailed` with the JS
    /// error's message when it rejected.
    func run(_ via: Via, in loaded: Loaded, _ message: [String: Any]) async throws -> Any {
        switch via {
        case .page:
            return try await run(in: loaded.page, message)
        case .worker:
            let asked = try await askWorker(from: loaded.page, message: ["type": "panelOp", "payload": message], timeout: 20)
            guard let reply = asked["reply"] as? [String: Any] else { throw WorkerSilent(envelope: asked) }
            guard reply["ok"] as? Bool == true else {
                throw OpFailed(message: reply["error"] as? String ?? "no error text: \(reply)")
            }
            return reply["value"] ?? NSNull()
        }
    }

    /// Runs one op in any web view that carries the polyfill (a panel's, say).
    func run(in webView: WKWebView, _ message: [String: Any]) async throws -> Any {
        let raw = try await webView.callAsyncJavaScript(SidePanelFixture.opJS + """

            try {
                const value = await __detourTestPanelOp(message);
                return JSON.stringify({ ok: true, value: value === undefined ? null : value });
            } catch (e) {
                return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
            }
            """, arguments: ["message": message], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        guard envelope["ok"] as? Bool == true else {
            throw OpFailed(message: envelope["error"] as? String ?? "no error text: \(envelope)")
        }
        return envelope["value"] ?? NSNull()
    }

    func runDict(_ via: Via, in loaded: Loaded, _ message: [String: Any]) async throws -> [String: Any] {
        let value = try await run(via, in: loaded, message)
        return try XCTUnwrap(value as? [String: Any], "expected an object, got \(value)")
    }

    /// The op's rejection text, or nil when it resolved.
    func failure(_ via: Via, in loaded: Loaded, _ message: [String: Any]) async throws -> String? {
        do {
            _ = try await run(via, in: loaded, message)
            return nil
        } catch let error as OpFailed {
            return error.message
        }
    }

    // MARK: WebKit's ids

    /// WebKit's tab id for `tab`, as this extension's contexts see it: found
    /// through the tab id bridge, which TASK-132.2's tests pin.
    func tabID(of tab: BrowserTab, _ via: Via, in loaded: Loaded,
               file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        let listed = try await listedTabs(via, in: loaded)
        let handle = ExtensionTabHandleRegistry.shared.handle(for: tab)
        let entry = try XCTUnwrap(listed.first { $0["handle"] as? Int == handle },
                                  "WebKit lists no tab with this handle: \(listed)", file: file, line: line)
        return try XCTUnwrap(entry["id"] as? Int, file: file, line: line)
    }

    /// WebKit's id for the window that lists `tab`.
    func windowID(listing tab: BrowserTab, _ via: Via, in loaded: Loaded,
                  file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        let listed = try await listedTabs(via, in: loaded)
        let handle = ExtensionTabHandleRegistry.shared.handle(for: tab)
        let entry = try XCTUnwrap(listed.first { $0["handle"] as? Int == handle },
                                  "WebKit lists no tab with this handle: \(listed)", file: file, line: line)
        return try XCTUnwrap(entry["windowId"] as? Int, file: file, line: line)
    }

    func listedTabs(_ via: Via, in loaded: Loaded) async throws -> [[String: Any]] {
        let answer = try await runDict(via, in: loaded, ["op": "tabs"])
        return try XCTUnwrap(answer["tabs"] as? [[String: Any]])
    }

    // MARK: Panels

    func panels(of loaded: Loaded) -> [ExtensionSidePanel] {
        loaded.profile.sidePanels.panels(for: loaded.ext.id)
    }

    /// Waits for the panel's page to have loaded and run its script.
    func waitForPanelPage(_ panel: ExtensionSidePanel, file: StaticString = #filePath, line: UInt = #line) async throws {
        let webView = try XCTUnwrap(panel.webView, file: file, line: line)
        try await waitUntil("the panel page to load", timeout: 20) {
            let loaded = try? await webView.callAsyncJavaScript(
                "return typeof globalThis.__detourTestLoadedAt === 'string';", arguments: [:], contentWorld: .page)
            return loaded as? Bool == true
        }
    }

    /// What the panel's page set when it loaded: changes if it loads again.
    func loadMarker(of panel: ExtensionSidePanel) async throws -> String {
        let webView = try XCTUnwrap(panel.webView)
        let raw = try await webView.callAsyncJavaScript(
            "return globalThis.__detourTestLoadedAt;", arguments: [:], contentWorld: .page)
        return try XCTUnwrap(raw as? String)
    }
}
