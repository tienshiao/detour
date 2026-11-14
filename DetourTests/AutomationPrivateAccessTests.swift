import XCTest
import AppKit
import WebKit
@testable import Detour

/// The Private opt-in of the automation endpoint (TASK-228.5): with the
/// user's "Allow agents to use Private windows" off, Private windows, spaces
/// and tabs are left out and refused; on, every tool reaches them (listing,
/// a page tool, an input tool, a menu tool) and page capture goes into
/// Private pages; turned off again, everything is refused at once and
/// capture is removed. The Private profile stays out of the extension
/// install targets either way.
nonisolated final class AutomationPrivateAccessTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var savedAccess: (() -> Bool)?

    @MainActor override func tearDown() async throws {
        AutomationPageCapture.shared.stop()
        if let savedAccess { AutomationPrivateAccess.isAllowed = savedAccess }
        savedAccess = nil
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        for id in spaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    /// The setting, as a box the tools and capture both read per call.
    private final class Setting {
        var allowed = false
    }

    private struct Fixture {
        let setting: Setting
        let tools: AutomationTools
        let server: MCPServer
        let window: BrowserWindowController
        let windowID: Int
        let privateWindow: BrowserWindowController
        let privateWindowID: Int
        let privateSpace: Space
        let privateTab: BrowserTab
        let entry: NSMenuItem
    }

    private static let page = """
        <!doctype html><html><head><title>Private Page</title></head><body>
        <button id="go" onclick="window.clicked = (window.clicked || 0) + 1">Go</button>
        </body></html>
        """

    /// A normal window and a shown Private window with a loaded tab; a menu
    /// whose Window menu has the Private window's entry.
    @MainActor private func makeFixture(capturing: Bool = false) async throws -> Fixture {
        let setting = Setting()
        savedAccess = AutomationPrivateAccess.isAllowed
        AutomationPrivateAccess.isAllowed = { setting.allowed }
        let http = try LoopbackHTTPServer(routes: ["/": Self.page])
        servers.append(http)
        let port = try await http.start()
        let store = TabStore.shared
        if capturing { AutomationPageCapture.shared.start(store: store) }

        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Automation Normal", emoji: "N", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)

        let privateWindow = BrowserWindowController(incognito: true)
        privateWindow.sidebarSplitView.autosaveName = nil
        windows.append(privateWindow)
        privateWindow.showWindow(nil)
        let privateSpace = try XCTUnwrap(privateWindow.activeSpace)
        let privateTab = store.addTab(in: privateSpace, url: URL(string: "http://127.0.0.1:\(port)/")!)
        privateWindow.selectTab(id: privateTab.id)
        try await waitUntil("the Private page to load") {
            privateTab.webView?.title == "Private Page" && !privateTab.isLoading
        }

        let bar = NSMenu(title: "Main")
        let barItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: ""))
        // Stands in for the Window menu's entry for the Private window; its
        // action does nothing visible.
        let entry = NSMenuItem(title: "Secret Page", action: #selector(NSWindow.update), keyEquivalent: "")
        entry.target = privateWindow.window
        windowMenu.addItem(entry)
        barItem.submenu = windowMenu
        bar.addItem(barItem)

        var environment = AutomationEnvironment(windowControllers: { [wc, privateWindow] }, mainMenu: { bar },
                                                store: store)
        environment.allowsPrivate = { setting.allowed }
        let tools = AutomationTools(environment: environment)
        tools.inputWait = .milliseconds(400)
        tools.menuActionWait = .milliseconds(400)
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(setting: setting, tools: tools, server: server, window: wc, windowID: tools.windowIDs.id(for: wc),
                       privateWindow: privateWindow, privateWindowID: tools.windowIDs.id(for: privateWindow),
                       privateSpace: privateSpace, privateTab: privateTab, entry: entry)
    }

    @MainActor private func call(_ f: Fixture, _ name: String, _ arguments: JSONValue = [:]) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(f.server.tools.first { $0.name == name }, name)
        let result = await f.server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor private func ok(_ f: Fixture, _ name: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let (content, isError) = try await call(f, name, arguments)
        XCTAssertFalse(isError, "\(name) \(arguments.jsonString): \(content.jsonString)")
        return content
    }

    @MainActor private func code(_ f: Fixture, _ name: String, _ arguments: JSONValue) async throws -> String? {
        let (content, isError) = try await call(f, name, arguments)
        XCTAssertTrue(isError, "\(name) \(arguments.jsonString) should fail: \(content.jsonString)")
        return content["error"]?["code"]?.stringValue
    }

    // MARK: Listing

    @MainActor func testListingFollowsTheSettingAtOnce() async throws {
        let f = try await makeFixture()
        let privateSpaceID = JSONValue.string(f.privateSpace.id.uuidString)

        // Off: left out, and refused by id.
        var windows = try await ok(f, "list_windows")
        XCTAssertEqual(windows["windows"]?.arrayValue?.count, 1)
        XCTAssertEqual(windows["hidden_private_windows"], 1)
        var spaces = try await ok(f, "list_spaces")["spaces"]?.arrayValue ?? []
        XCTAssertFalse(spaces.contains { $0["space_id"] == privateSpaceID })
        var refused = try await code(f, "list_tabs", ["space_id": privateSpaceID])
        XCTAssertEqual(refused, "private_unreachable")
        refused = try await code(f, "list_tabs", ["window_id": .int(f.privateWindowID)])
        XCTAssertEqual(refused, "private_unreachable")

        // On: listed, marked, reachable.
        f.setting.allowed = true
        windows = try await ok(f, "list_windows")
        let listed = windows["windows"]?.arrayValue ?? []
        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(windows["hidden_private_windows"], 0)
        let privateListed = try XCTUnwrap(listed.first { $0["window_id"] == .int(f.privateWindowID) })
        XCTAssertEqual(privateListed["is_private"], true)
        XCTAssertEqual(privateListed["selected_tab_id"], .string(f.privateTab.id.uuidString))
        spaces = try await ok(f, "list_spaces")["spaces"]?.arrayValue ?? []
        let space = try XCTUnwrap(spaces.first { $0["space_id"] == privateSpaceID })
        XCTAssertEqual(space["is_private"], true)
        XCTAssertEqual(space["shown_in_window_ids"], [.int(f.privateWindowID)])
        let tabs = try await ok(f, "list_tabs", ["window_id": .int(f.privateWindowID)])
        let items = tabs["items"]?.arrayValue ?? []
        XCTAssertTrue(items.contains { $0["tab_id"] == .string(f.privateTab.id.uuidString) })
        let selected = try await ok(f, "select_tab", ["window_id": .int(f.privateWindowID),
                                                      "id": .string(f.privateTab.id.uuidString)])
        XCTAssertEqual(selected["selected_tab_id"], .string(f.privateTab.id.uuidString))

        // Off again: refused at once.
        f.setting.allowed = false
        windows = try await ok(f, "list_windows")
        XCTAssertEqual(windows["hidden_private_windows"], 1)
        refused = try await code(f, "list_tabs", ["space_id": privateSpaceID])
        XCTAssertEqual(refused, "private_unreachable")
        refused = try await code(f, "select_tab", ["window_id": .int(f.privateWindowID),
                                                   "id": .string(f.privateTab.id.uuidString)])
        XCTAssertEqual(refused, "private_unreachable")
    }

    // MARK: A page tool and an input tool

    @MainActor func testPageAndInputToolsReachAPrivateTabOnlyWhileAllowed() async throws {
        let f = try await makeFixture()
        let context = JSONValue.string(f.privateTab.id.uuidString)
        var refused = try await code(f, "evaluate_js", ["context": context, "expression": "document.title"])
        XCTAssertEqual(refused, "private_unreachable")
        refused = try await code(f, "click", ["context": context, "selector": "#go"])
        XCTAssertEqual(refused, "private_unreachable")
        refused = try await code(f, "screenshot", ["window_id": .int(f.privateWindowID)])
        XCTAssertEqual(refused, "private_unreachable")

        f.setting.allowed = true
        let title = try await ok(f, "evaluate_js", ["context": context, "expression": "document.title"])
        XCTAssertEqual(title["value"], "Private Page")
        let clicked = try await ok(f, "click", ["context": context, "selector": "#go"])
        XCTAssertEqual(clicked["completed"], true)
        try await waitUntil("the click to reach the Private page") {
            let count = try await self.ok(f, "evaluate_js", ["context": context, "expression": "window.clicked || 0"])
            return count["value"] == 1
        }

        f.setting.allowed = false
        refused = try await code(f, "evaluate_js", ["context": context, "expression": "1"])
        XCTAssertEqual(refused, "private_unreachable")
        refused = try await code(f, "press_key", ["context": context, "key": "a"])
        XCTAssertEqual(refused, "private_unreachable")
    }

    // MARK: A menu tool

    @MainActor func testMenusOverPrivateWindowsFollowTheSetting() async throws {
        let f = try await makeFixture()
        let path: JSONValue = ["Window", "Secret Page"]
        var refused = try await code(f, "run_menu_item", ["window_id": .int(f.windowID), "path": path])
        XCTAssertEqual(refused, "unknown_menu_item", "the Private window's entry is not there")
        refused = try await code(f, "run_menu_item", ["window_id": .int(f.privateWindowID), "path": ["Window", "Minimize"]])
        XCTAssertEqual(refused, "private_unreachable", "nor a command for the Private window")
        let window = try XCTUnwrap(f.window.window)
        XCTAssertThrowsError(try AutomationMenus.resolve(f.entry, in: window, allowPrivate: false))
        let menu = try XCTUnwrap(f.entry.menu)
        XCTAssertEqual(AutomationMenuTracker.describe(menu, allowPrivate: false).compactMap { $0["title"]?.stringValue },
                       ["Minimize"])

        f.setting.allowed = true
        let ran = try await ok(f, "run_menu_item", ["window_id": .int(f.windowID), "path": path])
        XCTAssertEqual(ran["title"], "Secret Page")
        XCTAssertEqual(ran["completed"], true)
        XCTAssertNoThrow(try AutomationMenus.resolve(f.entry, in: window, allowPrivate: true))
        XCTAssertEqual(AutomationMenuTracker.describe(menu, allowPrivate: true).compactMap { $0["title"]?.stringValue },
                       ["Minimize", "Secret Page"])

        f.setting.allowed = false
        refused = try await code(f, "run_menu_item", ["window_id": .int(f.windowID), "path": path])
        XCTAssertEqual(refused, "unknown_menu_item")
    }

    // MARK: Page capture

    @MainActor func testCaptureGoesIntoPrivatePagesOnlyWhileAllowedAndIsRemovedWhenTurnedOff() async throws {
        let f = try await makeFixture(capturing: true)
        let store = TabStore.shared
        let ucc = try XCTUnwrap(f.privateTab.webView?.configuration.userContentController)
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: ucc), "off: no capture in a Private page")

        f.setting.allowed = true
        AutomationPageCapture.shared.privateAccessChanged(allowed: true)
        XCTAssertTrue(AutomationPageCapture.isInstalled(on: ucc), "on: installed in the live Private page")
        let context = JSONValue.string(f.privateTab.id.uuidString)
        _ = try await ok(f, "evaluate_js", ["context": context, "expression": "console.warn('from private'), 1"])
        try await waitUntil("the Private page's console") {
            let messages = try await self.ok(f, "console_messages", ["context": context])["messages"]?.arrayValue ?? []
            return messages.contains { $0["text"] == "from private" }
        }
        // A new Private tab gets it from the start; a Private Quick Detour
        // or quarantine page never does.
        let newTab = store.addTab(in: f.privateSpace, url: nil)
        defer { newTab.teardown() }
        let newController = newTab.webView?.configuration.userContentController
            ?? Space.makeUserContentController(for: f.privateSpace.profile)
        XCTAssertTrue(AutomationPageCapture.isInstalled(on: newController))
        let quickDetour = Space.makeUserContentController(for: f.privateSpace.profile, inSpace: false)
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: quickDetour))

        f.setting.allowed = false
        AutomationPageCapture.shared.privateAccessChanged(allowed: false)
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: ucc), "removed when turned off")
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: newController))
        XCTAssertNil(AutomationPageCapture.shared.console(for: f.privateTab.id), "its records are forgotten")
        let refused = try await code(f, "console_messages", ["context": context])
        XCTAssertEqual(refused, "private_unreachable")
        let later = Space.makeUserContentController(for: f.privateSpace.profile)
        XCTAssertFalse(AutomationPageCapture.isInstalled(on: later), "and not into new Private pages")
    }

    // MARK: Extensions

    @MainActor func testThePrivateProfileIsNeverAnInstallTargetButItsContextsFollowTheSetting() async throws {
        let f = try await makeFixture()
        let privateID = TabStore.incognitoProfileID
        for allowed in [false, true] {
            f.setting.allowed = allowed
            XCTAssertThrowsError(try f.tools.normalProfile(id: privateID)) { error in
                XCTAssertEqual((error as? AutomationToolError)?.code, .privateUnreachable)
            }
        }
        f.setting.allowed = false
        XCTAssertThrowsError(try f.tools.contextProfile(id: privateID)) { error in
            XCTAssertEqual((error as? AutomationToolError)?.code, .privateUnreachable)
        }
        XCTAssertFalse(f.tools.contextProfiles.contains { $0.id == privateID })
        f.setting.allowed = true
        XCTAssertEqual(try f.tools.contextProfile(id: privateID).id, privateID)
        XCTAssertTrue(f.tools.contextProfiles.contains { $0.id == privateID })
    }
}
