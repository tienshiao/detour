import XCTest
import Network
import WebKit
@testable import Detour

// Shared helpers for the extension-polyfill test suites: waiting on a real
// navigation instead of sleeping a fixed interval, and posting a raw polyfill
// envelope through `webkit.messageHandlers` from a loaded page.

/// Drives one navigation to completion. Installs itself as the web view's
/// navigation delegate for the duration and restores the previous delegate
/// afterwards, so a caller's own delegate survives the wait.
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {

    struct TimedOut: Error, CustomStringConvertible {
        let timeout: TimeInterval
        var description: String { "navigation did not finish within \(timeout)s" }
    }

    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?

    /// Run `start` on `webView` and return when the navigation it kicks off
    /// finishes; throws if the navigation fails or the timeout elapses.
    func navigate(
        _ webView: WKWebView, timeout: TimeInterval, start: (WKWebView) -> Void
    ) async throws {
        let previousDelegate = webView.navigationDelegate
        webView.navigationDelegate = self
        defer {
            webView.navigationDelegate = previousDelegate
            timeoutTask?.cancel()
            timeoutTask = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.settle(.failure(TimedOut(timeout: timeout)))
            }
            start(webView)
        }
    }

    /// Resume the waiting caller at most once: WebKit can report a failure and
    /// the timeout can fire for the same navigation.
    private func settle(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settle(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        settle(.failure(error))
    }
}

/// Load `request` and return once the page has finished loading.
@MainActor
func loadAndWait(_ webView: WKWebView, _ request: URLRequest, timeout: TimeInterval = 10) async throws {
    try await NavigationWaiter().navigate(webView, timeout: timeout) { $0.load(request) }
}

/// Load an HTML string and return once the page has finished loading.
@MainActor
func loadHTMLStringAndWait(
    _ webView: WKWebView, html: String, baseURL: URL?, timeout: TimeInterval = 10
) async throws {
    try await NavigationWaiter().navigate(webView, timeout: timeout) {
        $0.loadHTMLString(html, baseURL: baseURL)
    }
}

