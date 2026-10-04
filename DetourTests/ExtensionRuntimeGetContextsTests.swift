import XCTest
import WebKit
@testable import Detour

/// TASK-132.9: `chrome.runtime.getContexts` and `chrome.runtime.ContextType` in
/// a real extension — asked from its service worker and from one of its pages
/// — against the contexts Detour really hosts: the worker, an extension page in
/// a tab, an offscreen document and side panels.
///
/// Same world as `ExtensionSidePanelTests`: production profiles and store,
/// browser windows that are never shown.
@MainActor
final class ExtensionRuntimeGetContextsTests: XCTestCase {

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

    private struct Scene {
        let loaded: SidePanelTestWorld.Loaded
        let space: Space
        let window: BrowserWindowController
        let first: BrowserTab
        let second: BrowserTab
        var panels: ExtensionSidePanelController { loaded.profile.sidePanels }
    }

    private func makeScene(_ name: String, permissions: [String] = ["sidePanel"]) async throws -> Scene {
        let ext = try await world.makeExtension(name: name, permissions: permissions)
        let profile = world.makeProfile(name)
        let space = world.makeSpace(name, in: profile)
        let window = world.makeWindow(on: space)
        let first = try await world.addTab("one", in: space)
        let second = try await world.addTab("two", in: space)
        window.selectTab(id: first.id)
        let loaded = try await world.load(ext, in: profile)
        return Scene(loaded: loaded, space: space, window: window, first: first, second: second)
    }

    private func contexts(_ via: Via, in loaded: SidePanelTestWorld.Loaded,
                          filter: [String: Any] = [:]) async throws -> [[String: Any]] {
        let value = try await world.run(via, in: loaded, ["op": "getContexts", "filter": filter])
        return try XCTUnwrap(value as? [[String: Any]], "expected an array, got \(value)")
    }

    private func openTabPanel(_ via: Via, in scene: Scene, for tab: BrowserTab) async throws -> (panel: ExtensionSidePanel, tabID: Int) {
        let tabID = try await world.tabID(of: tab, via, in: scene.loaded)
        _ = try await world.run(via, in: scene.loaded, [
            "op": "setOptionsThenOpen",
            "options": ["tabId": tabID, "path": "tabpanel.html?tabId=\(tabID)", "enabled": true],
            "target": ["tabId": tabID],
        ])
        let panel = try XCTUnwrap(scene.panels.panels(for: scene.loaded.ext.id).first { $0.tab === tab })
        return (panel, tabID)
    }

    // MARK: - AC #1

    func testContextTypeAndGetContextsExistInTheWorkerAndInAPage() async throws {
        // No sidePanel permission: getContexts is the runtime's, not the panel's.
        let scene = try await makeScene("Contexts Enum", permissions: [])
        for via in Via.allCases {
            let state = try await world.runDict(via, in: scene.loaded, ["op": "install"])
            XCTAssertEqual(state["getContextsType"] as? String, "function", "[\(via)]")
            XCTAssertEqual(state["getContextsInstall"] as? String, "polyfill", "[\(via)]")
            XCTAssertEqual(state["contextType"] as? [String: String], [
                "TAB": "TAB", "POPUP": "POPUP", "BACKGROUND": "BACKGROUND",
                "OFFSCREEN_DOCUMENT": "OFFSCREEN_DOCUMENT", "SIDE_PANEL": "SIDE_PANEL",
                "DEVELOPER_TOOLS": "DEVELOPER_TOOLS",
            ], "[\(via)]")
        }
    }

    // MARK: - AC #2, #3

