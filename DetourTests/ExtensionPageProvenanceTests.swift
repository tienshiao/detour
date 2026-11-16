import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-381: a web page must never get an extension's page loaded in a tab.
/// WebKit refuses a main-frame `webkit-extension://` load unless the web view
/// was built from that extension's context configuration (TASK-352), but the
/// refused URL used to stay in the tab's `url`, and `BrowserTab.wake` builds a
/// tab whose `url` is an extension page from that extension's configuration.
/// So a page's `window.open` of a non-web-accessible `options.html`, then a
/// sleep and Reload, loaded it with the extension's privileges, and a relaunch
/// restored it the same way.
///
/// The rule under test: `url` only names an extension page the tab's web view
/// can show (`BrowserTab.servedExtensionOriginHost`), so everything built from
/// `url` (wake, the save, records, rehoming) only ever names one Detour or the
/// extension put there. Each "never loads" test fails with `mayAdopt` always
/// true, which is the code before TASK-381; the positive controls show the
/// same harness does load a legitimately opened page.
nonisolated final class ExtensionPageProvenanceTests: XCTestCase {

    private var controllers: [BrowserWindowController] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var localTabs: [BrowserTab] = []
    private var localProfiles: [Profile] = []
    /// Profiles outlive the test: WebKit traps when a profile that hosted
    /// extension web views is released while they wind down.
    @MainActor private static var retainedProfiles: [Profile] = []
    private var previousLastActiveSpaceID: UUID?
    private var defaultFaviconFetch: ((URL, @escaping @Sendable (NSImage?) -> Void) -> Void)!

    @MainActor override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = TabStore.shared.lastActiveSpaceID
        defaultFaviconFetch = FaviconLoader.shared.fetch
        FaviconLoader.shared.resetForTesting()
        FaviconLoader.shared.fetch = { _, completion in completion(nil) }
    }

    @MainActor override func tearDown() async throws {
        for controller in controllers {
            controller.sidebarSplitView.autosaveName = nil
            controller.window?.close()
        }
        controllers.removeAll()
        for id in createdSpaceIDs {
            if let space = TabStore.shared.space(withID: id) { space.tabs.forEach { $0.teardown() } }
            TabStore.shared.deleteSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for tab in localTabs { tab.teardown() }
        localTabs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for profile in localProfiles {
            profile.unloadAllExtensions()
            Self.retainedProfiles.append(profile)
        }
        localProfiles.removeAll()
        for id in registeredExtensionIDs { ExtensionManager.shared.extensions.removeAll { $0.id == id } }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        TabStore.shared.lastActiveSpaceID = previousLastActiveSpaceID
        FaviconLoader.shared.fetch = defaultFaviconFetch
        FaviconLoader.shared.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let optionsTitle = "Opts"

    /// A loopback web page: the attacker.
    @MainActor private func makePage() async throws -> URL {
        let server = try LoopbackHTTPServer(
            routes: ["/page": "<html><head><title>Opener</title></head><body>opener</body></html>"])
        servers.append(server)
        let port = try await server.start()
        return URL(string: "http://127.0.0.1:\(port)/page")!
    }

    /// An extension whose `options.html` is not web-accessible, and a second
    /// page of its own (`other.html`).
    @MainActor private func makeExtension(_ name: String = "TASK-381") async throws -> WebExtension {
        let ext = try await makeTestExtension(
            id: "task-381-\(UUID().uuidString.prefix(8))",
            manifestJSON: """
                {
                    "manifest_version": 3,
                    "name": "\(name)",
                    "version": "1.0.0",
                    "options_ui": { "page": "options.html" }
                }
                """,
            files: ["options.html": "<html><head><title>\(Self.optionsTitle)</title></head><body>options</body></html>",
                    "other.html": "<html><head><title>Other</title></head><body>other</body></html>",
                    // Framed with `?go`, sends the top frame to `other.html?top=1`
                    // itself: the requesting frame is a subframe of the
                    // extension's own origin (TASK-382).
                    "jump.html": "<html><head><script src=\"jump.js\"></script></head><body>jump</body></html>",
                    "jump.js": "if (location.search === '?go') top.location = 'other.html?top=1';"])
        tempDirs.append(ext.basePath)
        return ext
    }

    /// A profile of `TabStore.shared` with `exts` loaded into it.
    @MainActor private func makeProfile(loading exts: [WebExtension]) throws -> (Profile, [WKWebExtensionContext]) {
        let profile = TabStore.shared.addProfile(name: "TASK-381 \(UUID().uuidString.prefix(6))")
        createdProfiles.append(profile)
        _ = profile.extensionController
        var contexts: [WKWebExtensionContext] = []
        for ext in exts {
            ExtensionManager.shared.extensions.append(ext)
            registeredExtensionIDs.append(ext.id)
            contexts.append(try loadTestContext(ext, in: profile))
        }
        return (profile, contexts)
    }

    @MainActor private func makeSpace(_ profile: Profile) -> Space {
        let space = TabStore.shared.addSpace(name: "TASK-381", emoji: "🧪", colorHex: "007AFF", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    /// A web page's tab, selected in a window so its page can open windows.
    @MainActor private func openerTab(_ page: URL, in space: Space) async throws -> BrowserTab {
        let tab = TabStore.shared.addTab(in: space, url: page)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        controllers.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.selectTab(id: tab.id)
        wc.showWindow(nil)
        try await waitUntil("the opener to show") { tab.title == "Opener" }
        return tab
    }

    @MainActor private func showsErrorPage(_ tab: BrowserTab) -> Bool {
        tab.webView?.url?.scheme == ErrorPage.scheme && tab.webView?.isLoading == false
    }

    @MainActor private func waitForErrorPage(_ tab: BrowserTab, file: StaticString = #filePath,
                                             line: UInt = #line) async throws {
        try await waitUntil("the error page", file: file, line: line) { showsErrorPage(tab) }
    }

    /// Tags the document on screen, so a wait can tell the next document from it.
    @MainActor private func markDocument(_ tab: BrowserTab) async {
        _ = try? await tab.webView?.evaluateJavaScript("window.__task381 = 1; 1")
    }

    @MainActor private func isMarkedDocument(_ tab: BrowserTab) async -> Bool {
        (try? await tab.webView?.evaluateJavaScript("window.__task381 === 1")) as? Bool ?? false
    }

    @MainActor private func showsOptions(_ tab: BrowserTab, _ options: URL) -> Bool {
        tab.title == Self.optionsTitle || (tab.webView?.url == options && tab.webView?.isLoading == false)
    }

    /// Reloads `tab` and waits for the document that Reload produced: the
    /// extension page (a hole), a fresh error page, or the page the tab kept.
    @MainActor private func reloadAndWaitForNextDocument(_ tab: BrowserTab, options: URL,
                                                         file: StaticString = #filePath, line: UInt = #line) async throws {
        await markDocument(tab)
        tab.reload()
        try await waitUntil("the document Reload loads", file: file, line: line) {
            if showsOptions(tab, options) { return true }
            guard tab.webView?.url != nil, tab.webView?.isLoading == false else { return false }
            return await !isMarkedDocument(tab)
        }
    }

    /// The tab never shows `options` through a sleep, a wake and a Reload,
    /// and its `url` never names it.
    @MainActor private func assertNeverLoadsAfterSleepWakeAndReload(
        _ tab: BrowserTab, options: URL, host: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertFalse(isExtensionPageURL(tab.url), "the refused URL is not the tab's url: \(String(describing: tab.url))",
                       file: file, line: line)
        XCTAssertFalse(tab.showsExtensionPage(ofOriginHost: host),
                       "a rehome of the extension's origin must not pick the tab up", file: file, line: line)

        tab.sleep(force: true)
        XCTAssertTrue(tab.isSleeping, file: file, line: line)
        XCTAssertFalse(tab.showsExtensionPage(ofOriginHost: host), "asleep", file: file, line: line)
        tab.wake()
        try await waitUntil("the woken tab to settle", file: file, line: line) {
            tab.webView != nil && tab.webView?.isLoading == false
        }
        XCTAssertNil(tab.servedExtensionOriginHost, "woken from the space's configuration", file: file, line: line)
        XCTAssertFalse(showsOptions(tab, options), "the wake loaded the extension page", file: file, line: line)

        try await reloadAndWaitForNextDocument(tab, options: options, file: file, line: line)
        XCTAssertFalse(showsOptions(tab, options), "Reload after the wake loaded the extension page",
                       file: file, line: line)
        XCTAssertFalse(isExtensionPageURL(tab.webView?.url), "Reload committed an extension page",
                       file: file, line: line)
        XCTAssertFalse(isExtensionPageURL(tab.url), file: file, line: line)
    }

    // MARK: - Probe A: a web page chooses the extension page

    /// The reported hole: `window.open` from a web page. WebKit performs the
    /// child's navigation and refuses it; the child has no committed page.
    @MainActor func testAWindowOpenedByAPageNeverLoadsTheExtensionsPage() async throws {
        let page = try await makePage()
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let space = makeSpace(profile)
        let opener = try await openerTab(page, in: space)
        let before = Set(space.tabs.map(\.id))

        _ = try await XCTUnwrap(opener.webView).evaluateJavaScript("window.open('\(options.absoluteString)'); 1")
        try await waitUntil("the child tab") { space.tabs.count > before.count }
        let child = try XCTUnwrap(space.tabs.first { !before.contains($0.id) })
        try await waitForErrorPage(child)
        XCTAssertEqual(child.webView?.url.flatMap(ErrorPage.originalURL(from:)), options,
                       "the error page still names the URL that was refused")

        try await assertNeverLoadsAfterSleepWakeAndReload(child, options: options, host: try XCTUnwrap(context.baseURL.host))
    }

    /// A page-chosen URL the app loads itself (`load(_:)`): what Open Link in
    /// New Tab, a Cmd-click or a routed link does with a link's URL.
    @MainActor func testAPageChosenURLTheAppLoadsNeverLoadsTheExtensionsPage() async throws {
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let space = makeSpace(profile)

        let tab = TabStore.shared.addTab(in: space, url: options)
        try await waitForErrorPage(tab)

        try await assertNeverLoadsAfterSleepWakeAndReload(tab, options: options, host: try XCTUnwrap(context.baseURL.host))
    }

    /// A script's location change and a clicked link in a page that committed:
    /// WebKit sets the web view back to that page before the failure, so the
    /// tab keeps it. Passes on the code before TASK-381 too; it guards the
    /// TASK-372 fix, which names the refused URL and would otherwise adopt it.
    @MainActor func testAPageNavigatingItselfToTheExtensionsPageNeverLoadsIt() async throws {
        let page = try await makePage()
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let host = try XCTUnwrap(context.baseURL.host)
        let space = makeSpace(profile)

        let scripted = try await openerTab(page, in: space)
        _ = try await XCTUnwrap(scripted.webView).callAsyncJavaScript(
            "location.href = '\(options.absoluteString)';", arguments: [:], contentWorld: .page)
        try await waitForErrorPage(scripted)
        XCTAssertEqual(scripted.url, page)
        try await assertNeverLoadsAfterSleepWakeAndReload(scripted, options: options, host: host)

        let clicked = try await openerTab(page, in: space)
        _ = try await XCTUnwrap(clicked.webView).callAsyncJavaScript("""
            const a = document.createElement('a');
            a.href = '\(options.absoluteString)';
            document.body.appendChild(a);
            a.click();
            """, arguments: [:], contentWorld: .page)
        try await waitForErrorPage(clicked)
        XCTAssertEqual(clicked.url, page)
        try await assertNeverLoadsAfterSleepWakeAndReload(clicked, options: options, host: host)
    }

    /// `tabs.create` hands any `webkit-extension://` URL to the *calling*
    /// extension's configuration: another extension's page is refused there,
    /// and must not become reachable through a wake either.
    @MainActor func testAnotherExtensionsPageOpenedByTabsCreateNeverLoads() async throws {
        let caller = try await makeExtension("Caller")
        let target = try await makeExtension("Target")
        let (profile, contexts) = try makeProfile(loading: [caller, target])
        let callerContext = try testElement(contexts, 0)
        let targetContext = try testElement(contexts, 1)
        let options = try extensionPageURL("options.html", on: targetContext.baseURL)
        let space = makeSpace(profile)

        let tab = TabStore.shared.addExtensionTab(in: space, url: options, context: callerContext)
        // The tab's web view is the caller's context's own, which has no
        // error page handler: the refused load just ends.
        try await waitUntil("the refused load to end") { tab.webView?.isLoading == false }

        try await assertNeverLoadsAfterSleepWakeAndReload(tab, options: options,
                                                          host: try XCTUnwrap(targetContext.baseURL.host))
    }

    // MARK: - Positive controls (AC #2)

    /// An extension page opened from the extension's own context (tabs.create,
    /// the options entry points) loads, sleeps, wakes and reloads as before.
    @MainActor func testAnExtensionsOwnPageStillWakesAndReloads() async throws {
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let space = makeSpace(profile)

        let tab = TabStore.shared.addExtensionTab(in: space, url: options, context: context)
        try await waitUntil("the options page") { showsOptions(tab, options) }
        XCTAssertEqual(tab.url, options)
        XCTAssertEqual(tab.servedExtensionOriginHost, context.baseURL.host)
        XCTAssertTrue(tab.showsExtensionPage(ofOriginHost: try XCTUnwrap(context.baseURL.host)))

        tab.sleep(force: true)
        XCTAssertEqual(tab.url, options)
        tab.wake()
        XCTAssertEqual(tab.servedExtensionOriginHost, context.baseURL.host, "woken from the context's configuration")
        try await waitUntil("the woken options page") {
            tab.webView?.url == options && tab.webView?.isLoading == false
        }
        try await reloadAndWaitForNextDocument(tab, options: options)
        try await waitUntil("the reloaded options page") { tab.title == Self.optionsTitle }
        XCTAssertEqual(tab.url, options)
    }

    /// An extension page navigating to another page of its own extension
    /// commits in the context's configuration; the tab takes the new URL and
    /// a wake rebuilds it there.
    @MainActor func testAnExtensionPageNavigatingWithinItsExtensionKeepsItsOrigin() async throws {
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let other = try extensionPageURL("other.html", on: context.baseURL)
        let space = makeSpace(profile)

        let tab = TabStore.shared.addExtensionTab(in: space, url: options, context: context)
        try await waitUntil("the options page") { showsOptions(tab, options) }
        _ = try await XCTUnwrap(tab.webView).callAsyncJavaScript(
            "location.href = '\(other.absoluteString)';", arguments: [:], contentWorld: .page)
        try await waitUntil("the other page") { tab.title == "Other" && tab.url == other }

        tab.sleep(force: true)
        tab.wake()
        try await waitUntil("the woken page") {
            tab.webView?.url == other && tab.webView?.isLoading == false && tab.title == "Other"
        }
        XCTAssertFalse(showsErrorPage(tab))
    }

    // MARK: - Relaunch

    /// The session round trip: a refused page-chosen URL is not saved as an
    /// extension page, so the restore neither registers its origin as pending
    /// nor moves it onto the extension's new origin, where a wake would build
    /// it into the context's configuration. The extension's own tab, saved
    /// alongside, is restored and rehomed as before.
    @MainActor func testARelaunchDoesNotRestoreARefusedExtensionPage() async throws {
        let db = try AppDatabase(dbQueue: DatabaseQueue())
        let ext = try await makeExtension()
        installTestExtension(ext, in: db)

        let store1 = TabStore(appDB: db)
        let profile1 = store1.addProfile(name: "TASK-381 Relaunch")
        localProfiles.append(profile1)
        turnOnTestExtension(ext, in: profile1, db: db)
        let space1 = store1.addSpace(name: "Relaunch", emoji: "🧪", colorHex: "007AFF", profileID: profile1.id)
        _ = profile1.extensionController
        let context1 = try loadTestContext(ext, in: profile1)
        let base1 = context1.baseURL
        let options = try extensionPageURL("options.html", on: base1)
        let ownPage = try extensionPageURL("options.html?own=1", on: base1)

        let refused = store1.addTab(in: space1, url: options)
        localTabs.append(refused)
        let own = store1.addExtensionTab(in: space1, url: ownPage, context: context1)
        localTabs.append(own)
        try await waitForErrorPage(refused)
        try await waitUntil("the extension's own page") { own.title == Self.optionsTitle }

        store1.saveNow()
        let rows = try await db.dbQueue.read { try TabRecord.fetchAll($0) }
        let refusedRow = try XCTUnwrap(rows.first { $0.id == refused.id.uuidString })
        XCTAssertNil(refusedRow.extensionID, "the refused page is saved with no extension identity")
        XCTAssertFalse(isExtensionPageURL(refusedRow.url.flatMap(URL.init(string:))),
                       "nor as an extension page: \(refusedRow.url ?? "nil")")
        XCTAssertEqual(rows.first { $0.id == own.id.uuidString }?.extensionID, ext.id)
        profile1.unloadAllExtensions()

        let store2 = TabStore(appDB: db)
        _ = store2.restoreSession()
        let profile2 = try XCTUnwrap(store2.profile(withID: profile1.id))
        localProfiles.append(profile2)
        let space2 = try XCTUnwrap(store2.space(withID: space1.id))
        let restoredOwn = try XCTUnwrap(space2.tabs.first { $0.id == own.id })
        localTabs.append(contentsOf: space2.tabs)
        XCTAssertEqual(Set(profile2.pendingExtensionOrigins.keys), [try XCTUnwrap(base1.host).lowercased()],
                       "only the extension's own page waits for its context")

        _ = profile2.extensionController
        let base2 = try loadTestContext(ext, in: profile2).baseURL
        profile2.resolvePendingExtensionPages(in: store2)
        for tab in space2.tabs where tab.id != own.id {
            XCTAssertFalse(isExtensionPageURL(tab.url), "restored onto an extension origin: \(String(describing: tab.url))")
            XCTAssertFalse(tab.showsExtensionPage(ofOriginHost: try XCTUnwrap(base2.host)))
        }
        XCTAssertEqual(restoredOwn.url, rewriteExtensionPageURL(ownPage, from: base1, to: base2),
                       "the extension's own page is rehomed as before")
    }

    // MARK: - TASK-382: web content inside an extension's own tab

    /// A loopback server for the framed attacker: `/top` sends the top frame
    /// to the URL in its fragment as soon as it loads, with no user gesture.
    @MainActor private func makeFramedAttacker() async throws -> (LoopbackHTTPServer, UInt16) {
        let server = try LoopbackHTTPServer(routes: [
            "/top": "<html><body>top<script>top.location = decodeURIComponent(location.hash.slice(1));</script></body></html>",
            "/page": "<html><head><title>Web</title></head><body>web</body></html>",
        ])
        servers.append(server)
        return (server, try await server.start())
    }

    /// Frames `src` into the page `tab` shows, as the extension's own page
    /// would with an `<iframe>` of its markup.
    @MainActor private func frame(_ src: String, into tab: BrowserTab) async throws {
        _ = try await XCTUnwrap(tab.webView).callAsyncJavaScript(
            "const f = document.createElement('iframe'); f.src = src; document.body.appendChild(f);",
            arguments: ["src": src], contentWorld: .page)
    }

    @MainActor private func fragment(_ url: URL) -> String {
        "#" + (url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
    }

    /// WebKit's own gate, which is why the route TASK-382 was filed for is not
    /// real: a web view built from an extension context's configuration ignores
    /// every main-frame navigation off that extension (`NavigationState.mm`,
    /// `isUnsupportedWebExtensionNavigation`), after the delegate allowed it.
    /// The link from the options page never reaches the server, and the tab
    /// stays on the options page, so no web page is ever this tab's main frame.
    /// If WebKit drops the gate this fails, and the policy below is what then
    /// stands between such a page and the extension's pages.
    @MainActor func testAnExtensionsTabNeverLoadsAWebPageInItsMainFrame() async throws {
        let (server, port) = try await makeFramedAttacker()
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let space = makeSpace(profile)
        let tab = TabStore.shared.addExtensionTab(in: space, url: options, context: context)
        try await waitUntil("the options page") { showsOptions(tab, options) }

        _ = try await XCTUnwrap(tab.webView).callAsyncJavaScript(
            "const a = document.createElement('a'); a.href = href; document.body.appendChild(a); a.click();",
            arguments: ["href": "http://127.0.0.1:\(port)/page"], contentWorld: .page)
        let left = try await pollUntil(timeout: 2) { server.requestedPaths.contains("/page") || tab.title == "Web" }
        XCTAssertFalse(left, "WebKit let the extension's tab load a web page")
        XCTAssertEqual(tab.webView?.url, options)
    }

    /// The live route that is real: web content the extension's page frames
    /// sends the top frame to one of the extension's pages that is not
    /// web-accessible. WebKit serves it (main frame, the context's own
    /// configuration), so the navigation policy refuses it: the requesting
    /// frame is not the extension's. Here the tab is shown in a window, whose
    /// navigation delegate decides.
    @MainActor func testAWebFrameInAnExtensionsPageCannotNavigateItsTabToTheExtensionsPages() async throws {
        let (server, port) = try await makeFramedAttacker()
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let other = try extensionPageURL("other.html", on: context.baseURL)
        let space = makeSpace(profile)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        controllers.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)

        let tab = TabStore.shared.addExtensionTab(in: space, url: options, context: context)
        wc.selectTab(id: tab.id)
        try await waitUntil("the options page") { showsOptions(tab, options) }
        XCTAssertTrue(tab.webView?.navigationDelegate === wc, "the window decides")
        try await frame("http://127.0.0.1:\(port)/top\(fragment(other))", into: tab)
        try await waitUntil("the framed page to load") { server.requestedPaths.contains("/top") }

        let loaded = try await pollUntil(timeout: 3) { tab.title == "Other" || tab.webView?.url == other }
        XCTAssertFalse(loaded, "the framed web page loaded the extension's page into the tab")
        XCTAssertEqual(tab.url, options)
        XCTAssertEqual(tab.webView?.url, options)
        XCTAssertFalse(showsErrorPage(tab), "a refused navigation leaves the page as it was")
    }

    /// The same from a tab no window has claimed: its own navigation delegate
    /// decides.
    @MainActor func testAWebFrameInABackgroundExtensionTabCannotNavigateItToTheExtensionsPages() async throws {
        let (server, port) = try await makeFramedAttacker()
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let other = try extensionPageURL("other.html", on: context.baseURL)
        let space = makeSpace(profile)
        let tab = TabStore.shared.addExtensionTab(in: space, url: options, context: context)
        try await waitUntil("the options page") { showsOptions(tab, options) }
        XCTAssertTrue(tab.webView?.navigationDelegate === tab, "no window has claimed the tab")

        try await frame("http://127.0.0.1:\(port)/top\(fragment(other))", into: tab)
        try await waitUntil("the framed page to load") { server.requestedPaths.contains("/top") }
        let loaded = try await pollUntil(timeout: 3) { tab.title == "Other" || tab.webView?.url == other }
        XCTAssertFalse(loaded, "the framed web page loaded the extension's page into the tab")
        XCTAssertEqual(tab.url, options)
    }

    /// AC #2's other half: the extension still moves between its own pages, by
    /// a link in its page, by Back, by a frame of its own sending the top frame
    /// on, and by `tabs.update` on its own tab — in a window and in the
    /// background.
    @MainActor func testAnExtensionsOwnNavigationBetweenItsPagesStillWorks() async throws {
        let (profile, contexts) = try makeProfile(loading: [try await makeExtension()])
        let context = try testElement(contexts, 0)
        let options = try extensionPageURL("options.html", on: context.baseURL)
        let other = try extensionPageURL("other.html", on: context.baseURL)
        let space = makeSpace(profile)
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        controllers.append(wc)
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)

        for shownInWindow in [true, false] {
            let label = shownInWindow ? "in a window" : "in the background"
            let tab = TabStore.shared.addExtensionTab(in: space, url: options, context: context)
            if shownInWindow { wc.selectTab(id: tab.id) }
            try await waitUntil("the options page, \(label)") { showsOptions(tab, options) }
            XCTAssertTrue(tab.webView?.navigationDelegate === (shownInWindow ? wc as AnyObject : tab as AnyObject),
                          "the delegate this leg means to cover, \(label)")

            // A link in its page.
            _ = try await XCTUnwrap(tab.webView).callAsyncJavaScript(
                "const a = document.createElement('a'); a.href = href; document.body.appendChild(a); a.click();",
                arguments: ["href": other.absoluteString], contentWorld: .page)
            try await waitUntil("the link, \(label)") { tab.title == "Other" && tab.url == other }

            // Back.
            tab.webView?.goBack()
            try await waitUntil("Back, \(label)") {
                tab.webView?.url == options && tab.webView?.isLoading == false && tab.title == Self.optionsTitle
            }

            // A frame of its own sends the top frame on, from its own script.
            try await frame("jump.html?go", into: tab)
            try await waitUntil("its own frame's top navigation, \(label)") {
                tab.title == "Other" && tab.url?.query == "top=1"
            }

            // tabs.update on its own tab.
            let target = try extensionPageURL("options.html?updated=1", on: context.baseURL)
            let updated = expectation(description: "tabs.update \(label)")
            tab.loadURL(target, for: context) { error in
                XCTAssertNil(error)
                updated.fulfill()
            }
            await fulfillment(of: [updated], timeout: 5)
            try await waitUntil("tabs.update, \(label)") {
                tab.url == target && tab.title == Self.optionsTitle && tab.webView?.isLoading == false
            }
        }
    }
}
