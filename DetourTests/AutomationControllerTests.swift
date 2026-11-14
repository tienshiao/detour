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
    @MainActor private func makeController() throws -> (AutomationController, URL, UserDefaults) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let suite = "com.detourbrowser.tests.automation.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let controller = AutomationController(directory: { directory }, defaults: defaults,
                                              environment: { AutomationEnvironment(windowControllers: { [] },
                                                                                   mainMenu: { nil }, store: .shared) },
                                              portOverride: 0)
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

    @MainActor private func session(_ controller: AutomationController, name: String) async throws -> String? {
        let server = try XCTUnwrap(controller.server)
        let initialize: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                     "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": .string(name)]]]
        let response = await server.handle(AutomationHTTP.Request(method: "POST", path: "/mcp",
                                                                  headers: ["content-type": "application/json"],
                                                                  body: initialize.serialized()))
        return response.header(MCPServer.sessionHeader)
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

    @MainActor func testResetTokenEndsEverySessionAndRewritesTheFile() async throws {
        let (controller, directory, _) = try makeController()
        controller.setEnabled(true)
        _ = try await waitForListening(controller)
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

    @MainActor func testADisconnectedClientIsRefusedUntilAllowedAgain() async throws {
        let (controller, _, _) = try makeController()
        controller.setEnabled(true)
        _ = try await waitForListening(controller)
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