    func testTheWorkerATabPageAndAnOpenPanelAreListedWithTheirIds() async throws {
        let scene = try await makeScene("Contexts List")
        let base = scene.loaded.context.baseURL
        let origin = "webkit-extension://\(try XCTUnwrap(base.host))"

        // One of the extension's pages in a tab of the window.
        let pageTab = TabStore.shared.addExtensionTab(
            in: scene.space, url: base.appendingPathComponent("test.html"),
            configuration: try XCTUnwrap(scene.loaded.context.webViewConfiguration))
        try await waitUntil("the extension page tab to load") { pageTab.webView?.url?.path == "/test.html" && pageTab.webView?.isLoading == false }

        for via in Via.allCases {
            let (panel, tabID) = try await openTabPanel(via, in: scene, for: scene.first)
            try await world.waitForPanelPage(panel)
            let windowID = try await world.windowID(listing: scene.first, via, in: scene.loaded)
            let pageTabID = try await world.tabID(of: pageTab, via, in: scene.loaded)

            let all = try await contexts(via, in: scene.loaded)
            let types = all.compactMap { $0["contextType"] as? String }
            XCTAssertEqual(types.sorted(), ["BACKGROUND", "SIDE_PANEL", "TAB"], "[\(via)] \(all)")
            XCTAssertEqual(Set(all.compactMap { $0["contextId"] as? String }).count, 3, "[\(via)] context ids are distinct")
            for context in all {
                XCTAssertEqual(context["incognito"] as? Bool, false, "[\(via)]")
                XCTAssertNil(context["tabHandle"], "[\(via)] handles never reach the extension")
                XCTAssertNil(context["windowTabHandle"], "[\(via)]")
            }

            let background = try XCTUnwrap(all.first { $0["contextType"] as? String == "BACKGROUND" })
            XCTAssertEqual(background["tabId"] as? Int, -1, "[\(via)]")
            XCTAssertEqual(background["windowId"] as? Int, -1, "[\(via)]")
            XCTAssertEqual(background["frameId"] as? Int, -1, "[\(via)]")
            XCTAssertNil(background["documentUrl"], "[\(via)] a service worker has no document")

            let tab = try XCTUnwrap(all.first { $0["contextType"] as? String == "TAB" })
            XCTAssertEqual(tab["documentUrl"] as? String, base.appendingPathComponent("test.html").absoluteString, "[\(via)]")
            XCTAssertEqual(tab["documentOrigin"] as? String, origin, "[\(via)]")
            XCTAssertEqual(tab["tabId"] as? Int, pageTabID, "[\(via)]")
            XCTAssertEqual(tab["windowId"] as? Int, windowID, "[\(via)]")
            XCTAssertEqual(tab["frameId"] as? Int, 0, "[\(via)]")

            let sidePanel = try XCTUnwrap(all.first { $0["contextType"] as? String == "SIDE_PANEL" })
            XCTAssertEqual(sidePanel["documentUrl"] as? String, "\(origin)/tabpanel.html?tabId=\(tabID)",
                           "[\(via)] the full URL, query included")
            XCTAssertEqual(sidePanel["documentOrigin"] as? String, origin, "[\(via)]")
            XCTAssertEqual(sidePanel["tabId"] as? Int, -1, "[\(via)] a panel is not a tab")
            XCTAssertEqual(sidePanel["windowId"] as? Int, windowID, "[\(via)] the window its tab is in")

            // The filters, on real ids.
            let onlyPanels = try await contexts(via, in: scene.loaded, filter: ["contextTypes": ["SIDE_PANEL"]])
            XCTAssertEqual(onlyPanels.count, 1, "[\(via)]")
            XCTAssertEqual(onlyPanels.first?["contextId"] as? String, sidePanel["contextId"] as? String, "[\(via)] ids are stable")
            let byTab = try await contexts(via, in: scene.loaded, filter: ["tabIds": [pageTabID]])
            XCTAssertEqual(byTab.compactMap { $0["contextType"] as? String }, ["TAB"], "[\(via)]")
            let byOtherTab = try await contexts(via, in: scene.loaded, filter: ["tabIds": [tabID]])
            XCTAssertEqual(byOtherTab.count, 0, "[\(via)] the panel's tab is a web page, not a context")
            let byWindow = try await contexts(via, in: scene.loaded, filter: ["windowIds": [windowID]])
            XCTAssertEqual(byWindow.compactMap { $0["contextType"] as? String }.sorted(), ["SIDE_PANEL", "TAB"], "[\(via)]")
            let byURL = try await contexts(via, in: scene.loaded, filter: ["documentUrls": ["\(origin)/tabpanel.html?tabId=\(tabID)"]])
            XCTAssertEqual(byURL.compactMap { $0["contextType"] as? String }, ["SIDE_PANEL"], "[\(via)]")
            let byBareURL = try await contexts(via, in: scene.loaded, filter: ["documentUrls": ["\(origin)/tabpanel.html"]])
            XCTAssertEqual(byBareURL.count, 0, "[\(via)]")
            let incognito = try await contexts(via, in: scene.loaded, filter: ["incognito": true])
            XCTAssertEqual(incognito.count, 0, "[\(via)]")

            // Callback form.
            let callback = try await world.runDict(via, in: scene.loaded, ["op": "getContextsCallback", "filter": ["contextTypes": ["SIDE_PANEL"]]])
            XCTAssertEqual(callback["argc"] as? Int, 1, "[\(via)]")
            XCTAssertTrue(callback["lastError"] is NSNull, "[\(via)]")
            XCTAssertEqual((callback["contexts"] as? [[String: Any]])?.count, 1, "[\(via)]")
            let badFilter = try await world.runDict(via, in: scene.loaded, ["op": "getContextsCallback", "filter": ["contextTypes": "SIDE_PANEL"]])
            XCTAssertEqual(badFilter["argc"] as? Int, 0, "[\(via)]")
            XCTAssertTrue((badFilter["lastError"] as? String)?.contains("contextTypes must be an array") == true, "[\(via)] \(badFilter)")

            // A closed panel is not reported.
            scene.panels.close(panel, reason: .user)
            let afterClose = try await contexts(via, in: scene.loaded, filter: ["contextTypes": ["SIDE_PANEL"]])
            XCTAssertEqual(afterClose.count, 0, "[\(via)] a closed panel is not a context")
        }
    }

