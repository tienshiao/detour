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
/// `Sendable`: the listener and connections are Network.framework objects
/// driven from `queue`; the mutable state is behind `state`.
nonisolated final class AutomationEndpoint: Sendable {

    typealias Handler = @Sendable (AutomationHTTP.Request) async -> AutomationHTTP.Response

    private struct State {
        var port: UInt16 = 0
        var connections: [ObjectIdentifier: NWConnection] = [:]
        /// Connections that have sent at least one authorised request. The
        /// others are closed after `headTimeout`.
        var authorized: Set<ObjectIdentifier> = []
        var stopped = false
    }

    /// Connections open at once. Any local process, another account's
    /// included, can connect before it shows a token: without a bound, idle
    /// connections would use up Detour's file descriptors.
    let maximumConnections: Int
    /// How long a connection may stay open without an authorised request.
    let headTimeout: TimeInterval

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.detourbrowser.automation-endpoint")
    private let token: Mutex<String>
    private let handler: Handler
    private let state = Mutex(State())

    struct StartFailed: Error, CustomStringConvertible {
        var description: String
    }

    /// - Parameter port: 0 lets the system pick one; `start()` returns it.
    init(port: UInt16, token: String, maximumConnections: Int = 64, headTimeout: TimeInterval = 10,
         handler: @escaping Handler) throws {
        self.token = Mutex(token)
        self.handler = handler
        self.maximumConnections = maximumConnections
        self.headTimeout = headTimeout
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    var port: UInt16 { state.withLock { $0.port } }

    /// Replaces the token (Reset Token); requests from then on need the new one.
    func setToken(_ newToken: String) {
        token.withLock { $0 = newToken }
    }

    /// The token requests must carry now.
    var currentToken: String { token.withLock { $0 } }

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
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A connection that shows no token in time is closed, so one that
        // trickles a head (or sends nothing) cannot hold its place forever.
        queue.asyncAfter(deadline: .now() + headTimeout) { [weak self] in
            let idle = self?.state.withLock { $0.connections[id] != nil && !$0.authorized.contains(id) } ?? false
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
        let request: AutomationHTTP.Request
        let consumed: Int
        do {
            switch try AutomationHTTP.parse(buffer) {
            case .incomplete:
                // The head alone decides authorisation: refuse now rather than
                // buffer up to `maximumRequestSize` for a client that has no
                // token. The body is unread, so the connection closes.
                if let (head, _) = try AutomationHTTP.parseHead(buffer),
                   case .refused(let status, let reason) = authorize(head) {
                    refuse(status: status, reason: reason, on: connection, closing: true, rest: nil)
                    return true
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
        case .allowed:
            _ = state.withLock { $0.authorized.insert(ObjectIdentifier(connection)) }
            let handler = self.handler
            Task {
                let response = await handler(request)
                self.send(response, on: connection, closing: closing, rest: rest)
            }
        }
        return true
    }

    private func authorize(_ request: AutomationHTTP.Request) -> AutomationAuthorization.Decision {
        AutomationAuthorization.decide(headers: request.headers, token: token.withLock { $0 }, port: port)
    }

    private func refuse(status: Int, reason: String, on connection: NWConnection, closing: Bool, rest: Data?) {
        log.notice("Automation request refused (\(status, privacy: .public)): \(reason, privacy: .public)")
        let headers = status == 401 ? AutomationAuthorization.unauthorizedHeaders : []
        send(.text(reason, status: status, headers: headers), on: connection, closing: closing, rest: rest)
    }

    private func send(_ response: AutomationHTTP.Response, on connection: NWConnection, closing: Bool, rest: Data?) {
        let data = AutomationHTTP.serialize(response, closing: closing)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
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
