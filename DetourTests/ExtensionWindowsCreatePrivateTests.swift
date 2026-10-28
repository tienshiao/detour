import XCTest
import WebKit
@testable import Detour

/// TASK-214: `windows.create` from an extension context in an incognito
/// profile — the one behind Private windows and quarantines — opens a Private
/// window, whatever `incognito` says. WebKit hands the delegate
/// `incognito ?? false`, so a call that leaves the key out cannot be told from
/// one that asks for a normal window, and a normal window would carry a
/// Private page's address into a profile's cookies and history. A normal
/// profile's context opens a normal window on one of its own profile's spaces
/// (TASK-223), never on the space of another profile's window in front.
///
/// Also the `javascript:` URL refusals of `windows.create`, `tabs.create`
/// and `tabs.update` (TASK-225).
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
    private var databaseExtensionIDs: [String] = []

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
        // The row's deletion cascades to its `profileExtension` rows.
        for id in databaseExtensionIDs {
            // Allowed in Private, it may have been loaded into the built-in
            // Private profile too, when that profile's controller exists.
            for profile in TabStore.shared.profiles { profile.unloadExtension(id: id) }
            AppDatabase.shared.deleteExtension(id: id)
        }
        databaseExtensionIDs.removeAll()
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
        if (message.type === 'call') {
            const [namespace, name] = message.api.split('.');
            const fail = (e) => sendResponse({ error: String(e && e.message ? e.message : e) });
            try {
                const fn = chrome[namespace][name].bind(chrome[namespace]);
                if (message.form === 'callback') {
                    fn(...message.args, (value) => {
                        sendResponse({ value: value === undefined ? null : value,
                                       lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                    });
                } else {
                    fn(...message.args).then(
                        (value) => sendResponse({ value: value === undefined ? null : value }), fail);
                }
            } catch (e) {
                // An argument WebKit refuses throws before any callback.
                fail(e);
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

    /// `ext` saved in the shared database as installed and globally enabled,
    /// with its built-in Private profile row on, off, or left out (`nil`,
    /// which means off, TASK-74) — what "Allow in Private" decides.
    private func installInSharedDatabase(_ ext: WebExtension, allowedInPrivate: Bool?) {
        installTestExtension(ext, in: AppDatabase.shared,
                             manifestJSON: (try? testExtensionManifestData(ext)) ?? Data("{}".utf8))
        databaseExtensionIDs.append(ext.id)
        if let allowedInPrivate { setAllowedInPrivate(ext, allowedInPrivate) }
    }

    /// Writes `ext`'s built-in Private profile row. The row's foreign key wants
    /// the Private profile's own row, saved first, or the write fails silently.
    private func setAllowedInPrivate(_ ext: WebExtension, _ allowed: Bool) {
        AppDatabase.shared.saveProfile(TabStore.shared.ensureIncognitoProfile().toRecord())
        AppDatabase.shared.setProfileExtensionEnabled(
            extensionID: ext.id, profileID: TabStore.incognitoProfileID.uuidString, enabled: allowed)
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
    /// with the app delegate. Showing it makes the space its profile's most
    /// recently used one.
    @discardableResult
    private func browserWindow(showingANewSpaceOf profile: Profile) -> Space {
        let space = addSpace(of: profile)
        browserWindow(showing: space)
        return space
    }

    private func addSpace(of profile: Profile) -> Space {
        let space = TabStore.shared.addSpace(name: "Windows Create", emoji: "🧪", colorHex: "007AFF",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    private func browserWindow(showing space: Space) {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        (NSApp.delegate as? AppDelegate)?.registerWindowController(wc)
        browserWindows.append(wc)
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
        // Held, not just their identifiers: a closed window's controller freed
        // during the call could hand its address to the new one, which would
        // then look as if it had been there before.
        let before = browserWindowControllers()
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
        created.opened = browserWindowControllers().filter { wc in !before.contains { $0 === wc } }
        browserWindows.append(contentsOf: created.opened)
        return created
    }

    /// What one call of `chrome.<api>(...args)` gave: its value (nil when it
    /// failed or gave nothing) and the rejection or `lastError`.
    private struct Called {
        var value: Any?
        var error: String?
        var label: String
    }

    private func call(_ api: String, _ args: [Any], via transport: Transport, form: Form,
                      page: WKWebView) async throws -> Called {
        var called = Called(value: nil, error: nil, label: "\(transport) \(form.rawValue) \(api)\(args)")
        switch transport {
        case .worker:
            let answer = try await askWorker(
                from: page, message: ["type": "call", "api": api, "args": args, "form": form.rawValue])
            XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker: \(answer)")
            let reply = try XCTUnwrap(answer["reply"] as? [String: Any], "\(called.label): \(answer)")
            called.value = reply["value"].flatMap { $0 is NSNull ? nil : $0 }
            called.error = (reply["error"] as? String) ?? (reply["lastError"] as? String)
        case .page:
            let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            switch form {
            case .promise:
                let outcome = try await pageEval(promiseOutcomeJS("chrome.\(api)(...\(json))"), in: page)
                called.value = outcome["value"].flatMap { $0 is NSNull ? nil : $0 }
                called.error = outcome["message"] as? String
            case .callback:
                let outcome = try await pageEval(
                    callbackOutcomeJS(call: "return chrome.\(api)(...\(json), cb);"), in: page)
                XCTAssertEqual(outcome["timedOut"] as? Bool, false, "\(called.label): \(outcome)")
                if let arg0 = outcome["arg0"] as? String {
                    called.value = try JSONSerialization.jsonObject(with: Data(arg0.utf8),
                                                                    options: .fragmentsAllowed)
                    if called.value is NSNull { called.value = nil }
                }
                called.error = outcome["lastErrorInCallback"] as? String
            }
        }
        return called
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

    /// TASK-224: only a normal caller asking for Private needs the extension
    /// allowed there; a Private caller is running in Private already.
    func testThePrivateAccessRule() {
        for allowed in [false, true] {
            XCTAssertFalse(ExtensionManager.refusesPrivateWindow(requested: false, callerIsIncognito: false,
                                                                 allowedInPrivate: allowed))
            XCTAssertFalse(ExtensionManager.refusesPrivateWindow(requested: false, callerIsIncognito: true,
                                                                 allowedInPrivate: allowed))
            XCTAssertFalse(ExtensionManager.refusesPrivateWindow(requested: true, callerIsIncognito: true,
                                                                 allowedInPrivate: allowed))
        }
        XCTAssertTrue(ExtensionManager.refusesPrivateWindow(requested: true, callerIsIncognito: false,
                                                            allowedInPrivate: false))
        XCTAssertFalse(ExtensionManager.refusesPrivateWindow(requested: true, callerIsIncognito: false,
                                                             allowedInPrivate: true))
    }

    /// TASK-225: the scheme compare ignores case, which Foundation's `URL`
    /// keeps as written.
    func testTheJavaScriptURLRule() throws {
        for string in ["javascript:void(0)", "JavaScript:alert(1)", "JAVASCRIPT:x"] {
            XCTAssertTrue(ExtensionManager.isJavaScriptURL(try XCTUnwrap(URL(string: string))), string)
        }
        for string in ["https://example.com/javascript:x", "about:blank", "data:text/html,javascript:x"] {
            XCTAssertFalse(ExtensionManager.isJavaScriptURL(try XCTUnwrap(URL(string: string))), string)
        }
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

    // MARK: - From a normal profile

    /// The caller's profile is in front: the window opens on that space.
    func testFromANormalProfileOpensANormalWindowInTheFrontSpace() async throws {
        let ext = try await makeExtension()
        let normal = makeProfile("Windows Create Normal")
        let page = try await loadPage(ext, in: normal)
        let url = try await serve()

        for (transport, form) in [(Transport.worker, Form.promise), (.page, .callback)] {
            let space = browserWindow(showingANewSpaceOf: normal)
            let created = try await create(["url": url.absoluteString], via: transport, form: form, page: page)
            assertOpenedANormalWindow(created, on: space, showing: url)
            closeBrowserWindows()
        }
    }

    /// The task's case: another profile's window is in front. The window
    /// opens on the caller's own space, where its tabs load with the caller's
    /// cookies and history, and the front window's space gets nothing.
    func testFromANormalProfileWithAnotherProfileInFrontOpensOnTheCallersSpace() async throws {
        let ext = try await makeExtension()
        let caller = makeProfile("Windows Create Caller")
        let other = makeProfile("Windows Create Other")
        let page = try await loadPage(ext, in: caller)
        let url = try await serve()

        for transport in Transport.allCases {
            for form in Form.allCases {
                let callerSpace = browserWindow(showingANewSpaceOf: caller)
                let frontSpace = browserWindow(showingANewSpaceOf: other)
                let created = try await create(["url": url.absoluteString], via: transport, form: form, page: page)
                assertOpenedANormalWindow(created, on: callerSpace, showing: url)
                XCTAssertTrue(frontSpace.tabs.isEmpty, "\(created.label): \(frontSpace.tabs.map(\.url))")
                closeBrowserWindows()
            }
        }
    }

    /// No window shows the caller's profile: the window opens on the space of
    /// it used last (the user's decision), not on its first space and not on
    /// the front window's.
    func testFromANormalProfileWithNoOpenSpaceOpensOnItsLastActiveSpace() async throws {
        let ext = try await makeExtension()
        let caller = makeProfile("Windows Create Closed Caller")
        let other = makeProfile("Windows Create Closed Other")
        let page = try await loadPage(ext, in: caller)
        let url = try await serve()

        for (transport, form) in [(Transport.worker, Form.callback), (.page, .promise)] {
            let first = addSpace(of: caller)
            let lastActive = addSpace(of: caller)
            browserWindow(showing: first)
            browserWindow(showing: lastActive)
            closeBrowserWindows()
            let frontSpace = browserWindow(showingANewSpaceOf: other)

            let created = try await create(["url": url.absoluteString], via: transport, form: form, page: page)
            assertOpenedANormalWindow(created, on: lastActive, showing: url)
            XCTAssertTrue(first.tabs.isEmpty, created.label)
            XCTAssertTrue(frontSpace.tabs.isEmpty, created.label)
            closeBrowserWindows()
            // Gone before the next pass, so its `first` is the profile's first space again.
            for space in [first, lastActive] {
                space.tabs.forEach { $0.teardown() }
                TabStore.shared.forceRemoveSpace(id: space.id)
            }
        }
    }

    /// A profile with no space has nowhere of its own to open a window: the
    /// call is refused before any window opens, rather than borrowing the
    /// front window's space.
    func testFromANormalProfileWithNoSpaceIsRefusedAndOpensNoWindow() async throws {
        let ext = try await makeExtension()
        let caller = makeProfile("Windows Create Spaceless")
        let other = makeProfile("Windows Create Spaceless Other")
        let page = try await loadPage(ext, in: caller)
        let url = try await serve()
        let frontSpace = browserWindow(showingANewSpaceOf: other)

        for transport in Transport.allCases {
            for form in Form.allCases {
                let created = try await create(["url": url.absoluteString], via: transport, form: form, page: page)
                XCTAssertTrue(created.error?.contains("no space") ?? false,
                              "\(created.label): \(String(describing: created.error))")
                XCTAssertNil(created.window, created.label)
                XCTAssertEqual(created.opened.count, 0, created.label)
            }
        }
        XCTAssertTrue(frontSpace.tabs.isEmpty, "\(frontSpace.tabs.map(\.url))")
    }

    /// The call succeeded and opened one normal window, on `space`, whose new
    /// tab shows `url`.
    private func assertOpenedANormalWindow(_ created: Created, on space: Space, showing url: URL,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(created.error, created.label, file: file, line: line)
        XCTAssertEqual(created.window?["incognito"] as? Bool, false,
                       "\(created.label): \(String(describing: created.window))", file: file, line: line)
        XCTAssertEqual(created.opened.count, 1, created.label, file: file, line: line)
        let wc = created.opened.first
        XCTAssertEqual(wc?.isIncognito, false, created.label, file: file, line: line)
        XCTAssertEqual(wc?.activeSpaceID, space.id,
                       "\(created.label): opened on \(String(describing: wc?.activeSpace?.profile?.name))",
                       file: file, line: line)
        XCTAssertEqual(space.tabs.map(\.url), [url], created.label, file: file, line: line)
    }

    /// A normal context of an extension the user allowed in Private, asking
    /// for a Private window, gets one, but WebKit reports no window to a
    /// context without access to Private data, so the promise resolves with
    /// nothing.
    func testFromANormalProfileIncognitoTrueOpensAPrivateWindowWhenAllowedInPrivate() async throws {
        let ext = try await makeExtension()
        installInSharedDatabase(ext, allowedInPrivate: true)
        let normal = makeProfile("Windows Create Normal To Private")
        let page = try await loadPage(ext, in: normal)
        let url = try await serve()
        browserWindow(showingANewSpaceOf: normal)

        for (transport, form) in [(Transport.worker, Form.promise), (.page, .callback)] {
            let created = try await create(["url": url.absoluteString, "incognito": true],
                                           via: transport, form: form, page: page)
            assertOpenedAPrivateWindow(created, showing: url, reportsWindow: false)
            closeBrowserWindows()
        }
    }

    /// TASK-224: an extension the user kept out of Private (no row for the
    /// Private profile, which means off, or a row saying off) cannot put a
    /// page in front of them there. The call is refused before any window
    /// opens, from both transports, as a rejection and as `lastError`.
    func testFromANormalProfileIncognitoTrueIsRefusedWhenNotAllowedInPrivate() async throws {
        let ext = try await makeExtension()
        installInSharedDatabase(ext, allowedInPrivate: nil)
        let normal = makeProfile("Windows Create Not In Private")
        let page = try await loadPage(ext, in: normal)
        let url = try await serve()
        let space = browserWindow(showingANewSpaceOf: normal)

        func assertRefused(_ created: Created, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(created.error?.contains("not allowed in Private") ?? false,
                          "\(created.label): \(String(describing: created.error))", file: file, line: line)
            XCTAssertNil(created.window, created.label, file: file, line: line)
            XCTAssertEqual(created.opened.count, 0, created.label, file: file, line: line)
        }

        for transport in Transport.allCases {
            for form in Form.allCases {
                assertRefused(try await create(["url": url.absoluteString, "incognito": true],
                                               via: transport, form: form, page: page))
            }
        }

        setAllowedInPrivate(ext, false)
        assertRefused(try await create(["url": url.absoluteString, "incognito": true],
                                       via: .page, form: .promise, page: page))
        XCTAssertTrue(space.tabs.isEmpty, "\(space.tabs.map(\.url))")

        // The same extension's normal windows are not affected.
        let created = try await create(["url": url.absoluteString], via: .worker, form: .callback, page: page)
        assertOpenedANormalWindow(created, on: space, showing: url)
    }

    // MARK: - javascript: URLs (TASK-225)

    /// A `javascript:` URL has no page to open, and loading one into a tab
    /// runs the script in that tab's page; Chrome's MV3 refuses it in these
    /// APIs. Shipped WebKit (macOS 26, Darwin 25.6) passes it through to
    /// Detour: `windows.create` opened a window, `tabs.create` a tab, and
    /// `tabs.update` ran the script (WebKit `main` refuses it in
    /// `windows.create` first). Each is refused before anything opens or
    /// loads, from both transports, in both forms.
    ///
    /// One test with one profile for the three APIs: every profile a test
    /// loads an extension into is kept for the rest of the process (see
    /// `retainedProfiles`). With three more of them here, QuickDetourExtensionTests
    /// run after this suite in one process timed out on page loads, its
    /// occluded windows' loads never finishing on a loaded machine (TASK-225).
    func testJavaScriptURLsAreRefusedByWindowsCreateTabsCreateAndTabsUpdate() async throws {
        let ext = try await makeExtension()
        let normal = makeProfile("JavaScript URLs")
        let page = try await loadPage(ext, in: normal)
        let url = try await serve()
        let space = browserWindow(showingANewSpaceOf: normal)

        // windows.create, the URL alone and among others.
        for urls in [["javascript:void(0)"], [url.absoluteString, "javascript:document.title='ran'"]] {
            for transport in Transport.allCases {
                for form in Form.allCases {
                    let created = try await create(["url": urls], via: transport, form: form, page: page)
                    XCTAssertTrue(created.error?.contains("javascript:") ?? false,
                                  "\(created.label): \(String(describing: created.error))")
                    XCTAssertNil(created.window, created.label)
                    XCTAssertEqual(created.opened.count, 0, created.label)
                    closeBrowserWindows()
                }
            }
        }
        browserWindow(showing: space)

        // tabs.create opens no tab.
        for transport in Transport.allCases {
            for form in Form.allCases {
                let called = try await call("tabs.create", [["url": "javascript:document.title='ran'"]],
                                            via: transport, form: form, page: page)
                assertRefusedAJavaScriptURL(called)
            }
        }
        XCTAssertTrue(space.tabs.isEmpty, "\(space.tabs.map { $0.url?.absoluteString ?? "nil" })")

        // tabs.update leaves the tab's page alone.
        let opened = try await call("tabs.create", [["url": url.absoluteString, "active": true]],
                                    via: .worker, form: .promise, page: page)
        let tabID = try XCTUnwrap((opened.value as? [String: Any])?["id"] as? Int, opened.label)
        let tab = try XCTUnwrap(space.tabs.first { $0.url == url }, "\(space.tabs.map(\.url))")
        try await waitUntil("the tab to load") { !tab.isLoading && tab.title == "Looked Up" }
        for transport in Transport.allCases {
            for form in Form.allCases {
                let called = try await call("tabs.update", [tabID, ["url": "javascript:document.title='ran'"]],
                                            via: transport, form: form, page: page)
                assertRefusedAJavaScriptURL(called)
            }
        }
        // Give a script that did get through time to run.
        try await Task.sleep(nanoseconds: 500_000_000)
        let title = try await tab.webView?.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "Looked Up")
        XCTAssertEqual(tab.url, url)
    }

    // MARK: - tabs.create's space (TASK-226)

    /// `tabs.create` without a `windowId` adds its tab to the caller's
    /// profile's most recently used space, as `windows.create` opens on it
    /// (TASK-223): with two spaces on the profile and the second used last,
    /// not the first, and not the front window's space of another profile.
    /// A profile with no space is refused, and the other profile's space still
    /// gets nothing. One loaded profile for both halves (see `retainedProfiles`).
    func testTabsCreateAddsToTheCallersMostRecentlyUsedSpaceAndIsRefusedWithoutOne() async throws {
        let ext = try await makeExtension()
        let caller = makeProfile("Tabs Create Caller")
        let other = makeProfile("Tabs Create Other")
        let page = try await loadPage(ext, in: caller)
        let url = try await serve()

        let first = addSpace(of: caller)
        let used = addSpace(of: caller)
        browserWindow(showing: first)
        browserWindow(showing: used)
        let frontSpace = browserWindow(showingANewSpaceOf: other)

        var created = 0
        for transport in Transport.allCases {
            for form in Form.allCases {
                let called = try await call("tabs.create", [["url": url.absoluteString, "active": false]],
                                            via: transport, form: form, page: page)
                XCTAssertNil(called.error, called.label)
                XCTAssertNotNil((called.value as? [String: Any])?["id"] as? Int,
                                "\(called.label): \(String(describing: called.value))")
                created += 1
                XCTAssertEqual(used.tabs.count, created, "\(called.label): \(used.tabs.map(\.url))")
            }
        }
        XCTAssertTrue(first.tabs.isEmpty, "\(first.tabs.map(\.url))")
        XCTAssertTrue(frontSpace.tabs.isEmpty, "\(frontSpace.tabs.map(\.url))")

        closeBrowserWindows()
        browserWindow(showing: frontSpace)
        for space in [first, used] {
            space.tabs.forEach { $0.teardown() }
            TabStore.shared.forceRemoveSpace(id: space.id)
        }
        for transport in Transport.allCases {
            for form in Form.allCases {
                let called = try await call("tabs.create", [["url": url.absoluteString]],
                                            via: transport, form: form, page: page)
                XCTAssertTrue(called.error?.contains("no space") ?? false,
                              "\(called.label): \(String(describing: called.error)) \(String(describing: called.value))")
                XCTAssertNil(called.value, called.label)
            }
        }
        XCTAssertTrue(frontSpace.tabs.isEmpty, "\(frontSpace.tabs.map(\.url))")
    }

    private func assertRefusedAJavaScriptURL(_ called: Called, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(called.error?.contains("javascript:") ?? false,
                      "\(called.label): \(String(describing: called.error)) \(String(describing: called.value))",
                      file: file, line: line)
        XCTAssertNil(called.value, called.label, file: file, line: line)
    }
}
