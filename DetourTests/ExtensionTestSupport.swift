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

/// One round trip to an extension's background service worker: sends `message`
/// with `chrome.runtime.sendMessage` from a loaded extension page and returns the
/// parsed envelope, with both halves of the answer in it:
///  - `reply`: what the worker responded (`NSNull` when it answered nothing —
///    which is also what WebKit produces when it could not reach the worker at
///    all — and the string `"timeout"` when the callback never fired);
///  - `lastError`: `chrome.runtime.lastError.message`, the only place a delivery
///    failure is reported, so a caller can tell "the worker said nothing" from
///    "the message never got there".
@MainActor
func askWorker(from webView: WKWebView, message: [String: Any],
               timeout: TimeInterval = 10) async throws -> [String: Any] {
    let raw = try await webView.callAsyncJavaScript("""
        const reply = await new Promise((resolve) => {
            let settled = false;
            chrome.runtime.sendMessage(message, (r) => {
                settled = true;
                resolve({ reply: r === undefined ? null : r,
                          lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
            });
            setTimeout(() => { if (!settled) resolve({ reply: 'timeout', lastError: null }); }, timeoutMS);
        });
        return JSON.stringify(reply);
    """, arguments: ["message": message, "timeoutMS": Int(timeout * 1000)], contentWorld: .page)
    let jsonString = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
    let data = try XCTUnwrap(jsonString.data(using: .utf8))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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
