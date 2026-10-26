import XCTest
import WebKit
@testable import Detour

/// How extensions see a Quick Detour (TASK-193.1, decision 4): its page is a
/// tab in a window of type `popup`, listed to its own profile's contexts only;
/// content scripts run in it and reach the worker with a `sender.tab`; the
/// extension button acts on it; closing the window closes the tab.
///
/// Real contexts through the production wiring (`Profile.extensionController`
/// with `ExtensionManager` as its delegate, `loadExtensionContext`), asked
/// from an extension page and from the service worker. The page loaded in the
/// Quick Detour comes from a loopback server.
@MainActor
final class QuickDetourExtensionTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var openWebViews: [WKWebView] = []
    private var windows: [QuickDetourWindowController] = []
    private var servers: [LoopbackHTTPServer] = []
    private var browserWindows: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []

    /// Released profiles take their process pool down with them, which WebKit
    /// traps on inside an IPC dispatch (`ExtensionPrivateStoreTests`): kept for
    /// the rest of the test process.
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
        for controller in windows { controller.close() }
        windows.removeAll()
        for wc in browserWindows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        browserWindows.removeAll()
        for id in createdSpaceIDs {
            TabStore.shared.space(withID: id)?.tabs.forEach { $0.teardown() }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for webView in openWebViews {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        openWebViews.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The worker: answers the tests' questions with the native APIs, and
    /// records what the content script and the action button told it.
    private static let workerJS = """
    const seen = { hellos: [], clicks: [] };
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'hello') {
            seen.hellos.push({ url: sender.tab ? sender.tab.url : null,
                               tabId: sender.tab ? sender.tab.id : null,
                               windowId: sender.tab ? sender.tab.windowId : null });
            sendResponse({ ok: true });
            return true;
        }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'seen') { sendResponse(seen); return true; }
        if (message.type === 'windows') {
            chrome.windows.getAll({ populate: true }).then(
                (value) => sendResponse({ value }),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'popupTabs') {
            chrome.tabs.query({ windowType: 'popup' }).then(
                (value) => sendResponse({ value }),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        return false;
    });
    chrome.action.onClicked.addListener((tab) => {
        seen.clicks.push({ url: tab ? tab.url : null, windowId: tab ? tab.windowId : null });
    });
    // What Open in (TASK-193.3) tells the worker.
    const events = { created: [], removed: [], detached: [], attached: [], windowsRemoved: [], windowsCreated: [] };
    chrome.tabs.onCreated.addListener((tab) => {
        events.created.push({ id: tab.id, windowId: tab.windowId, url: tab.url || tab.pendingUrl || null });
    });
    chrome.tabs.onRemoved.addListener((tabId, info) => {
        events.removed.push({ tabId, windowId: info.windowId, isWindowClosing: info.isWindowClosing });
    });
    chrome.tabs.onDetached.addListener((tabId, info) => {
        events.detached.push({ tabId, oldWindowId: info.oldWindowId, oldPosition: info.oldPosition });
    });
    chrome.tabs.onAttached.addListener((tabId, info) => {
        events.attached.push({ tabId, newWindowId: info.newWindowId, newPosition: info.newPosition });
    });
    chrome.windows.onRemoved.addListener((windowId) => { events.windowsRemoved.push(windowId); });
    // What the profile pill (TASK-193.4) tells the new profile's worker.
    chrome.windows.onCreated.addListener((window) => {
        events.windowsCreated.push({ id: window.id, type: window.type, incognito: window.incognito });
    });
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'events') { sendResponse(events); return true; }
        if (message.type === 'getTab') {
            chrome.tabs.get(message.tabId).then(
                (value) => sendResponse({ value }),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        return false;
    });
    """

    /// Says hello to the worker from every page it runs in: a content script
    /// that can reach its worker is what a password manager's fill needs.
    private static let contentJS = """
    chrome.runtime.sendMessage({ type: 'hello' }, () => {
        document.documentElement.setAttribute('data-quick-detour-hello',
            chrome.runtime.lastError ? 'error: ' + chrome.runtime.lastError.message : 'ok');
    });
    """

    private func makeExtension(permissions: [String], hostPermissions: [String],
                               contentScripts: Bool) async throws -> WebExtension {
        let id = "quick-detour-\(UUID().uuidString.prefix(8))"
        func json(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let contentScriptsJSON = contentScripts
            ? #", "content_scripts": [{ "matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end" }]"#
            : ""
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Quick Detour Probe",
                "version": "1.0.0",
                "permissions": \(try json(permissions)),
                "host_permissions": \(try json(hostPermissions)),
                "background": { "service_worker": "background.js" },
                "action": { "default_title": "Probe" }\(contentScriptsJSON)
            }
            """,
            files: [
                "background.js": Self.workerJS,
                "content.js": Self.contentJS,
                "test.html": "<html><body>quick detour probe</body></html>",
            ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    /// The extension loaded into `profile` with what its manifest asks for
    /// granted (no prompt in a test), an extension page of it open, and its
    /// worker awake.
    private func loadPage(_ ext: WebExtension, in profile: Profile) async throws
        -> (context: WKWebExtensionContext, page: WKWebView) {
        let context = try loadTestContext(ext, in: profile)
        let wkExtension = try XCTUnwrap(ext.wkExtension)
        for permission in wkExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in wkExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        let config = try XCTUnwrap(context.webViewConfiguration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        openWebViews.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { _ in }
        try await waitUntil("the worker of \(profile.name) to wake", timeout: 30) {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        return (context, page)
    }

    private func serve() async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>Looked Up</title></head><body>a quick lookup</body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    /// A Quick Detour on `profile` with `url` loaded.
    private func openQuickDetour(on profile: Profile, loading url: URL) async throws -> QuickDetourWindowController {
        let controller = QuickDetourWindowController(profile: profile, sourceSpace: nil)
        windows.append(controller)
        controller.showWindow(nil)
        controller.load(url, typed: true)
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the Quick Detour page to load") {
            tab.url == url && !tab.isLoading && tab.title == "Looked Up"
        }
        return controller
    }

    private func pageEval(_ js: String, in page: WKWebView) async throws -> [String: Any] {
        let raw = try await page.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected JSON, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func pagePromise(_ call: String, in page: WKWebView) async throws -> [String: Any] {
        try await pageEval(promiseOutcomeJS(call), in: page)
    }

    private func worker(_ type: String, via page: WKWebView) async throws -> [String: Any] {
        let answer = try await askWorker(from: page, message: ["type": type])
        XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker: \(answer)")
        return try XCTUnwrap(answer["reply"] as? [String: Any], "the worker must answer \(type): \(answer)")
    }

    private func popupWindows(in value: Any?) -> [[String: Any]] {
        ((value as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "popup" }
    }

    private func tabs(of window: [String: Any]) -> [[String: Any]] {
        window["tabs"] as? [[String: Any]] ?? []
    }

    // MARK: - The window and its tab

    /// The page is the one tab of a `popup` window, from an extension page and
    /// from the worker; the window's id is the tab's `windowId`; the tab is
    /// active; `windows.get` and `tabs.query({windowType: 'popup'})` agree.
    func testThePageIsATabOfAPopupWindowFromBothTransports() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let profile = makeProfile("Quick Detour Ext A")
        let (_, page) = try await loadPage(ext, in: profile)
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)

        // Extension page.
        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: page)
        XCTAssertEqual(all["settled"] as? String, "resolved", "\(all)")
        let popups = popupWindows(in: all["value"])
        XCTAssertEqual(popups.count, 1, "one popup window: \(all)")
        let popup = try XCTUnwrap(popups.first)
        let windowID = try XCTUnwrap(popup["id"] as? Int)
        XCTAssertEqual(tabs(of: popup).map { $0["url"] as? String }, [url.absoluteString])
        let tab = try XCTUnwrap(tabs(of: popup).first)
        XCTAssertEqual(tab["windowId"] as? Int, windowID)
        XCTAssertEqual(tab["active"] as? Bool, true, "the page is its window's active tab")
        XCTAssertEqual(popup["incognito"] as? Bool, false)

        let got = try await pagePromise("chrome.windows.get(\(windowID))", in: page)
        XCTAssertEqual((got["value"] as? [String: Any])?["type"] as? String, "popup", "\(got)")

        let queried = try await pagePromise("chrome.tabs.query({ windowType: 'popup' })", in: page)
        XCTAssertEqual((queried["value"] as? [[String: Any]])?.map { $0["url"] as? String }, [url.absoluteString])

        // Callback form of windows.get.
        let callback = try await pageEval(callbackOutcomeJS(call: "return chrome.windows.get(\(windowID), cb);"),
                                          in: page)
        XCTAssertEqual(callback["argc"] as? Int, 1, "\(callback)")
        XCTAssertNil(callback["lastErrorInCallback"] as? String)
        XCTAssertTrue((callback["arg0"] as? String)?.contains("\"type\":\"popup\"") == true, "\(callback)")

        // Service worker.
        let workerWindows = try await worker("windows", via: page)
        let workerPopups = popupWindows(in: workerWindows["value"])
        XCTAssertEqual(workerPopups.map { $0["id"] as? Int }, [windowID], "\(workerWindows)")
        let workerTabs = try await worker("popupTabs", via: page)
        XCTAssertEqual((workerTabs["value"] as? [[String: Any]])?.map { $0["windowId"] as? Int }, [windowID])

        XCTAssertEqual(controller.windowType(for: try XCTUnwrap(profile.extensionContext(for: ext.id))), .popup)
    }

    /// Another profile's contexts never see the window or its page, even with
    /// the same extension and every permission.
    func testAnotherProfilesExtensionDoesNotSeeIt() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let owner = makeProfile("Quick Detour Ext Owner")
        let other = makeProfile("Quick Detour Ext Other")
        _ = try await loadPage(ext, in: owner)
        let (_, otherPage) = try await loadPage(ext, in: other)
        let url = try await serve()
        _ = try await openQuickDetour(on: owner, loading: url)

        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: otherPage)
        XCTAssertEqual(all["settled"] as? String, "resolved", "\(all)")
        XCTAssertTrue(popupWindows(in: all["value"]).isEmpty, "\(all)")
        let queried = try await pagePromise("chrome.tabs.query({})", in: otherPage)
        let urls = (queried["value"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        XCTAssertFalse(urls.contains(url.absoluteString), "\(queried)")
        let workerWindows = try await worker("windows", via: otherPage)
        XCTAssertTrue(popupWindows(in: workerWindows["value"]).isEmpty, "\(workerWindows)")
    }

    /// A context that loads while the window is open is told about it the way
    /// a loading context is told about every window (`openWindowsFor`,
    /// `notifyExistingTabs`) — its own profile's only.
    func testAContextLoadedAfterTheWindowOpensFindsItInItsProfileOnly() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let owner = makeProfile("Quick Detour Ext Late Owner")
        let other = makeProfile("Quick Detour Ext Late Other")
        let url = try await serve()
        _ = try await openQuickDetour(on: owner, loading: url)

        let (ownerContext, ownerPage) = try await loadPage(ext, in: owner)
        let (otherContext, otherPage) = try await loadPage(ext, in: other)
        ExtensionManager.shared.didReloadExtensionContext(ownerContext, in: owner)
        ExtensionManager.shared.didReloadExtensionContext(otherContext, in: other)

        let mine = try await pagePromise("chrome.windows.getAll({ populate: true })", in: ownerPage)
        let popup = try XCTUnwrap(popupWindows(in: mine["value"]).first, "\(mine)")
        XCTAssertEqual(tabs(of: popup).map { $0["url"] as? String }, [url.absoluteString])
        let theirs = try await pagePromise("chrome.windows.getAll({ populate: true })", in: otherPage)
        XCTAssertTrue(popupWindows(in: theirs["value"]).isEmpty, "\(theirs)")
        let theirTabs = try await pagePromise("chrome.tabs.query({})", in: otherPage)
        let urls = (theirTabs["value"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
        XCTAssertFalse(urls.contains(url.absoluteString), "\(theirTabs)")
    }

    /// Without `tabs` or a host permission the extension still sees a tab in a
    /// popup window, but not its URL: the window adds no access of its own.
    func testWithoutTheTabsPermissionTheURLIsNotReported() async throws {
        let ext = try await makeExtension(permissions: [], hostPermissions: [], contentScripts: false)
        let profile = makeProfile("Quick Detour Ext Unprivileged")
        let (_, page) = try await loadPage(ext, in: profile)
        let url = try await serve()
        _ = try await openQuickDetour(on: profile, loading: url)

        let queried = try await pagePromise("chrome.tabs.query({ windowType: 'popup' })", in: page)
        XCTAssertEqual(queried["settled"] as? String, "resolved", "\(queried)")
        let found = try XCTUnwrap(queried["value"] as? [[String: Any]])
        XCTAssertEqual(found.count, 1, "\(queried)")
        // WebKit blanks what the extension may not read rather than leaving it out.
        XCTAssertEqual(found.first?["url"] as? String ?? "", "", "no URL without the tabs or a host permission: \(queried)")
        XCTAssertEqual(found.first?["title"] as? String ?? "", "", "nor its title")
    }

    /// A content script runs in the page and reaches the worker, which knows
    /// its tab — what 1Password's fill needs (a page never reported as a tab
    /// gets "Tab not found", TASK-50).
    func testAContentScriptReachesTheWorkerWithItsTab() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: true)
        let profile = makeProfile("Quick Detour Ext Content")
        let (_, page) = try await loadPage(ext, in: profile)
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let webView = try XCTUnwrap(controller.tab?.webView)

        try await waitUntil("the content script to hear back from the worker", timeout: 15) {
            let mark = try await webView.callAsyncJavaScript(
                "return document.documentElement.getAttribute('data-quick-detour-hello');",
                arguments: [:], contentWorld: .page) as? String
            return mark != nil
        }
        let mark = try await webView.callAsyncJavaScript(
            "return document.documentElement.getAttribute('data-quick-detour-hello');",
            arguments: [:], contentWorld: .page) as? String
        XCTAssertEqual(mark, "ok")

        let seen = try await worker("seen", via: page)
        let hello = try XCTUnwrap((seen["hellos"] as? [[String: Any]])?.last, "\(seen)")
        XCTAssertEqual(hello["url"] as? String, url.absoluteString)
        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: page)
        XCTAssertEqual(hello["windowId"] as? Int, popupWindows(in: all["value"]).first?["id"] as? Int,
                       "sender.tab is the Quick Detour's tab")
    }

    /// The window's extension button acts on its page: with no popup, the
    /// worker's `action.onClicked` gets the Quick Detour's tab.
    func testTheExtensionButtonActsOnThePage() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let profile = makeProfile("Quick Detour Ext Action")
        let (_, page) = try await loadPage(ext, in: profile)
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)

        controller.performExtensionAction(ext.id, anchor: controller.titleBar.extensionsMenuButton)

        try await waitUntil("action.onClicked to reach the worker", timeout: 10) {
            let seen = try await self.worker("seen", via: page)
            return !((seen["clicks"] as? [Any]) ?? []).isEmpty
        }
        let seen = try await worker("seen", via: page)
        let click = try XCTUnwrap((seen["clicks"] as? [[String: Any]])?.first)
        XCTAssertEqual(click["url"] as? String, url.absoluteString)
    }

    /// Closing the window closes the tab and the window for the contexts: a
    /// by-id lookup is refused afterwards, promise and callback alike.
    func testClosingTheWindowClosesTheTab() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let profile = makeProfile("Quick Detour Ext Close")
        let (_, page) = try await loadPage(ext, in: profile)
        let url = try await serve()
        let controller = try await openQuickDetour(on: profile, loading: url)
        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: page)
        let popup = try XCTUnwrap(popupWindows(in: all["value"]).first, "\(all)")
        let tabID = try XCTUnwrap(tabs(of: popup).first?["id"] as? Int)
        let windowID = try XCTUnwrap(popup["id"] as? Int)

        controller.close()

        XCTAssertTrue(TabStore.shared.quickDetourTabs.isEmpty || !TabStore.shared.quickDetourTabs.contains {
            $0.id == controller.tabID
        })
        let tabLookup = try await pagePromise("chrome.tabs.get(\(tabID))", in: page)
        XCTAssertEqual(tabLookup["settled"] as? String, "rejected", "\(tabLookup)")
        let windowLookup = try await pagePromise("chrome.windows.get(\(windowID))", in: page)
        XCTAssertEqual(windowLookup["settled"] as? String, "rejected", "\(windowLookup)")
        let callback = try await pageEval(callbackOutcomeJS(call: "return chrome.tabs.get(\(tabID), cb);"), in: page)
        XCTAssertEqual(callback["argc"] as? Int, 0, "\(callback)")
        XCTAssertNotNil(callback["lastErrorInCallback"] as? String, "\(callback)")
        let after = try await pagePromise("chrome.windows.getAll({ populate: true })", in: page)
        XCTAssertTrue(popupWindows(in: after["value"]).isEmpty, "\(after)")
    }

    /// A Private Quick Detour is a Private popup window, seen by an extension
    /// allowed in Private.
    func testAPrivateQuickDetourIsAnIncognitoPopup() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let privateProfile = Profile(name: "Quick Detour Ext Private", isIncognito: true)
        createdProfiles.append(privateProfile)
        let (_, page) = try await loadPage(ext, in: privateProfile)
        let url = try await serve()
        let controller = try await openQuickDetour(on: privateProfile, loading: url)
        XCTAssertTrue(controller.tab?.webView?.configuration.websiteDataStore === privateProfile.dataStore)

        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: page)
        let popup = try XCTUnwrap(popupWindows(in: all["value"]).first, "\(all)")
        XCTAssertEqual(popup["incognito"] as? Bool, true)
        XCTAssertEqual(tabs(of: popup).first?["incognito"] as? Bool, true)
    }

    // MARK: - Open in (TASK-193.3)

    /// A normal window on a new space of `profile`, in front, registered with
    /// the app delegate as placement expects.
    private func browserWindow(showingANewSpaceOf profile: Profile, named name: String) -> (BrowserWindowController, Space) {
        let space = TabStore.shared.addSpace(name: name, emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        (NSApp.delegate as? AppDelegate)?.registerWindowController(wc)
        browserWindows.append(wc)
        return (wc, space)
    }

    private func popupAndTab(via page: WKWebView) async throws -> (windowID: Int, tabID: Int) {
        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: page)
        let popup = try XCTUnwrap(popupWindows(in: all["value"]).first, "\(all)")
        return (try XCTUnwrap(popup["id"] as? Int), try XCTUnwrap(tabs(of: popup).first?["id"] as? Int))
    }

    /// Within one profile the page moves as the same tab: the worker hears
    /// `tabs.onDetached` from the popup and `tabs.onAttached` to the browser
    /// window, then `windows.onRemoved` for the popup — no `tabs.onRemoved`
    /// and no `tabs.onCreated` for it. The tab id stays and now names the
    /// browser window, from an extension page and from the worker.
    func testMovingThePageIsADetachAndAttachUnderTheSameTabID() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let profile = makeProfile("Quick Detour Ext Move")
        let (_, page) = try await loadPage(ext, in: profile)
        let url = try await serve()
        let (window, space) = browserWindow(showingANewSpaceOf: profile, named: "Move Target")
        let controller = try await openQuickDetour(on: profile, loading: url)
        let (popupID, tabID) = try await popupAndTab(via: page)

        controller.open(in: .space(space.id))
        XCTAssertEqual(window.selectedTabID, controller.tabID, "moved")

        try await waitUntil("the worker to hear the move and the window close", timeout: 10) {
            let events = try await self.worker("events", via: page)
            return !((events["attached"] as? [Any]) ?? []).isEmpty
                && ((events["windowsRemoved"] as? [Int]) ?? []).contains(popupID)
        }
        let events = try await worker("events", via: page)
        let detached = try XCTUnwrap(events["detached"] as? [[String: Any]])
        XCTAssertEqual(detached.map { $0["tabId"] as? Int }, [tabID])
        XCTAssertEqual(detached.first?["oldWindowId"] as? Int, popupID)
        XCTAssertEqual(detached.first?["oldPosition"] as? Int, 0)
        let attached = try XCTUnwrap(events["attached"] as? [[String: Any]])
        XCTAssertEqual(attached.map { $0["tabId"] as? Int }, [tabID])
        let newWindowID = try XCTUnwrap(attached.first?["newWindowId"] as? Int)
        XCTAssertNotEqual(newWindowID, popupID)
        XCTAssertFalse(((events["removed"] as? [[String: Any]]) ?? []).contains { $0["tabId"] as? Int == tabID },
                       "never removed: \(events)")
        let created = ((events["created"] as? [[String: Any]]) ?? []).filter { $0["id"] as? Int == tabID }
        XCTAssertEqual(created.map { $0["windowId"] as? Int }, [popupID],
                       "created once, in the popup, and never again: \(events)")
        XCTAssertEqual(attached.first?["newPosition"] as? Int, 0,
                       "announced once the window has it selected, so WebKit lists it: \(events)")

        // The same id, in the browser window, from both transports.
        let got = try await pagePromise("chrome.tabs.get(\(tabID))", in: page)
        XCTAssertEqual(got["settled"] as? String, "resolved", "\(got)")
        let tab = try XCTUnwrap(got["value"] as? [String: Any])
        XCTAssertEqual(tab["windowId"] as? Int, newWindowID)
        XCTAssertEqual(tab["url"] as? String, url.absoluteString)
        let fromWorker = try await askWorker(from: page, message: ["type": "getTab", "tabId": tabID])
        let workerTab = try XCTUnwrap((fromWorker["reply"] as? [String: Any])?["value"] as? [String: Any],
                                      "\(fromWorker)")
        XCTAssertEqual(workerTab["windowId"] as? Int, newWindowID)
        let normal = try await pagePromise("chrome.windows.get(\(newWindowID))", in: page)
        XCTAssertEqual((normal["value"] as? [String: Any])?["type"] as? String, "normal", "\(normal)")

        // The popup is gone: refused by id, promise and callback alike.
        let popupLookup = try await pagePromise("chrome.windows.get(\(popupID))", in: page)
        XCTAssertEqual(popupLookup["settled"] as? String, "rejected", "\(popupLookup)")
        let callback = try await pageEval(callbackOutcomeJS(call: "return chrome.windows.get(\(popupID), cb);"),
                                          in: page)
        XCTAssertNotNil(callback["lastErrorInCallback"] as? String, "\(callback)")
        let after = try await pagePromise("chrome.windows.getAll({ populate: true })", in: page)
        XCTAssertTrue(popupWindows(in: after["value"]).isEmpty, "\(after)")
    }

    /// Another profile's extension hears nothing of a move within this one.
    func testAnotherProfilesExtensionHearsNothingOfTheMove() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let owner = makeProfile("Quick Detour Ext Move Owner")
        let other = makeProfile("Quick Detour Ext Move Other")
        _ = try await loadPage(ext, in: owner)
        let (_, otherPage) = try await loadPage(ext, in: other)
        let url = try await serve()
        let (_, space) = browserWindow(showingANewSpaceOf: owner, named: "Move Target Owner")
        let controller = try await openQuickDetour(on: owner, loading: url)

        controller.open(in: .space(space.id))
        try await Task.sleep(nanoseconds: 500_000_000)

        let events = try await worker("events", via: otherPage)
        for key in ["created", "removed", "detached", "attached", "windowsRemoved"] {
            XCTAssertTrue(((events[key] as? [Any]) ?? []).isEmpty, "\(key): \(events)")
        }
    }

    /// Into another profile's space the address reloads: the Quick Detour's
    /// tab is removed (and its window) for its own profile's extension, and
    /// the new tab is created for the other profile's, on the same URL.
    func testReloadingInAnotherProfileIsARemoveThereAndACreateHere() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let source = makeProfile("Quick Detour Ext Reload Source")
        let target = makeProfile("Quick Detour Ext Reload Target")
        let (_, sourcePage) = try await loadPage(ext, in: source)
        let (_, targetPage) = try await loadPage(ext, in: target)
        let url = try await serve()
        let (window, space) = browserWindow(showingANewSpaceOf: target, named: "Reload Target")
        let controller = try await openQuickDetour(on: source, loading: url)
        let (popupID, tabID) = try await popupAndTab(via: sourcePage)

        controller.open(in: .space(space.id))
        let opened = try XCTUnwrap(space.tabs.first)
        XCTAssertEqual(window.selectedTabID, opened.id)

        try await waitUntil("the source's worker to hear the close", timeout: 10) {
            let events = try await self.worker("events", via: sourcePage)
            return ((events["windowsRemoved"] as? [Int]) ?? []).contains(popupID)
        }
        let sourceEvents = try await worker("events", via: sourcePage)
        XCTAssertTrue(((sourceEvents["removed"] as? [[String: Any]]) ?? []).contains { $0["tabId"] as? Int == tabID },
                      "\(sourceEvents)")
        XCTAssertTrue(((sourceEvents["attached"] as? [Any]) ?? []).isEmpty, "nothing moved: \(sourceEvents)")

        // The new tab is created for the target profile's extension, and is
        // on the address (by id: the window it is in was opened after the
        // context loaded, which WebKit's window-scoped queries do not list).
        try await waitUntil("the target's worker to hear the new tab", timeout: 10) {
            let events = try await self.worker("events", via: targetPage)
            return !((events["created"] as? [Any]) ?? []).isEmpty
        }
        let targetEvents = try await worker("events", via: targetPage)
        let createdID = try XCTUnwrap(((targetEvents["created"] as? [[String: Any]]) ?? []).last?["id"] as? Int)
        XCTAssertNotEqual(createdID, tabID)
        try await waitUntil("the new tab on the address", timeout: 10) {
            let got = try await self.pagePromise("chrome.tabs.get(\(createdID))", in: targetPage)
            return (got["value"] as? [String: Any])?["url"] as? String == url.absoluteString
        }
        XCTAssertFalse(((targetEvents["created"] as? [Any]) ?? []).isEmpty, "\(targetEvents)")
    }

    // MARK: - The profile pill (TASK-193.4)

    /// Choosing another profile in the pill is a close for the old profile's
    /// contexts — `tabs.onRemoved` for the page and `windows.onRemoved` for
    /// the popup, which is then refused by id (promise and callback) — and an
    /// open for the new profile's: `windows.onCreated` for a popup and
    /// `tabs.onCreated` for a new tab in it, listed by `windows.getAll` on the
    /// same address, from an extension page and from the worker.
    func testSwitchingProfileIsACloseForTheOldProfileAndAnOpenForTheNew() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let source = makeProfile("Quick Detour Ext Switch Source")
        let target = makeProfile("Quick Detour Ext Switch Target")
        let (_, sourcePage) = try await loadPage(ext, in: source)
        let (_, targetPage) = try await loadPage(ext, in: target)
        let url = try await serve()
        let controller = try await openQuickDetour(on: source, loading: url)
        let (popupID, tabID) = try await popupAndTab(via: sourcePage)

        XCTAssertTrue(controller.switchProfile(to: target))
        let page = try XCTUnwrap(controller.tab)
        try await waitUntil("the page to load on the new profile") {
            page.url == url && !page.isLoading && page.title == "Looked Up"
        }

        // The old profile: the tab and its window are gone.
        try await waitUntil("the source's worker to hear the close", timeout: 10) {
            let events = try await self.worker("events", via: sourcePage)
            return ((events["windowsRemoved"] as? [Int]) ?? []).contains(popupID)
        }
        let sourceEvents = try await worker("events", via: sourcePage)
        XCTAssertEqual(((sourceEvents["removed"] as? [[String: Any]]) ?? []).compactMap { $0["tabId"] as? Int }, [tabID],
                       "\(sourceEvents)")
        XCTAssertTrue(((sourceEvents["detached"] as? [Any]) ?? []).isEmpty, "not a move: \(sourceEvents)")
        let sourceAll = try await pagePromise("chrome.windows.getAll({ populate: true })", in: sourcePage)
        XCTAssertTrue(popupWindows(in: sourceAll["value"]).isEmpty, "\(sourceAll)")
        let tabLookup = try await pagePromise("chrome.tabs.get(\(tabID))", in: sourcePage)
        XCTAssertEqual(tabLookup["settled"] as? String, "rejected", "\(tabLookup)")
        let windowLookup = try await pagePromise("chrome.windows.get(\(popupID))", in: sourcePage)
        XCTAssertEqual(windowLookup["settled"] as? String, "rejected", "\(windowLookup)")
        let callback = try await pageEval(callbackOutcomeJS(call: "return chrome.tabs.get(\(tabID), cb);"),
                                          in: sourcePage)
        XCTAssertEqual(callback["argc"] as? Int, 0, "\(callback)")
        XCTAssertNotNil(callback["lastErrorInCallback"] as? String, "\(callback)")

        // The new profile: a popup window and a tab in it.
        try await waitUntil("the target's worker to hear the new window and tab", timeout: 10) {
            let events = try await self.worker("events", via: targetPage)
            return !((events["windowsCreated"] as? [Any]) ?? []).isEmpty && !((events["created"] as? [Any]) ?? []).isEmpty
        }
        let targetEvents = try await worker("events", via: targetPage)
        let createdWindow = try XCTUnwrap((targetEvents["windowsCreated"] as? [[String: Any]])?.last, "\(targetEvents)")
        XCTAssertEqual(createdWindow["type"] as? String, "popup")
        let newWindowID = try XCTUnwrap(createdWindow["id"] as? Int)
        let createdTab = try XCTUnwrap((targetEvents["created"] as? [[String: Any]])?.last, "\(targetEvents)")
        XCTAssertEqual(createdTab["windowId"] as? Int, newWindowID)
        let newTabID = try XCTUnwrap(createdTab["id"] as? Int)
        XCTAssertNotEqual(newTabID, tabID)

        let targetAll = try await pagePromise("chrome.windows.getAll({ populate: true })", in: targetPage)
        let popup = try XCTUnwrap(popupWindows(in: targetAll["value"]).first, "\(targetAll)")
        XCTAssertEqual(popup["id"] as? Int, newWindowID)
        XCTAssertEqual(tabs(of: popup).map { $0["id"] as? Int }, [newTabID])
        XCTAssertEqual(tabs(of: popup).first?["url"] as? String, url.absoluteString)
        let fromWorker = try await askWorker(from: targetPage, message: ["type": "getTab", "tabId": newTabID])
        let workerTab = try XCTUnwrap((fromWorker["reply"] as? [String: Any])?["value"] as? [String: Any],
                                      "\(fromWorker)")
        XCTAssertEqual(workerTab["windowId"] as? Int, newWindowID)
    }

    /// Switching back is a new window for the first profile, not the one it
    /// was told closed.
    func testSwitchingBackIsANewWindowForTheFirstProfile() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let first = makeProfile("Quick Detour Ext Switch Back First")
        let second = makeProfile("Quick Detour Ext Switch Back Second")
        let (_, firstPage) = try await loadPage(ext, in: first)
        let url = try await serve()
        let controller = try await openQuickDetour(on: first, loading: url)
        let (popupID, tabID) = try await popupAndTab(via: firstPage)

        XCTAssertTrue(controller.switchProfile(to: second))
        XCTAssertTrue(controller.switchProfile(to: first))
        let page = try XCTUnwrap(controller.tab)
        try await waitUntil("the page to load again") { page.url == url && !page.isLoading }

        let (newPopupID, newTabID) = try await popupAndTab(via: firstPage)
        XCTAssertNotEqual(newPopupID, popupID)
        XCTAssertNotEqual(newTabID, tabID)
        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: firstPage)
        XCTAssertEqual(popupWindows(in: all["value"]).count, 1, "\(all)")
    }

    /// A profile the window was never on hears nothing of a switch between two
    /// others.
    func testAThirdProfilesExtensionHearsNothingOfASwitch() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let source = makeProfile("Quick Detour Ext Switch Iso Source")
        let target = makeProfile("Quick Detour Ext Switch Iso Target")
        let bystander = makeProfile("Quick Detour Ext Switch Iso Bystander")
        _ = try await loadPage(ext, in: source)
        _ = try await loadPage(ext, in: target)
        let (_, bystanderPage) = try await loadPage(ext, in: bystander)
        let url = try await serve()
        let controller = try await openQuickDetour(on: source, loading: url)

        XCTAssertTrue(controller.switchProfile(to: target))
        try await Task.sleep(nanoseconds: 500_000_000)

        let events = try await worker("events", via: bystanderPage)
        for key in ["created", "removed", "detached", "attached", "windowsRemoved", "windowsCreated"] {
            XCTAssertTrue(((events[key] as? [Any]) ?? []).isEmpty, "\(key): \(events)")
        }
        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: bystanderPage)
        XCTAssertTrue(popupWindows(in: all["value"]).isEmpty, "\(all)")
    }

    /// Into Private: an incognito popup for an extension allowed in Private,
    /// and a close for the normal profile's.
    func testSwitchingIntoPrivateIsAnIncognitoPopupThere() async throws {
        let ext = try await makeExtension(permissions: ["tabs"], hostPermissions: ["<all_urls>"], contentScripts: false)
        let source = makeProfile("Quick Detour Ext Switch Private Source")
        let privateProfile = Profile(name: "Quick Detour Ext Switch Private", isIncognito: true)
        createdProfiles.append(privateProfile)
        let (_, sourcePage) = try await loadPage(ext, in: source)
        let (_, privatePage) = try await loadPage(ext, in: privateProfile)
        let url = try await serve()
        let controller = try await openQuickDetour(on: source, loading: url)
        let (popupID, _) = try await popupAndTab(via: sourcePage)

        XCTAssertTrue(controller.switchProfile(to: privateProfile))
        XCTAssertTrue(controller.tab?.webView?.configuration.websiteDataStore === privateProfile.dataStore)

        try await waitUntil("the Private worker to hear the new window", timeout: 10) {
            let events = try await self.worker("events", via: privatePage)
            return !((events["windowsCreated"] as? [Any]) ?? []).isEmpty
        }
        let privateEvents = try await worker("events", via: privatePage)
        let created = try XCTUnwrap(privateEvents["windowsCreated"] as? [[String: Any]])
        XCTAssertEqual(created.last?["incognito"] as? Bool, true)
        let all = try await pagePromise("chrome.windows.getAll({ populate: true })", in: privatePage)
        let popup = try XCTUnwrap(popupWindows(in: all["value"]).first, "\(all)")
        XCTAssertEqual(popup["incognito"] as? Bool, true)
        XCTAssertEqual(tabs(of: popup).first?["incognito"] as? Bool, true)
        try await waitUntil("the source's worker to hear the close", timeout: 10) {
            let events = try await self.worker("events", via: sourcePage)
            return ((events["windowsRemoved"] as? [Int]) ?? []).contains(popupID)
        }
    }
}