    func testAPanelHiddenWithItsTabIsStillAContextAndAWindowPanelNamesItsWindow() async throws {
        let scene = try await makeScene("Contexts Hidden Panel")
        let (panel, tabID) = try await openTabPanel(.worker, in: scene, for: scene.first)
        scene.window.selectTab(id: scene.second.id)
        XCTAssertNil(panel.view.superview, "precondition: the panel is off screen")
        let hidden = try await contexts(.worker, in: scene.loaded, filter: ["contextTypes": ["SIDE_PANEL"]])
        XCTAssertEqual(hidden.count, 1, "open is open, on screen or not")
        XCTAssertTrue((hidden.first?["documentUrl"] as? String)?.hasSuffix("tabpanel.html?tabId=\(tabID)") == true)

        let windowID = try await world.windowID(listing: scene.second, .worker, in: scene.loaded)
        _ = try await world.run(.worker, in: scene.loaded, ["op": "call", "method": "open", "args": [["windowId": windowID]]])
        let both = try await contexts(.worker, in: scene.loaded, filter: ["contextTypes": ["SIDE_PANEL"]])
        XCTAssertEqual(both.count, 2)
        let windowPanel = try XCTUnwrap(both.first { ($0["documentUrl"] as? String)?.hasSuffix("/panel.html") == true })
        XCTAssertEqual(windowPanel["windowId"] as? Int, windowID)
        XCTAssertEqual(windowPanel["tabId"] as? Int, -1)
    }

