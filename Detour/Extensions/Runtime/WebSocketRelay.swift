import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "websocket-relay")

/// The worker end of a relayed WebSocket, as the session sees it: a native
/// messaging port carrying JSON objects both ways. `MessagePortRelayPort` is the
/// production adapter over `WKWebExtension.MessagePort`; tests substitute a fake
/// so the session's protocol can be driven without WebKit.
protocol WebSocketRelayPort: AnyObject {
    /// Send one message to the worker, calling `completion` once the port has
    /// taken it — the ordering hook the session needs to disconnect *after* the
    /// worker has been told the socket closed.
    func send(_ message: [String: Any], completion: (() -> Void)?)
    /// Drop the port. Fires `onDisconnect` exactly once, whichever side ends it.
    func disconnect()

    var onMessage: (([String: Any]) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
}

extension WebSocketRelayPort {
    func send(_ message: [String: Any]) { send(message, completion: nil) }
}

/// `WebSocketRelayPort` over a real extension message port.
///
/// `onDisconnect` fires for *either* cause — the worker (or WebKit, on context
/// unload) dropping the port, or a local `disconnect()` — so whoever owns the
/// session has a single "this port is gone" signal to clean up on; the guard
/// makes it exactly one.
final class MessagePortRelayPort: WebSocketRelayPort {

    private let port: WKWebExtension.MessagePort
    private var finished = false

    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    init(_ port: WKWebExtension.MessagePort) {
        self.port = port
        port.messageHandler = { [weak self] message, _ in
            guard let self, let body = message as? [String: Any] else { return }
            self.onMessage?(body)
        }
        port.disconnectHandler = { [weak self] _ in
            self?.finish()
        }
    }

    func send(_ message: [String: Any], completion: (() -> Void)?) {
        guard !finished else { return }
        port.sendMessage(message, completionHandler: { _ in completion?() })
    }

    func disconnect() {
        guard !finished else { return }
        port.disconnect(throwing: nil)
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onDisconnect?()
    }
}

/// One relayed WebSocket: the port protocol on one side, a real
/// `URLSessionWebSocketTask` on the other (TASK-8).
///
/// WebKit runs an extension's background service worker on the main thread of its
/// content process, where `new WebSocket()` self-deadlocks
/// (`WorkerThreadableWebSocketChannel` waits on the main thread — see
/// docs/1password-integration-plan.md, Phase 1). So the worker's `WebSocket` is a
/// stand-in (`ExtensionAPIPolyfill.webSocketRelayJS`) that opens a port to the
/// `detourWebSocketRelay` host and lets this run the socket natively.
///
/// Protocol, all fields JSON-safe:
///
/// | worker -> native | meaning |
/// |---|---|
/// | `{op:"open", url, protocols:[String]}` | connect (exactly once) |
/// | `{op:"send", text}` / `{op:"send", binary}` | one frame (binary is base64) |
/// | `{op:"close", code, reason}` | close handshake |
///
/// | native -> worker | meaning |
/// |---|---|
/// | `{op:"open", protocol, extensions}` | handshake finished |
/// | `{op:"message", text}` / `{op:"message", binary}` | one frame |
/// | `{op:"error", message}` | failure, always followed by a close |
/// | `{op:"close", code, reason, wasClean}` | socket closed; the port is dropped |
///
/// Anything the protocol does not allow (an op before `open`, a second `open`, an
/// unknown op) is answered with `error` + `close` 1006 and ends the session.
///
/// **Not enforced, deliberately**: the extension's CSP `connect-src` (WebKit
/// applies it to its own channel, which this bypasses) and host permissions —
/// Chrome does not CORS-restrict WebSockets opened from an extension worker
/// either, so requiring them here would break extensions that work everywhere
/// else. The gate that does apply is `ExtensionManager.nativeHostAccess`: only a
/// loaded extension context can open this port at all.
///
/// **Cookies**: the handshake carries the owning profile's cookies for the
/// origin (`cookieProvider`), as Chrome's does — without them a credentialed
/// socket to a site the user is signed into in that profile would fail. They are
/// read at handshake time only: nothing is written back, and a `Set-Cookie` on
/// the 101 response is not stored.
///
/// Main-thread only: the session's `URLSession` delivers on the main queue and
/// every caller is a WebKit delegate callback.
final class WebSocketRelaySession {

