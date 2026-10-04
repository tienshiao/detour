import XCTest
import WebKit
@testable import Detour

/// TASK-132.8: `chrome.sidePanel` end to end — the API called from a real
/// extension's service worker and from one of its pages, the panel Detour
/// builds for it, and where the windows put it.
///
/// Production wiring throughout: real `Profile`s, `TabStore.shared`, tabs
/// added through the store, and real `BrowserWindowController`s that are never
/// shown (so never key).
@MainActor
final class ExtensionSidePanelTests: XCTestCase {

    private typealias Via = SidePanelTestWorld.Via
    private var world: SidePanelTestWorld!

    override func setUp() async throws {
        try await super.setUp()
        world = SidePanelTestWorld()
        try await world.setUp()
    }

    override func tearDown() async throws {
        await world.tearDown()
        world = nil
        try await super.tearDown()
    }

    /// One profile, one space, one window, the extension loaded, two tabs with
    /// the first selected.
    private struct Scene {
        let loaded: SidePanelTestWorld.Loaded
        let space: Space
        let window: BrowserWindowController
        let first: BrowserTab
        let second: BrowserTab
        var profile: Profile { loaded.profile }
        var panels: ExtensionSidePanelController { loaded.profile.sidePanels }
    }

    private func makeScene(_ name: String, permissions: [String] = ["sidePanel"],
                           defaultPath: String? = "panel.html") async throws -> Scene {
        let ext = try await world.makeExtension(permissions: permissions, defaultPath: defaultPath)
        let profile = world.makeProfile(name)
        let space = world.makeSpace(name, in: profile)
        let window = world.makeWindow(on: space)
        let first = try await world.addTab("one", in: space)
        let second = try await world.addTab("two", in: space)
        window.selectTab(id: first.id)
        let loaded = try await world.load(ext, in: profile)
        return Scene(loaded: loaded, space: space, window: window, first: first, second: second)
    }

    /// As the Claude extension opens its panel: tab options, then open.
    @discardableResult
    private func openTabPanel(_ via: Via, in scene: Scene, for tab: BrowserTab,
                              file: StaticString = #filePath, line: UInt = #line) async throws -> ExtensionSidePanel {
        let tabID = try await world.tabID(of: tab, via, in: scene.loaded)
        let settled = try await world.run(via, in: scene.loaded, [
            "op": "setOptionsThenOpen",
            "options": ["tabId": tabID, "path": "tabpanel.html?tabId=\(tabID)", "enabled": true],
            "target": ["tabId": tabID],
        ])
        XCTAssertEqual(settled as? [String], ["ok", "ok"], "[\(via)]", file: file, line: line)
        let panel = try XCTUnwrap(scene.panels.panels(for: scene.loaded.ext.id).first { $0.tab === tab },
                                  "[\(via)] no panel was opened for the tab", file: file, line: line)
        return panel
    }

    private func layoutFrames(of window: BrowserWindowController) -> (content: NSRect, panel: NSRect?) {
        window.window?.layoutIfNeeded()
        return (window.contentContainerView.frame, window.contentAreaView.panelView?.frame)
    }

    // MARK: - The API exists only with the permission (AC #9)

    func testTheNamespaceExistsInTheWorkerAndInAPageWithThePermission() async throws {
        let scene = try await makeScene("Panel Namespace")
        for via in Via.allCases {
            let state = try await world.runDict(via, in: scene.loaded, ["op": "install"])
            XCTAssertEqual(state["type"] as? String, "object", "[\(via)]")
            XCTAssertEqual(state["install"] as? String, "polyfill", "[\(via)]")
            XCTAssertEqual(state["keys"] as? [String],
                           ["close", "getOptions", "getPanelBehavior", "open", "setOptions", "setPanelBehavior"], "[\(via)]")
            XCTAssertEqual(state["viaBrowser"] as? Bool, true, "[\(via)] browser.sidePanel must be the same object")
        }
    }

    func testAnExtensionWithoutThePermissionGetsNoNamespaceAndIsRefusedByTheBridge() async throws {
        let scene = try await makeScene("Panel No Permission", permissions: [])
        for via in Via.allCases {
            let state = try await world.runDict(via, in: scene.loaded, ["op": "install"])
            XCTAssertEqual(state["type"] as? String, "undefined", "[\(via)]")
            XCTAssertEqual(state["install"] as? String, "absent", "[\(via)]")
            XCTAssertEqual(state["closeWrapped"] as? Bool, false, "[\(via)]")
        }
        // A page that talks to the bridge directly, as the polyfill would.
        for type in ["sidePanel.open", "sidePanel.setOptions", "sidePanel.getOptions", "sidePanel.close",
                     "sidePanel.setPanelBehavior", "sidePanel.getPanelBehavior", "sidePanel.closeSelf"] {
            let handle = ExtensionTabHandleRegistry.shared.handle(for: scene.first)
            let reply = try await postRawPolyfillEnvelope(
                from: scene.loaded.page, type: type, claimedID: scene.loaded.ext.id,
                params: ["tabHandle": handle, "path": "panel.html", "hasWindow": true])
            XCTAssertEqual(reply.error, ExtensionPolyfillHandler.sidePanelPermissionRefusal, type)
        }
        XCTAssertTrue(scene.panels.panels.isEmpty)
        XCTAssertNil(scene.window.displayedSidePanel)
    }

    // MARK: - Options (every method, both transports)