    func testAnOffscreenDocumentIsListedOnceItHasLoaded() async throws {
        let scene = try await makeScene("Contexts Offscreen")
        let host = try XCTUnwrap(scene.loaded.context.baseURL.host)
        let created = try await postRawPolyfillEnvelope(from: scene.loaded.page, type: "offscreen.createDocument",
                                                        claimedID: scene.loaded.ext.id, params: ["url": "test.html"])
        XCTAssertNil(created.error)
        for via in Via.allCases {
            let offscreen = try await contexts(via, in: scene.loaded, filter: ["contextTypes": ["OFFSCREEN_DOCUMENT"]])
            XCTAssertEqual(offscreen.count, 1, "[\(via)]")
            XCTAssertEqual(offscreen.first?["documentUrl"] as? String, "webkit-extension://\(host)/test.html", "[\(via)]")
            XCTAssertEqual(offscreen.first?["tabId"] as? Int, -1, "[\(via)]")
            XCTAssertEqual(offscreen.first?["windowId"] as? Int, -1, "[\(via)]")
        }
        scene.loaded.profile.polyfillHandler?.closeOffscreenDocument(for: scene.loaded.ext.id)
        let after = try await contexts(.worker, in: scene.loaded, filter: ["contextTypes": ["OFFSCREEN_DOCUMENT"]])
        XCTAssertEqual(after.count, 0)
    }

    // MARK: - The Claude extension's toggle (TASK-132.8 AC #1, second half)

