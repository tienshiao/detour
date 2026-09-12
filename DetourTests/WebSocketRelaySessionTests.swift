import XCTest
@testable import Detour

/// The native half of the service-worker WebSocket relay (TASK-8):
/// `WebSocketRelaySession` speaks the port protocol on one side and drives a real
/// `URLSessionWebSocketTask` on the other. The worker side is faked
/// (`FakeRelayPort`) and the server side is real — a loopback WebSocket echo
/// server — so the protocol is checked against an actual socket, not a mock.
@MainActor
final class WebSocketRelaySessionTests: XCTestCase {

    private var server: LoopbackWebSocketServer!
    private var serverPort: UInt16 = 0
    private var sessions: [WebSocketRelaySession] = []

    override func setUp() async throws {
        try await super.setUp()
        server = try LoopbackWebSocketServer()
        serverPort = try await server.start()
    }

    override func tearDown() {
        for session in sessions { session.tearDown() }
        sessions.removeAll()
        server?.stop()
        server = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private var echoURL: String { "ws://127.0.0.1:\(serverPort)/" }

    /// A session whose cookie provider hands back `cookies` (the whole jar, the
    /// way `WKHTTPCookieStore.getAllCookies` does — the session picks the ones
    /// that apply). Passing nil means no provider at all.
    private func makeSession(cookies: [HTTPCookie]? = nil) -> (WebSocketRelaySession, FakeRelayPort) {
        let port = FakeRelayPort()
        let provider: WebSocketRelaySession.CookieProvider? = cookies.map { jar in
            { _, completion in completion(jar) }
        }
        let session = WebSocketRelaySession(port: port, extensionID: "relay-test-extension",
                                            cookieProvider: provider)
        sessions.append(session)
        return (session, port)
    }

    private func cookie(name: String, value: String, domain: String,
                       path: String = "/", secure: Bool = false) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: value, .domain: domain, .path: path
        ]
        if secure { properties[.secure] = "TRUE" }
        return try XCTUnwrap(HTTPCookie(properties: properties))
    }

    /// Wait for the session to send the worker a message with `op`, and return it.
    @discardableResult
    private func waitForOp(_ op: String, on port: FakeRelayPort, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        var found: [String: Any]?
        try await waitUntil("a '\(op)' message on the relay port (got: \(port.sentOps))",
                            timeout: timeout, file: file, line: line) {
            found = port.sent.first { $0["op"] as? String == op }
            return found != nil
        }
        return try XCTUnwrap(found, "no '\(op)' message", file: file, line: line)
    }

    /// Open a socket to the echo server and return once it is connected.
    private func openSocket(file: StaticString = #filePath,
                            line: UInt = #line) async throws -> (WebSocketRelaySession, FakeRelayPort) {
        let (session, port) = makeSession()
        port.deliver(["op": "open", "url": echoURL, "protocols": [String]()])
        try await waitForOp("open", on: port, file: file, line: line)
        return (session, port)
    }

    // MARK: - Opening

    func testOpenConnectsAndReportsTheHandshake() async throws {
        let (_, port) = makeSession()
        port.deliver(["op": "open", "url": echoURL, "protocols": [String]()])

        let opened = try await waitForOp("open", on: port)
        XCTAssertEqual(opened["protocol"] as? String, "",
                       "no subprotocol was requested, so none is negotiated")
        XCTAssertEqual(opened["extensions"] as? String, "")
        XCTAssertEqual(port.disconnectCount, 0, "an open socket must keep its port")
    }

    // MARK: - Data frames

    func testEchoesTextFrames() async throws {
        let (_, port) = try await openSocket()
        port.deliver(["op": "send", "text": "hello relay"])

        let message = try await waitForOp("message", on: port)
        XCTAssertEqual(message["text"] as? String, "hello relay")
        XCTAssertNil(message["binary"], "a text frame must not be reported as binary")
    }

    func testEchoesBinaryFramesAsBase64() async throws {
        let (_, port) = try await openSocket()
        // Bytes that are not valid UTF-8 on their own, so a text round trip would
        // corrupt them.
        let payload = Data([0x01, 0x02, 0xFA, 0xFF])
        port.deliver(["op": "send", "binary": payload.base64EncodedString()])

        let message = try await waitForOp("message", on: port)
        XCTAssertNil(message["text"])
        let echoed = try XCTUnwrap(message["binary"] as? String)
        XCTAssertEqual(Data(base64Encoded: echoed), payload, "the bytes must round-trip exactly")
    }

    // MARK: - Closing

    func testWorkerCloseClosesTheSocketExactlyOnce() async throws {
        let (_, port) = try await openSocket()
        port.deliver(["op": "close", "code": 1000, "reason": "bye"])

        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["code"] as? Int, 1000)
        XCTAssertEqual(closed["wasClean"] as? Bool, true)

        try await waitUntil("the port to be disconnected after the close") { port.disconnectCount > 0 }
        try await waitUntil("the server to see the connection end") { self.server.endedConnections >= 1 }

        // `cancel(with:)` does not reliably call the delegate, so the session
        // answers the close itself — and must not answer twice if it does.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(port.sent.filter { $0["op"] as? String == "close" }.count, 1,
                       "the worker must get exactly one close: \(port.sentOps)")
    }

    /// `close()` with no argument closes with *no status code*, and the CloseEvent
    /// the worker gets must then be 1005 ("no status received") with an empty
    /// reason — not the 1000 the task is actually cancelled with.
    func testWorkerCloseWithoutACodeReportsA1005Close() async throws {
        let (_, port) = try await openSocket()
        port.deliver(["op": "close"])

        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["code"] as? Int, 1005,
                       "an absent code is 'no status received', not a normal closure")
        XCTAssertEqual(closed["reason"] as? String, "")
        XCTAssertEqual(closed["wasClean"] as? Bool, true)

        try await waitUntil("the server to see the connection end") { self.server.endedConnections >= 1 }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(port.sent.filter { $0["op"] as? String == "close" }.count, 1,
                       "still exactly one close: \(port.sentOps)")
    }

    /// An application close code (3000-4999) has no `URLSessionWebSocketTask.CloseCode`
    /// case, so the frame goes out as a normal closure — but the worker must be
    /// told the code it asked for, not a 1000 it never chose.
    func testWorkerCloseWithAnApplicationCodeIsReportedBack() async throws {
        let (_, port) = try await openSocket()
        port.deliver(["op": "close", "code": 4001, "reason": "app close"])

        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["code"] as? Int, 4001)
        XCTAssertEqual(closed["reason"] as? String, "app close")
        XCTAssertEqual(closed["wasClean"] as? Bool, true)
    }

    func testServerCloseIsForwardedAndReleasesThePort() async throws {
        let (_, port) = try await openSocket()
        server.closeAllConnections()

        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["wasClean"] as? Bool, true,
                       "a close handshake from the server is clean, not a 1006 failure")
        XCTAssertEqual(closed["code"] as? Int, 1000)
        try await waitUntil("the port to be disconnected") { port.disconnectCount > 0 }
    }

    func testPortDisconnectCancelsTheSocket() async throws {
        let (_, port) = try await openSocket()
        try await waitUntil("the server to accept the connection") { self.server.acceptedConnections >= 1 }

        port.remoteDisconnect()

        try await waitUntil("the server to see the cancelled connection close") {
            self.server.endedConnections >= 1
        }
        XCTAssertFalse(port.sent.contains { $0["op"] as? String == "close" },
                       "the worker asked for nothing back: its port is already gone")
    }

    func testTearDownCancelsTheSocketAndDisconnectsThePort() async throws {
        let (session, port) = try await openSocket()
        try await waitUntil("the server to accept the connection") { self.server.acceptedConnections >= 1 }

        session.tearDown()

        try await waitUntil("the server to see the connection end") { self.server.endedConnections >= 1 }
        XCTAssertGreaterThan(port.disconnectCount, 0, "the context is gone: drop the port too")
    }

    // MARK: - Profile cookies on the handshake

    /// Chrome sends the profile's cookies on an extension worker's WebSocket
    /// handshake; a fresh ephemeral session sends none, so a credentialed socket
    /// to an origin the user is signed into would fail. The provider hands over
    /// the whole jar and the session picks what applies.
    func testHandshakeCarriesTheProfilesCookiesForTheHost() async throws {
        let jar = [try cookie(name: "session", value: "abc123", domain: "127.0.0.1")]
        let (session, port) = makeSession(cookies: jar)
        port.deliver(["op": "open", "url": echoURL, "protocols": [String]()])
        try await waitForOp("open", on: port)

        let request = try XCTUnwrap(session.lastRequestForTesting)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=abc123")
        XCTAssertEqual(request.httpShouldHandleCookies, false,
                       "URLSession would otherwise replace the header from its own empty store")

        // Reading the jar is asynchronous, so the socket must still work after it.
        port.deliver(["op": "send", "text": "still works"])
        let message = try await waitForOp("message", on: port)
        XCTAssertEqual(message["text"] as? String, "still works")
    }

    /// The headers really reach the server, rather than being dropped between the
    /// `URLRequest` and the wire (`URLSession` replaces a hand-set `Cookie` unless
    /// `httpShouldHandleCookies` is off). The capture server records the
    /// handshake and then drops the connection, so the socket never opens — what
    /// is under test is what was asked for.
    func testHandshakeSendsTheCookieAndProtocolHeadersOnTheWire() async throws {
        let capture = try LoopbackHandshakeCaptureServer()
        defer { capture.stop() }
        let capturePort = try await capture.start()

        let jar = [try cookie(name: "session", value: "abc123", domain: "127.0.0.1")]
        let (_, port) = makeSession(cookies: jar)
        port.deliver(["op": "open",
                      "url": "ws://127.0.0.1:\(capturePort)/notify",
                      "protocols": ["p1", "p2"]])

        try await waitUntil("the server to see the handshake") { !capture.requests.isEmpty }
        let headers = try XCTUnwrap(capture.requests.first)
        XCTAssertEqual(headers["cookie"], "session=abc123",
                       "the profile's cookie must survive onto the wire: \(headers)")
        XCTAssertEqual(headers["sec-websocket-protocol"], "p1, p2",
                       "subprotocols travel as a header when a URLRequest is used: \(headers)")
    }

    /// NEGATIVE: cookies scoped to another domain must not leak onto this
    /// handshake, even though the provider hands over the whole jar.
    func testHandshakeOmitsCookiesForOtherDomains() async throws {
        let jar = [
            try cookie(name: "elsewhere", value: "nope", domain: "example.com"),
            // Right host, wrong path.
            try cookie(name: "scoped", value: "nope", domain: "127.0.0.1", path: "/other"),
            // Right host, but Secure, and this is a plain ws:// socket.
            try cookie(name: "secured", value: "nope", domain: "127.0.0.1", secure: true)
        ]
        let (session, port) = makeSession(cookies: jar)
        port.deliver(["op": "open", "url": echoURL, "protocols": [String]()])
        try await waitForOp("open", on: port)

        let request = try XCTUnwrap(session.lastRequestForTesting)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"),
                     "no cookie applies to this origin, so no header at all")
    }

    /// NEGATIVE: no provider (no Profile owns the controller) means no cookies.
    func testHandshakeHasNoCookieHeaderWithoutAProvider() async throws {
        let (session, port) = makeSession()
        port.deliver(["op": "open", "url": echoURL, "protocols": [String]()])
        try await waitForOp("open", on: port)

        let request = try XCTUnwrap(session.lastRequestForTesting)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    // MARK: - Protocol errors (negative)

    func testInvalidURLFailsWithErrorAndClose1006() async throws {
        let (_, port) = makeSession()
        port.deliver(["op": "open", "url": "https://example.invalid/notify", "protocols": [String]()])

        let failure = try await waitForOp("error", on: port)
        XCTAssertNotNil(failure["message"] as? String)
        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["code"] as? Int, 1006)
        XCTAssertEqual(closed["wasClean"] as? Bool, false)
        try await waitUntil("the port to be disconnected") { port.disconnectCount > 0 }
        XCTAssertEqual(port.sentOps, ["error", "close"], "nothing else may be sent")
    }

    func testURLWithFragmentIsRejected() async throws {
        let (_, port) = makeSession()
        port.deliver(["op": "open", "url": "\(echoURL)#frag", "protocols": [String]()])

        try await waitForOp("error", on: port)
        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["code"] as? Int, 1006)
    }

    func testOpBeforeOpenIsAProtocolError() async throws {
        let (_, port) = makeSession()
        port.deliver(["op": "send", "text": "too early"])

        let failure = try await waitForOp("error", on: port)
        XCTAssertEqual(failure["message"] as? String, "no socket is open")
        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["code"] as? Int, 1006)
        XCTAssertEqual(closed["reason"] as? String, "protocol error")
        XCTAssertEqual(closed["wasClean"] as? Bool, false)
        try await waitUntil("the port to be disconnected") { port.disconnectCount > 0 }
    }

    func testSecondOpenIsAProtocolError() async throws {
        let (_, port) = try await openSocket()
        port.deliver(["op": "open", "url": echoURL, "protocols": [String]()])

        let failure = try await waitForOp("error", on: port)
        XCTAssertEqual(failure["message"] as? String, "a socket is already open")
        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["reason"] as? String, "protocol error")
    }

    func testUnknownOpIsAProtocolError() async throws {
        let (_, port) = try await openSocket()
        port.deliver(["op": "teleport"])

        try await waitForOp("error", on: port)
        let closed = try await waitForOp("close", on: port)
        XCTAssertEqual(closed["reason"] as? String, "protocol error")
    }

    func testSendAfterCloseIsIgnored() async throws {
        let (_, port) = try await openSocket()
        port.deliver(["op": "close", "code": 1000, "reason": "bye"])
        try await waitForOp("close", on: port)

        port.deliver(["op": "send", "text": "late"])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(port.sent.filter { $0["op"] as? String == "close" }.count, 1,
                       "a closed session must not send a second close: \(port.sentOps)")
        XCTAssertFalse(port.sent.contains { $0["op"] as? String == "error" },
                       "nor an error: the worker is already gone")
    }
}

// MARK: - Fake worker port

/// The worker side of a relay port, driven by the test: it records what the
/// session sent and injects what the worker would say.
final class FakeRelayPort: WebSocketRelayPort, @unchecked Sendable {

    private let lock = NSLock()
    private var _sent: [[String: Any]] = []
    private var _disconnectCount = 0

    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    /// Everything the session sent the worker, in order.
    var sent: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    /// Just the `op` of each message, for failure messages.
    var sentOps: [String] { sent.compactMap { $0["op"] as? String } }

    var disconnectCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _disconnectCount
    }

    func send(_ message: [String: Any], completion: (() -> Void)?) {
        lock.lock()
        _sent.append(message)
        lock.unlock()
        completion?()
    }

    func disconnect() {
        lock.lock()
        _disconnectCount += 1
        lock.unlock()
    }

    // MARK: Test drivers

    /// Deliver a message from the worker.
    func deliver(_ message: [String: Any]) { onMessage?(message) }

    /// The worker (or WebKit, on context unload) dropped the port.
    func remoteDisconnect() { onDisconnect?() }
}
