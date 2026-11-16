import XCTest
import AppKit
@testable import Detour

/// The windows `window_id` names besides browser windows (TASK-228.7): Quick
/// Detour, quarantine and Settings windows are listed with their kind and
/// keep their ids; run_menu_item, screenshot and the input tools take them,
/// while the tools for spaces and tabs answer `unsupported_window`. A Private
/// Quick Detour and a quarantine window follow "Allow agents to use Private
/// windows" as Private browser windows do (the user's decision,
/// `AutomationWindows.privateQuickDetourAccess`): left out and refused while
/// it is off, and so are menus over them and the Window menu's entries for
/// them; listed and reachable while it is on.
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
            if allowed {
                XCTAssertEqual(kinds, [f.id(f.browser): "browser", f.id(f.quickDetour): "quick_detour",
                                       f.id(f.privateQuickDetour): "quick_detour", f.id(f.quarantine): "quarantine",
                                       f.id(settings): "settings"],
                               "with Private windows allowed, the Private Quick Detour and the quarantine are listed")
                XCTAssertEqual(content["hidden_private_windows"], 0)
                for controller in [f.privateQuickDetour, f.quarantine] {
                    let entry = try XCTUnwrap(listed.first { $0["window_id"]?.intValue == f.id(controller) })
                    XCTAssertEqual(entry["is_private"], true)
                }
            } else {
                XCTAssertEqual(kinds, [f.id(f.browser): "browser", f.id(f.quickDetour): "quick_detour",
                                       f.id(settings): "settings"],
                               "the Private Quick Detour and the quarantine are left out while Private is off")
                XCTAssertEqual(content["hidden_private_windows"], 2)
            }
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

    /// Off: refused by every window tool, their Window-menu entries neither
    /// matched nor listed.
    @MainActor func testPrivateQuickDetourAndQuarantineWindowsAreRefusedWhilePrivateIsOff() async throws {
        let f = try makeFixture()
        XCTAssertEqual(AutomationWindows.privateQuickDetourAccess, .privateOptIn,
                       "the user's decision: they follow the Private setting")
        f.setting.allowed = false
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
                XCTAssertEqual(refused, "private_unreachable", tool)
            }
            let (testRunTools, testRun) = testRunServer(f)
            let frame: [String: JSONValue] = ["x": 40, "y": 80, "width": 500, "height": 400]
            let selectors: [[String: JSONValue]] = [["window_id": .int(testRunTools.windowIDs.id(for: controller))],
                                                    ["window_number": .int(try XCTUnwrap(controller.window).windowNumber)]]
            for selector in selectors {
                let refused = try await code(testRun, "set_window_frame", .object(frame.merging(selector) { $1 }))
                XCTAssertEqual(refused, "private_unreachable", "set_window_frame \(selector.keys.sorted())")
            }
        }
        // The Window menu's entries for them are neither matched nor listed.
        let message = try await call(f.server, "run_menu_item", ["window_id": .int(f.id(f.browser)),
                                                                "path": ["Window", "Quarantined Page"]])
        XCTAssertEqual(message.content["error"]?["code"], "unknown_menu_item")
        let windowMenu = try XCTUnwrap(f.tools.environment.mainMenu()?.items.last?.submenu)
        XCTAssertEqual(AutomationMenuTracker.describe(windowMenu, allowPrivate: false)
            .compactMap { $0["title"]?.stringValue }, ["Quick Page"])
        XCTAssertEqual(AutomationWindows.access(of: f.quarantine.window), .privateOptIn)
        XCTAssertEqual(AutomationWindows.access(of: f.privateQuickDetour.window), .privateOptIn)
        XCTAssertEqual(AutomationWindows.access(of: f.quickDetour.window), .open)
    }

    /// On: reachable as a Quick Detour is (screenshot, hit_test and a click
    /// into the page, set_window_frame by id and by number, the Window
    /// menu's entries, a menu command), the tools for spaces and tabs still
    /// `unsupported_window`.
    @MainActor func testPrivateQuickDetourAndQuarantineWindowsAreReachableWhilePrivateIsOn() async throws {
        let f = try makeFixture()
        f.setting.allowed = true
        let (testRunTools, testRun) = testRunServer(f)
        for controller in [f.privateQuickDetour, f.quarantine] {
            let id: JSONValue = .int(f.id(controller))
            let shot = try await ok(f.server, "screenshot", ["window_id": id, "include_image": false])
            let content = try XCTUnwrap(controller.window?.contentView)
            XCTAssertEqual(shot["width"]?.intValue, Int(content.bounds.width.rounded()))
            let webView = try XCTUnwrap(controller.tab?.webView)
            let point = try contentCentre(of: webView)
            let hit = try await ok(f.server, "hit_test", ["window_id": id, "x": point["x"]!, "y": point["y"]!])
            XCTAssertEqual(hit["target"], "web_view")
            let clicked = try await ok(f.server, "click", ["window_id": id, "x": point["x"]!, "y": point["y"]!])
            XCTAssertEqual(clicked["target"], "web_view")
            let refused = try await code(f.server, "list_tabs", ["window_id": id])
            XCTAssertEqual(refused, "unsupported_window", "a Quick Detour's page is no tab of a space")
            let window = try XCTUnwrap(controller.window)
            let frame: [String: JSONValue] = ["x": 40, "y": 80, "width": 720, "height": 480]
            let selectors: [[String: JSONValue]] = [["window_id": .int(testRunTools.windowIDs.id(for: controller))],
                                                    ["window_number": .int(window.windowNumber)]]
            for selector in selectors {
                _ = try await ok(testRun, "set_window_frame", .object(frame.merging(selector) { $1 }))
                XCTAssertEqual(window.frame.size, NSSize(width: 720, height: 480), "set_window_frame \(selector.keys.sorted())")
            }
        }
        // The Window menu's entries for them are listed and run.
        let windowMenu = try XCTUnwrap(f.tools.environment.mainMenu()?.items.last?.submenu)
        XCTAssertEqual(AutomationMenuTracker.describe(windowMenu, allowPrivate: true)
            .compactMap { $0["title"]?.stringValue }, ["Quick Page", "Private Quick Page", "Quarantined Page"])
        let entry = try await ok(f.server, "run_menu_item", ["window_id": .int(f.id(f.browser)),
                                                            "path": ["Window", "Quarantined Page"]])
        XCTAssertEqual(entry["completed"], true)

        // A command goes to the Private Quick Detour's own responder chain.
        f.privateQuickDetour.closeDisposition = .discard
        let ran = try await ok(f.server, "run_menu_item", ["window_id": .int(f.id(f.privateQuickDetour)),
                                                          "path": ["File", "Close Window"]])
        XCTAssertEqual(ran["completed"], true)
        let deadline = Date().addingTimeInterval(3)
        while QuickDetourWindowController.openControllers.contains(where: { $0 === f.privateQuickDetour })
            && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(QuickDetourWindowController.openControllers.contains { $0 === f.privateQuickDetour }, "it closed")

        // Turned off again: refused at once.
        f.setting.allowed = false
        let refused = try await code(f.server, "screenshot", ["window_id": .int(f.id(f.quarantine)), "include_image": false])
        XCTAssertEqual(refused, "private_unreachable")
    }

    @MainActor func testAMenuOpenedOverAQuarantineFollowsThePrivateSetting() async throws {
        let f = try makeFixture()
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
        XCTAssertEqual(AutomationMenuTracker.shared.access(of: menu), .privateOptIn)
        f.setting.allowed = false
        let refused = try await code(f.server, "list_menu", ["timeout_ms": 500])
        XCTAssertEqual(refused, "private_unreachable", "with Private windows off")
        let chosen = try await code(f.server, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        XCTAssertEqual(chosen, "private_unreachable")
        f.setting.allowed = true
        let listed = try await ok(f.server, "list_menu", ["timeout_ms": 500])
        XCTAssertEqual(listed["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["Item"],
                       "with Private windows allowed: \(listed.jsonString)")
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
        f.setting.allowed = false
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
        XCTAssertEqual(AutomationMenuTracker.shared.access(of: menu), .privateOptIn,
                       "noted as over the quarantine, not the hit-tested browser window")
        let refused = try await code(f.server, "choose_menu_item", ["title": "Item", "timeout_ms": 500])
        XCTAssertEqual(refused, "private_unreachable")
    }

    @MainActor func testAWindowHangingOffAChildOfAPrivateQuickDetourIsReachedAsItIs() throws {
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
        XCTAssertEqual(AutomationWindows.access(of: grandchild), .privateOptIn, "a popover on a popover of the quarantine")
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
        // The fixture's quarantine can be the key window while the test host
        // is active, and the tracker then notes the pop-up's menu as over a
        // Private window: allowed here, so only the Settings gates count.
        f.setting.allowed = true
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

    /// A row of a Settings list selects for a test run's click with the
    /// window not key and the test host in the background, as with Detour in
    /// the background (TASK-228.12). Before, `-[NSTableView mouseDown:]` gave
    /// up on the press (the trap TASK-228.9 met in the sidebar); every list
    /// in Settings is now an `AutomationTableView`.
    @MainActor func testARowOfASettingsListSelectsForATestRunsClick() async throws {
        try XCTSkipIf(NSApp.isActive, "needs the test host in the background, as Detour is when an agent drives it")
        let f = try makeFixture(settings: true)
        let settings = try XCTUnwrap(f.settings)
        // Through the toolbar, as a person switches: `showPane` also shows
        // the window, which activates the app.
        let toolbar = try XCTUnwrap(settings.window?.toolbar)
        func show(_ pane: String) throws {
            let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == pane }, pane)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item), pane)
        }
        for pane in ["general", "spaces", "links", "quickdetour", "profiles", "search", "shortcuts", "extensions",
                     "contentblocker"] {
            try show(pane)
            for table in settings.visiblePaneTables {
                XCTAssertTrue(table is AutomationTableView, "\(pane)'s \(type(of: table)) takes the endpoint's press")
            }
        }

        let (tools, testRun) = testRunServer(f)
        let settingsID: JSONValue = .int(tools.windowIDs.id(for: settings))
        // The lists with two rows or more in the test host (the fixture's
        // space, the private profile, the built-in site searches).
        for pane in ["spaces", "profiles", "search"] {
            try show(pane)
            let settingsWindow = try await settledWindow(settings)
            let table = try XCTUnwrap(settings.visiblePaneTables.first, pane)
            XCTAssertGreaterThanOrEqual(table.numberOfRows, 2, pane)
            let target = table.selectedRow == 1 ? 0 : 1
            let content = try XCTUnwrap(settingsWindow.contentView)
            let rect = table.rect(ofRow: target)
            let point = table.convert(NSPoint(x: rect.minX + min(60, rect.width / 3), y: rect.midY), to: content)
            XCTAssertFalse(settingsWindow.isKeyWindow, pane)
            try XCTSkipIf(NSApp.isActive, "the test host became active (\(pane)): not a background click")

            let clicked = try await ok(testRun, "click", ["window_id": settingsID, "x": .double(point.x),
                                                          "y": .double(content.isFlipped ? point.y
                                                                       : content.bounds.height - point.y)])
            XCTAssertEqual(clicked["view"], "AutomationTableView", pane)
            XCTAssertEqual(table.selectedRow, target, "\(pane): the clicked row is selected")
            XCTAssertFalse(NSApp.isActive, "\(pane): the click did not activate the app")
            XCTAssertFalse(settingsWindow.isKeyWindow, "\(pane): nor make the window key")
            XCTAssertTrue(table.needsPanelToBecomeKey, "outside the endpoint's press the table is as AppKit made it")
            XCTAssertNil(AutomationInput.viewTakingPress)
            XCTAssertNil(NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking,
                                         dequeue: false), "\(pane): the table's tracking took the release")
        }
    }
}
