import XCTest
import WebKit
@testable import Detour

/// TASK-214: `windows.create` from an extension context in an incognito
/// profile — the one behind Private windows and quarantines — opens a Private
/// window, whatever `incognito` says. WebKit hands the delegate
/// `incognito ?? false`, so a call that leaves the key out cannot be told from
/// one that asks for a normal window, and a normal window would carry a
/// Private page's address into a profile's cookies and history. Calls from a
/// normal profile's context are unchanged.
///
/// Real contexts through the production wiring (`Profile.extensionController`
/// with `ExtensionManager` as its delegate), asked from the service worker and
/// from an extension page, in the promise and the callback form.
@MainActor
final class ExtensionWindowsCreatePrivateTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var openWebViews: [WKWebView] = []
    private var quickDetours: [QuickDetourWindowController] = []
    private var servers: [LoopbackHTTPServer] = []
    private var browserWindows: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []

    /// Released profiles take their process pool down with them, which WebKit
    /// traps on inside an IPC dispatch (`ExtensionPrivateStoreTests`): kept for
    /// the rest of the test process.
    private static var retainedProfiles: [Profile] = []

    override func tearDown() async throws {
        closeBrowserWindows()
        for controller in quickDetours { controller.close() }
        quickDetours.removeAll()
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

    /// Closes every browser window a test opened or had opened for it. A
    /// Private one removes its incognito space as it closes.
    private func closeBrowserWindows() {
        for wc in browserWindows {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        browserWindows.removeAll()
    }

    // MARK: - Fixtures

    /// The worker creates a window in the form asked for and answers with what
    /// the API gave it.
    private static let workerJS = """
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'create') {
            if (message.form === 'callback') {
                chrome.windows.create(message.options, (window) => {
                    sendResponse({ value: window === undefined ? null : window,
                                   lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                });
            } else {
                chrome.windows.create(message.options).then(
                    (value) => sendResponse({ value }),
                    (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            }
            return true;
        }
        return false;
    });
    """

    private func makeExtension() async throws -> WebExtension {
        let id = "windows-create-private-\(UUID().uuidString.prefix(8))"
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Windows Create Probe",
                "version": "1.0.0",
                "permissions": ["tabs"],
                "host_permissions": ["<all_urls>"],
                "background": { "service_worker": "background.js" }
            }
            """,
            files: [
                "background.js": Self.workerJS,
                "test.html": "<html><body>windows create probe</body></html>",
            ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    /// An incognito profile of its own — never the built-in Private profile
    /// whose rows other suites share, but the same `isIncognito` wiring.
    private func makeIncognitoProfile(_ name: String) -> Profile {
        let profile = Profile(name: name, isIncognito: true)
        createdProfiles.append(profile)
        return profile
    }

    private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        return profile
    }

    /// The extension loaded into `profile` with what its manifest asks for
    /// granted, an extension page of it open, and its worker awake.
    private func loadPage(_ ext: WebExtension, in profile: Profile) async throws -> WKWebView {
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
        return page
    }

    private func serve() async throws -> URL {
        let server = try LoopbackHTTPServer(routes: [
            "/": "<html><head><title>Looked Up</title></head><body>a page</body></html>",
        ])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    /// A normal window on a new space of `profile`, in front and registered
    /// with the app delegate, so a normal window `windows.create` opens takes
    /// its space (`AppDelegate.assignDefaultSpace`).
    private func browserWindow(showingANewSpaceOf profile: Profile) -> Space {
        let space = TabStore.shared.addSpace(name: "Windows Create", emoji: "🧪", colorHex: "007AFF",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        (NSApp.delegate as? AppDelegate)?.registerWindowController(wc)
        browserWindows.append(wc)
        return space
    }

    /// A quarantine window on `privateProfile` with `url` loaded.
    private func openQuarantine(on privateProfile: Profile, loading url: URL) async throws {
        let controller = QuickDetourWindowController(profile: privateProfile, sourceSpace: nil,
                                                     quarantine: QuarantineSession(originalURL: url))
        quickDetours.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.load(url, typed: false)
        let tab = try XCTUnwrap(controller.tab)
        try await waitUntil("the quarantine page to load") {
            tab.url == url && !tab.isLoading && tab.title == "Looked Up"
        }
    }

    private func browserWindowControllers() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }
    }

    private enum Transport: CaseIterable { case worker, page }
    private enum Form: String, CaseIterable { case promise, callback }

    /// What one `windows.create` did: the window the API reported (nil when it
    /// failed), the rejection or `lastError`, and the browser windows that
    /// appeared.
    private struct Created {
        var window: [String: Any]?
        var error: String?
        var opened: [BrowserWindowController]
        var label: String
    }

    private func create(_ options: [String: Any], via transport: Transport, form: Form,
                        page: WKWebView) async throws -> Created {
        let before = Set(browserWindowControllers().map(ObjectIdentifier.init))
        var created = Created(window: nil, error: nil, opened: [],
                              label: "\(transport) \(form.rawValue) \(options)")
        switch transport {
        case .worker:
            let answer = try await askWorker(
                from: page, message: ["type": "create", "form": form.rawValue, "options": options])
            XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker: \(answer)")
            let reply = try XCTUnwrap(answer["reply"] as? [String: Any], "\(created.label): \(answer)")
            created.window = reply["value"] as? [String: Any]
            created.error = (reply["error"] as? String) ?? (reply["lastError"] as? String)
        case .page:
            let json = String(decoding: try JSONSerialization.data(withJSONObject: options), as: UTF8.self)
            switch form {
            case .promise:
                let outcome = try await pageEval(promiseOutcomeJS("chrome.windows.create(\(json))"), in: page)
                created.window = outcome["value"] as? [String: Any]
                created.error = outcome["message"] as? String
            case .callback:
                let outcome = try await pageEval(
                    callbackOutcomeJS(call: "return chrome.windows.create(\(json), cb);"), in: page)
                XCTAssertEqual(outcome["timedOut"] as? Bool, false, "\(created.label): \(outcome)")
                if let arg0 = outcome["arg0"] as? String {
                    // `"null"` when the callback got null: a fragment.
                    created.window = try JSONSerialization.jsonObject(
                        with: Data(arg0.utf8), options: .fragmentsAllowed) as? [String: Any]
                }
                created.error = outcome["lastErrorInCallback"] as? String
            }
        }
        created.opened = browserWindowControllers().filter { !before.contains(ObjectIdentifier($0)) }
        browserWindows.append(contentsOf: created.opened)
        return created
    }

    /// The call succeeded, reported an incognito window (or, to a context
    /// without access to Private data, none), and the one window it opened is
    /// a Private browser window showing `url` — no normal window.
    private func assertOpenedAPrivateWindow(_ created: Created, showing url: URL, reportsWindow: Bool = true,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(created.error, created.label, file: file, line: line)
        if reportsWindow {
            XCTAssertEqual(created.window?["incognito"] as? Bool, true,
                           "\(created.label): \(String(describing: created.window))", file: file, line: line)
        } else {
            XCTAssertNil(created.window, "\(created.label): \(String(describing: created.window))",
                         file: file, line: line)
        }
        XCTAssertEqual(created.opened.count, 1, created.label, file: file, line: line)
        XCTAssertTrue(created.opened.allSatisfy(\.isIncognito),
                      "\(created.label): a normal window was opened", file: file, line: line)
        let wc = created.opened.first
        XCTAssertEqual(wc?.activeSpace?.isIncognito, true, created.label, file: file, line: line)
        XCTAssertEqual(wc?.activeSpace?.tabs.map(\.url), [url], created.label, file: file, line: line)
    }

    // MARK: - The rule

    func testTheRule() {
        XCTAssertFalse(ExtensionManager.opensPrivateWindow(requested: false, callerIsIncognito: false))
        XCTAssertTrue(ExtensionManager.opensPrivateWindow(requested: true, callerIsIncognito: false))
        XCTAssertTrue(ExtensionManager.opensPrivateWindow(requested: false, callerIsIncognito: true))
        XCTAssertTrue(ExtensionManager.opensPrivateWindow(requested: true, callerIsIncognito: true))
    }

    // MARK: - From Private

    /// The common call — no `incognito` — from a Private context opens a
    /// Private window, from the worker and from an extension page, in both
    /// forms; the callback form has no `lastError`.
    func testFromPrivateWithoutIncognitoOpensAPrivateWindow() async throws {
        let ext = try await makeExtension()
        let page = try await loadPage(ext, in: makeIncognitoProfile("Windows Create Private"))
        let url = try await serve()

        for transport in Transport.allCases {
            for form in Form.allCases {
                let created = try await create(["url": url.absoluteString], via: transport, form: form, page: page)
                assertOpenedAPrivateWindow(created, showing: url)
                closeBrowserWindows()
            }
        }
    }

    /// Asking for a normal window by name changes nothing: WebKit gives the
    /// same `false` for it as for a call that leaves the key out.
    func testFromPrivateWithIncognitoFalseStillOpensAPrivateWindow() async throws {
        let ext = try await makeExtension()
        let page = try await loadPage(ext, in: makeIncognitoProfile("Windows Create Private False"))
        let url = try await serve()

        for (transport, form) in [(Transport.worker, Form.promise), (.page, .callback)] {
            let created = try await create(["url": url.absoluteString, "incognito": false],
                                           via: transport, form: form, page: page)
            assertOpenedAPrivateWindow(created, showing: url)
            closeBrowserWindows()
        }
    }

    func testFromPrivateWithIncognitoTrueOpensAPrivateWindow() async throws {
        let ext = try await makeExtension()
        let page = try await loadPage(ext, in: makeIncognitoProfile("Windows Create Private True"))
        let url = try await serve()

        let created = try await create(["url": url.absoluteString, "incognito": true],
                                       via: .page, form: .promise, page: page)
        assertOpenedAPrivateWindow(created, showing: url)
    }

    /// The task's case: with a quarantine in front, its extension opens the
    /// quarantined address in a new window. The window is Private, so the page
    /// never reaches a normal profile's cookies and history.
    func testFromAQuarantineTheQuarantinedAddressOpensInAPrivateWindow() async throws {
        let ext = try await makeExtension()
        let privateProfile = makeIncognitoProfile("Windows Create Quarantine")
        let page = try await loadPage(ext, in: privateProfile)
        let url = try await serve()
        try await openQuarantine(on: privateProfile, loading: url)

        for (transport, form) in [(Transport.worker, Form.callback), (.page, .promise)] {
            let created = try await create(["url": url.absoluteString], via: transport, form: form, page: page)
            assertOpenedAPrivateWindow(created, showing: url)
            closeBrowserWindows()
        }
    }

    // MARK: - Errors

    /// A `detour://` URL is refused by `openNewWindowUsing`, as `tabs.create`
    /// refuses it (it used to be dropped, leaving an empty window reported as
    /// a success): the promise rejects, the callback sees `lastError`, and no
    /// window opens.
    func testFromPrivateAnInternalURLIsRefusedAndOpensNoWindow() async throws {
        let ext = try await makeExtension()
        let page = try await loadPage(ext, in: makeIncognitoProfile("Windows Create Refused"))

        for transport in Transport.allCases {
            for form in Form.allCases {
                let created = try await create(["url": "\(InternalPage.scheme)://history"],
                                               via: transport, form: form, page: page)
                XCTAssertTrue(created.error?.contains("\(InternalPage.scheme)://") ?? false,
                              "\(created.label): \(String(describing: created.error))")
                XCTAssertNil(created.window, created.label)
                XCTAssertEqual(created.opened.count, 0, created.label)
                closeBrowserWindows()
            }
        }
    }

    // MARK: - From a normal profile (unchanged)

    func testFromANormalProfileOpensANormalWindowInTheFrontSpace() async throws {
        let ext = try await makeExtension()
        let normal = makeProfile("Windows Create Normal")
        let page = try await loadPage(ext, in: normal)
        let url = try await serve()

        for (transport, form) in [(Transport.worker, Form.promise), (.page, .callback)] {
            let space = browserWindow(showingANewSpaceOf: normal)
            let created = try await create(["url": url.absoluteString], via: transport, form: form, page: page)
            XCTAssertNil(created.error, created.label)
            XCTAssertEqual(created.window?["incognito"] as? Bool, false, "\(created.label): \(String(describing: created.window))")
            XCTAssertEqual(created.opened.count, 1, created.label)
            let wc = try XCTUnwrap(created.opened.first, created.label)
            XCTAssertFalse(wc.isIncognito, created.label)
            XCTAssertEqual(wc.activeSpaceID, space.id, created.label)
            XCTAssertTrue(space.tabs.contains { $0.url == url }, created.label)
            closeBrowserWindows()
        }
    }

    /// As before TASK-214: a normal context asking for a Private window gets
    /// one, but WebKit reports no window to a context without access to
    /// Private data, so the promise resolves with nothing.
    func testFromANormalProfileIncognitoTrueOpensAPrivateWindow() async throws {
        let ext = try await makeExtension()
        let normal = makeProfile("Windows Create Normal To Private")
        let page = try await loadPage(ext, in: normal)
        let url = try await serve()
        _ = browserWindow(showingANewSpaceOf: normal)

        let created = try await create(["url": url.absoluteString, "incognito": true],
                                       via: .worker, form: .promise, page: page)
        assertOpenedAPrivateWindow(created, showing: url, reportsWindow: false)
    }
}