    func testOptionsRoundTripFromBothTransports() async throws {
        let scene = try await makeScene("Panel Options")
        for via in Via.allCases {
            let tabID = try await world.tabID(of: scene.first, via, in: scene.loaded)
            let otherID = try await world.tabID(of: scene.second, via, in: scene.loaded)

            // The manifest's default_path is the default panel.
            let initial = try await world.runDict(via, in: scene.loaded, ["op": "call", "method": "getOptions", "args": [[String: Any]()]])
            XCTAssertEqual(initial as NSDictionary, ["enabled": true, "path": "panel.html"], "[\(via)]")
            let initialForTab = try await world.runDict(via, in: scene.loaded, ["op": "call", "method": "getOptions", "args": [["tabId": tabID]]])
            XCTAssertEqual(initialForTab as NSDictionary, ["enabled": true, "path": "panel.html"],
                           "[\(via)] a tab without options of its own reports the default, and no tabId")

            let set = try await world.run(via, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                                  "args": [["tabId": tabID, "path": "tabpanel.html?tabId=\(tabID)", "enabled": true]]])
            XCTAssertTrue(set is NSNull, "[\(via)] setOptions resolves with nothing")
            let own = try await world.runDict(via, in: scene.loaded, ["op": "call", "method": "getOptions", "args": [["tabId": tabID]]])
            XCTAssertEqual(own as NSDictionary, ["enabled": true, "path": "tabpanel.html?tabId=\(tabID)", "tabId": tabID], "[\(via)]")
            let other = try await world.runDict(via, in: scene.loaded, ["op": "call", "method": "getOptions", "args": [["tabId": otherID]]])
            XCTAssertEqual(other as NSDictionary, ["enabled": true, "path": "panel.html"], "[\(via)] another tab is untouched")

            // Natively, the options are the tab's.
            let state = scene.panels.stateForTesting(extensionID: scene.loaded.ext.id)
            XCTAssertTrue(state.hasOptions(for: scene.first.id), "[\(via)]")
            XCTAssertFalse(state.hasOptions(for: scene.second.id), "[\(via)]")

            // Callback form.
            let callback = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "getOptions", "args": [["tabId": tabID]]])
            XCTAssertEqual(callback["argc"] as? Int, 1, "[\(via)]")
            XCTAssertTrue(callback["lastError"] is NSNull, "[\(via)]")
            XCTAssertEqual(callback["returnedType"] as? String, "undefined", "[\(via)]")
            XCTAssertEqual((callback["arg0"] as? [String: Any])?["tabId"] as? Int, tabID, "[\(via)]")

            // Reset for the other transport.
            scene.panels.extensionDidUnload(scene.loaded.ext.id)
        }
    }

    func testOptionErrorsFromBothTransports() async throws {
        let scene = try await makeScene("Panel Option Errors")
        for via in Via.allCases {
            let unknownTab = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                                           "args": [["tabId": 987_654, "path": "panel.html"]]])
            XCTAssertEqual(unknownTab, "No tab with id: 987654.", "[\(via)]")

            let foreignPath = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                                            "args": [["path": "https://example.com/panel.html"]]])
            XCTAssertTrue(foreignPath?.contains("the path must be a page in the extension's own package") == true,
                          "[\(via)] \(foreignPath ?? "resolved")")

            let badType = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "setOptions", "args": [["enabled": "yes"]]])
            XCTAssertEqual(badType, "Error in invocation of sidePanel.setOptions: enabled must be a boolean", "[\(via)]")

            // The callback form reports the same failure through lastError.
            let callback = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "setOptions",
                                                                         "args": [["tabId": 987_654, "path": "panel.html"]]])
            XCTAssertEqual(callback["argc"] as? Int, 0, "[\(via)]")
            XCTAssertTrue((callback["lastError"] as? String)?.contains("No tab with id: 987654.") == true,
                          "[\(via)] \(callback)")
        }
        XCTAssertEqual(scene.panels.stateForTesting(extensionID: scene.loaded.ext.id).resolvedOptions(for: nil).path,
                       "panel.html", "a refused path changes nothing")
    }

    func testPanelBehaviourFromBothTransports() async throws {
        let scene = try await makeScene("Panel Behaviour")
        for via in Via.allCases {
            let before = try await world.runDict(via, in: scene.loaded, ["op": "call", "method": "getPanelBehavior"])
            XCTAssertEqual(before as NSDictionary, ["openPanelOnActionClick": false], "[\(via)]")
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "setPanelBehavior",
                                                            "args": [["openPanelOnActionClick": true]]])
            XCTAssertTrue(scene.panels.opensPanelOnActionClick(extensionID: scene.loaded.ext.id), "[\(via)]")
            let after = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "getPanelBehavior"])
            XCTAssertEqual(after["arg0"] as? NSDictionary, ["openPanelOnActionClick": true], "[\(via)]")
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "setPanelBehavior",
                                                            "args": [["openPanelOnActionClick": false]]])
        }
    }

    // MARK: - Opening (AC #1, #3)

    func testOpeningATabPanelShowsItBesideTheTabAndItIsNotATab() async throws {
        for via in Via.allCases {
            let scene = try await makeScene("Panel Open \(via.rawValue)")
            let tabsBefore = scene.space.tabs.count
            let rowsBefore = scene.window.tabSidebar.tableView.numberOfRows
            let queryBefore = try await world.runDict(via, in: scene.loaded, ["op": "queryCount"])["count"] as? Int
            let switcherBefore = scene.window.recentTabSwitcherEntries().map { $0.tabs.map(\.id) }
            let fullWidth = layoutFrames(of: scene.window).content.width

            let panel = try await openTabPanel(via, in: scene, for: scene.first)
            try await world.waitForPanelPage(panel)
            let tabID = try await world.tabID(of: scene.first, via, in: scene.loaded)

            // The page the options named, query included.
            XCTAssertEqual(panel.documentURL.path, "/tabpanel.html", "[\(via)]")
            XCTAssertEqual(panel.documentURL.query, "tabId=\(tabID)", "[\(via)]")
            XCTAssertEqual(panel.documentURL.host, scene.loaded.context.baseURL.host, "[\(via)]")

            // Beside the tab, in the window showing the tab.
            XCTAssertTrue(scene.window.displayedSidePanel === panel, "[\(via)]")
            let frames = layoutFrames(of: scene.window)
            let panelFrame = try XCTUnwrap(frames.panel, "[\(via)]")
            XCTAssertEqual(panelFrame.width, SidePanelLayout.defaultPanelWidth, "[\(via)]")
            XCTAssertEqual(frames.content.maxX, panelFrame.minX, "[\(via)] the panel is the trailing pane")
            XCTAssertEqual(frames.content.width + panelFrame.width, fullWidth, "[\(via)]")
            XCTAssertTrue(scene.first.webViewContainer?.isDescendant(of: scene.window.contentContainerView) == true)
            XCTAssertEqual(scene.first.webViewContainer?.frame.width, frames.content.width,
                           "[\(via)] the page fills what the panel leaves")
            XCTAssertTrue(panel.webView?.window === scene.window.window, "[\(via)]")

            // Registered as a page Detour hosts, with the extension's own APIs.
            XCTAssertTrue(ExtensionPageHostRegistry.isDetourHosted(try XCTUnwrap(panel.webView)), "[\(via)]")
            let panelWebView = try XCTUnwrap(panel.webView)
            let inPanelValue = try await world.run(in: panelWebView, ["op": "install"])
            let inPanel = try XCTUnwrap(inPanelValue as? [String: Any])
            XCTAssertEqual(inPanel["type"] as? String, "object", "[\(via)] the panel page has chrome.sidePanel too")
            XCTAssertEqual(inPanel["contextKind"] as? String, "page", "[\(via)]")

            // Not a tab, anywhere.
            XCTAssertEqual(scene.space.tabs.count, tabsBefore, "[\(via)]")
            XCTAssertEqual(scene.window.tabSidebar.tableView.numberOfRows, rowsBefore, "[\(via)] no sidebar row")
            XCTAssertEqual(scene.window.selectedTabID, scene.first.id, "[\(via)] never selectedTabID")
            XCTAssertEqual(scene.window.extensionTabs.count, tabsBefore, "[\(via)]")
            let queryAfter = try await world.runDict(via, in: scene.loaded, ["op": "queryCount"])["count"] as? Int
            XCTAssertEqual(queryAfter, queryBefore, "[\(via)] tabs.query must not list the panel")
            let currentValue = try await world.run(in: panelWebView, ["op": "getCurrent"])
            let current = try XCTUnwrap(currentValue as? [String: Any])
            XCTAssertEqual(current["promise"] as? String, "undefined", "[\(via)] tabs.getCurrent() in a panel: \(current)")
            XCTAssertEqual((current["callback"] as? [String: Any])?["kind"] as? String, "undefined", "[\(via)] \(current)")
            XCTAssertTrue((current["callback"] as? [String: Any])?["lastError"] is NSNull, "[\(via)] \(current)")
            XCTAssertEqual(current["native"] as? String, "null",
                           "[\(via)] canary: WebKit's own getCurrent answers null in a page that is not a tab")
            let switcherAfter = scene.window.recentTabSwitcherEntries().map { $0.tabs.map(\.id) }
            XCTAssertEqual(switcherAfter, switcherBefore, "[\(via)] the Control+Tab switcher offers what it offered before")
            XCTAssertTrue(Set(switcherAfter.flatMap { $0 }).isSubset(of: [scene.first.id, scene.second.id]),
                          "[\(via)] and only tabs")

            // Opening it again changes nothing and loads nothing.
            let marker = try await world.loadMarker(of: panel)
            let again = try await openTabPanel(via, in: scene, for: scene.first)
            XCTAssertTrue(again === panel, "[\(via)]")
            XCTAssertEqual(scene.panels.panels.count, 1, "[\(via)]")
            let markerAfter = try await world.loadMarker(of: panel)
            XCTAssertEqual(markerAfter, marker, "[\(via)] an open panel is not reloaded by open()")
        }
    }

    func testOpenErrorsFromBothTransports() async throws {
        let scene = try await makeScene("Panel Open Errors", defaultPath: nil)
        for via in Via.allCases {
            let tabID = try await world.tabID(of: scene.first, via, in: scene.loaded)
            let windowID = try await world.windowID(listing: scene.first, via, in: scene.loaded)

            let neither = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "open", "args": [[String: Any]()]])
            XCTAssertEqual(neither, "At least one of \"tabId\" and \"windowId\" must be provided", "[\(via)]")

            let noPanelForTab = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["tabId": tabID]]])
            XCTAssertEqual(noPanelForTab, "No active side panel for tabId: \(tabID)", "[\(via)] no path anywhere")
            let noPanelForWindow = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["windowId": windowID]]])
            XCTAssertEqual(noPanelForWindow, "No active side panel for windowId: \(windowID)", "[\(via)]")

            let unknownTab = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["tabId": 987_654]]])
            XCTAssertEqual(unknownTab, "No tab with id: 987654.", "[\(via)]")
            let unknownWindow = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["windowId": 987_654]]])
            XCTAssertEqual(unknownWindow, "No window with id: 987654.", "[\(via)]")

            // Disabled for the tab.
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                            "args": [["tabId": tabID, "path": "tabpanel.html", "enabled": false]]])
            let disabled = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["tabId": tabID]]])
            XCTAssertEqual(disabled, "No active side panel for tabId: \(tabID)", "[\(via)]")

            let callback = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "open", "args": [["tabId": tabID]]])
            XCTAssertEqual(callback["argc"] as? Int, 0, "[\(via)]")
            XCTAssertTrue((callback["lastError"] as? String)?.contains("No active side panel for tabId: \(tabID)") == true,
                          "[\(via)] \(callback)")
            scene.panels.extensionDidUnload(scene.loaded.ext.id)
        }
        XCTAssertTrue(scene.panels.panels.isEmpty)
        XCTAssertNil(scene.window.displayedSidePanel)
    }

    // MARK: - Tab switching (AC #2)

    func testATabPanelHidesWithItsTabAndComesBackWithoutReloading() async throws {
        let scene = try await makeScene("Panel Switch")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        try await world.waitForPanelPage(panel)
        let webView = try XCTUnwrap(panel.webView)
        let marker = try await world.loadMarker(of: panel)
        let fullWidth = scene.window.contentAreaView.bounds.width

        scene.window.selectTab(id: scene.second.id)
        XCTAssertNil(scene.window.displayedSidePanel, "the other tab has no panel")
        XCTAssertNil(panel.view.superview, "the panel left the window")
        XCTAssertEqual(layoutFrames(of: scene.window).content.width, fullWidth, "the page has the whole area again")
        XCTAssertTrue(panel.webView === webView, "the panel's web view is kept while the panel is open")
        XCTAssertEqual(scene.panels.panels.count, 1)

        scene.window.selectTab(id: scene.first.id)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertTrue(panel.webView === webView)
        XCTAssertTrue(webView.window === scene.window.window)
        let markerAfter = try await world.loadMarker(of: panel)
        XCTAssertEqual(markerAfter, marker, "the panel page must not load again")
        XCTAssertEqual(layoutFrames(of: scene.window).panel?.width, SidePanelLayout.defaultPanelWidth)
    }

    func testEachTabsPanelSwapsInWhenItsTabIsSelected() async throws {
        let scene = try await makeScene("Panel Swap")
        let firstPanel = try await openTabPanel(.page, in: scene, for: scene.first)
        let secondPanel = try await openTabPanel(.page, in: scene, for: scene.second)
        XCTAssertFalse(firstPanel === secondPanel)
        XCTAssertTrue(scene.window.displayedSidePanel === firstPanel, "the second tab is not selected yet")

        scene.window.selectTab(id: scene.second.id)
        XCTAssertTrue(scene.window.displayedSidePanel === secondPanel)
        XCTAssertNil(firstPanel.view.superview)
        scene.window.selectTab(id: scene.first.id)
        XCTAssertTrue(scene.window.displayedSidePanel === firstPanel)
        XCTAssertNil(secondPanel.view.superview)
    }

    func testAWindowPanelShowsForEveryTabThatHasNoOpenPanelOfItsOwn() async throws {
        for via in Via.allCases {
            let scene = try await makeScene("Panel Window \(via.rawValue)")
            let windowID = try await world.windowID(listing: scene.first, via, in: scene.loaded)
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["windowId": windowID]]])
            let windowPanel = try XCTUnwrap(scene.panels.panels.first, "[\(via)]")
            XCTAssertNil(windowPanel.tab, "[\(via)] a window panel belongs to no tab")
            XCTAssertTrue(windowPanel.windowController === scene.window, "[\(via)]")
            XCTAssertEqual(windowPanel.documentURL.path, "/panel.html", "[\(via)] the manifest's default path")
            XCTAssertTrue(scene.window.displayedSidePanel === windowPanel, "[\(via)]")

            scene.window.selectTab(id: scene.second.id)
            XCTAssertTrue(scene.window.displayedSidePanel === windowPanel, "[\(via)] it stays for the other tab")

            // A tab with a panel of its own shows that one instead.
            let tabPanel = try await openTabPanel(via, in: scene, for: scene.second)
            XCTAssertTrue(scene.window.displayedSidePanel === tabPanel, "[\(via)]")
            scene.window.selectTab(id: scene.first.id)
            XCTAssertTrue(scene.window.displayedSidePanel === windowPanel, "[\(via)]")

            // open({tabId}) for a tab without options of its own is the window's panel.
            let firstID = try await world.tabID(of: scene.first, via, in: scene.loaded)
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["tabId": firstID]]])
            XCTAssertEqual(scene.panels.panels.count, 2, "[\(via)] no third panel")

            // With nothing selected the window still shows its own panel.
            scene.window.deselectAllTabs()
            XCTAssertTrue(scene.window.displayedSidePanel === windowPanel, "[\(via)]")
        }
    }

    func testAWindowPanelHidesBesideATabItIsDisabledFor() async throws {
        let scene = try await makeScene("Panel Window Disabled Tab")
        let windowID = try await world.windowID(listing: scene.first, .page, in: scene.loaded)
        _ = try await world.run(.page, in: scene.loaded, ["op": "call", "method": "open", "args": [["windowId": windowID]]])
        let windowPanel = try XCTUnwrap(scene.panels.panels.first)
        XCTAssertTrue(scene.window.displayedSidePanel === windowPanel)

        // Disabled for the tab on screen: hidden at once, but still open.
        let firstID = try await world.tabID(of: scene.first, .page, in: scene.loaded)
        _ = try await world.run(.page, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                          "args": [["tabId": firstID, "enabled": false]]])
        XCTAssertNil(scene.window.displayedSidePanel)
        XCTAssertTrue(scene.panels.panels.first === windowPanel, "the window's panel stays open")

        scene.window.selectTab(id: scene.second.id)
        XCTAssertTrue(scene.window.displayedSidePanel === windowPanel, "it shows beside the other tab")
        scene.window.selectTab(id: scene.first.id)
        XCTAssertNil(scene.window.displayedSidePanel)

        _ = try await world.run(.page, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                          "args": [["tabId": firstID, "enabled": true]]])
        XCTAssertTrue(scene.window.displayedSidePanel === windowPanel, "enabled again, it is back")
    }

    // MARK: - Closing (AC #6)

    func testCloseFromBothTransports() async throws {
        for via in Via.allCases {
            let scene = try await makeScene("Panel Close \(via.rawValue)")
            let tabID = try await world.tabID(of: scene.first, via, in: scene.loaded)
            let windowID = try await world.windowID(listing: scene.first, via, in: scene.loaded)
            _ = try await openTabPanel(via, in: scene, for: scene.first)
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "open", "args": [["windowId": windowID]]])
            XCTAssertEqual(scene.panels.panels.count, 2, "[\(via)]")

            let closed = try await world.run(via, in: scene.loaded, ["op": "call", "method": "close", "args": [["tabId": tabID]]])
            XCTAssertTrue(closed is NSNull, "[\(via)]")
            XCTAssertEqual(scene.panels.panels.map(\.documentURL.path), ["/panel.html"], "[\(via)] the tab's own panel closes first")
            XCTAssertNotNil(scene.window.displayedSidePanel, "[\(via)] the window's panel shows now")

            let callback = try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": "close", "args": [["windowId": windowID]]])
            XCTAssertEqual(callback["argc"] as? Int, 0, "[\(via)]")
            XCTAssertTrue(callback["lastError"] is NSNull, "[\(via)]")
            XCTAssertTrue(scene.panels.panels.isEmpty, "[\(via)]")
            XCTAssertNil(scene.window.displayedSidePanel, "[\(via)]")
            XCTAssertEqual(layoutFrames(of: scene.window).content.width, scene.window.contentAreaView.bounds.width, "[\(via)]")

            // Closing a closed panel is not an error; closing nothing in particular is.
            _ = try await world.run(via, in: scene.loaded, ["op": "call", "method": "close", "args": [["tabId": tabID]]])
            let neither = try await world.failure(via, in: scene.loaded, ["op": "call", "method": "close", "args": [[String: Any]()]])
            XCTAssertEqual(neither, "At least one of \"tabId\" and \"windowId\" must be provided", "[\(via)]")
        }
    }

    func testTheCloseButtonClosesThePanelAndCmdWStillClosesTheTab() async throws {
        let scene = try await makeScene("Panel Close Button")
        let closedRecordsBefore = AppDatabase.shared.closedTabs(spaceID: scene.space.id.uuidString).count
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        let webView = try XCTUnwrap(panel.webView)
        // Focus in the panel: the keys must go back to the page when it closes.
        XCTAssertTrue(scene.window.window?.makeFirstResponder(webView) == true)

        panel.view.closeButton.performClick(nil)
        XCTAssertTrue(scene.panels.panels.isEmpty)
        XCTAssertNil(scene.window.displayedSidePanel)
        XCTAssertNil(panel.webView, "the panel's web view is released")
        XCTAssertTrue(scene.window.window?.firstResponder === scene.first.webView, "the page takes the keys back")
        XCTAssertEqual(scene.space.tabs.count, 2, "closing a panel closes no tab")
        XCTAssertEqual(AppDatabase.shared.closedTabs(spaceID: scene.space.id.uuidString).count, closedRecordsBefore,
                       "a closed panel leaves no closed-tab record")
        XCTAssertFalse(TabStore.shared.undoManager.canUndo && TabStore.shared.undoManager.undoActionName.contains("Panel"),
                       "and nothing to undo")

        // The options stay: the panel can be opened again.
        let tabID = try await world.tabID(of: scene.first, .worker, in: scene.loaded)
        _ = try await world.run(.worker, in: scene.loaded, ["op": "call", "method": "open", "args": [["tabId": tabID]]])
        let reopened = try XCTUnwrap(scene.panels.panels.first)
        XCTAssertTrue(scene.window.window?.makeFirstResponder(reopened.webView) == true)

        // Cmd+W with the panel focused closes the tab, and the panel with it.
        scene.window.closeCurrentTab(nil)
        XCTAssertFalse(scene.space.tabs.contains { $0 === scene.first }, "Cmd+W closes the tab, not the panel")
        XCTAssertTrue(scene.panels.panels.isEmpty, "the tab's panel closes with it")
        XCTAssertFalse(scene.panels.stateForTesting(extensionID: scene.loaded.ext.id).hasOptions(for: scene.first.id))
        XCTAssertNil(scene.window.displayedSidePanel)
    }

    func testWindowCloseInThePanelPageClosesThePanel() async throws {
        let scene = try await makeScene("Panel window.close")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        try await world.waitForPanelPage(panel)
        let webView = try XCTUnwrap(panel.webView)
        // A single-page app's history: WebKit alone would refuse to close it.
        _ = try await webView.callAsyncJavaScript(
            "history.pushState({}, '', '?tabId=1&step=2'); history.pushState({}, '', '?tabId=1&step=3'); window.close();",
            arguments: [:], contentWorld: .page)
        try await waitUntil("window.close() to close the panel") { self.world.panels(of: scene.loaded).isEmpty }
        XCTAssertNil(scene.window.displayedSidePanel)
    }

    func testAPanelThatFailsToLoadCloses() async throws {
        let scene = try await makeScene("Panel Missing Page")
        let tabID = try await world.tabID(of: scene.first, .page, in: scene.loaded)
        _ = try await world.run(.page, in: scene.loaded, ["op": "setOptionsThenOpen",
                                                          "options": ["tabId": tabID, "path": "no-such-page.html", "enabled": true],
                                                          "target": ["tabId": tabID]])
        try await waitUntil("the panel with no page to close") { self.world.panels(of: scene.loaded).isEmpty }
        XCTAssertNil(scene.window.displayedSidePanel)
    }

    func testClosingAPanelDisconnectsItsPorts() async throws {
        let scene = try await makeScene("Panel Ports")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        try await world.waitForPanelPage(panel)
        try await waitUntil("the panel's port to reach the worker") {
            ((try? await self.world.runDict(.worker, in: scene.loaded, ["op": "ports"]))?["connected"] as? Int ?? 0) >= 1
        }
        let before = try await world.runDict(.worker, in: scene.loaded, ["op": "ports"])
        let disconnectedBefore = before["disconnected"] as? Int ?? 0

        scene.panels.close(panel, reason: .user)
        try await waitUntil("the worker to see the panel's port disconnect", timeout: 20) {
            ((try? await self.world.runDict(.worker, in: scene.loaded, ["op": "ports"]))?["disconnected"] as? Int ?? 0) > disconnectedBefore
        }
    }

    func testDisablingThePanelOrChangingItsPathActsOnTheOpenPanel() async throws {
        let scene = try await makeScene("Panel Options Live")
        let panel = try await openTabPanel(.page, in: scene, for: scene.first)
        try await world.waitForPanelPage(panel)
        let tabID = try await world.tabID(of: scene.first, .page, in: scene.loaded)
        let webView = try XCTUnwrap(panel.webView)

        // Another path: the same panel loads it.
        _ = try await world.run(.page, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                          "args": [["tabId": tabID, "path": "other.html?tabId=\(tabID)"]]])
        XCTAssertTrue(scene.panels.panels.first === panel)
        XCTAssertTrue(panel.webView === webView)
        try await waitUntil("the panel to load the new page") { panel.webView?.url?.path == "/other.html" }

        // Disabled: it closes.
        _ = try await world.run(.page, in: scene.loaded, ["op": "call", "method": "setOptions",
                                                          "args": [["tabId": tabID, "enabled": false]]])
        XCTAssertTrue(scene.panels.panels.isEmpty)
        XCTAssertNil(scene.window.displayedSidePanel)
    }

    func testClosingTheTabTearsItsPanelDown() async throws {
        let scene = try await makeScene("Panel Tab Close")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.second)
        scene.window.selectTab(id: scene.second.id)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)

        TabStore.shared.closeTab(id: scene.second.id, in: scene.space, undoable: false, registersUndo: false)
        XCTAssertTrue(scene.panels.panels.isEmpty)
        XCTAssertNil(panel.webView)
        XCTAssertNil(scene.window.displayedSidePanel)
        XCTAssertEqual(layoutFrames(of: scene.window).content.width, scene.window.contentAreaView.bounds.width)
    }

    /// A tab the store closes while it is the window's selection (what
    /// `tabs.remove` does) releases its web view before the window hears of
    /// it. The window registered script message handlers on that web view's
    /// content controller, which holds them strongly: left there, they kept
    /// the window's controller alive after the window closed.
    func testAWindowWhoseSelectedTabTheStoreClosedIsReleased() async throws {
        weak var window: BrowserWindowController?
        do {
            let scene = try await makeScene("Panel Window Released")
            window = scene.window
            scene.window.selectTab(id: scene.second.id)
            TabStore.shared.closeTab(id: scene.second.id, in: scene.space, undoable: false, registersUndo: false)
        }
        await world.tearDown()
        try await waitUntil("the closed window's controller to be released") { window == nil }
    }

    /// `TabStore.moveTab` takes the tab out of one list, notifies, and only
    /// then puts it in the other; the window answers the removal by selecting
    /// the next tab, which reconciles the panels while the tab is in no list.
    func testMovingTheSelectedTabToAnotherSpaceKeepsItsPanel() async throws {
        let scene = try await makeScene("Panel Tab Move")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        try await world.waitForPanelPage(panel)
        let marker = try await world.loadMarker(of: panel)
        let other = world.makeSpace("Panel Tab Move Other", in: scene.profile)

        XCTAssertTrue(TabStore.shared.moveTab(id: scene.first.id, from: scene.space, to: other))
        XCTAssertEqual(scene.window.selectedTabID, scene.second.id, "precondition: the window moved on mid-move")
        // The second look at the unlisted tab runs on the next main-queue turn.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }

        XCTAssertTrue(scene.panels.panels.contains { $0 === panel }, "a tab between two lists is not a closed tab")
        XCTAssertNotNil(panel.webView)
        XCTAssertNil(scene.window.displayedSidePanel, "its tab is not on screen")
        XCTAssertTrue(scene.panels.stateForTesting(extensionID: scene.loaded.ext.id).isOpen(.tab(scene.first.id)))
        let markerAfter = try await world.loadMarker(of: panel)
        XCTAssertEqual(markerAfter, marker, "the panel was not loaded again")

        // A tab that really is gone still takes its panel with it.
        TabStore.shared.closeTab(id: scene.first.id, in: other, undoable: false, registersUndo: false)
        XCTAssertTrue(scene.panels.panels.isEmpty)
    }

    func testUnloadingTheExtensionTearsItsPanelsDownAndForgetsItsOptions() async throws {
        let scene = try await makeScene("Panel Unload")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertGreaterThan(ExtensionManager.shared.activity(for: scene.loaded.ext.id).openSidePanels, 0,
                             "an open panel keeps an update waiting")
        XCTAssertTrue(ExtensionUpdateDeferral.shouldDefer(ExtensionManager.shared.activity(for: scene.loaded.ext.id)))

        // What disabling the extension in this profile does.
        scene.profile.unloadExtension(id: scene.loaded.ext.id)
        XCTAssertTrue(scene.panels.panels.isEmpty)
        XCTAssertNil(panel.webView)
        XCTAssertNil(scene.window.displayedSidePanel)
        XCTAssertFalse(scene.panels.stateForTesting(extensionID: scene.loaded.ext.id).hasOptions(for: scene.first.id))
        XCTAssertEqual(ExtensionManager.shared.activity(for: scene.loaded.ext.id).openSidePanels, 0)
    }

    func testClosingTheWindowClosesItsOwnPanelAndLetsATabPanelGo() async throws {
        let scene = try await makeScene("Panel Window Close")
        let windowID = try await world.windowID(listing: scene.first, .page, in: scene.loaded)
        _ = try await world.run(.page, in: scene.loaded, ["op": "call", "method": "open", "args": [["windowId": windowID]]])
        let tabPanel = try await openTabPanel(.page, in: scene, for: scene.first)
        XCTAssertEqual(scene.panels.panels.count, 2)

        scene.window.window?.close()
        XCTAssertEqual(scene.panels.panels.count, 1, "the window's own panel closed with it")
        XCTAssertTrue(scene.panels.panels.first === tabPanel, "the tab's panel is the tab's")
        XCTAssertNil(tabPanel.view.superview, "but it is in no window now")

        // Another window on the space shows the tab, and its panel.
        let other = world.makeWindow(on: scene.space)
        other.selectTab(id: scene.first.id)
        // A window that is not key only claims a tab nothing hosts, and the
        // closed window's views still hold this one: claim as a key window does.
        other.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: other.window))
        XCTAssertTrue(other.ownsWebView)
        XCTAssertTrue(other.displayedSidePanel === tabPanel)
    }

    // MARK: - Split tabs (AC #4)

    func testASplitTabShowsBothPanesAndThePanel() async throws {
        let scene = try await makeScene("Panel Split")
        TabStore.shared.createSplit(draggedTabID: scene.second.id, targetTabID: scene.first.id, edge: .right, in: scene.space)
        scene.window.selectTab(id: scene.first.id)
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)

        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        let frames = layoutFrames(of: scene.window)
        let panelFrame = try XCTUnwrap(frames.panel)
        XCTAssertEqual(frames.content.maxX, panelFrame.minX)
        let split = try XCTUnwrap(scene.first.webViewContainer?.superview as? NSSplitView, "the split is still hosted")
        XCTAssertTrue(split.superview === scene.window.contentContainerView)
        XCTAssertEqual(split.arrangedSubviews.count, 2, "both panes")
        XCTAssertTrue(scene.second.webViewContainer?.superview === split)
        XCTAssertLessThanOrEqual(split.frame.maxX, frames.content.width, "the split stays inside the narrowed content area")
        for pane in split.arrangedSubviews {
            XCTAssertGreaterThan(pane.frame.width, 100, "neither pane collapsed")
        }

        // Focusing the other pane keeps the first pane's panel: it has none of its own.
        scene.window.selectTab(id: scene.second.id)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        // Once it has one, the focused pane's shows.
        let secondPanel = try await openTabPanel(.worker, in: scene, for: scene.second)
        XCTAssertTrue(scene.window.displayedSidePanel === secondPanel)
        scene.window.selectTab(id: scene.first.id)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
    }

    // MARK: - The divider (AC #5)

    func testTheDividerDragsToAMinimumAndTheWidthIsRemembered() async throws {
        let scene = try await makeScene("Panel Divider")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        let area = scene.window.contentAreaView
        let total = area.bounds.width
        XCTAssertFalse(area.divider.isHidden)
        XCTAssertEqual(area.divider.frame.midX, total - SidePanelLayout.defaultPanelWidth, accuracy: 0.5)

        // Drag the boundary left: the panel grows.
        area.divider.onDrag?(total - 520)
        XCTAssertEqual(layoutFrames(of: scene.window).panel?.width, 520)
        XCTAssertEqual(layoutFrames(of: scene.window).content.width, total - 520)
        // All the way right: the minimum width holds.
        area.divider.onDrag?(total - 20)
        XCTAssertEqual(layoutFrames(of: scene.window).panel?.width, SidePanelLayout.minimumPanelWidth)
        // All the way left: the page keeps its minimum.
        area.divider.onDrag?(5)
        XCTAssertEqual(layoutFrames(of: scene.window).content.width, SidePanelLayout.minimumContentWidth)

        area.divider.onDrag?(total - 450)
        XCTAssertEqual(SidePanelWidthStore.width, SidePanelLayout.defaultPanelWidth, "nothing is saved mid-drag")
        area.divider.onDragEnded?()
        XCTAssertEqual(SidePanelWidthStore.width, 450)

        // The width comes back: after a tab switch, and for a panel opened later.
        scene.window.selectTab(id: scene.second.id)
        scene.window.selectTab(id: scene.first.id)
        XCTAssertEqual(layoutFrames(of: scene.window).panel?.width, 450)
        scene.panels.close(panel, reason: .user)
        _ = try await openTabPanel(.worker, in: scene, for: scene.second)
        scene.window.selectTab(id: scene.second.id)
        XCTAssertEqual(layoutFrames(of: scene.window).panel?.width, 450, "a reopened panel has the remembered width")

        // The window resizing keeps the panel's width and gives the page the rest.
        scene.window.window?.setFrame(NSRect(x: 60, y: 60, width: 1300, height: 700), display: false)
        let wider = layoutFrames(of: scene.window)
        XCTAssertEqual(wider.panel?.width, 450)
        XCTAssertEqual(wider.content.width, scene.window.contentAreaView.bounds.width - 450)
    }

    // MARK: - Two windows (AC #7)

    func testATabShownInTwoWindowsShowsItsPanelOnlyWhereItsWebViewIs() async throws {
        let scene = try await makeScene("Panel Ownership")
        let other = world.makeWindow(on: scene.space)
        other.selectTab(id: scene.first.id)
        XCTAssertFalse(other.ownsWebView, "precondition: the second window shows a snapshot")
        XCTAssertTrue(scene.window.ownsWebView)

        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        try await world.waitForPanelPage(panel)
        let marker = try await world.loadMarker(of: panel)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertNil(other.displayedSidePanel, "a window showing a snapshot shows no panel")
        XCTAssertEqual(layoutFrames(of: other).content.width, other.contentAreaView.bounds.width)

        // The second window takes the web view, as it does when it becomes key.
        other.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: other.window))
        XCTAssertTrue(other.ownsWebView)
        XCTAssertFalse(scene.window.ownsWebView)
        XCTAssertTrue(other.displayedSidePanel === panel, "the panel goes with the web view")
        XCTAssertNil(scene.window.displayedSidePanel)
        XCTAssertTrue(panel.webView?.window === other.window)
        XCTAssertEqual(layoutFrames(of: scene.window).content.width, scene.window.contentAreaView.bounds.width)
        let markerAfter = try await world.loadMarker(of: panel)
        XCTAssertEqual(markerAfter, marker, "moving the panel does not reload it")

        // And back.
        scene.window.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: scene.window.window))
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertNil(other.displayedSidePanel)
    }

    // MARK: - Isolation

    func testAnotherExtensionCannotTouchThisExtensionsPanel() async throws {
        let scene = try await makeScene("Panel Two Extensions")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)

        let otherExt = try await world.makeExtension(name: "Other Side Panel")
        let other = try await world.load(otherExt, in: scene.profile)
        let tabID = try await world.tabID(of: scene.first, .worker, in: other)
        // Its close is about its own panel, which is not open.
        _ = try await world.run(.worker, in: other, ["op": "call", "method": "close", "args": [["tabId": tabID]]])
        XCTAssertTrue(scene.panels.panels.first === panel, "another extension's close must not close this panel")
        let options = try await world.runDict(.worker, in: other, ["op": "call", "method": "getOptions", "args": [["tabId": tabID]]])
        XCTAssertEqual(options as NSDictionary, ["enabled": true, "path": "panel.html"], "it sees its own options only")

        // Its own panel for the same tab takes the place: one panel in one place.
        _ = try await world.run(.worker, in: other, ["op": "setOptionsThenOpen",
                                                     "options": ["tabId": tabID, "path": "tabpanel.html?tabId=\(tabID)", "enabled": true],
                                                     "target": ["tabId": tabID]])
        XCTAssertEqual(scene.panels.panels.map(\.extensionID), [otherExt.id])
        XCTAssertEqual(scene.window.displayedSidePanel?.extensionID, otherExt.id)
        XCTAssertEqual(scene.window.displayedSidePanel?.documentURL.host, other.context.baseURL.host,
                       "each panel is a page of its own extension's origin")
    }

    func testAnotherProfileCannotReachThisProfilesTabsOrPanels() async throws {
        let scene = try await makeScene("Panel Profile A")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)

        // The same extension, loaded in a second profile with its own window.
        let profileB = world.makeProfile("Panel Profile B")
        let spaceB = world.makeSpace("Panel Profile B", in: profileB)
        let windowB = world.makeWindow(on: spaceB)
        let tabB = try await world.addTab("three", in: spaceB)
        windowB.selectTab(id: tabB.id)
        let loadedB = try await world.load(scene.loaded.ext, in: profileB)

        // B's contexts cannot name A's tab: by handle, straight at the bridge.
        let handleOfA = ExtensionTabHandleRegistry.shared.handle(for: scene.first)
        for type in ["sidePanel.open", "sidePanel.close", "sidePanel.setOptions", "sidePanel.getOptions"] {
            let reply = try await postRawPolyfillEnvelope(from: loadedB.page, type: type, claimedID: loadedB.ext.id,
                                                          params: ["tabHandle": handleOfA, "path": "panel.html"])
            XCTAssertEqual(reply.error, "\(type): no tab for this handle", type)
            let asWindow = try await postRawPolyfillEnvelope(from: loadedB.page, type: type, claimedID: loadedB.ext.id,
                                                             params: ["windowTabHandle": handleOfA, "hasWindow": true])
            if type == "sidePanel.open" || type == "sidePanel.close" {
                XCTAssertEqual(asWindow.error, "\(type): no tab for this handle", type)
            }
        }
        XCTAssertTrue(scene.panels.panels.first === panel)
        XCTAssertFalse(profileB.sidePanels.stateForTesting(extensionID: loadedB.ext.id).hasOptions(for: scene.first.id))

        // B's own panel lives in B: its controller, its window, its origin.
        let panelB = try await openTabPanelIn(loadedB, window: windowB, tab: tabB)
        XCTAssertEqual(scene.panels.panels.count, 1)
        XCTAssertEqual(profileB.sidePanels.panels.count, 1)
        XCTAssertTrue(windowB.displayedSidePanel === panelB)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertNotEqual(panelB.documentURL.host, panel.documentURL.host)
        XCTAssertTrue(panelB.webView?.configuration.websiteDataStore === profileB.dataStore,
                      "a panel runs in its own profile's data store")

        // Unloading in B leaves A's panel alone.
        profileB.unloadExtension(id: loadedB.ext.id)
        XCTAssertTrue(profileB.sidePanels.panels.isEmpty)
        XCTAssertTrue(scene.panels.panels.first === panel)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
    }

    private func openTabPanelIn(_ loaded: SidePanelTestWorld.Loaded, window: BrowserWindowController,
                                tab: BrowserTab) async throws -> ExtensionSidePanel {
        let tabID = try await world.tabID(of: tab, .worker, in: loaded)
        _ = try await world.run(.worker, in: loaded, ["op": "setOptionsThenOpen",
                                                      "options": ["tabId": tabID, "path": "tabpanel.html?tabId=\(tabID)", "enabled": true],
                                                      "target": ["tabId": tabID]])
        return try XCTUnwrap(loaded.profile.sidePanels.panels(for: loaded.ext.id).first { $0.tab === tab })
    }

    // MARK: - Private (AC #8)

    func testInAPrivateProfileThePanelNeedsTheExtensionToBeAllowedThere() async throws {
        let ext = try await world.makeExtension()
        let privateProfile = Profile(name: "Panel Private", isIncognito: true)
        _ = privateProfile.extensionController

        // Not allowed in Private: no context is loaded there, so nothing opens.
        XCTAssertNil(privateProfile.extensionContext(for: ext.id))
        let refused = privateProfile.sidePanels.open(extensionID: ext.id, tab: nil, window: nil, focus: false)
        guard case .failure(let error) = refused else { return XCTFail("a panel opened without a context") }
        XCTAssertEqual(error.message, "sidePanel.open: the extension is not loaded in this profile")
        XCTAssertTrue(privateProfile.sidePanels.panels.isEmpty)
        if case .success = privateProfile.sidePanels.setOptions(extensionID: ext.id, tab: nil, path: "panel.html", enabled: true) {
            XCTFail("options were accepted without a context")
        }

        // Allowed: the context is loaded in the Private profile, and its panel
        // is a page of that profile's ephemeral store.
        let loaded = try await world.load(ext, in: privateProfile)
        let opened = privateProfile.sidePanels.setOptions(extensionID: ext.id, tab: nil, path: "panel.html", enabled: true)
        if case .failure(let error) = opened { XCTFail(error.message) }
        let installed = try await world.runDict(.worker, in: loaded, ["op": "install"])
        XCTAssertEqual(installed["type"] as? String, "object")
        // No window is on this profile, so there is no window to open it in.
        let noWindow = try await world.failure(.page, in: loaded, ["op": "call", "method": "open", "args": [["windowId": -2]]])
        XCTAssertNotNil(noWindow)
        XCTAssertTrue(privateProfile.sidePanels.panels.isEmpty)
    }

    // MARK: - Keyboard focus

    func testAPanelOpenedByTheExtensionTakesFocusOnlyAfterAUserGesture() async throws {
        let scene = try await makeScene("Panel Focus")
        var now: TimeInterval = 1_000
        scene.panels.clock = { now }
        let pageWebView = try XCTUnwrap(scene.first.webView)
        XCTAssertTrue(scene.window.window?.makeFirstResponder(pageWebView) == true)

        // No gesture: the page keeps the keys.
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        XCTAssertTrue(scene.window.window?.firstResponder === pageWebView, "an extension call must not steal focus")
        // Nor may the panel's page, once it has loaded: the fixture's field is
        // `autofocus`, and WebKit makes a web view first responder when its
        // page focuses an element unless told not to.
        try await world.waitForPanelPage(panel)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(scene.window.window?.firstResponder === pageWebView,
                      "a panel's page must not take the keys by focusing a field")
        scene.panels.close(panel, reason: .api)

        // A gesture that is too old does not count.
        scene.panels.noteUserGesture(extensionID: scene.loaded.ext.id)
        now += ExtensionSidePanelController.userGestureLifetime + 1
        let stale = try await openTabPanel(.worker, in: scene, for: scene.first)
        XCTAssertTrue(scene.window.window?.firstResponder === pageWebView)
        scene.panels.close(stale, reason: .api)

        // A fresh one lets the panel take focus — once.
        scene.panels.noteUserGesture(extensionID: scene.loaded.ext.id)
        now += 1
        let focused = try await openTabPanel(.worker, in: scene, for: scene.first)
        XCTAssertTrue(scene.window.window?.firstResponder === focused.webView, "a panel opened on a click takes the keys")
        XCTAssertTrue(scene.window.window?.makeFirstResponder(pageWebView) == true)
        _ = try await openTabPanel(.worker, in: scene, for: scene.first)
        XCTAssertTrue(scene.window.window?.firstResponder === pageWebView, "one gesture, one focus")

        // A panel that comes back with its tab never takes the keys.
        scene.window.selectTab(id: scene.second.id)
        scene.window.selectTab(id: scene.first.id)
        XCTAssertFalse((scene.window.window?.firstResponder as? NSView)?.isDescendant(of: focused.view) ?? false)
    }

    /// The page cannot take the keys for its panel, but the user can give
    /// them to it: a mouse press in the panel hands them over.
    func testAClickInThePanelGivesItTheKeys() async throws {
        let scene = try await makeScene("Panel Click Focus")
        let window = try XCTUnwrap(scene.window.window)
        let pageWebView = try XCTUnwrap(scene.first.webView)
        XCTAssertTrue(window.makeFirstResponder(pageWebView))
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        try await world.waitForPanelPage(panel)
        let webView = try XCTUnwrap(panel.webView)
        window.layoutIfNeeded()
        XCTAssertTrue(window.firstResponder === pageWebView, "precondition: opening it left the keys with the page")

        // Sent to the view itself: a window that is never shown is never key,
        // and AppKit does not deliver a press through one.
        let point = webView.convert(NSPoint(x: webView.bounds.midX, y: webView.bounds.midY), to: nil)
        let press = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        webView.mouseDown(with: press)
        XCTAssertTrue(window.firstResponder === webView, "a click in the panel must give it keyboard focus")
    }

    func testAPanelLeavingWithItsTabHandsTheKeysToThePage() async throws {
        let scene = try await makeScene("Panel Focus Leaves")
        let panel = try await openTabPanel(.worker, in: scene, for: scene.first)
        XCTAssertTrue(scene.window.window?.makeFirstResponder(panel.webView) == true)
        scene.window.selectTab(id: scene.second.id)
        XCTAssertTrue(scene.window.window?.firstResponder === scene.second.webView,
                      "the keys must not stay with a panel that is off screen")
    }

    // MARK: - The toolbar action and the command shortcut (AC #1)

    func testTheToolbarActionFiresOnClickedAndTheExtensionOpensItsPanel() async throws {
        let scene = try await makeScene("Panel Action")
        let anchor = scene.window.tabSidebar.fauxAddressBar
        let popover = ExtensionPopoverController(extensionID: scene.loaded.ext.id)
        popover.show(relativeTo: anchor.bounds, of: anchor, in: scene.window)

        try await waitUntil("the click to open the panel", timeout: 20) { !self.world.panels(of: scene.loaded).isEmpty }
        let panel = try XCTUnwrap(scene.panels.panels.first)
        XCTAssertTrue(panel.tab === scene.first, "the active tab's panel")
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertTrue(scene.window.window?.firstResponder === panel.webView, "opened on a click, so it takes the keys")
        let events = try await world.runDict(.worker, in: scene.loaded, ["op": "events"])["events"] as? [[String: Any]]
        XCTAssertEqual(events?.first?["event"] as? String, "action.onClicked")
    }

    func testWithOpenPanelOnActionClickTheClickTogglesThePanelAndFiresNoEvent() async throws {
        let scene = try await makeScene("Panel Action Behaviour")
        _ = try await world.run(.worker, in: scene.loaded, ["op": "call", "method": "setPanelBehavior",
                                                            "args": [["openPanelOnActionClick": true]]])
        let anchor = scene.window.tabSidebar.fauxAddressBar

        // No popover goes up, so whoever waits for one to close (the address
        // bar, keeping its buttons up meanwhile) is told at once.
        let click = ExtensionPopoverController(extensionID: scene.loaded.ext.id)
        var closes = 0
        click.onClose = { closes += 1 }
        click.show(relativeTo: anchor.bounds, of: anchor, in: scene.window)
        XCTAssertEqual(closes, 1, "a click that shows no popover must still report its close")
        let panel = try XCTUnwrap(scene.panels.panels.first, "the click opens the default panel")
        XCTAssertEqual(panel.documentURL.path, "/panel.html")
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertTrue(scene.window.window?.firstResponder === panel.webView)

        ExtensionPopoverController(extensionID: scene.loaded.ext.id).show(relativeTo: anchor.bounds, of: anchor, in: scene.window)
        XCTAssertTrue(scene.panels.panels.isEmpty, "the second click closes it")
        XCTAssertNil(scene.window.displayedSidePanel)

        try await Task.sleep(nanoseconds: 300_000_000)
        let events = try await world.runDict(.worker, in: scene.loaded, ["op": "events"])["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 0, "action.onClicked does not fire when the click opens the panel")
    }

    func testTheCommandShortcutReachesTheExtension() async throws {
        let scene = try await makeScene("Panel Command")
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: scene.window.window?.windowNumber ?? 0, context: nil,
            characters: "Y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16))
        XCTAssertNotNil(scene.loaded.context.command(for: event), "precondition: WebKit knows the manifest's shortcut")

        XCTAssertTrue(ExtensionCommandDispatch.perform(event, in: scene.window, mainMenu: nil))
        try await waitUntil("commands.onCommand to fire") {
            let events = (try? await self.world.runDict(.worker, in: scene.loaded, ["op": "events"]))?["events"] as? [[String: Any]]
            return events?.contains { $0["event"] as? String == "commands.onCommand" && $0["command"] as? String == "toggle-side-panel" } == true
        }
        try await waitUntil("the shortcut to open the panel", timeout: 20) { !self.world.panels(of: scene.loaded).isEmpty }
        let panel = try XCTUnwrap(scene.panels.panels.first)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)
        XCTAssertTrue(scene.window.window?.firstResponder === panel.webView, "a shortcut is a user gesture")

        // Detour's own menu wins a key both claim.
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Claimed", action: #selector(MenuTarget.fire(_:)), keyEquivalent: "y")
        item.keyEquivalentModifierMask = [.option, .shift]
        let target = MenuTarget()
        item.target = target
        _ = try await world.run(.worker, in: scene.loaded, ["op": "clearEvents"])
        XCTAssertTrue(ExtensionCommandDispatch.perform(event, in: scene.window, mainMenu: menu))
        XCTAssertEqual(target.fired, 1, "the menu item ran")
        try await Task.sleep(nanoseconds: 400_000_000)
        let events = try await world.runDict(.worker, in: scene.loaded, ["op": "events"])["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 0, "and the extension's command did not")

        // A held key repeats, and WebKit has no command for a repeat: one
        // press is one command.
        let held = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: scene.window.window?.windowNumber ?? 0, context: nil,
            characters: "Y", charactersIgnoringModifiers: "y", isARepeat: true, keyCode: 16))
        XCTAssertFalse(ExtensionCommandDispatch.perform(held, in: scene.window, mainMenu: nil))

        // A key no extension has a command for is left to AppKit.
        let other = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: scene.window.window?.windowNumber ?? 0, context: nil,
            characters: "Q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        XCTAssertFalse(ExtensionCommandDispatch.perform(other, in: scene.window, mainMenu: nil))
    }
}

private final class MenuTarget: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}
