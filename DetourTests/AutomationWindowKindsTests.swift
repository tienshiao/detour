import XCTest
import AppKit
@testable import Detour

/// The windows `window_id` names besides browser windows (TASK-228.7): Quick
/// Detour, quarantine and Settings windows are listed with their kind and
/// keep their ids; run_menu_item, screenshot and the input tools take them,
/// while the tools for spaces and tabs answer `unsupported_window`. A Private
/// Quick Detour and a quarantine window are left out and refused whatever the
/// Private setting (PROVISIONAL, `AutomationWindows.privateQuickDetourAccess`),
/// and so are menus over them and the Window menu's entries for them.
/// Settings takes input only in a test run, and never in its Automation
/// section.
nonisolated final class AutomationWindowKindsTests: XCTestCase {

    private var quickDetours: [QuickDetourWindowController] = []
    private var windows: [BrowserWindowController] = []
    private var spaceIDs: [UUID] = []
    private var settingsShown = false

    @MainActor override func tearDown() async throws {
        await AutomationMenuTracker.shared.closeAll()
        for controller in quickDetours where QuickDetourWindowController.openControllers.contains(where: { $0 === controller }) {
            controller.closeDisposition = .discard
            controller.close()
        }
        quickDetours.removeAll()
        if settingsShown { SettingsWindowController.shared.window?.close() }
        settingsShown = false
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
        TabStore.shared.undoManager.removeAllActions()
        try await super.tearDown()
    }

    private final class Setting {
        var allowed = false
        var testRun = false
    }

    private struct Fixture {
        let setting: Setting
        let tools: AutomationTools
        let server: MCPServer
        let browser: BrowserWindowController
        let quickDetour: QuickDetourWindowController
        let privateQuickDetour: QuickDetourWindowController
        let quarantine: QuickDetourWindowController
        let settings: SettingsWindowController?

        @MainActor func id(_ controller: NSWindowController) -> Int { tools.windowIDs.id(for: controller) }
    }

    /// A browser window, a Quick Detour, a Private Quick Detour and a
    /// quarantine window (and Settings with `settings`); a menu bar whose
    /// File menu closes a window and whose Window menu names each Quick
    /// Detour window.
    @MainActor private func makeFixture(settings showSettings: Bool = false) throws -> Fixture {
        let setting = Setting()
        let store = TabStore.shared
        let profile = try XCTUnwrap(store.profiles.first { !$0.isIncognito })
        let space = store.addSpace(name: "Automation Kinds", emoji: "K", colorHex: "007AFF", profileID: profile.id)
        spaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        windows.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)

        let quickDetour = QuickDetourWindowController.open(profile: profile, sourceSpace: space,
                                                           url: URL(string: "https://kinds.invalid/quick")!)
        let privateQuickDetour = QuickDetourWindowController.open(profile: store.ensureIncognitoProfile(),
                                                                  url: URL(string: "https://kinds.invalid/private")!)
        let quarantine = QuickDetourWindowController.openQuarantine(url: URL(string: "https://kinds.invalid/quarantine")!,
                                                                     privateProfile: store.ensureIncognitoProfile(),
                                                                     sourceSpace: space)
        quickDetours += [quickDetour, privateQuickDetour, quarantine]
        var settings: SettingsWindowController?
        if showSettings {
            settings = SettingsWindowController.shared
            settings?.showPane(named: "general")
            settingsShown = true
        }

        let bar = NSMenu(title: "Main")
        let fileItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: ""))
        fileItem.submenu = file
        bar.addItem(fileItem)
        let windowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        for (title, controller) in [("Quick Page", quickDetour), ("Private Quick Page", privateQuickDetour),
                                    ("Quarantined Page", quarantine)] {
            let entry = NSMenuItem(title: title, action: #selector(NSWindow.update), keyEquivalent: "")
            entry.target = controller.window
            windowMenu.addItem(entry)
        }
        windowItem.submenu = windowMenu
        bar.addItem(windowItem)

        let mine = quickDetours
        var environment = AutomationEnvironment(windowControllers: { [wc] }, mainMenu: { bar }, store: store)
        environment.otherWindows = {
            QuickDetourWindowController.openControllers.filter { open in mine.contains { $0 === open } }
                + (settings.map { [$0] } ?? [])
        }
        environment.allowsPrivate = { setting.allowed }
        environment.isTestRun = false
        let tools = AutomationTools(environment: environment)
        tools.inputWait = .milliseconds(400)
        tools.menuActionWait = .milliseconds(400)
        let server = MCPServer(tools: tools.all, serverVersion: "test", instructions: "")
        return Fixture(setting: setting, tools: tools, server: server, browser: wc, quickDetour: quickDetour,
                       privateQuickDetour: privateQuickDetour, quarantine: quarantine, settings: settings)
    }

    /// The same fixture's tools in a test run.
    @MainActor private func testRunServer(_ f: Fixture) -> (AutomationTools, MCPServer) {
        var environment = f.tools.environment
        environment.isTestRun = true
        let tools = AutomationTools(environment: environment)
        tools.inputWait = .milliseconds(400)
        tools.menuActionWait = .milliseconds(400)
        return (tools, MCPServer(tools: tools.all, serverVersion: "test", instructions: ""))
    }

    @MainActor private func call(_ server: MCPServer, _ name: String, _ arguments: JSONValue = [:]) async throws
        -> (content: JSONValue, isError: Bool) {
        let tool = try XCTUnwrap(server.tools.first { $0.name == name }, name)
        let result = await server.call(tool, arguments: arguments)
        return (try XCTUnwrap(result["structuredContent"]), result["isError"] == true)
    }

    @MainActor private func ok(_ server: MCPServer, _ name: String, _ arguments: JSONValue = [:]) async throws -> JSONValue {
        let (content, isError) = try await call(server, name, arguments)
        XCTAssertFalse(isError, "\(name) \(arguments.jsonString): \(content.jsonString)")
        return content
    }

    @MainActor private func code(_ server: MCPServer, _ name: String, _ arguments: JSONValue) async throws -> String? {
        let (content, isError) = try await call(server, name, arguments)
        XCTAssertTrue(isError, "\(name) \(arguments.jsonString) should fail: \(content.jsonString)")
        return content["error"]?["code"]?.stringValue
    }

    /// `view`'s centre in its window's content, top-left origin, as tools take it.
    @MainActor private func contentCentre(of view: NSView) throws -> JSONValue {
        let content = try XCTUnwrap(view.window?.contentView)
        let r = view.convert(view.bounds, to: content)
        return ["x": .double(r.midX), "y": .double(content.isFlipped ? r.midY : content.bounds.height - r.midY)]
    }

    @MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    // MARK: Listing

    @MainActor func testQuickDetourAndSettingsWindowsAreListedWithTheirKindAndKeepTheirIDs() async throws {
        let f = try makeFixture(settings: true)
        let settings = try XCTUnwrap(f.settings)
        for allowed in [false, true] {
            f.setting.allowed = allowed
            let content = try await ok(f.server, "list_windows")
            let listed = try XCTUnwrap(content["windows"]?.arrayValue)
            let kinds = Dictionary(uniqueKeysWithValues: listed.compactMap { entry in
                entry["window_id"]?.intValue.map { ($0, entry["kind"]?.stringValue ?? "") }
            })
            XCTAssertEqual(kinds, [f.id(f.browser): "browser", f.id(f.quickDetour): "quick_detour",
                                   f.id(settings): "settings"],
                           "the Private Quick Detour and the quarantine are left out (allowed: \(allowed))")
            XCTAssertEqual(content["hidden_private_windows"], 2)
            let quick = try XCTUnwrap(listed.first { $0["kind"] == "quick_detour" })
            XCTAssertEqual(quick["is_private"], false)
            XCTAssertEqual(quick["selected_tab_url"], "https://kinds.invalid/quick")
            XCTAssertEqual(quick["selected_tab_id"], .null, "the page tools do not take a Quick Detour's page")
            XCTAssertEqual(quick["active_space_id"], .null)
            XCTAssertEqual(quick["window_number"]?.intValue, f.quickDetour.window?.windowNumber)
        }
        // Ids come from one counter and stay as they were.
        let before = [f.browser, f.quickDetour, settings].map(f.id)
        _ = try await ok(f.server, "list_windows")
        XCTAssertEqual([f.browser, f.quickDetour, settings].map(f.id), before)
        XCTAssertEqual(Set(before).count, 3)
    }

    @MainActor func testPrivateQuickDetourAndQuarantineWindowsAreRefusedWhateverTheSetting() async throws {
        let f = try makeFixture()
        XCTAssertEqual(AutomationWindows.privateQuickDetourAccess, .never,
                       "PROVISIONAL: change this test with the setting if they come to follow the opt-in")
        for allowed in [false, true] {
            f.setting.allowed = allowed
            for controller in [f.privateQuickDetour, f.quarantine] {
                let id: JSONValue = .int(f.id(controller))
                for (tool, arguments) in [
                    ("screenshot", ["window_id": id, "include_image": false]),
                    ("hit_test", ["window_id": id, "x": 10, "y": 10]),
                    ("click", ["window_id": id, "x": 10, "y": 10]),
                    ("press_key", ["window_id": id, "key": "escape"]),
                    ("run_menu_item", ["window_id": id, "path": ["File", "Close Window"]]),
                    ("list_tabs", ["window_id": id]),
                ] as [(String, JSONValue)] {
                    let refused = try await code(f.server, tool, arguments)
                    XCTAssertEqual(refused, "private_unreachable", "\(tool) allowed: \(allowed)")
                }
            }
            // The Window menu's entries for them are neither matched nor listed.
            let message = try await call(f.server, "run_menu_item", ["window_id": .int(f.id(f.browser)),
                                                                    "path": ["Window", "Quarantined Page"]])
            XCTAssertEqual(message.content["error"]?["code"], "unknown_menu_item")
            let windowMenu = try XCTUnwrap(f.tools.environment.mainMenu()?.items.last?.submenu)
            XCTAssertEqual(AutomationMenuTracker.describe(windowMenu, allowPrivate: allowed)
                .compactMap { $0["title"]?.stringValue }, ["Quick Page"])
        }
        XCTAssertEqual(AutomationWindows.access(of: f.quarantine.window), .never)
        XCTAssertEqual(AutomationWindows.access(of: f.privateQuickDetour.window), .never)
        XCTAssertEqual(AutomationWindows.access(of: f.quickDetour.window), .open)
    }

    @MainActor func testAMenuOpenedOverAPrivateQuickDetourIsRefused() async throws {
        let f = try makeFixture()
        f.setting.allowed = true
        let window = try XCTUnwrap(f.quarantine.window)
        let menu = NSMenu(title: "Quarantine Menu")
        menu.addItem(NSMenuItem(title: "Item", action: nil, keyEquivalent: ""))
        // The person's right click in the quarantine window: the current event is theirs there.
        let press = try XCTUnwrap(AutomationInput.mouseEvent(.rightMouseDown, at: NSPoint(x: 20, y: 20), in: window,
                                                             modifiers: [], clickCount: 1))
        // The tracker hears that the menu began tracking while the press was
        // current. AppKit's own notification is posted by hand: a context menu
        // popped up from the test in a Quick Detour window held the main queue
        // in the test host.
        AutomationInput.makeCurrent(press)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }
        XCTAssertTrue(AutomationMenuTracker.shared.topMenu === menu, "the tracker took the menu")
        XCTAssertEqual(AutomationMenuTracker.shared.access(of: menu), .never)
        let refused = try await code(f.server, "list_menu", ["timeout_ms": 500])
        XCTAssertEqual(refused, "private_unreachable", "even with Private windows allowed")
        let chosen = try await code(f.server, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        XCTAssertEqual(chosen, "private_unreachable")
    }

    // MARK: Quick Detour windows

    @MainActor func testAQuickDetourTakesMenuCommandsScreenshotsAndInputButNotTabTools() async throws {
        let f = try makeFixture()
        let id: JSONValue = .int(f.id(f.quickDetour))
        let shot = try await ok(f.server, "screenshot", ["window_id": id, "include_image": false])
        let content = try XCTUnwrap(f.quickDetour.window?.contentView)
        XCTAssertEqual(shot["width"]?.intValue, Int(content.bounds.width.rounded()))

        // A point in the page reaches its web view.
        let webView = try XCTUnwrap(f.quickDetour.tab?.webView)
        let point = try contentCentre(of: webView)
        let hit = try await ok(f.server, "hit_test", ["window_id": id, "x": point["x"]!, "y": point["y"]!])
        XCTAssertEqual(hit["target"], "web_view")
        let clicked = try await ok(f.server, "click", ["window_id": id, "x": point["x"]!, "y": point["y"]!])
        XCTAssertEqual(clicked["target"], "web_view")
        XCTAssertEqual(clicked["window_id"], id)

        for (tool, arguments) in [
            ("list_tabs", ["window_id": id]),
            ("select_tab", ["window_id": id, "id": .string(UUID().uuidString)]),
            ("open_url", ["window_id": id, "url": "https://kinds.invalid/other"]),
            ("screenshot", ["window_id": id, "part": "sidebar", "include_image": false]),
        ] as [(String, JSONValue)] {
            let refused = try await code(f.server, tool, arguments)
            XCTAssertEqual(refused, "unsupported_window", tool)
        }

        // The command goes to the Quick Detour window's own responder chain.
        let ran = try await ok(f.server, "run_menu_item", ["window_id": id, "path": ["File", "Close Window"]])
        XCTAssertEqual(ran["completed"], true)
        f.quickDetour.closeDisposition = .discard
        let deadline = Date().addingTimeInterval(3)
        while QuickDetourWindowController.openControllers.contains(where: { $0 === f.quickDetour }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(QuickDetourWindowController.openControllers.contains { $0 === f.quickDetour }, "it closed")
        let gone = try await code(f.server, "hit_test", ["window_id": id, "x": 10, "y": 10])
        XCTAssertEqual(gone, "unknown_window")
    }

    // MARK: Settings

    /// Settings' window once it has animated to the pane's height (its frame
    /// holds), laid out.
    @MainActor private func settledWindow(_ settings: SettingsWindowController) async throws -> NSWindow {
        let settingsWindow = try XCTUnwrap(settings.window)
        var last = NSRect.zero
        let deadline = Date().addingTimeInterval(3)
        while settingsWindow.frame != last && Date() < deadline {
            last = settingsWindow.frame
            try await Task.sleep(for: .milliseconds(150))
        }
        try XCTUnwrap(settingsWindow.contentView).layoutSubtreeIfNeeded()
        return settingsWindow
    }

    /// A person's press: made here, not by `AutomationInput.mouseEvent`, so
    /// the tools do not take it for one of theirs.
    @MainActor private func personsPress(at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime - 0.5,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 7,
                                         clickCount: 1, pressure: 1))
    }

    /// Leaves a release current, so no press is left for a later menu to wait on.
    @MainActor private func releaseCurrentPress(in window: NSWindow) {
        if let release = AutomationInput.mouseEvent(.rightMouseUp, at: NSPoint(x: 1, y: 1), in: window,
                                                    modifiers: [], clickCount: 1) {
            AutomationInput.makeCurrent(release)
        }
    }

    @MainActor func testAHitTestBeforeThePersonsMenuOpensDoesNotOpenItUp() async throws {
        let f = try makeFixture()
        f.setting.allowed = true
        let quarantineWindow = try XCTUnwrap(f.quarantine.window)
        // The person right-clicks the quarantine's page; WebKit's menu opens
        // some time later, and an agent's hit_test runs in between.
        XCTAssertTrue(AutomationInput.makeCurrent(try personsPress(at: NSPoint(x: 20, y: 20), in: quarantineWindow)))
        defer { releaseCurrentPress(in: quarantineWindow) }
        _ = try await ok(f.server, "hit_test", ["window_id": .int(f.id(f.browser)), "x": 10, "y": 10])
        XCTAssertTrue(NSApp.currentEvent.map(AutomationInput.isSynthetic) ?? false, "the hit test's event is current")
        let menu = NSMenu(title: "Page Menu")
        menu.addItem(NSMenuItem(title: "Item", action: nil, keyEquivalent: ""))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }
        XCTAssertEqual(AutomationMenuTracker.shared.access(of: menu), .never)
        let refused = try await code(f.server, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        XCTAssertEqual(refused, "private_unreachable")
    }

    @MainActor func testAWindowHangingOffAChildOfAPrivateQuickDetourIsAsUnreachable() throws {
        let f = try makeFixture()
        let quarantineWindow = try XCTUnwrap(f.quarantine.window)
        let rect = NSRect(x: 0, y: 0, width: 40, height: 40)
        let child = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
        let grandchild = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: true)
        child.isReleasedWhenClosed = false
        grandchild.isReleasedWhenClosed = false
        quarantineWindow.addChildWindow(child, ordered: .above)
        child.addChildWindow(grandchild, ordered: .above)
        defer {
            child.removeChildWindow(grandchild)
            quarantineWindow.removeChildWindow(child)
            grandchild.orderOut(nil)
            child.orderOut(nil)
        }
        XCTAssertEqual(AutomationWindows.access(of: grandchild), .never, "a popover on a popover of the quarantine")
        XCTAssertEqual(AutomationWindows.access(of: f.browser.window), .open)
    }

    @MainActor func testAMenuOverSettingsIsChosenOnlyInATestRunAndNeverOverTheAutomationSection() async throws {
        let f = try makeFixture(settings: true)
        let settingsWindow = try await settledWindow(try XCTUnwrap(f.settings))
        let switches = views(NSSwitch.self, in: try XCTUnwrap(settingsWindow.contentView))
        let automationSwitch = try XCTUnwrap(switches.first { $0.accessibilityIdentifier() == "automationEnabled" })
        let otherSwitch = try XCTUnwrap(switches.first { !AutomationWindows.isInAutomationSettings($0) })
        settingsWindow.makeFirstResponder(otherSwitch)
        let (_, testRun) = testRunServer(f)
        defer { releaseCurrentPress(in: settingsWindow) }

        func openMenu(pressedOn view: NSView) throws -> NSMenu {
            let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            XCTAssertTrue(AutomationInput.makeCurrent(try personsPress(at: centre, in: settingsWindow)))
            let menu = NSMenu(title: "Settings Menu")
            menu.addItem(NSMenuItem(title: "Item", action: nil, keyEquivalent: ""))
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            return menu
        }

        // A menu over Settings outside the Automation section: listed on any
        // endpoint, chosen from only in a test run.
        let menu = try openMenu(pressedOn: otherSwitch)
        XCTAssertEqual(AutomationMenuTracker.shared.settingsReach(of: menu), .settings)
        _ = try await ok(f.server, "list_menu", ["timeout_ms": 500])
        let refused = try await code(f.server, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        XCTAssertEqual(refused, "gate_closed")
        _ = try await ok(testRun, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)

        // An agent's menu over the browser window after the person's last
        // press was in Settings is not taken for one over Settings.
        let browserWindow = try XCTUnwrap(f.browser.window)
        browserWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(AutomationInput.makeCurrent(try personsPress(at: NSPoint(x: 20, y: 20), in: settingsWindow)))
        let agentsPress = try XCTUnwrap(AutomationInput.mouseEvent(.rightMouseDown, at: NSPoint(x: 20, y: 20),
                                                                   in: browserWindow, modifiers: [], clickCount: 1))
        XCTAssertTrue(AutomationInput.makeCurrent(agentsPress))
        let agentsMenu = NSMenu(title: "Agent's Menu")
        agentsMenu.addItem(NSMenuItem(title: "Item", action: nil, keyEquivalent: ""))
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: agentsMenu)
        XCTAssertEqual(AutomationMenuTracker.shared.settingsReach(of: agentsMenu), .none)
        _ = try await ok(f.server, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: agentsMenu)

        // One opened by a press on the Automation section's switch: never.
        let section = try openMenu(pressedOn: automationSwitch)
        defer { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: section) }
        XCTAssertEqual(AutomationMenuTracker.shared.settingsReach(of: section), .automationSection)
        let sectionRefused = try await code(testRun, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        XCTAssertEqual(sectionRefused, "gate_closed")
    }

    @MainActor func testSettingsCanBeSeenOnAnyEndpointButTakesInputOnlyInATestRun() async throws {
        let f = try makeFixture(settings: true)
        let settings = try XCTUnwrap(f.settings)
        let id: JSONValue = .int(f.id(settings))
        // Settings animates to the pane's height: wait until its frame holds.
        let settingsWindow = try await settledWindow(settings)
        let paneView = try XCTUnwrap(settingsWindow.contentView)
        let switches = views(NSSwitch.self, in: paneView)
        let automationSwitch = try XCTUnwrap(switches.first { $0.accessibilityIdentifier() == "automationEnabled" })
        let privateSwitch = try XCTUnwrap(switches.first { $0.accessibilityIdentifier() == "automationAllowPrivate" })
        let otherSwitch = try XCTUnwrap(switches.first { !AutomationWindows.isInAutomationSettings($0) },
                                        "General has switches outside its Automation section")
        let other = try contentCentre(of: otherSwitch)

        // Read-only tools work on the user's endpoint.
        _ = try await ok(f.server, "screenshot", ["window_id": id, "include_image": false])
        let hit = try await ok(f.server, "hit_test", ["window_id": id, "x": other["x"]!, "y": other["y"]!])
        XCTAssertEqual(hit["view"], "NSSwitch")
        // Input and commands do not.
        settings.window?.makeFirstResponder(otherSwitch)
        for (tool, arguments) in [
            ("click", ["window_id": id, "x": other["x"]!, "y": other["y"]!]),
            ("press_key", ["window_id": id, "key": "space"]),
            ("type_text", ["window_id": id, "text": "a"]),
            ("run_menu_item", ["window_id": id, "path": ["File", "Close Window"]]),
        ] as [(String, JSONValue)] {
            let refused = try await code(f.server, tool, arguments)
            XCTAssertEqual(refused, "gate_closed", tool)
        }
        XCTAssertEqual(settings.window?.isVisible, true)

        // A test run clicks and types there, except in the Automation section.
        let (testRunTools, testRun) = testRunServer(f)
        let testRunID: JSONValue = .int(testRunTools.windowIDs.id(for: settings))
        let otherBefore = otherSwitch.state
        // The click changes the stored setting; a failure between the two
        // clicks must not leave it changed for the rest of the run.
        let peekBefore = PeekSettings.shared.isEnabled
        defer { PeekSettings.shared.isEnabled = peekBefore }
        let clicked = try await ok(testRun, "click", ["window_id": testRunID, "x": other["x"]!, "y": other["y"]!])
        XCTAssertEqual(clicked["view"], "NSSwitch")
        XCTAssertNotEqual(otherSwitch.state, otherBefore, "the switch toggled, as with a person's click (TASK-228.8)")
        _ = try await ok(testRun, "click", ["window_id": testRunID, "x": other["x"]!, "y": other["y"]!])
        XCTAssertEqual(otherSwitch.state, otherBefore, "and back")
        for control in [automationSwitch, privateSwitch] {
            let point = try contentCentre(of: control)
            let before = control.state
            let refused = try await code(testRun, "click", ["window_id": testRunID, "x": point["x"]!, "y": point["y"]!])
            XCTAssertEqual(refused, "gate_closed")
            settings.window?.makeFirstResponder(control)
            let key = try await code(testRun, "press_key", ["window_id": testRunID, "key": "space"])
            XCTAssertEqual(key, "gate_closed")
            let command = try await code(testRun, "run_menu_item", ["window_id": testRunID,
                                                                    "path": ["File", "Close Window"]])
            XCTAssertEqual(command, "gate_closed")
            XCTAssertEqual(control.state, before)
        }
        settings.window?.makeFirstResponder(otherSwitch)
        let ran = try await ok(testRun, "run_menu_item", ["window_id": testRunID, "path": ["File", "Close Window"]])
        XCTAssertEqual(ran["completed"], true)
        XCTAssertEqual(settings.window?.isVisible, false, "the command went to Settings' own window")
    }

    /// A pop-up in Settings opens for a test run's click as for a person's
    /// (TASK-228.8), and is refused on the user's endpoint.
    @MainActor func testASettingsPopUpOpensForATestRunsClick() async throws {
        let f = try makeFixture(settings: true)
        let settings = try XCTUnwrap(f.settings)
        settings.showPane(named: "quickdetour")
        let settingsWindow = try await settledWindow(settings)
        let popUp = try XCTUnwrap(views(NSPopUpButton.self, in: try XCTUnwrap(settingsWindow.contentView))
            .first { $0.accessibilityIdentifier() == "quickDetourIdleTimeout" })
        let point = try contentCentre(of: popUp)
        let refused = try await code(f.server, "click", ["window_id": .int(f.id(settings)),
                                                         "x": point["x"]!, "y": point["y"]!])
        XCTAssertEqual(refused, "gate_closed")

        let (testRunTools, testRun) = testRunServer(f)
        let id: JSONValue = .int(testRunTools.windowIDs.id(for: settings))
        let (clicked, clickError) = try await call(testRun, "click", ["window_id": id, "x": point["x"]!, "y": point["y"]!])
        let (listed, listError) = try await call(testRun, "list_menu", ["timeout_ms": 3000])
        // Closed before any unwrap can throw, so a failure leaves no menu open.
        await AutomationMenuTracker.shared.closeAll()
        XCTAssertFalse(clickError, clicked.jsonString)
        XCTAssertEqual(clicked["view"], "NSPopUpButton")
        XCTAssertEqual(clicked["menu_open"], true, clicked.jsonString)
        XCTAssertFalse(listError, listed.jsonString)
        let titles = listed["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        XCTAssertEqual(titles, popUp.itemTitles, "the pop-up's own menu")
    }
}
