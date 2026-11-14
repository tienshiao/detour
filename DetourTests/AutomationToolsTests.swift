import XCTest
import AppKit
@testable import Detour

/// The first automation tools (TASK-228.1, AC #1, #7, #9) against real
/// windows on `TabStore.shared`: listing, selection (including a dormant
/// pinned entry and another space), typed URLs, menu commands by path and key
/// equivalent, the Private-window refusal and each tool's error codes.
nonisolated final class AutomationToolsTests: XCTestCase {

    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var tabs: [BrowserTab] = []
    private var routeIDs: [UUID] = []

    @MainActor override func tearDown() async throws {
        // A routed URL may have opened a window of its own on a test space.
        let routedWindows = NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
            .filter { wc in !windows.contains { $0 === wc } && wc.activeSpaceID.map(spaceIDs.contains) == true }
        windows += routedWindows
        for wc in windows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        windows.removeAll()
        // Routes first: a space a route targets cannot be deleted.
        for id in routeIDs { TabStore.shared.linkRoutes.removeRoute(id: id) }
        routeIDs.removeAll()
        for id in spaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs + space.pinnedTabs { tab.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        spaceIDs.removeAll()
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    // MARK: Fixture

    private struct Fixture {
        let tools: AutomationTools
        let server: MCPServer
        let window: BrowserWindowController
        let windowID: Int
        let a: Space
        let b: Space
    }

    /// One window on space A; B is the next space. The menu is the test's own,
    /// so its items are known.
    @MainActor private func makeFixture(menu: NSMenu? = nil, extraWindows: [BrowserWindowController] = []) throws -> Fixture {
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let a = store.addSpace(name: "Automation A", emoji: "A", colorHex: "007AFF", profileID: profile.id)
        let b = store.addSpace(name: "Automation B", emoji: "B", colorHex: "FF9500", profileID: profile.id)
        spaceIDs += [a.id, b.id]
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: a.id)
        let all = [wc] + extraWindows
        let tools = AutomationTools(environment: AutomationEnvironment(windowControllers: { all },
                                                                       mainMenu: { menu ?? Self.testMenu() },
                                                                       store: store))
        tools.menuActionWait = .milliseconds(200)
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(tools: tools, server: server, window: wc, windowID: tools.windowIDs.id(for: wc), a: a, b: b)
    }

    @MainActor private func addTab(_ url: String, in space: Space) -> BrowserTab {
        let tab = TabStore.shared.addTab(in: space, url: URL(string: url))
        tabs.append(tab)
        return tab
    }

    /// Calls `name` the way a client does and returns the structured content
    /// and whether it is an error.
    @MainActor private func call(_ fixture: Fixture, _ name: String, _ arguments: JSONValue = [:]) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(fixture.server.tools.first { $0.name == name }, name)
        let result = await fixture.server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor private func errorCode(_ fixture: Fixture, _ name: String, _ arguments: JSONValue) async throws -> String? {
        let (content, isError) = try await call(fixture, name, arguments)
        XCTAssertTrue(isError, "\(name) \(arguments.jsonString) should fail")
        return content["error"]?["code"]?.stringValue
    }

    // MARK: list_windows / list_spaces

    @MainActor func testListWindowsDescribesTheWindowAndHidesPrivateOnes() async throws {
        let privateWindow = BrowserWindowController(incognito: true)
        privateWindow.sidebarSplitView.autosaveName = nil
        windows.append(privateWindow)
        let f = try makeFixture(extraWindows: [privateWindow])
        let tab = addTab("http://127.0.0.1:9/a", in: f.a)
        f.window.selectTab(id: tab.id)

        let (content, isError) = try await call(f, "list_windows")
        XCTAssertFalse(isError)
        let listed = try XCTUnwrap(content["windows"]?.arrayValue)
        XCTAssertEqual(listed.count, 1, "the Private window is not listed")
        XCTAssertEqual(content["hidden_private_windows"], 1)
        XCTAssertEqual(listed[0]["window_id"], .int(f.windowID))
        XCTAssertEqual(listed[0]["active_space_id"], .string(f.a.id.uuidString))
        XCTAssertEqual(listed[0]["selected_tab_id"], .string(tab.id.uuidString))
        XCTAssertNotNil(listed[0]["frame"]?["width"]?.doubleValue)

        let privateID = f.tools.windowIDs.id(for: privateWindow)
        let code = try await errorCode(f, "list_tabs", ["window_id": .int(privateID)])
        XCTAssertEqual(code, "private_unreachable")
        let selectCode = try await errorCode(f, "select_tab", ["window_id": .int(privateID), "id": .string(tab.id.uuidString)])
        XCTAssertEqual(selectCode, "private_unreachable")
        let privateSpace = try XCTUnwrap(privateWindow.activeSpaceID)
        let spaceCode = try await errorCode(f, "list_tabs", ["space_id": .string(privateSpace.uuidString)])
        XCTAssertEqual(spaceCode, "private_unreachable")
    }

    @MainActor func testListSpacesLeavesOutPrivateSpacesAndSaysWhichWindowShowsEach() async throws {
        let privateWindow = BrowserWindowController(incognito: true)
        privateWindow.sidebarSplitView.autosaveName = nil
        windows.append(privateWindow)
        let f = try makeFixture(extraWindows: [privateWindow])
        let (content, _) = try await call(f, "list_spaces")
        let spaces = try XCTUnwrap(content["spaces"]?.arrayValue)
        XCTAssertFalse(spaces.contains { $0["space_id"] == .string(privateWindow.activeSpaceID?.uuidString ?? "") })
        let a = try XCTUnwrap(spaces.first { $0["space_id"] == .string(f.a.id.uuidString) })
        XCTAssertEqual(a["name"], "Automation A")
        XCTAssertEqual(a["shown_in_window_ids"], [.int(f.windowID)])
        let b = try XCTUnwrap(spaces.first { $0["space_id"] == .string(f.b.id.uuidString) })
        XCTAssertEqual(b["shown_in_window_ids"], [])
    }

    // MARK: list_tabs

    @MainActor func testListTabsListsPinnedEntriesLiveAndDormantThenTabs() async throws {
        let f = try makeFixture()
        let pinned = addTab("http://127.0.0.1:9/pinned", in: f.a)
        TabStore.shared.pinTab(id: pinned.id, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)
        TabStore.shared.closePinnedTab(id: entry.id, in: f.a)
        XCTAssertNil(entry.tab, "dormant")
        let one = addTab("http://127.0.0.1:9/one", in: f.a)
        f.window.selectTab(id: one.id)

        let (content, isError) = try await call(f, "list_tabs", ["window_id": .int(f.windowID)])
        XCTAssertFalse(isError)
        XCTAssertEqual(content["space_id"], .string(f.a.id.uuidString))
        let items = try XCTUnwrap(content["items"]?.arrayValue).filter { $0["section"] != "favorite" }
        XCTAssertEqual(items.map { $0["section"] }, ["pinned", "tab"])
        XCTAssertEqual(items[0]["id"], .string(entry.id.uuidString))
        XCTAssertEqual(items[0]["live"], false)
        XCTAssertEqual(items[0]["tab_id"], .null)
        XCTAssertEqual(items[0]["context"], .null)
        XCTAssertEqual(items[0]["url"], "http://127.0.0.1:9/pinned")
        XCTAssertEqual(items[1]["tab_id"], .string(one.id.uuidString))
        XCTAssertEqual(items[1]["context"], .string("tab:\(one.id.uuidString)"))
        XCTAssertEqual(items[1]["selected_in_window_ids"], [.int(f.windowID)])

        let bySpace = try await call(f, "list_tabs", ["space_id": .string(f.b.id.uuidString)])
        XCTAssertEqual(bySpace.content["items"]?.arrayValue?.filter { $0["section"] != "favorite" }.count, 0)
    }

    @MainActor func testListTabsErrors() async throws {
        let f = try makeFixture()
        let neither = try await errorCode(f, "list_tabs", [:])
        XCTAssertEqual(neither, "invalid_arguments")
        let unknownSpace = try await errorCode(f, "list_tabs", ["space_id": .string(UUID().uuidString)])
        XCTAssertEqual(unknownSpace, "unknown_space")
        let unknownWindow = try await errorCode(f, "list_tabs", ["window_id": 9999])
        XCTAssertEqual(unknownWindow, "unknown_window")
        let badID = try await errorCode(f, "list_tabs", ["space_id": "nope"])
        XCTAssertEqual(badID, "invalid_arguments")
    }

    // MARK: select_tab

    @MainActor func testSelectTabSelectsATabInTheWindowsSpace() async throws {
        let f = try makeFixture()
        let one = addTab("http://127.0.0.1:9/one", in: f.a)
        let two = addTab("http://127.0.0.1:9/two", in: f.a)
        f.window.selectTab(id: one.id)

        let (content, isError) = try await call(f, "select_tab", ["window_id": .int(f.windowID), "id": .string(two.id.uuidString)])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(f.window.selectedTabID, two.id)
        XCTAssertEqual(content["selected_tab_id"], .string(two.id.uuidString))
        XCTAssertEqual(content["space_id"], .string(f.a.id.uuidString))
    }

    @MainActor func testSelectTabSwitchesToTheTabsSpace() async throws {
        let f = try makeFixture()
        let there = addTab("http://127.0.0.1:9/b", in: f.b)
        let (content, isError) = try await call(f, "select_tab", ["window_id": .int(f.windowID), "id": .string(there.id.uuidString)])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(f.window.activeSpaceID, f.b.id)
        XCTAssertEqual(f.window.selectedTabID, there.id)
    }

    @MainActor func testSelectTabWakesADormantPinnedEntry() async throws {
        let f = try makeFixture()
        let pinned = addTab("http://127.0.0.1:9/pinned", in: f.a)
        TabStore.shared.pinTab(id: pinned.id, in: f.a)
        let entry = try XCTUnwrap(f.a.pinnedEntries.first)
        TabStore.shared.closePinnedTab(id: entry.id, in: f.a)
        XCTAssertNil(entry.tab)

        let (content, isError) = try await call(f, "select_tab", ["window_id": .int(f.windowID), "id": .string(entry.id.uuidString)])
        XCTAssertFalse(isError, content.jsonString)
        let woken = try XCTUnwrap(entry.tab, "the entry is live again")
        XCTAssertEqual(f.window.selectedTabID, woken.id)
        XCTAssertEqual(content["selected_tab_id"], .string(woken.id.uuidString))
    }

    @MainActor func testSelectTabErrors() async throws {
        let f = try makeFixture()
        let tab = addTab("http://127.0.0.1:9/a", in: f.a)
        let unknownTab = try await errorCode(f, "select_tab", ["window_id": .int(f.windowID), "id": .string(UUID().uuidString)])
        XCTAssertEqual(unknownTab, "unknown_tab")
        let unknownWindow = try await errorCode(f, "select_tab", ["window_id": 9999, "id": .string(tab.id.uuidString)])
        XCTAssertEqual(unknownWindow, "unknown_window")
        let missing = try await errorCode(f, "select_tab", ["window_id": .int(f.windowID)])
        XCTAssertEqual(missing, "invalid_arguments")
        let closed = tab.id
        TabStore.shared.closeTab(id: closed, in: f.a)
        let closedCode = try await errorCode(f, "select_tab", ["window_id": .int(f.windowID), "id": .string(closed.uuidString)])
        XCTAssertEqual(closedCode, "unknown_tab", "a closed tab is gone")
    }

    @MainActor func testAClosedWindowIsUnknown() async throws {
        let f = try makeFixture()
        f.window.window?.close()
        let code = try await errorCode(f, "list_tabs", ["window_id": .int(f.windowID)])
        XCTAssertEqual(code, "unknown_window")
    }

    // MARK: open_url

    @MainActor func testOpenURLOpensANewSelectedTabOrLoadsInPlace() async throws {
        let f = try makeFixture()
        let before = f.a.tabs.count
        let (content, isError) = try await call(f, "open_url", ["window_id": .int(f.windowID), "url": "http://127.0.0.1:9/new"])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(f.a.tabs.count, before + 1)
        let opened = try XCTUnwrap(f.window.selectedTab)
        tabs.append(opened)
        XCTAssertEqual(content["selected_tab_id"], .string(opened.id.uuidString))
        XCTAssertEqual(content["routed"], false)

        let inPlace = try await call(f, "open_url", ["window_id": .int(f.windowID), "url": "http://127.0.0.1:9/again",
                                                     "in_place": true])
        XCTAssertFalse(inPlace.isError)
        XCTAssertEqual(f.a.tabs.count, before + 1, "no new tab")
        XCTAssertEqual(f.window.selectedTabID, opened.id)
        XCTAssertEqual(inPlace.content["routed"], false)
    }

    @MainActor private func route(_ pattern: String, to target: LinkRouteTarget) {
        let added = TabStore.shared.linkRoutes.add(
            LinkRoute(match: LinkRouteMatch(kind: .domainIs, pattern: pattern), sourceApp: nil, target: target))
        if let added { routeIDs.append(added.id) }
    }

    @MainActor func testOpenURLRefusesARouteIntoAPrivateWindow() async throws {
        let f = try makeFixture()
        route("automation-private.test", to: .privateWindow)
        let before = f.a.tabs.count
        let code = try await errorCode(f, "open_url", ["window_id": .int(f.windowID),
                                                       "url": "http://automation-private.test/"])
        XCTAssertEqual(code, "private_unreachable")
        XCTAssertEqual(f.a.tabs.count, before, "nothing opened")

        // Loading in place never routes, so it is not refused.
        let tab = addTab("http://127.0.0.1:9/a", in: f.a)
        f.window.selectTab(id: tab.id)
        let inPlace = try await call(f, "open_url", ["window_id": .int(f.windowID),
                                                     "url": "http://automation-private.test/", "in_place": true])
        XCTAssertFalse(inPlace.isError, inPlace.content.jsonString)
        XCTAssertEqual(inPlace.content["routed"], false)
    }

    @MainActor func testOpenURLReportsARouteToAnotherSpace() async throws {
        let f = try makeFixture()
        route("automation-b.test", to: .space(f.b.id))
        let (content, isError) = try await call(f, "open_url", ["window_id": .int(f.windowID),
                                                                "url": "http://automation-b.test/"])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(content["routed"], true)
        XCTAssertEqual(f.b.tabs.count, 1, "the tab opened in space B")
    }

    @MainActor func testOpenURLRefusesWhatIsNotAURL() async throws {
        let f = try makeFixture()
        let code = try await errorCode(f, "open_url", ["window_id": .int(f.windowID), "url": "two words"])
        XCTAssertEqual(code, "invalid_arguments")
        let unknownWindow = try await errorCode(f, "open_url", ["window_id": 9999, "url": "example.com"])
        XCTAssertEqual(unknownWindow, "unknown_window")
    }

    // MARK: run_menu_item

    /// A menu bar with a Spaces menu whose items go to the window's responder
    /// chain (no target), as the real menu's do.
    @MainActor private static func testMenu() -> NSMenu {
        let bar = NSMenu(title: "Main")
        let spacesItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let spaces = NSMenu(title: "Spaces")
        let next = NSMenuItem(title: "Next Space", action: #selector(BrowserWindowController.nextSpace(_:)), keyEquivalent: "]")
        next.keyEquivalentModifierMask = [.command, .option]
        spaces.addItem(next)
        spaces.addItem(.separator())
        let nested = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        nested.submenu = NSMenu(title: "More")
        spaces.addItem(nested)
        spacesItem.submenu = spaces
        bar.addItem(spacesItem)
        return bar
    }

    /// Next Space animates the sidebar to the space, and the window switches
    /// when the animation ends.
    @MainActor private func waitForActiveSpace(_ space: Space, in window: BrowserWindowController) async throws {
        let deadline = Date().addingTimeInterval(5)
        while window.activeSpaceID != space.id && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor func testRunMenuItemByPathGoesToTheWindowsResponderChain() async throws {
        let f = try makeFixture()
        let (content, isError) = try await call(f, "run_menu_item", ["window_id": .int(f.windowID),
                                                                     "path": ["Spaces", "Next Space"]])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(content["completed"], true)
        XCTAssertEqual(content["path"], ["Spaces", "Next Space"], "the bar item is named by its menu")
        try await waitForActiveSpace(f.b, in: f.window)
        XCTAssertEqual(f.window.activeSpaceID, f.b.id, "the window's own nextSpace ran, though it is not key")
    }

    @MainActor func testRunMenuItemByKeyEquivalentIsValidatedLikeAKeyPress() async throws {
        let f = try makeFixture()
        let (content, isError) = try await call(f, "run_menu_item", ["window_id": .int(f.windowID), "key": "cmd+option+]"])
        XCTAssertFalse(isError, content.jsonString)
        try await waitForActiveSpace(f.b, in: f.window)
        XCTAssertEqual(f.window.activeSpaceID, f.b.id)
        // B is the last space: the window's validation disables Next Space.
        let code = try await errorCode(f, "run_menu_item", ["window_id": .int(f.windowID), "key": "cmd+option+]"])
        XCTAssertEqual(code, "menu_item_disabled")
        XCTAssertEqual(f.window.activeSpaceID, f.b.id)
    }

    @MainActor func testRunMenuItemErrors() async throws {
        let f = try makeFixture()
        let window: JSONValue = .int(f.windowID)
        let cases: [(JSONValue, String)] = [
            (["window_id": window, "path": ["Spaces", "Nope"]], "unknown_menu_item"),
            (["window_id": window, "path": ["Nope"]], "unknown_menu_item"),
            (["window_id": window, "path": ["Spaces", "More"]], "unknown_menu_item"),
            (["window_id": window, "key": "cmd+k"], "unknown_menu_item"),
            (["window_id": window, "key": "hyper+k"], "invalid_arguments"),
            (["window_id": window], "invalid_arguments"),
            (["window_id": window, "key": "cmd+k", "path": ["Spaces"]], "invalid_arguments"),
            (["window_id": window, "path": []], "invalid_arguments"),
            (["window_id": 9999, "key": "cmd+k"], "unknown_window"),
        ]
        for (arguments, expected) in cases {
            let code = try await errorCode(f, "run_menu_item", arguments)
            XCTAssertEqual(code, expected, arguments.jsonString)
        }
    }

    @MainActor func testACommandStillRunningAfterTheWaitIsReportedNotCompleted() async throws {
        final class SlowTarget: NSObject {
            var finished = false
            @objc func slow(_ sender: Any?) {
                // Stands in for a modal alert: the action does not return for a while.
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                finished = true
            }
        }
        let target = SlowTarget()
        let bar = NSMenu(title: "Main")
        let barItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Test")
        let item = NSMenuItem(title: "Slow", action: #selector(SlowTarget.slow(_:)), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        barItem.submenu = menu
        bar.addItem(barItem)
        let f = try makeFixture(menu: bar)

        let (content, isError) = try await call(f, "run_menu_item", ["window_id": .int(f.windowID), "path": ["Test", "Slow"]])
        XCTAssertFalse(isError, content.jsonString)
        XCTAssertEqual(content["completed"], false)
        let deadline = Date().addingTimeInterval(5)
        while !target.finished && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(target.finished, "the command still ran to the end")
    }

    @MainActor func testKeyEquivalentsParse() throws {
        let (t, tMods) = try AutomationMenus.parseKeyEquivalent("Cmd+Shift+T")
        XCTAssertEqual(t, "t")
        XCTAssertEqual(tMods, [.command, .shift])
        let (down, downMods) = try AutomationMenus.parseKeyEquivalent("cmd+option+down")
        XCTAssertEqual(down, "\u{F701}")
        XCTAssertEqual(downMods, [.command, .option])
        XCTAssertEqual(try AutomationMenus.parseKeyEquivalent("ctrl+plus").0, "+")
        XCTAssertEqual(try AutomationMenus.parseKeyEquivalent("cmd+[").0, "[")
        XCTAssertThrowsError(try AutomationMenus.parseKeyEquivalent("cmd+"))
        XCTAssertThrowsError(try AutomationMenus.parseKeyEquivalent("cmd+pageup"))
    }
}
