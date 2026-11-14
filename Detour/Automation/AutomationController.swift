import AppKit
import os

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "automation")

/// Runs the automation endpoint for the app (TASK-228.1): starts it at launch
/// when `AutomationGate` allows, turns it on and off from Settings and from
/// the window's indicator, resets the token, disconnects clients, and ends
/// the sessions of clients that went quiet. Everything that shows its state
/// (the indicator in every window, the Settings section) listens for
/// `didChangeNotification`.
final class AutomationController {

    static let shared = AutomationController()

    /// Posted when the status, the connected clients or the blocked clients
    /// change. No user info: read the controller.
    static let didChangeNotification = Notification.Name("DetourAutomationControllerDidChange")

    enum Status: Equatable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)

        var isOn: Bool {
            switch self {
            case .starting, .listening: true
            case .off, .failed: false
            }
        }
    }

    private(set) var status: Status = .off {
        didSet { if status != oldValue { changed() } }
    }
    /// How the endpoint was turned on (a test run, or the user's setting).
    private(set) var mode: AutomationGate.Mode = .off
    private(set) var server: MCPServer?
    private(set) var tools: AutomationTools?
    private var endpoint: AutomationEndpoint?
    /// Bumped by every start and stop: a start still in flight when it
    /// changes neither keeps listening nor writes an endpoint file.
    private var generation = 0
    private var expiryTimer: Timer?

    /// A session quiet for this long has ended (its client went away
    /// without a DELETE, which most clients never send).
    static let idleSessionLimit: TimeInterval = 10 * 60

    private let directory: () -> URL
    private let defaults: UserDefaults
    private let environment: () -> AutomationEnvironment
    /// Tests listen on a port of their own instead of the setting's.
    private let portOverride: UInt16?

    init(directory: @escaping () -> URL = { detourDataDirectory() },
         defaults: UserDefaults = UserDefaultsScope.defaults,
         environment: @escaping () -> AutomationEnvironment = { .live },
         portOverride: UInt16? = nil) {
        self.directory = directory
        self.defaults = defaults
        self.environment = environment
        self.portOverride = portOverride
    }

    /// What the server tells a client at initialize: how the ids fit together.
    static let instructions = """
        Detour browser automation. list_windows gives each window a window_id; list_spaces and list_tabs \
        describe spaces and their sidebar items; a tab's tab_id is the context the page tools take. \
        select_tab, open_url, run_menu_item, click, type_text, press_key and screenshot act on a window or a \
        tab. evaluate_js, read_page, console_messages, network_requests, wait_for and wake_tab read a tab's \
        page, whether or not a window shows it. Private windows and spaces are never reachable. Failed calls return isError with \
        structuredContent.error.code, a stable code such as unknown_window or selector_no_match.
        """

    // MARK: State for the UI

    /// The clients connected now, oldest first.
    var sessions: [MCPSessionStore.Session] { server?.sessions.orderedSessions ?? [] }

    /// Client names the user disconnected, sorted.
    var blockedClientNames: [String] { (server?.sessions.blockedClientNames ?? []).sorted() }

    /// The user's setting (what Settings shows).
    var isEnabledInSettings: Bool { defaults.bool(forKey: AutomationGate.enabledDefaultsKey) }

    /// The URL clients use, while listening.
    var endpointURL: String? {
        if case .listening(let port) = status { return AutomationCredentials.endpointURL(port: port) }
        return nil
    }

    /// The token clients present (created on first use). While listening,
    /// the endpoint's own: a token file removed or damaged since the start
    /// would otherwise be replaced here by one the endpoint refuses.
    func token() throws -> String {
        if let endpoint { return endpoint.currentToken }
        return try AutomationCredentials.loadOrCreateToken(in: directory())
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    // MARK: Starting and stopping

    /// At launch: listens when the setting is on, or for a test run with an
    /// isolated data directory.
    func startIfEnabled(isRunningUnitTests: Bool) {
        let (mode, refusal) = AutomationGate.mode(
            environment: ProcessInfo.processInfo.environment,
            settingEnabled: defaults.bool(forKey: AutomationGate.enabledDefaultsKey),
            settingPort: defaults.object(forKey: AutomationGate.portDefaultsKey) as? Int,
            isRunningUnitTests: isRunningUnitTests)
        if let refusal {
            log.error("Automation endpoint not started for the test run: \(refusal.description, privacy: .public)")
        }
        guard mode != .off else { return }
        start(mode: mode)
    }

    /// The Settings checkbox and the indicator's Turn Off: saves the setting
    /// and starts or stops the endpoint to match.
    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: AutomationGate.enabledDefaultsKey)
        if enabled {
            guard !status.isOn else { return }
            let port = AutomationGate.userPort(
                settingPort: defaults.object(forKey: AutomationGate.portDefaultsKey) as? Int)
            // A test run keeps its own port when turned back on.
            start(mode: mode.isTestRun ? mode : .userEnabled(port: port))
        } else {
            stop()
        }
    }

    private func start(mode: AutomationGate.Mode) {
        guard let port = portOverride ?? mode.port else { return }
        generation += 1
        let started = generation
        self.mode = mode
        status = .starting
        let directory = directory()
        Task { await self.start(port: port, in: directory, generation: started) }
    }

    private func start(port: UInt16, in directory: URL, generation started: Int) async {
        // Kept outside the `do`, so a failure after it is listening stops it
        // rather than leaving a listener nothing can turn off.
        var pending: AutomationEndpoint?
        do {
            let initialToken = try AutomationCredentials.loadOrCreateToken(in: directory)
            let tools = AutomationTools(environment: environment())
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let server = MCPServer(tools: tools.all, serverVersion: version, instructions: Self.instructions)
            let endpoint = try AutomationEndpoint(port: port, token: initialToken) { request in
                await server.handle(request)
            }
            pending = endpoint
            let listening = try await endpoint.start()
            guard started == generation else {
                endpoint.stop()
                return
            }
            // Reset Token may have run while this was starting: listen with,
            // and publish, the token on disk now.
            let token = try AutomationCredentials.loadOrCreateToken(in: directory)
            if token != initialToken { endpoint.setToken(token) }
            try AutomationCredentials.writeEndpointFile(port: listening, token: token,
                                                        pid: ProcessInfo.processInfo.processIdentifier,
                                                        testRun: mode.isTestRun, in: directory)
            server.sessions.onChange = { [weak self] in self?.changed() }
            self.tools = tools
            self.server = server
            self.endpoint = endpoint
            startExpiryTimer()
            AutomationPageCapture.shared.start(store: environment().store)
            status = .listening(port: listening)
            log.notice("Automation endpoint listening on \(AutomationCredentials.endpointURL(port: listening), privacy: .public)")
        } catch {
            pending?.stop()
            guard started == generation else { return }
            status = .failed(String(describing: error))
            log.error("Automation endpoint did not start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops listening, ends every session and forgets disconnected clients.
    func stop() {
        generation += 1
        expiryTimer?.invalidate()
        expiryTimer = nil
        endpoint?.stop()
        endpoint = nil
        server?.sessions.onChange = nil
        server = nil
        tools = nil
        AutomationPageCapture.shared.stop()
        AutomationCredentials.removeEndpointFile(in: directory(), pid: ProcessInfo.processInfo.processIdentifier)
        status = .off
    }

    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledMainTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.expireIdleSessions(now: Date())
        }
    }

    /// Ends sessions quiet for longer than `idleSessionLimit`.
    func expireIdleSessions(now: Date) {
        server?.sessions.expire(idleFor: Self.idleSessionLimit, now: now)
    }

    // MARK: Clients and the token

    /// Refuses `sessionID`'s client name until it is allowed again, and ends
    /// every session under that name: one left running would keep acting
    /// while the name shows as disconnected.
    func disconnect(sessionID: String) {
        guard let sessions = server?.sessions, let session = sessions.sessions[sessionID] else { return }
        sessions.block(session.clientName)
        for other in sessions.orderedSessions where other.clientName == session.clientName {
            sessions.end(other.id)
        }
    }

    func allow(clientName: String) {
        server?.sessions.unblock(clientName)
    }

    /// A new token: every connected client is disconnected and must be set up
    /// again with it (or reconnect through the bundled helper, which reads it).
    @discardableResult
    func resetToken() throws -> String {
        let directory = directory()
        let token = try AutomationCredentials.resetToken(in: directory)
        endpoint?.setToken(token)
        server?.sessions.endAll()
        if case .listening(let port) = status {
            try AutomationCredentials.writeEndpointFile(port: port, token: token,
                                                        pid: ProcessInfo.processInfo.processIdentifier,
                                                        testRun: mode.isTestRun, in: directory)
        }
        changed()
        return token
    }
}

/// What the window's automation indicator says (TASK-228.1, AC #10, #17).
enum AutomationIndicator {

    /// The capsule's title: the first client's name, and how many more. Nil
    /// hides the indicator (nothing connected).
    static func title(for sessions: [MCPSessionStore.Session]) -> String? {
        guard let first = sessions.first else { return nil }
        let others = sessions.count - 1
        return others == 0 ? first.clientName : "\(first.clientName) + \(others)"
    }

    /// How long ago, for the menu ("just now", "5 min ago", "2 h ago").
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600)) h ago"
    }
}
