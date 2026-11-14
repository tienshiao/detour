import AppKit
import Network
import os
import Synchronization

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "automation")

/// The automation endpoint's socket (TASK-228.1): HTTP/1.1 on 127.0.0.1 only.
/// Each request is parsed and authorised here, on the listener's queue, and
/// only an authorised one is handed to `handler` (the main-actor MCP server).
/// Responses go back on the same connection, which stays open for the next
/// request unless the client asks to close it.
///
/// With per-client credentials (the user's setting, TASK-228.5), a
/// `POST /mcp/authorize` that passed the Host and Origin checks goes to
/// `authorizer` instead (the approval prompt). Its head is checked before
/// the body is read (POST, JSON, a Content-Length of at most 4 KB); while
/// the prompt is up the connection is held, exempt from `headTimeout` but
/// never authorised, at most `maximumHeldAuthorizations` at once, and the
/// answer always closes it, so no connection outlives the deadline without
/// having sent an authorised request except while a prompt it asked for is
/// up (5 minutes, or up to 10 for a request queued behind another prompt
/// for its name). A client that closes its connection meanwhile
/// withdraws its request (`AutomationRequestCancellation`).
///
/// `Sendable`: the listener and connections are Network.framework objects
/// driven from `queue`; the mutable state is behind `state`.
nonisolated final class AutomationEndpoint: Sendable {

    typealias Handler = @Sendable (AutomationHTTP.Request) async -> AutomationHTTP.Response
    typealias AuthorizeHandler = @Sendable (AutomationHTTP.Request, AutomationRequestCancellation) async
        -> AutomationAuthorizeOutcome

    private struct State {
        var port: UInt16 = 0
        var connections: [ObjectIdentifier: NWConnection] = [:]
        /// Connections that have sent at least one authorised request. The
        /// others are closed after `headTimeout`.
        var authorized: Set<ObjectIdentifier> = []
        /// Connections holding an authorize request (waiting for the user's
        /// answer): spared by `headTimeout`, closed once answered.
        var held: Set<ObjectIdentifier> = []
        /// The approved client whose token each connection's last authorised
        /// request carried, so revoking it closes them (TASK-228.5).
        var clients: [ObjectIdentifier: UUID] = [:]
        var stopped = false
    }

    /// Connections open at once. Any local process, another account's
    /// included, can connect before it shows a token: without a bound, idle
    /// connections would use up Detour's file descriptors.
    let maximumConnections: Int
    /// How long a connection may stay open without an authorised request.
    let headTimeout: TimeInterval
    /// Authorize requests held at once (prompts shown and requests waiting
    /// for one); `AutomationApprovals` has tighter limits of its own.
    let maximumHeldAuthorizations: Int

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.detourbrowser.automation-endpoint")
    private let credentials: Mutex<AutomationAuthorization.Credentials>
    private let handler: Handler
    private let authorizer: AuthorizeHandler?
    private let state = Mutex(State())

    struct StartFailed: Error, CustomStringConvertible {
        var description: String
    }

    /// A test run's endpoint: one shared token.
    /// - Parameter port: 0 lets the system pick one; `start()` returns it.
    convenience init(port: UInt16, token: String, maximumConnections: Int = 64, headTimeout: TimeInterval = 10,
                     handler: @escaping Handler) throws {
        try self.init(port: port, credentials: .shared(token: token), maximumConnections: maximumConnections,
                      headTimeout: headTimeout, handler: handler)
    }

    /// - Parameter authorizer: answers `POST /mcp/authorize` with per-client
    ///   credentials; without one that route is 404.
    init(port: UInt16, credentials: AutomationAuthorization.Credentials, maximumConnections: Int = 64,
         headTimeout: TimeInterval = 10, maximumHeldAuthorizations: Int = 8,
         handler: @escaping Handler, authorizer: AuthorizeHandler? = nil) throws {
        self.credentials = Mutex(credentials)
        self.handler = handler
        self.authorizer = authorizer
        self.maximumConnections = maximumConnections
        self.headTimeout = headTimeout
        self.maximumHeldAuthorizations = maximumHeldAuthorizations
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    var port: UInt16 { state.withLock { $0.port } }

    /// Replaces a test run's shared token (Reset Token); requests from then
    /// on need the new one. Per-client credentials are left as they are.
    func setToken(_ newToken: String) {
        credentials.withLock { credentials in
            if case .shared = credentials { credentials = .shared(token: newToken) }
        }
    }

    /// The shared token requests must carry now; nil with per-client
    /// credentials, where no shared token is accepted.
    var currentToken: String? {
        credentials.withLock { credentials in
            if case .shared(let token) = credentials { return token }
            return nil
        }
    }

    /// Starts listening; returns the port once the listener is ready.
    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            let claim: @Sendable () -> Bool = { once.claim() }
            listener.stateUpdateHandler = { [listener, weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self?.state.withLock { $0.port = port }
                    if claim() { continuation.resume(returning: port) }
                case .failed(let error):
                    if claim() { continuation.resume(throwing: StartFailed(description: "\(error)")) }
                    else { log.error("Automation endpoint failed: \(String(describing: error), privacy: .public)") }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [listener] in
                if claim() {
                    listener.cancel()
                    continuation.resume(throwing: StartFailed(description: "the listener did not become ready"))
                }
            }
        }
    }

    /// Stops listening and closes every connection.
    func stop() {
        let connections = state.withLock { state in
            state.stopped = true
            defer {
                state.connections.removeAll()
                state.authorized.removeAll()
                state.held.removeAll()
                state.clients.removeAll()
            }
            return Array(state.connections.values)
        }
        for connection in connections { connection.cancel() }
        listener.cancel()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let maximum = maximumConnections
        let accepted = state.withLock { state in
            guard !state.stopped, state.connections.count < maximum else { return false }
            state.connections[id] = connection
            return true
        }
        guard accepted else {
            log.notice("Automation connection refused: \(maximum, privacy: .public) already open")
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.state.withLock { state in
                    state.connections.removeValue(forKey: id)
                    state.authorized.remove(id)
                    state.held.remove(id)
                    state.clients.removeValue(forKey: id)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A connection that shows no token in time is closed, so one that
        // trickles a head (or sends nothing) cannot hold its place forever.
        // One waiting for the user's answer to its authorize request is
        // spared: that answer closes it.
        queue.asyncAfter(deadline: .now() + headTimeout) { [weak self] in
            let idle = self?.state.withLock {
                $0.connections[id] != nil && !$0.authorized.contains(id) && !$0.held.contains(id)
            } ?? false
            if idle { connection.cancel() }
        }
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        // A complete request may already be buffered (pipelining).
        if !buffer.isEmpty, process(connection, buffer: buffer) { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let data, !data.isEmpty, self.process(connection, buffer: buffer) { return }
            if isComplete { connection.cancel(); return }
            self.read(connection, buffer: buffer)
        }
    }

    /// Answers the first request in `buffer` if it is complete. Returns true
    /// when it took over the connection (answered, or closed it).
    private func process(_ connection: NWConnection, buffer: Data) -> Bool {
        var request: AutomationHTTP.Request
        let consumed: Int
        do {
            switch try AutomationHTTP.parse(buffer) {
            case .incomplete:
                // The head alone decides authorisation: refuse now rather than
                // buffer up to `maximumRequestSize` for a client that has no
                // token. The body is unread, so the connection closes. An
                // authorize request is held to its own small size.
                if let (head, _) = try AutomationHTTP.parseHead(buffer) {
                    switch authorize(head) {
                    case .refused(let status, let reason):
                        refuse(status: status, reason: reason, on: connection, closing: true, rest: nil)
                        return true
                    case .authorizationRequest:
                        if let (status, reason) = AutomationAuthorization.authorizationHeadRefusal(head) {
                            refuse(status: status, reason: reason, on: connection, closing: true, rest: nil)
                            return true
                        }
                    case .allowed, .allowedClient:
                        break
                    }
                }
                return false
            case .request(let parsed, let used):
                request = parsed
                consumed = used
            }
        } catch {
            let status: Int
            switch error {
            case .tooLarge: status = 413
            case .unsupportedTransferEncoding: status = 501
            case .malformed: status = 400
            }
            send(.text("Bad request: \(error)", status: status), on: connection, closing: true, rest: nil)
            return true
        }
        let rest = Data(buffer.dropFirst(consumed))
        let closing = request.closesConnection

        switch authorize(request) {
        case .refused(let status, let reason):
            refuse(status: status, reason: reason, on: connection, closing: closing, rest: rest)
            return true
        case .authorizationRequest:
            holdAuthorization(request, on: connection)
            return true
        case .allowedClient(let client):
            request.client = client
            if case .perClient(let store) = credentials.withLock({ $0 }) {
                store.noteUsed(clientID: client.id, now: Date())
            }
        case .allowed:
            break
        }
        state.withLock { state in
            let id = ObjectIdentifier(connection)
            state.authorized.insert(id)
            state.clients[id] = request.client?.id
        }
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.send(response, on: connection, closing: closing, rest: rest)
        }
        return true
    }

    /// Closes the connections whose last authorised request carried
    /// `clientID`'s token (it was revoked). Otherwise they would stay open,
    /// spared by `headTimeout` as authorised ones are, holding places under
    /// `maximumConnections` that nothing they send can use.
    func closeConnections(clientID: UUID) {
        let closing = state.withLock { state in
            state.clients.filter { $0.value == clientID }.compactMap { state.connections[$0.key] }
        }
        for connection in closing { connection.cancel() }
    }

    private func authorize(_ request: AutomationHTTP.Request) -> AutomationAuthorization.Decision {
        AutomationAuthorization.decide(path: request.path, headers: request.headers,
                                       credentials: credentials.withLock { $0 }, port: port)
    }

    /// Hands an authorize request to `authorizer` and holds the connection
    /// until it answers; the answer always closes the connection. A client
    /// that closes its side first withdraws the request. When the answer
    /// cannot be sent, its `undo` runs (an approval nobody received is
    /// revoked).
    private func holdAuthorization(_ request: AutomationHTTP.Request, on connection: NWConnection) {
        if let (status, reason) = AutomationAuthorization.authorizationHeadRefusal(request) {
            refuse(status: status, reason: reason, on: connection, closing: true, rest: nil)
            return
        }
        guard let authorizer else {
            refuse(status: 404, reason: "Not found", on: connection, closing: true, rest: nil)
            return
        }
        let id = ObjectIdentifier(connection)
        let maximum = maximumHeldAuthorizations
        let held = state.withLock { state in
            guard state.held.count < maximum else { return false }
            state.held.insert(id)
            return true
        }
        guard held else {
            refuse(status: 429, reason: "Too many authorize requests are waiting", on: connection, closing: true,
                   rest: nil)
            return
        }
        let cancellation = AutomationRequestCancellation()
        // Nothing more is expected on the connection: any end of it (the
        // client closed it, or sent more) withdraws the request.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
            cancellation.cancel()
            connection.cancel()
        }
        Task {
            let outcome = await authorizer(request, cancellation)
            self.state.withLock { _ = $0.held.remove(id) }
            if cancellation.isCancelled {
                outcome.undo?()
                connection.cancel()
                return
            }
            self.send(outcome.response, on: connection, closing: true, rest: nil, onFailure: outcome.undo)
        }
    }

    private func refuse(status: Int, reason: String, on connection: NWConnection, closing: Bool, rest: Data?) {
        log.notice("Automation request refused (\(status, privacy: .public)): \(reason, privacy: .public)")
        let headers = status == 401 ? AutomationAuthorization.unauthorizedHeaders : []
        send(.text(reason, status: status, headers: headers), on: connection, closing: closing, rest: rest)
    }

    private func send(_ response: AutomationHTTP.Response, on connection: NWConnection, closing: Bool, rest: Data?,
                      onFailure: (@Sendable () -> Void)? = nil) {
        let data = AutomationHTTP.serialize(response, closing: closing)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { onFailure?() }
            guard let self, error == nil, !closing, let rest else {
                connection.cancel()
                return
            }
            self.queue.async { self.read(connection, buffer: rest) }
        })
    }
}

/// True for the first caller of `claim()` only.
nonisolated private final class OnceFlag: Sendable {
    private let used = Mutex(false)

    func claim() -> Bool {
        used.withLock { used in
            defer { used = true }
            return !used
        }
    }
}