    /// The native messaging host name a worker connects to for a relayed socket.
    static let hostName = "detourWebSocketRelay"

    /// Hands back every cookie the profile's data store holds for `url` (an
    /// http/https URL). The session picks the ones that apply
    /// (`applicableCookies(_:for:)`) and puts them on the handshake request.
    typealias CookieProvider = (URL, @escaping ([HTTPCookie]) -> Void) -> Void

    private let port: WebSocketRelayPort
    private let extensionID: String
    private let urlSession: URLSession
    /// Reads the owning profile's cookie jar, or nil to send no cookies at all
    /// (no profile owns the controller — only test-built controllers).
    private let cookieProvider: CookieProvider?

    private var task: URLSessionWebSocketTask?
    /// Set as soon as an `open` op is accepted, so a second one is a protocol
    /// error even before the handshake finishes.
    private var openRequested = false
    /// The worker has been told the socket closed: nothing more may be sent.
    private var closed = false
    private var tornDown = false

    /// The handshake request the socket was created with. Tests only — it is how
    /// the `Cookie` header is asserted without reading the wire.
    private(set) var lastRequestForTesting: URLRequest?

    init(port: WebSocketRelayPort, extensionID: String, cookieProvider: CookieProvider? = nil) {
        self.port = port
        self.extensionID = extensionID
        self.cookieProvider = cookieProvider
        let delegate = Delegate()
        self.urlSession = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: .main)
        delegate.session = self
        port.onMessage = { [weak self] message in self?.handle(message) }
        port.onDisconnect = { [weak self] in self?.handlePortDisconnect() }
    }

    // MARK: - Worker -> native

    private func handle(_ message: [String: Any]) {
        guard !closed else { return }
        switch message["op"] as? String {
        case "open":
            handleOpen(message)
        case "send":
            handleSend(message)
        case "close":
            handleClose(message)
        case let op:
            failProtocol("unsupported op '\(op ?? "(none)")'")
        }
    }

    private func handleOpen(_ message: [String: Any]) {
        guard !openRequested else {
            failProtocol("a socket is already open")
            return
        }
        guard let text = message["url"] as? String, let url = Self.validate(urlString: text) else {
            fail("invalid WebSocket URL")
            return
        }
        openRequested = true

        var request = URLRequest(url: url)
        // With a URLRequest the subprotocols are a header rather than a parameter
        // (`webSocketTask(with:protocols:)` takes the URL form only).
        let protocols = (message["protocols"] as? [String]) ?? []
        if !protocols.isEmpty {
            request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        // URLSession replaces a hand-set `Cookie` header from its own (here empty,
        // ephemeral) store unless cookie handling is off. The profile's jar is the
        // only cookie source that matters.
        request.httpShouldHandleCookies = false

        guard let cookieProvider else {
            startTask(with: request)
            return
        }
        // Chrome sends the profile's cookies on an extension worker's WebSocket
        // handshake; a fresh ephemeral session would send none, so a credentialed
        // socket to an origin the user is signed into would fail. Read at
        // handshake time only — nothing is written back and a `Set-Cookie` on the
        // 101 response is not stored.
        let cookieURL = Self.httpEquivalent(of: url)
        cookieProvider(cookieURL) { [weak self] cookies in
            guard let self else { return }
            self.onMain {
                // The worker may have closed (or the context unloaded) while the
                // cookie store was being read: there is no socket to open any more.
                guard !self.closed, !self.tornDown else { return }
                var request = request
                let applicable = Self.applicableCookies(cookies, for: cookieURL)
                if !applicable.isEmpty,
                   let header = HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] {
                    request.setValue(header, forHTTPHeaderField: "Cookie")
                }
                self.startTask(with: request)
            }
        }
    }

    /// Create the socket for a prepared handshake request and start reading.
    private func startTask(with request: URLRequest) {
        lastRequestForTesting = request
        let task = urlSession.webSocketTask(with: request)
        self.task = task
        let url = request.url?.absoluteString ?? "(none)"
        log.info("Relaying a WebSocket for \(self.extensionID, privacy: .public) to \(url, privacy: .private)")
        task.resume()
        receiveNext()
    }

