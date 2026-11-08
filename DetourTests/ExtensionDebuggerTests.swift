import XCTest
import WebKit
@testable import Detour

/// TASK-132.13: `chrome.debugger` (attach, detach, getTargets, sendCommand,
/// onEvent, onDetach) and `Page.captureScreenshot`, called from a real
/// extension's service worker and from one of its pages, against real tabs in
/// a real (never shown) browser window.
nonisolated final class ExtensionDebuggerTests: XCTestCase {

    private typealias Via = SidePanelTestWorld.Via
    private var world: SidePanelTestWorld!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        world = SidePanelTestWorld(opJS: DebuggerFixture.opJS, workerJS: TabGroupsFixture.workerJS)
        try await world.setUp()
    }

    @MainActor override func tearDown() async throws {
        ExtensionDebugger.shared.resetForTesting()
        await world.tearDown()
        world = nil
        try await super.tearDown()
    }

    /// One profile, one space, one window, four tabs (the first selected),
    /// the extension loaded.
    @MainActor private struct Scene {
        let loaded: SidePanelTestWorld.Loaded
        let space: Space
        let window: BrowserWindowController
        let tabs: [BrowserTab]
        var profile: Profile { loaded.profile }
    }

    @MainActor private func makeScene(_ name: String, permissions: [String] = ["debugger", "tabs"]) async throws -> Scene {
        let ext = try await world.makeExtension(name: "Debugger Test", permissions: permissions, defaultPath: nil)
        let profile = world.makeProfile(name)
        let space = world.makeSpace(name, in: profile)
        let window = world.makeWindow(on: space)
        var tabs: [BrowserTab] = []
        for page in ["one", "two", "three", "four"] { tabs.append(try await world.addTab(page, in: space)) }
        window.selectTab(id: tabs[0].id)
        let loaded = try await world.load(ext, in: profile)
        for tab in tabs {
            TabStore.shared.moveTab(id: tab.id, toGapIndex: space.tabs.count, in: space)
        }
        for tab in space.tabs { try await waitForLoad(tab) }
        return Scene(loaded: loaded, space: space, window: window, tabs: space.tabs)
    }

    @MainActor private func waitForLoad(_ tab: BrowserTab) async throws {
        try await waitUntil("the tab's page to load", timeout: 20) {
            guard let webView = tab.webView, !webView.isLoading else { return false }
            let ready = try? await webView.callAsyncJavaScript("return document.readyState === 'complete';",
                                                               arguments: [:], contentWorld: .page)
            return ready as? Bool == true
        }
    }

    @MainActor private func call(_ via: Via, _ scene: Scene, _ method: String, _ args: [Any]) async throws -> Any {
        try await world.run(via, in: scene.loaded, ["op": "call", "method": method, "args": args])
    }

    @MainActor private func failure(_ via: Via, _ scene: Scene, _ method: String, _ args: [Any]) async throws -> String? {
        try await world.failure(via, in: scene.loaded, ["op": "call", "method": method, "args": args])
    }

    @MainActor private func callback(_ via: Via, _ scene: Scene, _ method: String, _ args: [Any]) async throws -> [String: Any] {
        try await world.runDict(via, in: scene.loaded, ["op": "callback", "method": method, "args": args])
    }

    @MainActor private func tabID(_ tab: BrowserTab, _ via: Via, _ scene: Scene) async throws -> Int {
        try await world.tabID(of: tab, via, in: scene.loaded)
    }

    @MainActor private func events(_ via: Via, _ scene: Scene) async throws -> [[String: Any]] {
        let value = try await world.run(via, in: scene.loaded, ["op": "events"])
        return try XCTUnwrap(value as? [[String: Any]])
    }

    @MainActor private func listen(_ scene: Scene) async throws {
        for via in Via.allCases { _ = try await world.run(via, in: scene.loaded, ["op": "listen"]) }
    }

    @MainActor private func waitForDetach(_ via: Via, _ scene: Scene, tabID: Int,
                                          file: StaticString = #filePath, line: UInt = #line) async throws -> String? {
        var reason: String?
        try await waitUntil("onDetach in the \(via)", timeout: 10) {
            let recorded = (try? await self.events(via, scene)) ?? []
            reason = recorded.first { $0["event"] as? String == "onDetach" && $0["tabId"] as? Int == tabID }?["reason"] as? String
            return reason != nil
        }
        return reason
    }

    // MARK: - The API exists only with the permission (AC #6)

    @MainActor func testTheNamespaceExistsWithThePermission() async throws {
        let scene = try await makeScene("Debugger Namespace")
        for via in Via.allCases {
            let state = try await world.runDict(via, in: scene.loaded, ["op": "install"])
            XCTAssertEqual(state["type"] as? String, "object", "[\(via)]")
            XCTAssertEqual(state["install"] as? String, "polyfill", "[\(via)]")
            XCTAssertEqual(state["keys"] as? [String],
                           ["DetachReason", "TargetInfoType", "attach", "detach", "getTargets", "onDetach", "onEvent",
                            "sendCommand"], "[\(via)]")
            XCTAssertEqual(state["viaBrowser"] as? Bool, true, "[\(via)] browser.debugger must be the same object")
        }
    }

    /// NEGATIVE: no debugger permission, no namespace, and the bridge refuses
    /// the calls a page could make directly.
    @MainActor func testWithoutThePermissionThereIsNoNamespaceAndTheBridgeRefuses() async throws {
        let scene = try await makeScene("Debugger No Permission", permissions: ["tabs"])
        for via in Via.allCases {
            let state = try await world.runDict(via, in: scene.loaded, ["op": "install"])
            XCTAssertEqual(state["type"] as? String, "undefined", "[\(via)]")
            XCTAssertEqual(state["install"] as? String, "absent", "[\(via)]")
        }
        let handle = ExtensionTabHandleRegistry.shared.handle(for: scene.tabs[1])
        for (type, params) in [("debugger.attach", ["tabId": 1, "tabHandle": handle, "version": "1.3"] as [String: Any]),
                               ("debugger.sendCommand", ["tabId": 1, "method": "Page.captureScreenshot"]),
                               ("debugger.targets", ["tabs": [["tabId": 1, "handle": handle]]]),
                               ("debugger.awaitEvent", ["instance": "x"])] {
            let reply = try await postRawPolyfillEnvelope(from: scene.loaded.page, type: type,
                                                          claimedID: scene.loaded.ext.id, params: params)
            XCTAssertEqual(reply.error, ExtensionPolyfillHandler.debuggerPermissionRefusal, type)
        }
        XCTAssertFalse(scene.tabs[1].isAutomationAttached)
    }

    /// The install prompt says what the permission gives (AC #6).
    @MainActor func testThePermissionHasAnInstallWarning() {
        let warnings = ExtensionPermissionDescriptions.warnings(permissions: ["debugger"], hostPermissions: [])
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("all websites"), warnings[0])
        XCTAssertTrue(warnings[0].contains("debugger"), warnings[0])
    }

    /// A denial in Settings refuses the API and ends an attachment the
    /// extension already holds, told as a user cancel.
    @MainActor func testADenialInSettingsEndsTheAttachmentAndRefusesTheAPI() async throws {
        let scene = try await makeScene("Debugger Denied")
        // Settings saves the decision against the installed extension's row.
        installTestExtension(scene.loaded.ext, in: AppDatabase.shared)
        try await listen(scene)
        let target = scene.tabs[1]
        let id = try await tabID(target, .worker, scene)
        _ = try await call(.worker, scene, "attach", [["tabId": id], "1.3"])
        XCTAssertTrue(target.isAutomationAttached)

        ExtensionManager.shared.setPermissionDecision(extensionID: scene.loaded.ext.id, key: "debugger",
                                                      type: .apiPermission, granted: false)
        let reason = try await waitForDetach(.worker, scene, tabID: id)
        XCTAssertEqual(reason, "canceled_by_user")
        XCTAssertFalse(target.isAutomationAttached, "the tab is released")
        for via in Via.allCases {
            let refused = try await failure(via, scene, "attach", [["tabId": id], "1.3"])
            XCTAssertEqual(refused, "debugger permission denied by the user", "[\(via)]")
        }
        ExtensionManager.shared.setPermissionDecision(extensionID: scene.loaded.ext.id, key: "debugger",
                                                      type: .apiPermission, granted: true)
        _ = try await call(.page, scene, "attach", [["tabId": id], "1.3"])
        XCTAssertTrue(target.isAutomationAttached, "granted again, it attaches")
        // The worker kept listening through the denial: a second one still
        // reaches its onDetach.
        ExtensionManager.shared.setPermissionDecision(extensionID: scene.loaded.ext.id, key: "debugger",
                                                      type: .apiPermission, granted: false)
        try await waitUntil("a second onDetach in the worker", timeout: 10) {
            let recorded = (try? await self.events(.worker, scene)) ?? []
            return recorded.filter {
                $0["event"] as? String == "onDetach" && $0["tabId"] as? Int == id
                    && $0["reason"] as? String == "canceled_by_user"
            }.count >= 2
        }
        ExtensionManager.shared.setPermissionDecision(extensionID: scene.loaded.ext.id, key: "debugger",
                                                      type: .apiPermission, granted: true)
    }

    // MARK: - Attach, getTargets, detach (AC #1)

    @MainActor func testAttachGetTargetsAndDetachFromBothContexts() async throws {
        let scene = try await makeScene("Debugger Attach")
        try await listen(scene)
        for via in Via.allCases {
            let target = scene.tabs[2]
            let id = try await tabID(target, via, scene)
            let value = try await call(via, scene, "attach", [["tabId": id], "1.3"])
            XCTAssertTrue(value is NSNull, "[\(via)] attach resolves with nothing")
            XCTAssertTrue(target.isAutomationAttached, "[\(via)]")
            XCTAssertEqual(target.automationOwners,
                           [TabAutomationOwner(extensionID: scene.loaded.ext.id, reason: "debugger")], "[\(via)]")
            XCTAssertEqual(target.automationHosting, .parked, "[\(via)] an unselected tab is parked")
            XCTAssertEqual(scene.window.selectedTabID, scene.tabs[0].id, "[\(via)] the selection does not move")

            let listed = try await call(via, scene, "getTargets", [])
            let targets = try XCTUnwrap(listed as? [[String: Any]])
            let mine = try XCTUnwrap(targets.first { $0["tabId"] as? Int == id }, "[\(via)] \(targets)")
            XCTAssertEqual(mine["attached"] as? Bool, true, "[\(via)]")
            XCTAssertEqual(mine["type"] as? String, "page", "[\(via)]")
            XCTAssertEqual(mine["url"] as? String, world.url("three").absoluteString, "[\(via)]")
            XCTAssertEqual(mine["title"] as? String, "three", "[\(via)]")
            XCTAssertTrue((mine["id"] as? String ?? "").hasPrefix("detour-tab-"), "[\(via)]")
            XCTAssertEqual(targets.filter { $0["attached"] as? Bool == true }.count, 1, "[\(via)] only that tab")

            let detached = try await call(via, scene, "detach", [["tabId": id]])
            XCTAssertTrue(detached is NSNull, "[\(via)]")
            XCTAssertFalse(target.isAutomationAttached, "[\(via)]")
            let listedAfter = try await call(via, scene, "getTargets", [])
            let after = try XCTUnwrap(listedAfter as? [[String: Any]])
            XCTAssertEqual(after.first { $0["tabId"] as? Int == id }?["attached"] as? Bool, false, "[\(via)]")

            // By target id, as getTargets lists it.
            _ = try await call(via, scene, "attach", [["targetId": mine["id"] as? String ?? ""], "1.3"])
            XCTAssertTrue(target.isAutomationAttached, "[\(via)] attach by targetId")
            _ = try await call(via, scene, "detach", [["targetId": mine["id"] as? String ?? ""]])
            XCTAssertFalse(target.isAutomationAttached, "[\(via)]")
        }
        // Chrome fires no onDetach for the extension's own detach.
        try await Task.sleep(for: .milliseconds(300))
        for via in Via.allCases {
            let answer1 = try await events(via, scene).filter { $0["event"] as? String == "onDetach" }.isEmpty
            XCTAssertTrue(answer1, "[\(via)]")
        }
    }

    /// Closing the tab ends the attachment with `target_closed`, told to every
    /// context that listens — the worker attached, the page hears it too.
    @MainActor func testClosingTheTabFiresOnDetachTargetClosedInBothContexts() async throws {
        let scene = try await makeScene("Debugger Close")
        try await listen(scene)
        let target = scene.tabs[3]
        let workerID = try await tabID(target, .worker, scene)
        let pageID = try await tabID(target, .page, scene)
        XCTAssertEqual(workerID, pageID, "one id per tab across the extension's contexts")
        _ = try await call(.worker, scene, "attach", [["tabId": workerID], "1.3"])
        TabStore.shared.closeTab(id: target.id, in: scene.space, undoable: false, registersUndo: false)
        for via in Via.allCases {
            let reason = try await waitForDetach(via, scene, tabID: workerID)
            XCTAssertEqual(reason, "target_closed", "[\(via)]")
        }
        XCTAssertNil(ExtensionDebugger.shared.session(forTabUUID: target.id))
    }

    /// The user's Stop (AC #5) ends the attachment as Chrome's infobar
    /// Cancel does: `canceled_by_user`.
    @MainActor func testTheUsersStopFiresOnDetachCanceledByUser() async throws {
        let scene = try await makeScene("Debugger Stop")
        try await listen(scene)
        let target = scene.tabs[1]
        let id = try await tabID(target, .page, scene)
        _ = try await call(.page, scene, "attach", [["tabId": id], "1.3"])
        let owner = try XCTUnwrap(target.automationOwners.first)
        XCTAssertTrue(TabAutomationStop.isStoppable(owner))
        TabAutomationStop.stopAll(on: target)
        XCTAssertFalse(target.isAutomationAttached, "Stop releases the tab at once")
        for via in Via.allCases {
            let reason = try await waitForDetach(via, scene, tabID: id)
            XCTAssertEqual(reason, "canceled_by_user", "[\(via)]")
        }
        let notAttached = try await failure(.worker, scene, "sendCommand", [["tabId": id], "Page.enable"])
        XCTAssertEqual(notAttached, "Debugger is not attached to the tab with id: \(id).")
    }

    /// Unloading the extension (disabled, removed) releases its tabs; nobody
    /// is left to tell.
    @MainActor func testUnloadingTheExtensionReleasesTheTab() async throws {
        let scene = try await makeScene("Debugger Unload")
        let target = scene.tabs[1]
        let id = try await tabID(target, .page, scene)
        _ = try await call(.page, scene, "attach", [["tabId": id], "1.3"])
        XCTAssertTrue(target.isAutomationAttached)
        _ = scene.profile.unloadExtension(id: scene.loaded.ext.id)
        XCTAssertFalse(target.isAutomationAttached)
        XCTAssertNil(ExtensionDebugger.shared.session(forTabUUID: target.id))
    }

    /// Navigating an attached tab to a page no extension may attach to ends
    /// the attachment, as Chrome's client host does.
    @MainActor func testNavigatingToAnInternalPageEndsTheAttachment() async throws {
        let scene = try await makeScene("Debugger Navigate")
        try await listen(scene)
        let target = scene.tabs[1]
        let id = try await tabID(target, .worker, scene)
        _ = try await call(.worker, scene, "attach", [["tabId": id], "1.3"])
        target.loadInternalPage(.history)
        let reason = try await waitForDetach(.worker, scene, tabID: id)
        XCTAssertEqual(reason, "target_closed")
        XCTAssertFalse(target.isAutomationAttached)
    }

    // MARK: - Attach refusals (AC #2)

    @MainActor func testAttachRefusalsInChromesWords() async throws {
        let scene = try await makeScene("Debugger Refusals")
        let target = scene.tabs[1]
        for via in Via.allCases {
            let id = try await tabID(target, via, scene)
            let answer2 = try await failure(via, scene, "attach", [["tabId": 987_654], "1.3"])
            XCTAssertEqual(answer2,
                           "No tab with given id 987654.", "[\(via)]")
            let answer3 = try await failure(via, scene, "attach", [["tabId": id], "2.0"])
            XCTAssertEqual(answer3,
                           "Requested protocol version is not supported: 2.0.", "[\(via)]")
            let answer4 = try await failure(via, scene, "attach", [["extensionId": scene.loaded.ext.id], "1.3"])
            XCTAssertEqual(answer4,
                           "Cannot attach to this target.", "[\(via)]")
            _ = try await call(via, scene, "attach", [["tabId": id], "1.3"])
            let answer5 = try await failure(via, scene, "attach", [["tabId": id], "1.3"])
            XCTAssertEqual(answer5,
                           "Another debugger is already attached to the tab with id: \(id).", "[\(via)] the same extension")
            let callback = try await callback(via, scene, "attach", [["tabId": id], "1.3"])
            XCTAssertEqual(callback["lastError"] as? String,
                           "Another debugger is already attached to the tab with id: \(id).", "[\(via)] callback form")
            _ = try await call(via, scene, "detach", [["tabId": id]])
        }

        // Another extension, while this one holds the tab.
        let other = try await world.load(try await world.makeExtension(name: "Other Debugger", permissions: ["debugger", "tabs"],
                                                                       defaultPath: nil), in: scene.profile)
        let id = try await tabID(target, .page, scene)
        _ = try await call(.page, scene, "attach", [["tabId": id], "1.3"])
        let otherID = try await world.tabID(of: target, .page, in: other)
        let taken = try await world.failure(.page, in: other, ["op": "call", "method": "attach",
                                                               "args": [["tabId": otherID], "1.3"]])
        XCTAssertEqual(taken, "Another debugger is already attached to the tab with id: \(otherID).")
        let notMine = try await world.failure(.page, in: other, ["op": "call", "method": "sendCommand",
                                                                 "args": [["tabId": otherID], "Page.enable"]])
        XCTAssertEqual(notMine, "Debugger is not attached to the tab with id: \(otherID).",
                       "another extension cannot drive the attachment")
        _ = try await call(.page, scene, "detach", [["tabId": id]])

        // Detour's own pages, and another extension's page in a tab.
        let internalTab = TabStore.shared.addTab(in: scene.space, internalPage: .history)
        try await waitUntil("the internal page tab to have its URL") { internalTab.url != nil }
        let internalID = try await tabID(internalTab, .page, scene)
        let answer6 = try await failure(.page, scene, "attach", [["tabId": internalID], "1.3"])
        XCTAssertEqual(answer6,
                       "Cannot access a detour:// URL")
        let foreign = TabStore.shared.addExtensionTab(in: scene.space, url: other.context.baseURL.appendingPathComponent("test.html"),
                                                      configuration: try XCTUnwrap(other.context.webViewConfiguration))
        try await waitUntil("the extension page tab to have its URL") { foreign.url != nil }
        let foreignID = try await tabID(foreign, .page, scene)
        let answer7 = try await failure(.page, scene, "attach", [["tabId": foreignID], "1.3"])
        XCTAssertEqual(answer7,
                       ExtensionDebugger.otherExtensionPageError)
        XCTAssertFalse(internalTab.isAutomationAttached)
        XCTAssertFalse(foreign.isAutomationAttached)
        // Its own page is fine, as in Chrome.
        let own = TabStore.shared.addExtensionTab(in: scene.space, url: scene.loaded.context.baseURL.appendingPathComponent("test.html"),
                                                  configuration: try XCTUnwrap(scene.loaded.context.webViewConfiguration))
        try await waitUntil("the own page tab to have its URL") { own.url != nil }
        let ownID = try await tabID(own, .page, scene)
        _ = try await call(.page, scene, "attach", [["tabId": ownID], "1.3"])
        XCTAssertTrue(own.isAutomationAttached)
    }

    /// NEGATIVE: an extension's context in another profile cannot name this
    /// profile's tab, nor drive this profile's attachment.
    @MainActor func testAnotherProfileCannotAttachOrDrive() async throws {
        let scene = try await makeScene("Debugger Profile A")
        let target = scene.tabs[1]
        let id = try await tabID(target, .page, scene)
        _ = try await call(.page, scene, "attach", [["tabId": id], "1.3"])

        let otherProfile = world.makeProfile("Debugger Profile B")
        let otherSpace = world.makeSpace("Debugger Profile B", in: otherProfile)
        let otherWindow = world.makeWindow(on: otherSpace)
        let otherTab = try await world.addTab("one", in: otherSpace)
        otherWindow.selectTab(id: otherTab.id)
        let otherLoaded = try await world.load(scene.loaded.ext, in: otherProfile)

        let handle = ExtensionTabHandleRegistry.shared.handle(for: target)
        let attach = try await postRawPolyfillEnvelope(from: otherLoaded.page, type: "debugger.attach",
                                                       claimedID: scene.loaded.ext.id,
                                                       params: ["tabId": id, "tabHandle": handle, "version": "1.3"])
        XCTAssertEqual(attach.error, "No tab with given id \(id).", "another profile's tab is no tab at all")
        let drive = try await postRawPolyfillEnvelope(from: otherLoaded.page, type: "debugger.sendCommand",
                                                      claimedID: scene.loaded.ext.id,
                                                      params: ["tabId": id, "method": "Page.enable"])
        XCTAssertEqual(drive.error, "Debugger is not attached to the tab with id: \(id).")
        let detach = try await postRawPolyfillEnvelope(from: otherLoaded.page, type: "debugger.detach",
                                                       claimedID: scene.loaded.ext.id, params: ["tabId": id])
        XCTAssertEqual(detach.error, "Debugger is not attached to the tab with id: \(id).")
        XCTAssertTrue(target.isAutomationAttached, "the attachment stands")
        let targets = try await postRawPolyfillEnvelope(from: otherLoaded.page, type: "debugger.targets",
                                                        claimedID: scene.loaded.ext.id,
                                                        params: ["tabs": [["tabId": id, "handle": handle]]])
        XCTAssertEqual(((targets.result as? [String: Any])?["targets"] as? [[String: Any]])?.count, 0,
                       "another profile's tab is not listed")
    }

    // MARK: - Commands (AC #4)

    @MainActor func testUnknownMethodsAndDetachedTabsFailInChromesWords() async throws {
        let scene = try await makeScene("Debugger Commands")
        for via in Via.allCases {
            let id = try await tabID(scene.tabs[1], via, scene)
            let answer8 = try await failure(via, scene, "sendCommand", [["tabId": id], "Page.enable"])
            XCTAssertEqual(answer8,
                           "Debugger is not attached to the tab with id: \(id).", "[\(via)]")
            let notAttached = try await callback(via, scene, "sendCommand", [["tabId": id], "Page.enable", [:]])
            XCTAssertEqual(notAttached["lastError"] as? String, "Debugger is not attached to the tab with id: \(id).",
                           "[\(via)] callback form")
            let answer9 = try await failure(via, scene, "detach", [["tabId": id]])
            XCTAssertEqual(answer9,
                           "Debugger is not attached to the tab with id: \(id).", "[\(via)]")

            _ = try await call(via, scene, "attach", [["tabId": id], "1.3"])
            let answer10 = try await failure(via, scene, "sendCommand", [["tabId": id], "Bogus.method", [:]])
            XCTAssertEqual(answer10,
                           #"{"code":-32601,"message":"'Bogus.method' wasn't found"}"#, "[\(via)]")
            let unknown = try await callback(via, scene, "sendCommand", [["tabId": id], "Bogus.method"])
            XCTAssertEqual(unknown["lastError"] as? String, #"{"code":-32601,"message":"'Bogus.method' wasn't found"}"#,
                           "[\(via)] callback form")
            XCTAssertEqual(unknown["argc"] as? Int, 0, "[\(via)] Chrome calls back with no result on error")
            let enabled = try await call(via, scene, "sendCommand", [["tabId": id], "Page.enable"])
            XCTAssertEqual((enabled as? [String: Any])?.isEmpty, true, "[\(via)] Page.enable answers {}")
            _ = try await call(via, scene, "detach", [["tabId": id]])
        }
    }

    // MARK: - Page.captureScreenshot (AC #3)

    @MainActor private func paint(_ tab: BrowserTab) async throws {
        let webView = try XCTUnwrap(tab.webView)
        _ = try await webView.callAsyncJavaScript("""
            document.body.innerHTML = '';
            document.documentElement.style.background = 'rgb(0, 0, 255)';
            document.body.style.margin = '0';
            const box = document.createElement('div');
            box.style.cssText = 'position:fixed;left:0;top:0;width:100px;height:100px;background:rgb(255,0,0)';
            document.body.appendChild(box);
            // Not requestAnimationFrame: a window that is never shown runs none.
            await new Promise((r) => setTimeout(r, 50));
            """, arguments: [:], contentWorld: .page)
    }

    @MainActor private func viewport(_ tab: BrowserTab) async throws -> (width: Double, height: Double, dpr: Double) {
        let webView = try XCTUnwrap(tab.webView)
        let raw = try await webView.callAsyncJavaScript("return [innerWidth, innerHeight, devicePixelRatio];",
                                                        arguments: [:], contentWorld: .page)
        let values = try XCTUnwrap(raw as? [NSNumber]).map(\.doubleValue)
        return (values[0], values[1], values[2])
    }

    /// `probes` are points in CSS pixels of what was captured (the clip's own
    /// space before scale); `probeScale` turns them into image pixels.
    @MainActor private func shoot(_ via: Via, _ scene: Scene, tabID: Int, params: [String: Any],
                                  probes: [[Double]], probeScale: Double = 1) async throws -> [String: Any] {
        try await world.runDict(via, in: scene.loaded, ["op": "screenshot", "tabId": tabID, "params": params,
                                                        "probes": probes, "probeScale": probeScale])
    }

    /// The visible viewport of the selected tab and of an unselected (parked)
    /// one, at the page's CSS size × devicePixelRatio, with format, quality
    /// and clip-with-scale honoured.
    @MainActor func testCaptureScreenshotOfTheSelectedAndAnUnselectedTab() async throws {
        let scene = try await makeScene("Debugger Screenshot")
        for (index, via) in [(0, Via.worker), (1, Via.page)] {
            let tab = scene.tabs[index]
            let id = try await tabID(tab, via, scene)
            _ = try await call(via, scene, "attach", [["tabId": id], "1.3"])
            XCTAssertEqual(tab.automationHosting, index == 0 ? .displayed : .parked, "[\(via)]")
            try await paint(tab)
            let (width, height, dpr) = try await viewport(tab)

            let full = try await shoot(via, scene, tabID: id, params: ["format": "png"],
                                       probes: [[10, 10], [width / 2, height / 2]], probeScale: dpr)
            XCTAssertEqual(full["magic"] as? String, "png", "[\(via)]")
            XCTAssertEqual(full["width"] as? Int, Int((width * dpr).rounded()), "[\(via)] \(full)")
            XCTAssertEqual(full["height"] as? Int, Int((height * dpr).rounded()), "[\(via)] \(full)")
            let pixels = try XCTUnwrap(full["pixels"] as? [[Int]], "[\(via)]")
            XCTAssertTrue(isColor(pixels[0], red: 255, green: 0, blue: 0), "[\(via)] top-left is the red box: \(pixels[0])")
            XCTAssertTrue(isColor(pixels[1], red: 0, green: 0, blue: 255), "[\(via)] the middle is blue: \(pixels[1])")

            // The red box alone, at half scale.
            let clipped = try await shoot(via, scene, tabID: id,
                                          params: ["format": "png", "clip": ["x": 0, "y": 0, "width": 100, "height": 100, "scale": 0.5]],
                                          probes: [[10, 10], [90, 90]], probeScale: 0.5 * dpr)
            XCTAssertEqual(clipped["width"] as? Int, Int((100 * 0.5 * dpr).rounded()), "[\(via)] \(clipped)")
            XCTAssertEqual(clipped["height"] as? Int, Int((100 * 0.5 * dpr).rounded()), "[\(via)]")
            for pixel in try XCTUnwrap(clipped["pixels"] as? [[Int]]) {
                XCTAssertTrue(isColor(pixel, red: 255, green: 0, blue: 0), "[\(via)] all red: \(pixel)")
            }
            // Below the box: blue only. Proves the clip's y is honoured.
            let below = try await shoot(via, scene, tabID: id,
                                        params: ["clip": ["x": 0, "y": 150, "width": 50, "height": 50, "scale": 1]],
                                        probes: [[25, 25]], probeScale: dpr)
            XCTAssertTrue(isColor(try XCTUnwrap((below["pixels"] as? [[Int]])?.first), red: 0, green: 0, blue: 255),
                          "[\(via)] \(below)")

            let rough = try await shoot(via, scene, tabID: id, params: ["format": "jpeg", "quality": 5], probes: [])
            let fine = try await shoot(via, scene, tabID: id, params: ["format": "jpeg", "quality": 95], probes: [])
            XCTAssertEqual(rough["magic"] as? String, "jpeg", "[\(via)]")
            XCTAssertLessThan(rough["length"] as? Int ?? .max, fine["length"] as? Int ?? 0, "[\(via)] quality is honoured")
            XCTAssertEqual(fine["width"] as? Int, Int((width * dpr).rounded()), "[\(via)]")

            let answer11 = try await failure(via, scene, "sendCommand", [["tabId": id], "Page.captureScreenshot",
                                                                         ["format": "gif"]])
            XCTAssertEqual(answer11,
                           #"{"code":-32602,"message":"Invalid parameters: format: unknown value"}"#, "[\(via)]")
            _ = try await call(via, scene, "detach", [["tabId": id]])
        }
        XCTAssertEqual(scene.window.selectedTabID, scene.tabs[0].id, "capturing never changes the selection")
    }

    private func isColor(_ pixel: [Int], red: Int, green: Int, blue: Int, tolerance: Int = 40) -> Bool {
        pixel.count >= 3 && abs(pixel[0] - red) <= tolerance && abs(pixel[1] - green) <= tolerance
            && abs(pixel[2] - blue) <= tolerance
    }
}

enum DebuggerFixture {

    static let opJS = """
    async function __detourTestPanelOp(message) {
        const orNull = (value) => value === undefined ? null : value;
        const record = (entry) => { (globalThis.__detourTestEvents = globalThis.__detourTestEvents || []).push(entry); };
        switch (message.op) {
        case 'install':
            return {
                type: typeof chrome.debugger,
                install: orNull(globalThis.__detourDebuggerInstall),
                keys: chrome.debugger ? Object.keys(chrome.debugger).sort() : [],
                viaBrowser: !!(globalThis.browser && browser.debugger && browser.debugger === chrome.debugger)
            };
        case 'call': {
            const value = await chrome.debugger[message.method].apply(chrome.debugger, message.args || []);
            return orNull(value);
        }
        case 'callback':
            return await new Promise((resolve) => {
                chrome.debugger[message.method].apply(chrome.debugger, (message.args || []).concat([function() {
                    resolve({
                        argc: arguments.length,
                        arg0: arguments.length ? orNull(arguments[0]) : null,
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
                    });
                }]));
            });
        case 'screenshot': {
            const reply = await chrome.debugger.sendCommand({ tabId: message.tabId }, 'Page.captureScreenshot', message.params);
            const data = reply.data;
            const bytes = Uint8Array.from(atob(data), (c) => c.charCodeAt(0));
            const magic = bytes[0] === 0x89 && bytes[1] === 0x50 ? 'png' : bytes[0] === 0xFF && bytes[1] === 0xD8 ? 'jpeg' : 'other';
            const bitmap = await createImageBitmap(new Blob([bytes]));
            const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
            const context = canvas.getContext('2d');
            context.drawImage(bitmap, 0, 0);
            const k = message.probeScale || 1;
            const pixels = [];
            for (const [x, y] of (message.probes || [])) {
                const px = Math.min(bitmap.width - 1, Math.floor(x * k));
                const py = Math.min(bitmap.height - 1, Math.floor(y * k));
                pixels.push(Array.from(context.getImageData(px, py, 1, 1).data));
            }
            return { magic: magic, width: bitmap.width, height: bitmap.height, length: data.length, pixels: pixels };
        }
        case 'tabs': {
            const all = await chrome.windows.getAll({ populate: true });
            const out = [];
            for (const w of all) {
                for (const t of (w.tabs || [])) {
                    out.push({ id: t.id, windowId: w.id, active: t.active, handle: await __detourResolveTab(t.id) });
                }
            }
            return { tabs: out };
        }
        case 'listen': {
            if (globalThis.__detourTestListening) return true;
            globalThis.__detourTestListening = true;
            chrome.debugger.onEvent.addListener((source, method, params) => {
                record({ event: 'onEvent', tabId: source.tabId, method: method, params: params });
            });
            chrome.debugger.onDetach.addListener((source, reason) => {
                record({ event: 'onDetach', tabId: source.tabId, reason: reason });
            });
            return true;
        }
        case 'events':
            return (globalThis.__detourTestEvents || []).slice();
        case 'clearEvents':
            globalThis.__detourTestEvents = [];
            return true;
        }
        throw new Error('unknown op ' + message.op);
    }
    """
}
