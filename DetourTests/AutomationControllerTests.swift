import XCTest
import AppKit
@testable import Detour

/// The automation endpoint's lifecycle and its connected-agent controls
/// (TASK-228.1 phase 4, AC #7, #10, #14, #17): turning it on and off from the
/// setting, the endpoint file following, Reset Token, disconnecting and
/// allowing a client, idle sessions ending, and the window's indicator.
nonisolated final class AutomationControllerTests: XCTestCase {

    private var directories: [URL] = []
    private var suites: [String] = []
    private var controllers: [AutomationController] = []
    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []

    @MainActor override func tearDown() async throws {
        for controller in controllers { controller.stop() }
        controllers.removeAll()
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for id in spaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites.removeAll()
        try await super.tearDown()
    }

    /// A controller over a directory and defaults of its own, on a port the
    /// system picks: never the real profile or the real port.
    @MainActor private func makeController(prompter: FakeApprovalPrompter = FakeApprovalPrompter()) throws
        -> (AutomationController, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let suite = "com.detourbrowser.tests.automation.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = AutomationController(directory: { directory }, defaults: defaults,
                                              environment: { AutomationEnvironment(windowControllers: { [] },
                                                                                   mainMenu: { nil }, store: .shared) },
                                              portOverride: 0, prompter: { prompter })
        controllers.append(controller)
        return (controller, directory, defaults)
    }

    @MainActor private func waitForListening(_ controller: AutomationController) async throws -> UInt16 {
        var port: UInt16 = 0
        try await waitUntil("the endpoint to listen", timeout: 5) {
            if case .listening(let p) = controller.status { port = p; return true }
            return false
        }
        return port
    }

    private func endpointFile(_ directory: URL) -> URL {
        directory.appendingPathComponent(AutomationCredentials.endpointFileName)
    }

    @MainActor private func session(_ controller: AutomationController, name: String,
                                    client: AutomationClientIdentity? = nil) async throws -> String? {
        let server = try XCTUnwrap(controller.server)
        let initialize: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                     "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": .string(name)]]]
        var request = AutomationHTTP.Request(method: "POST", path: "/mcp", headers: ["content-type": "application/json"],
                                             body: initialize.serialized())
        request.client = client
        let response = await server.handle(request)
        return response.header(MCPServer.sessionHeader)
    }

    /// A test run, as `DETOUR_MCP=1` starts one: the shared token, no prompt.
    @MainActor private func startTestRun(_ controller: AutomationController) async throws -> UInt16 {
        controller.start(mode: .testRun(port: 0))
        return try await waitForListening(controller)
    }

    // MARK: On and off

    @MainActor func testTheSettingTurnsTheEndpointOnAndOffWithItsFile() async throws {
        let (controller, directory, defaults) = try makeController()
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: AutomationController.didChangeNotification,
                                                              object: controller, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(controller.isEnabledInSettings)

        controller.setEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: AutomationGate.enabledDefaultsKey), "the setting is saved")
        let port = try await waitForListening(controller)
        XCTAssertNotEqual(port, 0)
        XCTAssertEqual(controller.endpointURL, AutomationCredentials.endpointURL(port: port))
        let file = try JSONValue.parse(Data(contentsOf: endpointFile(directory)))
        XCTAssertEqual(file["port"], .int(Int(port)))
        XCTAssertGreaterThan(changes, 0, "the UI hears about it")
        XCTAssertTrue(AutomationPageCapture.shared.isActive, "pages are recorded while it listens (TASK-228.4)")

        controller.setEnabled(false)
        XCTAssertFalse(AutomationPageCapture.shared.isActive, "and no longer once it stops")
        XCTAssertEqual(controller.status, .off)
        XCTAssertFalse(defaults.bool(forKey: AutomationGate.enabledDefaultsKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointFile(directory).path), "the file goes with it")
        XCTAssertNil(controller.server)
    }

    @MainActor func testAStopDuringAStartLeavesNothingListening() async throws {
        let (controller, directory, _) = try makeController()
        controller.setEnabled(true)
        controller.stop()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(controller.status, .off)
        XCTAssertNil(controller.server)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointFile(directory).path))
    }

    // MARK: Token

    @MainActor func testATestRunKeepsItsSharedTokenInTheEndpointFile() async throws {
        let (controller, directory, _) = try makeController()
        _ = try await startTestRun(controller)
        XCTAssertFalse(controller.usesClientApproval)
        XCTAssertNil(controller.approvals, "no prompt in a test run")
        let file = try JSONValue.parse(Data(contentsOf: endpointFile(directory)))
        XCTAssertEqual(file["token"], .string(try controller.token()))
        XCTAssertEqual(file["test_run"], true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(AutomationCredentials.tokenFileName).path))
    }

    @MainActor func testResetTokenEndsEverySessionAndRewritesTheFile() async throws {
        let (controller, directory, _) = try makeController()
        _ = try await startTestRun(controller)
        let old = try controller.token()
        _ = try await session(controller, name: "Claude Code")
        XCTAssertEqual(controller.sessions.count, 1)

        let new = try controller.resetToken()
        XCTAssertNotEqual(new, old)
        XCTAssertEqual(try controller.token(), new)
        XCTAssertTrue(controller.sessions.isEmpty, "everyone is disconnected")
        let file = try JSONValue.parse(Data(contentsOf: endpointFile(directory)))
        XCTAssertEqual(file["token"], .string(new))
    }

    // MARK: Clients

    @MainActor func testInATestRunADisconnectedClientIsRefusedUntilAllowedAgain() async throws {
        let (controller, _, _) = try makeController()
        _ = try await startTestRun(controller)
        let first = try await session(controller, name: "Claude Code")
        let id = try XCTUnwrap(first)
        _ = try await session(controller, name: "Other Agent")
        // A second session under the same name ends with the first.
        _ = try await session(controller, name: "Claude Code")

        controller.disconnect(sessionID: id)
        XCTAssertEqual(controller.sessions.map(\.clientName), ["Other Agent"])
        XCTAssertEqual(controller.blockedClientNames, ["Claude Code"])
        let refused = try await session(controller, name: "Claude Code")
        XCTAssertNil(refused, "a disconnected client cannot simply start again")

        controller.allow(clientName: "Claude Code")
        XCTAssertTrue(controller.blockedClientNames.isEmpty)
        let again = try await session(controller, name: "Claude Code")
        XCTAssertNotNil(again)

        // Turning automation off forgets who was disconnected.
        controller.disconnect(sessionID: try XCTUnwrap(again))
        controller.setEnabled(false)
        controller.setEnabled(true)
        _ = try await waitForListening(controller)
        XCTAssertTrue(controller.blockedClientNames.isEmpty)
    }

    // MARK: The user's endpoint (TASK-228.5)

    @MainActor func testTheUsersEndpointPublishesNoTokenAndDeletesALeftoverOne() async throws {
        let (controller, directory, _) = try makeController()
        let leftover = try AutomationCredentials.loadOrCreateToken(in: directory)
        controller.setEnabled(true)
        _ = try await waitForListening(controller)
        XCTAssertTrue(controller.usesClientApproval)
        XCTAssertNotNil(controller.approvals)
        let tokenFile = directory.appendingPathComponent(AutomationCredentials.tokenFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path), "the leftover shared token is deleted")
        let file = try JSONValue.parse(Data(contentsOf: endpointFile(directory)))
        XCTAssertNil(file["token"], "the endpoint file carries no token")
        XCTAssertEqual(file["test_run"], false)
        XCTAssertNotNil(file["url"])
        XCTAssertThrowsError(try controller.token(), "no shared token to copy")
        XCTAssertThrowsError(try controller.resetToken(), "nor to reset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path), "and asking for one made none")

        // The leftover token is refused over the socket.
        var request = URLRequest(url: try XCTUnwrap(URL(string: try XCTUnwrap(controller.endpointURL))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(leftover)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    @MainActor func testDisconnectAndRevokeDeleteTheClientsTokenAndKeepOthers() async throws {
        let prompter = FakeApprovalPrompter()
        prompter.autoAnswer = .allow
        let (controller, directory, _) = try makeController(prompter: prompter)
        controller.setEnabled(true)
        _ = try await waitForListening(controller)
        let store = controller.clientStore
        let (_, claude) = try store.add(name: "claude-code", title: "Claude Code", version: nil, now: Date())
        let (_, cursor) = try store.add(name: "cursor", title: nil, version: nil, now: Date())
        XCTAssertEqual(controller.approvedClients.map(\.clientID), [claude.clientID, cursor.clientID])
        let claudeIdentity = AutomationClientIdentity(id: claude.clientID, name: claude.displayName)
        let firstSession = try await session(controller, name: "x", client: claudeIdentity)
        let first = try XCTUnwrap(firstSession)
        _ = try await session(controller, name: "y", client: claudeIdentity)
        _ = try await session(controller, name: "z", client: AutomationClientIdentity(id: cursor.clientID, name: "cursor"))
        XCTAssertEqual(controller.sessions.map(\.clientName), ["Claude Code", "Claude Code", "cursor"])

        controller.disconnect(sessionID: first)
        XCTAssertEqual(controller.sessions.map(\.clientName), ["cursor"], "every session of the client ends")
        XCTAssertNil(store.record(id: claude.clientID), "its token is revoked")
        XCTAssertTrue(controller.blockedClientNames.isEmpty, "no name blocking for approved clients")
        XCTAssertEqual(AutomationClientStore(directory: directory).records.map(\.clientID), [cursor.clientID])

        controller.revoke(clientID: cursor.clientID)
        XCTAssertTrue(controller.sessions.isEmpty)
        XCTAssertTrue(controller.approvedClients.isEmpty)

        // Revoke works with the endpoint off too (Settings).
        let (_, later) = try store.add(name: "later", title: nil, version: nil, now: Date())
        controller.setEnabled(false)
        controller.revoke(clientID: later.clientID)
        XCTAssertTrue(AutomationClientStore(directory: directory).records.isEmpty)
    }

    @MainActor func testThePrivateSettingIsSavedAndReadByTheToolsAtEveryCall() async throws {
        let (controller, _, defaults) = try makeController()
        _ = try await startTestRun(controller)
        let tools = try XCTUnwrap(controller.tools)
        XCTAssertFalse(controller.allowsPrivateInSettings, "off by default")
        XCTAssertFalse(tools.privateAllowed)
        controller.setAllowsPrivate(true)
        XCTAssertTrue(defaults.bool(forKey: AutomationGate.allowPrivateDefaultsKey))
        XCTAssertTrue(tools.privateAllowed, "the running tools see it at once")
        controller.setAllowsPrivate(false)
        XCTAssertFalse(tools.privateAllowed)
        // A test run turns it on only through the same setting.
        defaults.set(true, forKey: AutomationGate.allowPrivateDefaultsKey)
        XCTAssertTrue(tools.privateAllowed)
    }

    @MainActor func testTurningOffWithAPromptUpClosesItAndAnswersTheRequest() async throws {
        let prompter = FakeApprovalPrompter()
        let (controller, _, _) = try makeController(prompter: prompter)
        controller.setEnabled(true)
        _ = try await waitForListening(controller)
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(controller.endpointURL)))
        var request = URLRequest(url: url.appendingPathComponent("authorize"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"client_name":"claude-code"}"#.utf8)
        let held = Task { try? await URLSession.shared.data(for: request) }
        try await waitUntil("the prompt") { prompter.prompts.count == 1 }
        controller.setEnabled(false)
        XCTAssertTrue(prompter.prompts[0].dismissed, "the panel closes with the endpoint")
        _ = await held.value
        prompter.prompts[0].respond(.allow)
        XCTAssertTrue(controller.approvedClients.isEmpty)
    }

    @MainActor func testQuietSessionsEnd() async throws {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let server = MCPServer(tools: [], serverVersion: "1", instructions: "", now: { now })
        _ = server.sessions.start(clientName: "Old", clientVersion: nil, protocolVersion: "2025-06-18", now: now)
        now += AutomationController.idleSessionLimit / 2
        let recent = server.sessions.start(clientName: "Recent", clientVersion: nil, protocolVersion: "2025-06-18", now: now)
        now += AutomationController.idleSessionLimit / 2 + 1
        let ended = server.sessions.expire(idleFor: AutomationController.idleSessionLimit, now: now)
        XCTAssertEqual(ended.map(\.clientName), ["Old"])
        XCTAssertEqual(server.sessions.orderedSessions.map(\.id), [recent.id])
    }

    // MARK: Indicator

    @MainActor func testTheIndicatorNamesTheClients() {
        let now = Date()
        func session(_ name: String) -> MCPSessionStore.Session {
            MCPSessionStore.Session(id: UUID().uuidString, clientName: name, clientVersion: nil,
                                    protocolVersion: "2025-06-18", startedAt: now, lastSeen: now, initialized: true)
        }
        XCTAssertNil(AutomationIndicator.title(for: []), "hidden when nothing is connected")
        XCTAssertEqual(AutomationIndicator.title(for: [session("Claude Code")]), "Claude Code")
        XCTAssertEqual(AutomationIndicator.title(for: [session("Claude Code"), session("Cursor"), session("x")]),
                       "Claude Code + 2")
        XCTAssertEqual(AutomationIndicator.age(of: now, now: now), "just now")
        XCTAssertEqual(AutomationIndicator.age(of: now - 300, now: now), "5 min ago")
        XCTAssertEqual(AutomationIndicator.age(of: now - 7300, now: now), "2 h ago")
    }

    @MainActor func testTheWindowKeepsItsIndicatorAboveThePageThroughTabSwitches() throws {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Automation Indicator", emoji: "I", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        let one = store.addTab(in: space, url: nil)
        let two = store.addTab(in: space, url: nil)

        let now = Date()
        let connected = [MCPSessionStore.Session(id: "s", clientName: "Claude Code", clientVersion: nil,
                                                 protocolVersion: "2025-06-18", startedAt: now, lastSeen: now,
                                                 initialized: true)]
        wc.updateAutomationIndicator(sessions: connected)
        XCTAssertFalse(wc.automationIndicator.isHidden)
        XCTAssertEqual(wc.automationIndicator.title, "Claude Code")

        // Selecting a tab clears the content view's subviews; the indicator stays, on top.
        wc.selectTab(id: one.id)
        wc.selectTab(id: two.id)
        XCTAssertTrue(wc.automationIndicator.superview === wc.contentContainerView)
        let subviews = wc.contentContainerView.subviews
        let indicatorIndex = try XCTUnwrap(subviews.firstIndex { $0 === wc.automationIndicator })
        let pageIndex = try XCTUnwrap(subviews.firstIndex { two.webViewContainer.map($0.isDescendant(of:)) == true || $0 === two.webViewContainer })
        XCTAssertGreaterThan(indicatorIndex, pageIndex, "above the page")
        XCTAssertEqual(wc.automationIndicator.accessibilityLabel(), "Automation: Claude Code connected")

        wc.updateAutomationIndicator(sessions: [])
        XCTAssertTrue(wc.automationIndicator.isHidden, "gone when the last client leaves")
    }
}