/// Poll `condition` until it holds, failing the test if `timeout` elapses first.
/// `what` names the thing being waited for, so the failure says what never
/// happened.
@MainActor
func waitUntil(_ what: String, timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.1,
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try await !condition() {
        if Date() >= deadline {
            XCTFail("timed out after \(timeout) s waiting for \(what)", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
}

/// How a test page reaches the background worker.
enum WorkerTransport {
    /// Call `chrome.runtime.sendMessage` from the page itself — only works on an
    /// extension-origin page, which is the only kind that has `chrome` in the
    /// page world.
    case direct
    /// Post `{ __detourTest: 'ask', id, message }` on `window` and wait for the
    /// matching `{ __detourTest: 'answer' }` — for an https page whose only
    /// `chrome` lives in the content-script world, which a test cannot evaluate
    /// JS in. The fixture's content.js must carry the relay listener.
    case contentScriptRelay
}

/// One round trip to an extension's background service worker: sends `message`
/// either straight from the page (`.direct`) or through the content script's
/// relay (`.contentScriptRelay`) and returns the parsed envelope, with both
/// halves of the answer in it:
///  - `reply`: what the worker responded (`NSNull` when it answered nothing —
///    which is also what WebKit produces when it could not reach the worker at
///    all — and the string `"timeout"` when the callback never fired);
///  - `lastError`: `chrome.runtime.lastError.message`, the only place a delivery
///    failure is reported, so a caller can tell "the worker said nothing" from
///    "the message never got there".
@MainActor
func askWorker(from webView: WKWebView, message: [String: Any],
               via transport: WorkerTransport = .direct,
               timeout: TimeInterval = 10) async throws -> [String: Any] {
    let js: String
    switch transport {
    case .direct:
        js = """
            const reply = await new Promise((resolve) => {
                const timer = setTimeout(() => resolve({ reply: 'timeout', lastError: null }), timeoutMS);
                chrome.runtime.sendMessage(message, (r) => {
                    clearTimeout(timer);
                    resolve({ reply: r === undefined ? null : r,
                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                });
            });
            return JSON.stringify(reply);
        """
    case .contentScriptRelay:
        js = """
            const id = String(Math.random());
            const answer = await new Promise((resolve) => {
                const onAnswer = (event) => {
                    const data = event.data;
                    if (!data || data.__detourTest !== 'answer' || data.id !== id) { return; }
                    clearTimeout(timer);
                    window.removeEventListener('message', onAnswer);
                    resolve({ reply: data.reply, lastError: data.lastError });
                };
                const timer = setTimeout(() => {
                    window.removeEventListener('message', onAnswer);
                    resolve({ reply: 'timeout', lastError: null });
                }, timeoutMS);
                window.addEventListener('message', onAnswer);
                window.postMessage({ __detourTest: 'ask', id: id, message: message }, '*');
            });
            return JSON.stringify(answer);
        """
    }
    let raw = try await webView.callAsyncJavaScript(
        js, arguments: ["message": message, "timeoutMS": Int(timeout * 1000)], contentWorld: .page)
    let jsonString = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
    let data = try XCTUnwrap(jsonString.data(using: .utf8))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Did the worker answer nothing? A message that never got there and a worker
/// that responded `undefined` both arrive as null, and `"timeout"` means the
/// callback never fired at all.
func workerReplyIsEmpty(_ envelope: [String: Any]) -> Bool {
    guard let reply = envelope["reply"] else { return true }
    if reply is NSNull { return true }
    if let text = reply as? String, text == "timeout" { return true }
    return false
}

/// Post a raw polyfill envelope straight through `webkit.messageHandlers` from
/// the page, bypassing the polyfill JS (which stamps its own `extensionID`), so
/// a test can claim any id. Returns the bridge's reply or its rejection text.
@MainActor
func postRawPolyfillEnvelope(
    from webView: WKWebView,
    type: String,
    claimedID: String,
    params: [String: Any] = ["detectionIntervalInSeconds": 60]
) async throws -> (result: Any?, error: String?) {
    let js = """
        try {
            const r = await webkit.messageHandlers.detourPolyfill.postMessage({
                type: type, extensionID: claimedID, params: params
            });
            return JSON.stringify({ result: r === undefined ? null : r });
        } catch (e) {
            return JSON.stringify({ error: String(e && e.message ? e.message : e) });
        }
    """
    let raw = try await webView.callAsyncJavaScript(
        js, arguments: ["type": type, "claimedID": claimedID, "params": params],
        contentWorld: .page
    )
    let jsonString = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
    let data = try XCTUnwrap(jsonString.data(using: .utf8))
    let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (dict["result"], dict["error"] as? String)
}

// MARK: - Minimal tab/window conformances

/// A window WebKit will accept for a bare WKWebView. `BrowserWindowController`
/// is the app's conformance, but it needs a real NSWindow and a TabStore space;
/// a test only needs `chrome.tabs` to see one window with one tab.
@MainActor
final class ProbeExtensionWindow: NSObject, WKWebExtensionWindow {
    var openTabs: [any WKWebExtensionTab] = []

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { openTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { openTabs.first }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func frame(for context: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 800, height: 600) }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 1440, height: 900) }
}

/// A tab backed by a plain WKWebView, so a page loaded outside TabStore can
/// still be given a `chrome.tabs` id.
@MainActor
final class ProbeExtensionTab: NSObject, WKWebExtensionTab {
    private let wv: WKWebView
    private weak var containingWindow: ProbeExtensionWindow?

    init(webView: WKWebView, window: ProbeExtensionWindow) {
        self.wv = webView
        self.containingWindow = window
        super.init()
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { wv }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { containingWindow }
    func url(for context: WKWebExtensionContext) -> URL? { wv.url }
    func title(for context: WKWebExtensionContext) -> String? { wv.title }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !wv.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { false }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// Register `webView` with `context` as the one tab of a fresh window. This
/// mirrors the app's own open/focus/activate sequence
/// (`ExtensionManager.notifyExistingTabs`) — the focus step is what gives the
/// context a `focusedWindow`, without which `tabs.query({currentWindow: true})`
/// and `windows.getCurrent` see nothing. It does not forward
/// `didChangeTabProperties` after the load: url and title are read live off the
/// web view, so the only thing missing is `tabs.onUpdated` events.
///
/// Content-script messages only reach the background worker, and
/// `chrome.tabs.query` only sees anything, once the web view is a registered tab
/// — so this must happen *before* the page loads. The returned pair has to be
/// kept alive for as long as the tab should exist and handed to
/// `unregisterProbeTab` when the test is done with it.
@MainActor
func registerProbeTab(for webView: WKWebView, in context: WKWebExtensionContext)
    -> (window: ProbeExtensionWindow, tab: ProbeExtensionTab) {
    let window = ProbeExtensionWindow()
    let tab = ProbeExtensionTab(webView: webView, window: window)
    window.openTabs = [tab]
    context.didOpenWindow(window)
    context.didFocusWindow(window)
    context.didOpenTab(tab)
    context.didActivateTab(tab, previousActiveTab: nil)
    return (window, tab)
}

/// Undo `registerProbeTab`, so a tab does not outlive the test that opened it.
@MainActor
func unregisterProbeTab(_ probe: (window: ProbeExtensionWindow, tab: ProbeExtensionTab),
                        in context: WKWebExtensionContext) {
    context.didCloseTab(probe.tab, windowIsClosing: true)
    context.didCloseWindow(probe.window)
}

// MARK: - Extension fixtures

/// The `options.html` the minimal fixture manifest points at.
let optionsPageTestFiles: [String: String] = ["options.html": "<html><body>options</body></html>"]

/// The minimal MV3 manifest the extension-page suites build on: an options page
/// and no background content.
func optionsPageManifestJSON(name: String) -> String {
    """
    {
        "manifest_version": 3,
        "name": "\(name)",
        "version": "1.0.0",
        "options_ui": { "page": "options.html" }
    }
    """
}

/// Write an unpacked extension into `directory` — by default a fresh temp
/// directory named after `id` — and return it with its `WKWebExtension` loaded.
/// The caller owns that directory (`ext.basePath`) and is responsible for
/// removing it in tearDown; it is deliberately not registered anywhere, so a
/// suite decides for itself what "installed" means for it.
@MainActor
func makeTestExtension(id: String, manifestJSON: String, files: [String: String] = [:],
                       in directory: URL? = nil) async throws -> WebExtension {
    let dir = directory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("detour-test-\(id)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try manifestJSON.write(to: dir.appendingPathComponent("manifest.json"),
                           atomically: true, encoding: .utf8)
    for (file, contents) in files {
        try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    let wkExt = try await WKWebExtension(resourceBaseURL: dir)
    let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
    let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
    ext.wkExtension = wkExt
    return ext
}

/// `makeTestExtension` for the minimal options-page fixture. The id is
/// `idPrefix` plus a random suffix, so two fixtures never collide.
@MainActor
func makeOptionsPageTestExtension(idPrefix: String, name: String) async throws -> WebExtension {
    try await makeTestExtension(id: "\(idPrefix)-\(UUID().uuidString.prefix(8))",
                                manifestJSON: optionsPageManifestJSON(name: name),
                                files: optionsPageTestFiles)
}

/// The manifest.json `ext` was built from, as it is on disk — what a suite that
/// wants a real manifest blob in the DB row saves.
func testExtensionManifestData(_ ext: WebExtension) throws -> Data {
    try Data(contentsOf: ext.basePath.appendingPathComponent("manifest.json"))
}

/// Save `ext` as an installed, globally enabled extension. `manifestJSON`
/// defaults to an empty object, for the suites that never read the blob back.
@MainActor
func installTestExtension(_ ext: WebExtension, in db: AppDatabase,
                          manifestJSON: Data = Data("{}".utf8)) {
    db.saveExtension(ExtensionRecord(
        id: ext.id, name: ext.manifest.name, version: ext.manifest.version,
        manifestJSON: manifestJSON, basePath: ext.basePath.path,
        isEnabled: true, installedAt: Date().timeIntervalSince1970
    ))
}

/// Load `ext`'s context into `profile` and return it. The caller is responsible
/// for unloading it in tearDown.
@MainActor
func loadTestContext(_ ext: WebExtension, in profile: Profile) throws -> WKWebExtensionContext {
    _ = profile.loadExtensionContext(ext)
    return try XCTUnwrap(profile.extensionContext(for: ext.id), "the context should load")
}

/// A tab as a restore or an undo builds one: never woken, so it has no web view
/// and nothing has loaded its URL yet.
@MainActor
func sleepingTab(_ url: URL, title: String = "Page", in space: Space) -> BrowserTab {
    BrowserTab(id: UUID(), title: title, url: url, faviconURL: nil,
               cachedInteractionState: nil, spaceID: space.id)
}

/// An extension page URL, resolved against a context's base URL. An escaped
/// query and a fragment must both survive a rehost untouched, so tests build
/// them here rather than by string concatenation.
func extensionPageURL(_ path: String, on base: URL) throws -> URL {
    try XCTUnwrap(URL(string: path, relativeTo: base)?.absoluteURL)
}

// MARK: - One-shot flag

/// One-shot flag guarding a continuation that several callbacks can reach.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - Loopback WebSocket echo server

/// A WebSocket echo server on 127.0.0.1, built on Network.framework's own
/// `NWProtocolWebSocket` (it performs the server-side handshake). Every text and
/// binary frame is echoed back unchanged and a close from the peer is answered
/// with a close, so a relayed socket can be driven end to end against a real
/// server (TASK-8, `WebSocketRelaySessionTests`).
final class LoopbackWebSocketServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "detour-test-loopback-ws")
    private let lock = NSLock()
    private var openConnections: [ObjectIdentifier: NWConnection] = [:]
    private var _accepted = 0
    private var _ended = 0
    private var _closeFrames = 0

    struct StartTimedOut: Error, CustomStringConvertible {
        var description: String { "loopback WebSocket server did not become ready" }
    }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: params, on: .any)
    }

    /// Connections the server has accepted so far.
    var acceptedConnections: Int {
        lock.lock(); defer { lock.unlock() }
        return _accepted
    }

    /// Connections that have since ended (peer close, cancel, or failure) — this
    /// is how a test sees that the relay really tore its socket down.
    var endedConnections: Int {
        lock.lock(); defer { lock.unlock() }
        return _ended
    }

    /// Close frames received from clients.
    var closeFramesReceived: Int {
        lock.lock(); defer { lock.unlock() }
        return _closeFrames
    }

    /// Start listening and return the port that was assigned.
    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                continuation.resume(throwing: StartTimedOut())
            }
        }
    }

    /// Close every open connection with a normal-closure handshake, so a test can
    /// drive a server-initiated close.
    func closeAllConnections() {
        lock.lock()
        let connections = Array(openConnections.values)
        lock.unlock()
        for connection in connections {
            sendClose(on: connection)
        }
    }

    func stop() {
        closeAllConnections()
        listener.cancel()
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        lock.lock()
        _accepted += 1
        openConnections[ObjectIdentifier(connection)] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        let removed = openConnections.removeValue(forKey: ObjectIdentifier(connection)) != nil
        if removed { _ended += 1 }
        lock.unlock()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                self.forget(connection)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .close:
                self.lock.lock(); self._closeFrames += 1; self.lock.unlock()
                self.sendClose(on: connection)
                return
            case .text:
                self.send(data ?? Data(), opcode: .text, on: connection)
            case .binary:
                self.send(data ?? Data(), opcode: .binary, on: connection)
            default:
                break
            }
            self.receive(on: connection)
        }
    }

    private func send(_ payload: Data, opcode: NWProtocolWebSocket.Opcode, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "echo", metadata: [metadata])
        connection.send(content: payload, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    private func sendClose(on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        })
    }
}