    private func handleSend(_ message: [String: Any]) {
        guard let task else {
            failProtocol("no socket is open")
            return
        }
        let frame: URLSessionWebSocketTask.Message
        if let text = message["text"] as? String {
            frame = .string(text)
        } else if let base64 = message["binary"] as? String, let data = Data(base64Encoded: base64) {
            frame = .data(data)
        } else {
            failProtocol("a send op needs a text or binary payload")
            return
        }
        task.send(frame) { [weak self] error in
            guard let error, let self else { return }
            self.onMain { self.fail("send failed: \(error.localizedDescription)") }
        }
    }

    private func handleClose(_ message: [String: Any]) {
        // `openRequested` rather than `task`: the socket may not exist yet (the
        // profile's cookies are still being read), and closing before the
        // handshake started is legal — `close()` on a CONNECTING socket.
        guard openRequested else {
            failProtocol("no socket is open")
            return
        }
        let requested = message["code"] as? Int
        let reason = message["reason"] as? String

        // Answer the worker here rather than waiting for the delegate: `cancel(with:)`
        // does deliver `didCloseWith` in practice (measured against the loopback
        // echo server, 2026-09-12) but nothing documents that it must, and a close
        // the worker never gets would leave its socket stuck in CLOSING. `closed`
        // makes the delegate callback, when it arrives, a no-op — exactly one close,
        // whichever of the two runs first.
        guard let requested else {
            // `close()` with no code: the close frame carries no status, so the
            // CloseEvent the worker gets must be 1005 ("no status received") with
            // an empty reason — not the 1000 the task is actually cancelled with,
            // and not the reason, which the spec drops along with the code.
            task?.cancel(with: .normalClosure, reason: nil)
            emitClose(code: 1005, reason: "", wasClean: true)
            return
        }
        // URLSession only models the registered close codes, so an application
        // code (3000-4999, which is what the JS side allows besides 1000) has no
        // `CloseCode` case: the frame goes out as a normal closure, but the worker
        // is told the code it asked for rather than a 1000 it never chose.
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: requested) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason?.data(using: .utf8))
        emitClose(code: requested, reason: reason ?? "", wasClean: true)
    }

    // MARK: - Native -> worker

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.onMain {
                guard !self.closed else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.port.send(["op": "message", "text": text])
                    case .data(let data):
                        self.port.send(["op": "message", "binary": data.base64EncodedString()])
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                case .failure(let error):
                    // A closed socket also surfaces here (the read fails once the
                    // connection is gone). If the task carries a close code the
                    // handshake completed, so report the close rather than a 1006
                    // failure — whichever of this and `didCloseWith` runs first.
                    if let task = self.task, task.closeCode != .invalid {
                        self.emitClose(code: task.closeCode.rawValue,
                                       reason: Self.text(task.closeReason), wasClean: true)
                    } else {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
    }

    fileprivate func handleDidOpen(protocol negotiated: String?) {
        guard !closed else { return }
        log.info("Relayed WebSocket open for \(self.extensionID, privacy: .public)")
        port.send(["op": "open", "protocol": negotiated ?? "", "extensions": ""])
    }

    fileprivate func handleDidClose(code: Int, reason: Data?) {
        emitClose(code: code, reason: Self.text(reason), wasClean: true)
    }

    /// The socket failed: tell the worker, then close it the way an aborted
    /// connection closes (1006, not clean).
    private func fail(_ message: String) {
        guard !closed else { return }
        log.error("Relayed WebSocket failed for \(self.extensionID, privacy: .public): \(message, privacy: .public)")
        port.send(["op": "error", "message": message])
        emitClose(code: 1006, reason: message, wasClean: false)
    }

    /// The worker broke the protocol. Same shape as `fail`, with a fixed close
    /// reason so the worker (and the tests) can tell the two apart.
    private func failProtocol(_ message: String) {
        guard !closed else { return }
        log.error("WebSocket relay protocol error for \(self.extensionID, privacy: .public): \(message, privacy: .public)")
        port.send(["op": "error", "message": message])
        emitClose(code: 1006, reason: "protocol error", wasClean: false)
    }

    /// Send the one close the worker gets, then release everything.
    private func emitClose(code: Int, reason: String, wasClean: Bool) {
        guard !closed else { return }
        closed = true
        log.info("Relayed WebSocket closed for \(self.extensionID, privacy: .public): code \(code), clean \(wasClean)")
        port.send(["op": "close", "code": code, "reason": reason, "wasClean": wasClean]) { [weak self] in
            // Only once the close has reached the worker: a port dropped before it
            // would surface as a 1006 failure instead of this close.
            self?.tearDown()
        }
    }

    // MARK: - Teardown

    /// The port is gone (the worker closed it, or the context unloaded): drop the
    /// socket with it. Nothing is sent — there is nobody left to tell.
    private func handlePortDisconnect() {
        guard !tornDown else { return }
        tornDown = true
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // Also what releases the delegate, and with it its reference to us.
        urlSession.invalidateAndCancel()
    }

    /// Tear the session down from the Detour side (context unload). Cancels the
    /// socket and disconnects the port.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        port.disconnect()
        // Also what releases the delegate, and with it its reference to us.
        urlSession.invalidateAndCancel()
    }

    // MARK: - Helpers

    /// ws/wss, parseable, no fragment — everything else is refused before a
    /// connection is attempted.
    private static func validate(urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              url.host?.isEmpty == false,
              url.fragment == nil else { return nil }
        return url
    }

    private static func text(_ data: Data?) -> String {
        guard let data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The http/https URL a ws/wss URL's cookies live under — cookie scope is by
    /// origin, and a cookie jar is keyed with the http schemes.
    static func httpEquivalent(of url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = url.scheme?.lowercased() == "wss" ? "https" : "http"
        return components.url ?? url
    }

    /// The cookies from a profile's whole jar that a request to `url` carries:
    /// domain match (a leading-dot cookie also covers subdomains), path prefix,
    /// `Secure` only over https/wss, and not already expired. `url` must be the
    /// http/https equivalent (`httpEquivalent(of:)`).
    ///
    /// Done here because `WKHTTPCookieStore.getAllCookies` hands back the entire
    /// store, not the cookies for one URL.
    static func applicableCookies(_ all: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let isSecure = url.scheme?.lowercased() == "https"
        let path = url.path.isEmpty ? "/" : url.path
        let now = Date()
        return all.filter { cookie in
            if cookie.isSecure && !isSecure { return false }
            if let expires = cookie.expiresDate, expires <= now { return false }
            guard domainMatches(cookieDomain: cookie.domain.lowercased(), host: host) else { return false }
            return pathMatches(cookiePath: cookie.path, requestPath: path)
        }
    }

    private static func domainMatches(cookieDomain: String, host: String) -> Bool {
        guard cookieDomain.hasPrefix(".") else { return host == cookieDomain }
        let bare = String(cookieDomain.dropFirst())
        return host == bare || host.hasSuffix("." + bare)
    }

    private static func pathMatches(cookiePath: String, requestPath: String) -> Bool {
        let cookiePath = cookiePath.isEmpty ? "/" : cookiePath
        if cookiePath == "/" || cookiePath == requestPath { return true }
        guard requestPath.hasPrefix(cookiePath) else { return false }
        // "/a" covers "/a/b" but not "/ab".
        return cookiePath.hasSuffix("/") || requestPath[requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)] == "/"
    }

    /// The session's bookkeeping is main-thread only; URLSession callbacks arrive
    /// on the delegate queue (main), but a custom session may not.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Separate object so the URLSession's strong reference to its delegate does
    /// not retain the session that owns it.
    private final class Delegate: NSObject, URLSessionWebSocketDelegate {
        weak var session: WebSocketRelaySession?

        func urlSession(_ urlSession: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didOpenWithProtocol protocolName: String?) {
            session?.handleDidOpen(protocol: protocolName)
        }

        func urlSession(_ urlSession: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                        reason: Data?) {
            session?.handleDidClose(code: closeCode.rawValue, reason: reason)
        }
    }
}
