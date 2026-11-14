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
        var stopped = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.detourbrowser.automation-endpoint")
    private let token: String
    private let handler: Handler
    private let state = Mutex(State())

    struct StartFailed: Error, CustomStringConvertible {
        var description: String
    }

    /// - Parameter port: 0 lets the system pick one; `start()` returns it.
    init(port: UInt16, token: String, handler: @escaping Handler) throws {
        self.token = token
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    var port: UInt16 { state.withLock { $0.port } }

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
            defer { state.connections.removeAll() }
            return Array(state.connections.values)
        }
        for connection in connections { connection.cancel() }
        listener.cancel()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let accepted = state.withLock { state in
            guard !state.stopped else { return false }
            state.connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard accepted else { connection.cancel(); return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.state.withLock { _ = $0.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            default:
                break
            }
        }
        connection.start(queue: queue)
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
            let handler = self.handler
            Task {
                let response = await handler(request)
                self.send(response, on: connection, closing: closing, rest: rest)
            }
        }
        return true
    }

    private func authorize(_ request: AutomationHTTP.Request) -> AutomationAuthorization.Decision {
        AutomationAuthorization.decide(headers: request.headers, token: token, port: port)
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

/// Starts and stops the automation endpoint for the app (TASK-228.1): asks
/// `AutomationGate` at launch, creates the token, writes the endpoint file once
/// listening, and removes it at quit.
final class AutomationController {

    static let shared = AutomationController()

    private(set) var mode: AutomationGate.Mode = .off
    private(set) var server: MCPServer?
    private(set) var tools: AutomationTools?
    private var endpoint: AutomationEndpoint?
    private var directory: URL?
    /// Set by `stop()`, so a start still in flight at quit neither keeps
    /// listening nor writes an endpoint file nothing would remove.
    private var stopped = false

    /// What the server tells a client at initialize: how the ids fit together.
    static let instructions = """
        Detour browser automation. list_windows gives each window a window_id; list_spaces and list_tabs \
        describe spaces and their sidebar items. select_tab, open_url and run_menu_item act on a window by \
        window_id. Private windows and spaces are never reachable. Failed calls return isError with \
        structuredContent.error.code, a stable code such as unknown_window or unknown_tab.
        """

    func startIfEnabled(isRunningUnitTests: Bool) {
        let defaults = UserDefaultsScope.defaults
        let (mode, refusal) = AutomationGate.mode(
            environment: ProcessInfo.processInfo.environment,
            settingEnabled: defaults.bool(forKey: AutomationGate.enabledDefaultsKey),
            settingPort: defaults.object(forKey: AutomationGate.portDefaultsKey) as? Int,
            isRunningUnitTests: isRunningUnitTests)
        if let refusal {
            log.error("Automation endpoint not started for the test run: \(refusal.description, privacy: .public)")
        }
        guard let port = mode.port else { return }
        self.mode = mode
        let directory = detourDataDirectory()
        self.directory = directory
        Task { await start(port: port, in: directory) }
    }

    private func start(port: UInt16, in directory: URL) async {
        do {
            let token = try AutomationCredentials.loadOrCreateToken(in: directory)
            let tools = AutomationTools(environment: .live)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let server = MCPServer(tools: tools.all, serverVersion: version, instructions: Self.instructions)
            let endpoint = try AutomationEndpoint(port: port, token: token) { request in
                await server.handle(request)
            }
            let listening = try await endpoint.start()
            guard !stopped else {
                endpoint.stop()
                return
            }
            try AutomationCredentials.writeEndpointFile(port: listening, token: token,
                                                        pid: ProcessInfo.processInfo.processIdentifier,
                                                        testRun: mode.isTestRun, in: directory)
            self.tools = tools
            self.server = server
            self.endpoint = endpoint
            log.notice("Automation endpoint listening on \(AutomationCredentials.endpointURL(port: listening), privacy: .public)")
        } catch {
            log.error("Automation endpoint did not start: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        stopped = true
        endpoint?.stop()
        endpoint = nil
        server?.sessions.endAll()
        if let directory {
            AutomationCredentials.removeEndpointFile(in: directory, pid: ProcessInfo.processInfo.processIdentifier)
        }
    }
}