// MARK: - Loopback WebSocket handshake capture

/// A loopback server that records the headers of the WebSocket handshake sent
/// to it and then drops the connection, so a test can assert what actually went
/// out on the wire — `NWProtocolWebSocket` (and `URLSessionWebSocketTask`)
/// perform the handshake internally and expose none of it, which is how the
/// relay's `Cookie` header (TASK-8) is verified rather than merely inspected on
/// the `URLRequest`.
///
/// It deliberately never completes the upgrade: `URLSessionWebSocketTask`
/// refuses a hand-rolled `101` over a plain TCP `NWConnection` even when the
/// response is byte-identical to the one `NWProtocolWebSocket`'s own server
/// sends, so the socket that opens is `LoopbackWebSocketServer`'s job and this
/// one's is only to show what was asked for. The client sees the connection
/// fail, which the relay reports as an error and a 1006 close.
final class LoopbackHandshakeCaptureServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "detour-test-ws-handshake")
    private let lock = NSLock()
    private var _requests: [[String: String]] = []
    private var connections: [NWConnection] = []

    struct StartTimedOut: Error, CustomStringConvertible {
        var description: String { "loopback handshake server did not become ready" }
    }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    /// The headers of each handshake seen, in order, with lowercased names.
    var requests: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                continuation.resume(throwing: StartTimedOut())
            }
        }
    }

    func stop() {
        lock.lock()
        let open = connections
        connections.removeAll()
        lock.unlock()
        for connection in open { connection.cancel() }
        listener.cancel()
    }

    // MARK: Handshake

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                self.readRequest(on: connection, buffer: buffer)
                return
            }
            self.capture(text, on: connection)
        }
    }

    private func capture(_ request: String, on connection: NWConnection) {
        var headers: [String: String] = [:]
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        lock.lock()
        _requests.append(headers)
        lock.unlock()
        connection.cancel()
    }
}

