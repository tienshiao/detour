import AppKit
import os

nonisolated private let log = Logger(subsystem: "com.detourbrowser.mac", category: "automation")

/// Runs the automation endpoint for the app (TASK-228.1): starts it at launch
/// when `AutomationGate` allows, turns it on and off from Settings and from
/// the window's indicator, disconnects clients, and ends the sessions of
/// clients that went quiet. Everything that shows its state (the indicator
/// in every window, the Settings section) listens for
/// `didChangeNotification`.
///
/// Who may connect depends on the mode (TASK-228.5):
/// - A test run keeps one shared token (`mcp-token`, written into the
///   endpoint file) and never prompts; Reset Token replaces it, and
///   Disconnect blocks a client's name (a "please stop": the token is
///   everyone's).
/// - The user's setting takes only approved clients' tokens
///   (`AutomationClientStore`). A client asks at `/mcp/authorize`, the user
///   answers Detour's prompt (`AutomationApprovals`), and Disconnect or
///   Revoke deletes the client's token. The endpoint file carries no token,
///   and a leftover `mcp-token` is deleted at start.
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
    /// The approval flow, while the user's endpoint listens.
    private(set) var approvals: AutomationApprovals?
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
    /// Shows the approval prompt: the panel, or a fake in tests.
    private let makePrompter: () -> AutomationApprovalPrompter

    /// The approved clients of the user's endpoint, read from the data
    /// directory once: the endpoint, Settings and the indicator share it.
    private(set) lazy var clientStore = AutomationClientStore(directory: directory())

    init(directory: @escaping () -> URL = { detourDataDirectory() },
         defaults: UserDefaults = UserDefaultsScope.defaults,
         environment: @escaping () -> AutomationEnvironment = { .live },
         portOverride: UInt16? = nil,
         prompter: @escaping () -> AutomationApprovalPrompter = { AutomationApprovalPanelPrompter() }) {
        self.directory = directory
        self.defaults = defaults
        self.environment = environment
        self.portOverride = portOverride
        self.makePrompter = prompter
    }

    /// What the server tells a client at initialize: how the ids fit together.
    static let instructions = """
        Detour browser automation. list_windows gives each window a window_id; list_spaces and list_tabs \
        describe spaces and their sidebar items; a tab's tab_id is the context the page tools take. \
        select_tab, open_url, run_menu_item, click, type_text, press_key and screenshot act on a window or a \
        tab. evaluate_js, read_page, console_messages, network_requests, wait_for and wake_tab read a tab's \
        page, whether or not a window shows it. Extensions: list_extensions names each by id; \
        open_extension_context opens its popup or options page, and popup:<ext>, options:<ext> and worker:<ext> \
        (ext is an id or manifest name) are contexts the page tools take; call_extension_api and \
        read_extension_global reach its service worker. install_extension, uninstall_extension, \
        set_extension_enabled and set_extension_permission work only in a test run. Private windows, spaces and \
        the Private profile's tabs and extension contexts are reachable only while the user allows it in Detour's \
        Settings (otherwise private_unreachable). Failed calls return isError with \
        structuredContent.error.code, a stable code such as unknown_window or selector_no_match.
        """

    // MARK: State for the UI

    /// The clients connected now, oldest first.
    var sessions: [MCPSessionStore.Session] { server?.sessions.orderedSessions ?? [] }

    /// Client names the user disconnected in a test run, sorted.
    var blockedClientNames: [String] { (server?.sessions.blockedClientNames ?? []).sorted() }

    /// Whether clients need the user's approval: everywhere but a test run.
    var usesClientApproval: Bool { !mode.isTestRun }

    /// The clients the user approved, oldest first.
    var approvedClients: [AutomationClientRecord] { clientStore.records }

    /// The user's setting (what Settings shows).
    var isEnabledInSettings: Bool { defaults.bool(forKey: AutomationGate.enabledDefaultsKey) }

    /// Whether the user allows agents to use Private windows (TASK-228.5),
    /// read now: every check asks again, so turning it off refuses at once.
    var allowsPrivateInSettings: Bool { defaults.bool(forKey: AutomationGate.allowPrivateDefaultsKey) }

    /// The Settings switch. Turning it off also removes page capture from
    /// Private pages and forgets their records, stops the Private profile's
    /// workers' parks and forgets its extension console and stub counts.
    func setAllowsPrivate(_ allowed: Bool) {
        defaults.set(allowed, forKey: AutomationGate.allowPrivateDefaultsKey)
        Self.privateAccessChanged(allowed: allowed)
        changed()
    }

    /// What follows a change of the Private setting outside the tools, which
    /// read it per call.
    static func privateAccessChanged(allowed: Bool) {
        AutomationPageCapture.shared.privateAccessChanged(allowed: allowed)
        guard !allowed else { return }
        let id = TabStore.incognitoProfileID
        AutomationExtensionChannel.shared.closeParks(profileID: id)
        AutomationExtensionConsole.shared.forget(profileID: id)
        AutomationExtensionStubCalls.shared.forget(profileID: id)
        AutomationExtensionPopups.shared.close(profileID: id)
    }

    /// The URL clients use, while listening.
    var endpointURL: String? {
        if case .listening(let port) = status { return AutomationCredentials.endpointURL(port: port) }
        return nil
    }

    /// A test run's shared token (created on first use). While listening,
    /// the endpoint's own: a token file removed or damaged since the start
    /// would otherwise be replaced here by one the endpoint refuses. The
    /// user's endpoint has none, and none is created for it.
    func token() throws -> String {
        guard mode.isTestRun else { throw Self.noSharedToken }
        if let token = endpoint?.currentToken { return token }
        return try AutomationCredentials.loadOrCreateToken(in: directory())
    }

    private static let noSharedToken = AutomationCredentials.FileError(
        description: "Only a test run has a shared token; with the user's setting each client has its own")

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

    /// The Settings switch and the indicator's Turn Off: saves the setting
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

    /// Starts listening in `mode` (internal for tests, which start a test
    /// run this way).
    func start(mode: AutomationGate.Mode) {
        guard let port = portOverride ?? mode.port else { return }
        generation += 1
        let started = generation
        self.mode = mode
        // In this main-actor turn, before any extension background's first
        // message is handled: a background parks for the endpoint's commands
        // only while the channel is open when it starts (TASK-228.2). The
        // extension console and the stub-call counts start in the same turn,
        // so a worker's start-up errors and stub calls are kept too (a
        // context told `stop` by the counting stops reporting for good).
        AutomationExtensionChannel.shared.isOpen = true
        AutomationExtensionConsole.shared.start()
        AutomationExtensionStubCalls.shared.start()
        status = .starting
        let directory = directory()
        Task { await self.start(port: port, in: directory, generation: started) }
    }

    private func start(port: UInt16, in directory: URL, generation started: Int) async {
        // Kept outside the `do`, so a failure after it is listening stops it
        // rather than leaving a listener nothing can turn off.
        var pending: AutomationEndpoint?
        var pendingApprovals: AutomationApprovals?
        do {
            let testRun = mode.isTestRun
            let credentials: AutomationAuthorization.Credentials
            var initialToken: String?
            if testRun {
                let token = try AutomationCredentials.loadOrCreateToken(in: directory)
                initialToken = token
                credentials = .shared(token: token)
            } else {
                // The user's endpoint never accepts a shared token: one left
                // from before (or from a test run in this directory) goes.
                AutomationCredentials.removeTokenFile(in: directory)
                credentials = .perClient(clientStore)
            }
            var toolEnvironment = environment()
            toolEnvironment.isTestRun = testRun
            // The tools read the Private setting from these defaults, per call.
            toolEnvironment.allowsPrivate = { [defaults] in defaults.bool(forKey: AutomationGate.allowPrivateDefaultsKey) }
            let tools = AutomationTools(environment: toolEnvironment)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            let server = MCPServer(tools: tools.all, serverVersion: version, instructions: Self.instructions)
            var authorizer: AutomationEndpoint.AuthorizeHandler?
            if !testRun {
                let store = clientStore
                server.isClientApproved = { store.contains(clientID: $0) }
                let approvals = AutomationApprovals(store: store, prompter: makePrompter())
                approvals.onApproval = { [weak self] in self?.changed() }
                pendingApprovals = approvals
                authorizer = { request, cancellation in await approvals.handle(request, cancellation: cancellation) }
            }
            let endpoint = try AutomationEndpoint(port: port, credentials: credentials, handler: { request in
                await server.handle(request)
            }, authorizer: authorizer)
            pending = endpoint
            let listening = try await endpoint.start()
            guard started == generation else {
                endpoint.stop()
                pendingApprovals?.stop()
                return
            }
            var published: String?
            if let initialToken {
                // Reset Token may have run while this was starting: listen
                // with, and publish, the token on disk now.
                let token = try AutomationCredentials.loadOrCreateToken(in: directory)
                if token != initialToken { endpoint.setToken(token) }
                published = token
            }
            try AutomationCredentials.writeEndpointFile(port: listening, token: published,
                                                        pid: ProcessInfo.processInfo.processIdentifier,
                                                        testRun: testRun, in: directory)
            server.sessions.onChange = { [weak self] in self?.changed() }
            self.tools = tools
            self.server = server
            self.endpoint = endpoint
            self.approvals = pendingApprovals
            startExpiryTimer()
            AutomationPageCapture.shared.start(store: environment().store)
            status = .listening(port: listening)
            log.notice("Automation endpoint listening on \(AutomationCredentials.endpointURL(port: listening), privacy: .public)")
        } catch {
            pending?.stop()
            pendingApprovals?.stop()
            guard started == generation else { return }
            AutomationExtensionChannel.shared.isOpen = false
            AutomationExtensionConsole.shared.stop()
            AutomationExtensionStubCalls.shared.stop()
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
        // Every prompt closes, and every held request is answered.
        approvals?.stop()
        approvals = nil
        server?.sessions.onChange = nil
        server = nil
        tools = nil
        AutomationPageCapture.shared.stop()
        AutomationExtensionConsole.shared.stop()
        AutomationExtensionStubCalls.shared.stop()
        AutomationExtensionPopups.shared.closeAll()
        AutomationExtensionChannel.shared.isOpen = false
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

    /// Disconnects `sessionID`'s client. An approved client's token is
    /// revoked (`revoke(clientID:)`). In a test run, whose token is shared,
    /// the client's name is refused until it is allowed again, and every
    /// session under that name ends: one left running would keep acting
    /// while the name shows as disconnected.
    func disconnect(sessionID: String) {
        guard let sessions = server?.sessions, let session = sessions.sessions[sessionID] else { return }
        if let clientID = session.clientID {
            revoke(clientID: clientID)
            return
        }
        sessions.block(session.clientName)
        for other in sessions.orderedSessions where other.clientName == session.clientName {
            sessions.end(other.id)
        }
    }

    func allow(clientName: String) {
        server?.sessions.unblock(clientName)
    }

    /// Deletes an approved client's token, from the indicator's Disconnect
    /// or Settings' Revoke: its next request is refused (401) and its
    /// sessions end. Other clients keep working. Asking again shows the
    /// prompt again. Works with the endpoint off too (Settings).
    func revoke(clientID: UUID) {
        let removed = clientStore.revoke(clientID: clientID)
        server?.sessions.endAll(clientID: clientID)
        endpoint?.closeConnections(clientID: clientID)
        if let removed {
            log.notice("Automation: revoked \(removed.displayName, privacy: .public)")
        }
        changed()
    }

    /// A test run's new token: every connected client is disconnected and
    /// must be set up again with it (or reconnect through the bundled
    /// helper, which reads it). The user's endpoint has no shared token.
    @discardableResult
    func resetToken() throws -> String {
        guard mode.isTestRun else { throw Self.noSharedToken }
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

/// Whether automation may reach Private windows, spaces and tabs, menus over
/// Private windows, and the Private profile's extension contexts
/// (TASK-228.5): the user's "Allow agents to use Private windows" setting,
/// off by default. Read at every check, never cached, so turning it off
/// refuses at once. The tools read it through `AutomationEnvironment`; page
/// capture, the extension channel, console and stub counts read it here.
/// Tests replace it.
enum AutomationPrivateAccess {
    static var isAllowed: () -> Bool = { AutomationController.shared.allowsPrivateInSettings }
}

/// What the window's automation indicator says (TASK-228.1, AC #10, #17).
enum AutomationIndicator {

    #if DEBUG
    /// Debug builds only: hides the capsule while a capture records the
    /// window (set_debug_override automation_indicator, TASK-228.3). Release
    /// builds always show who is connected.
    static var isHiddenForCapture = false
    #endif

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