    func testTheShortcutOpensThePanelAndPressedAgainClosesIt() async throws {
        let scene = try await makeScene("Contexts Toggle")
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: scene.window.window?.windowNumber ?? 0, context: nil,
            characters: "Y", charactersIgnoringModifiers: "y", isARepeat: false, keyCode: 16))

        XCTAssertTrue(ExtensionCommandDispatch.perform(event, in: scene.window, mainMenu: nil))
        try await waitUntil("the shortcut to open the panel", timeout: 20) { !self.world.panels(of: scene.loaded).isEmpty }
        let panel = try XCTUnwrap(scene.panels.panels.first)
        try await world.waitForPanelPage(panel)
        XCTAssertTrue(scene.window.displayedSidePanel === panel)

        // Again: the handler finds the panel's context and tells its page to
        // close itself.
        XCTAssertTrue(ExtensionCommandDispatch.perform(event, in: scene.window, mainMenu: nil))
        try await waitUntil("the shortcut to close the panel", timeout: 20) { self.world.panels(of: scene.loaded).isEmpty }
        XCTAssertNil(scene.window.displayedSidePanel)

        // And a third press opens it again.
        XCTAssertTrue(ExtensionCommandDispatch.perform(event, in: scene.window, mainMenu: nil))
        try await waitUntil("the shortcut to open the panel again", timeout: 20) { !self.world.panels(of: scene.loaded).isEmpty }
    }

    // MARK: - AC #4: isolation

    func testAnotherExtensionsAndAnotherProfilesContextsAreNeverReturned() async throws {
        let scene = try await makeScene("Contexts Isolation A")
        let (panel, _) = try await openTabPanel(.worker, in: scene, for: scene.first)
        let panelContextID = ExtensionContextIdentity.id(for: try XCTUnwrap(panel.webView))
        let ownHost = try XCTUnwrap(scene.loaded.context.baseURL.host)

        // Another extension in the same profile.
        let otherExt = try await world.makeExtension(name: "Contexts Other Extension")
        let other = try await world.load(otherExt, in: scene.loaded.profile)
        // The same extension in another profile.
        let profileB = world.makeProfile("Contexts Isolation B")
        let spaceB = world.makeSpace("Contexts Isolation B", in: profileB)
        let windowB = world.makeWindow(on: spaceB)
        let tabB = try await world.addTab("three", in: spaceB)
        windowB.selectTab(id: tabB.id)
        let loadedB = try await world.load(scene.loaded.ext, in: profileB)

        for via in Via.allCases {
            for (who, loaded) in [("another extension", other), ("another profile", loadedB)] {
                let seen = try await contexts(via, in: loaded)
                XCTAssertEqual(seen.compactMap { $0["contextType"] as? String }, ["BACKGROUND"],
                               "[\(via)] \(who) sees only its own worker: \(seen)")
                XCTAssertFalse(seen.contains { $0["contextId"] as? String == panelContextID }, "[\(via)] \(who)")
                XCTAssertFalse(seen.contains { ($0["documentUrl"] as? String)?.contains(ownHost) == true }, "[\(via)] \(who)")
                let byID = try await contexts(via, in: loaded, filter: ["contextIds": [panelContextID]])
                XCTAssertEqual(byID.count, 0, "[\(via)] \(who) cannot ask for it by id either")
            }
            // The owner still sees its panel.
            let own = try await contexts(via, in: scene.loaded, filter: ["contextTypes": ["SIDE_PANEL"]])
            XCTAssertEqual(own.first?["contextId"] as? String, panelContextID, "[\(via)]")
        }

        // A body that claims the other extension's id is refused outright.
        let forged = try await postRawPolyfillEnvelope(from: other.page, type: "runtime.getContexts",
                                                       claimedID: scene.loaded.ext.id, params: [:])
        XCTAssertEqual(forged.error, "Extension identity mismatch")
    }

    func testAPrivateProfilesContextsAreIncognito() async throws {
        let ext = try await world.makeExtension(name: "Contexts Private")
        let privateProfile = Profile(name: "Contexts Private", isIncognito: true)
        _ = privateProfile.extensionController
        let loaded = try await world.load(ext, in: privateProfile)
        for via in Via.allCases {
            let all = try await contexts(via, in: loaded)
            XCTAssertEqual(all.compactMap { $0["incognito"] as? Bool }, [true], "[\(via)] \(all)")
            let filtered = try await contexts(via, in: loaded, filter: ["incognito": false])
            XCTAssertEqual(filtered.count, 0, "[\(via)]")
        }
    }

    // MARK: - AC #5: garbage collection

    func testThePatchSurvivesGarbageCollection() async throws {
        let scene = try await makeScene("Contexts GC", permissions: [])
        let raw = try await scene.loaded.page.callAsyncJavaScript("""
            const before = typeof chrome.runtime.getContexts;
            const heldBefore = __detourHeldWrappers.runtime === chrome.runtime;
            // Unreachable the moment it is created: once a collection runs the
            // WeakRef is cleared, which is the proof that one did.
            const control = new WeakRef({ marker: 'control' });
            let collected = false;
            let rounds = 0;
            while (!collected && rounds < 10) {
                rounds += 1;
                for (let i = 0; i < 20 * rounds; i++) {
                    const junk = [];
                    for (let k = 0; k < 50000; k++) junk.push({ i: i, k: k, s: 'x' + k });
                }
                await new Promise(resolve => setTimeout(resolve, 25));
                collected = control.deref() === undefined;
            }
            const after = typeof chrome.runtime.getContexts;
            const contexts = after === 'function' ? await chrome.runtime.getContexts({}) : null;
            return JSON.stringify({
                before: before, heldBefore: heldBefore, collected: collected, rounds: rounds, after: after,
                heldAfter: __detourHeldWrappers.runtime === chrome.runtime,
                sidePanelType: chrome.runtime.ContextType ? chrome.runtime.ContextType.SIDE_PANEL : null,
                browserAfter: typeof browser.runtime.getContexts,
                count: contexts ? contexts.length : null
            });
            """, arguments: [:], contentWorld: .page)
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw as? String).utf8)) as? [String: Any])
        XCTAssertEqual(result["before"] as? String, "function")
        XCTAssertEqual(result["heldBefore"] as? Bool, true, "the polyfill must root the very wrapper chrome.runtime answers with")
        XCTAssertEqual(result["collected"] as? Bool, true,
                       "no collection observed in \(result["rounds"] ?? "nil") rounds, so the read-back proves nothing")
        XCTAssertEqual(result["after"] as? String, "function", "getContexts did not survive a collection")
        XCTAssertEqual(result["heldAfter"] as? Bool, true)
        XCTAssertEqual(result["sidePanelType"] as? String, "SIDE_PANEL", "ContextType did not survive a collection")
        XCTAssertEqual(result["browserAfter"] as? String, "function", "browser.runtime must answer too")
        XCTAssertEqual(result["count"] as? Int, 1, "and it still answers: the worker")
    }
}