// MARK: - Callback-form polyfill calls (TASK-23)

/// JS (for `callAsyncJavaScript`) that makes one callback-style extension API
/// call and returns, as a JSON string, everything the callback-or-promise
/// contract is judged on:
///  - `returnedType`: `typeof` what the API call returned (`undefined` when a
///    callback was taken);
///  - `argc` / `arg0`: what the callback was invoked with (`arg0` JSON-encoded);
///  - `lastErrorInCallback`: `chrome.runtime.lastError.message` read inside the
///    callback, or null (absent when `readLastError` is false, so the error
///    goes unchecked);
///  - `lastErrorAfter`: `chrome.runtime.lastError` once the callback has
///    returned and the event loop has turned (`"undefined"`, `"null"`, or JSON);
///  - `ownLastErrorAfter`: whether `lastError` is still an own property of
///    `chrome.runtime` afterwards;
///  - `mode`: `__detourCallbackLastError.lastMode`;
///  - `unhandled`: reasons of every `unhandledrejection` seen meanwhile;
///  - `consoleErrors`: every `console.error` line meanwhile;
///  - `uncaught`: messages of every `error` event meanwhile (exceptions the
///    callback threw);
///  - `timedOut`: the callback never ran.
///
/// `call` is a function body with `cb` in scope that returns the API's return
/// value, e.g. `return chrome.offscreen.createDocument({...}, cb);`. `setup`
/// runs first; `teardown` runs in a `finally` after the outcome is recorded.
func callbackOutcomeJS(call: String, setup: String = "", teardown: String = "",
                       readLastError: Bool = true, throwFromCallback: Bool = false) -> String {
    #"""
    const unhandled = [];
    const uncaught = [];
    const consoleErrors = [];
    const onUnhandled = (event) => {
        unhandled.push(String(event.reason && event.reason.message ? event.reason.message : event.reason));
        event.preventDefault();
    };
    const onError = (event) => { uncaught.push(String(event.message)); event.preventDefault(); };
    const originalConsoleError = console.error;
    globalThis.addEventListener('unhandledrejection', onUnhandled);
    globalThis.addEventListener('error', onError);
    console.error = function(...args) { consoleErrors.push(args.map(String).join(' ')); };
    try {
        \#(setup)
        const outcome = { timedOut: false };
        await new Promise((resolve) => {
            const timer = setTimeout(() => { outcome.timedOut = true; resolve(); }, 8000);
            const cb = function(...args) {
                clearTimeout(timer);
                outcome.argc = args.length;
                outcome.arg0 = args.length ? JSON.stringify(args[0]) : null;
                if (\#(readLastError ? "true" : "false")) {
                    const lastError = chrome.runtime.lastError;
                    outcome.lastErrorInCallback = lastError ? String(lastError.message) : null;
                }
                resolve();
                if (\#(throwFromCallback ? "true" : "false")) throw new Error('thrown from callback');
            };
            const returned = (function() { \#(call) })();
            outcome.returnedType = typeof returned;
        });
        // Let a stray rejection or a rethrown exception be reported.
        await new Promise((resolve) => setTimeout(resolve, 150));
        const after = chrome.runtime.lastError;
        outcome.lastErrorAfter = after === undefined ? 'undefined' : JSON.stringify(after);
        outcome.ownLastErrorAfter = Object.prototype.hasOwnProperty.call(chrome.runtime, 'lastError');
        outcome.mode = globalThis.__detourCallbackLastError ? globalThis.__detourCallbackLastError.lastMode : 'missing';
        outcome.unhandled = unhandled;
        outcome.uncaught = uncaught;
        outcome.consoleErrors = consoleErrors.slice();
        return JSON.stringify(outcome);
    } finally {
        console.error = originalConsoleError;
        globalThis.removeEventListener('unhandledrejection', onUnhandled);
        globalThis.removeEventListener('error', onError);
        \#(teardown)
    }
    """#
}

/// JS returning, as a JSON string, how the promise form of `call` settled:
/// `{ settled: 'resolved' | 'rejected', value, message }`. `call` is an
/// expression evaluating to the promise.
func promiseOutcomeJS(_ call: String) -> String {
    #"""
    try {
        const value = await (\#(call));
        return JSON.stringify({ settled: 'resolved', value: value === undefined ? null : value });
    } catch (e) {
        return JSON.stringify({ settled: 'rejected', message: String(e && e.message ? e.message : e) });
    }
    """#
}

// MARK: - Loopback HTTP server

/// A one-shot-per-connection HTTP/1.1 server on 127.0.0.1, just enough to serve
/// a handful of HTML routes. Content scripts are only injected into frames whose
/// URL matches a manifest match pattern, and `<all_urls>` covers neither
/// `about:srcdoc` nor `data:` — so a frame probe needs real http documents.
///
/// Every request's path is recorded in `requestedPaths` (a 404 counts too), so
/// a page can also use the server as a beacon target to say "I loaded".
final class LoopbackHTTPServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "detour-test-loopback-http")
    private let routes: [String: String]
    private let lock = NSLock()
    private var _requestedPaths: [String] = []

    /// The request paths seen so far, in arrival order.
    var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return _requestedPaths
    }

    struct StartTimedOut: Error, CustomStringConvertible {
        var description: String { "loopback HTTP server did not become ready" }
    }

    init(routes: [String: String]) throws {
        self.routes = routes
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    /// Start listening and return the port that was assigned.
    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                continuation.resume(throwing: StartTimedOut())
            }
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, accumulated: Data())
    }

    /// A single `receive` is not guaranteed to deliver the whole request line —
    /// keep reading until the head terminator arrives, and give up (cancelling
    /// the connection) on EOF or error rather than leaving it open.
    private func readHead(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            var head = accumulated
            head.append(data)
            guard head.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete || head.count > 64 * 1024 {
                    connection.cancel()
                } else {
                    self.readHead(connection, accumulated: head)
                }
                return
            }
            self.respond(connection, head: head)
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        let request = String(decoding: head, as: UTF8.self)
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock()
        _requestedPaths.append(path)
        lock.unlock()
        let body = Data((routes[path] ?? "<html><body>not found</body></html>").utf8)
        let status = routes[path] == nil ? "404 Not Found" : "200 OK"
        let header = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
