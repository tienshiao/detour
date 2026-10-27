import XCTest
import WebKit
@testable import Detour

/// Quarantine (TASK-194) in real windows of the shared store: the window is
/// marked; its page has a store of its own, shared with no other window,
/// Private window or profile; Open in loads the address fresh in a tab of the
/// chosen space and closes it, and nothing quarantined reaches that space
/// (a loopback server that sets a cookie, and records the cookies each request
/// sends); a download is asked about each time.
@MainActor
final class QuarantineWindowTests: XCTestCase {

    private var store: TabStore { .shared }
    private var appDelegate: AppDelegate!
    private var quickDetoursBefore: Set<ObjectIdentifier> = []
    private var browserWindowsBefore: Set<ObjectIdentifier> = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    private var previousAsk: ((QuarantineDownloadQuestion, NSWindow?, @escaping (Bool) -> Void) -> Void)!
    private var previousDownloadsDirectory: URL!
    private var downloadsDirectory: URL!
    private var cookiesToRemove: [(WKHTTPCookieStore, HTTPCookie)] = []
    private static var retainedProfiles: [Profile] = []

    private var work: Profile!
    private var desk: Space!

    override func setUpWithError() throws {
        try super.setUpWithError()
        appDelegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        quickDetoursBefore = Set(QuickDetourWindowController.openControllers.map(ObjectIdentifier.init))
        browserWindowsBefore = Set(browserWindows().map(ObjectIdentifier.init))
        previousAsk = QuickDetourWindowController.askQuarantineDownload
        QuickDetourWindowController.askQuarantineDownload = { question, _, _ in
            XCTFail("no download question expected: \(question)")
        }
        previousDownloadsDirectory = DownloadManager.shared.downloadsDirectory
        downloadsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarantine-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        DownloadManager.shared.downloadsDirectory = downloadsDirectory

        work = store.addProfile(name: "Quarantine Work \(UUID().uuidString.prefix(4))")
        createdProfiles.append(work)
        desk = store.addSpace(name: "Desk", emoji: "💼", colorHex: "007AFF", profileID: work.id)
        createdSpaceIDs.append(desk.id)
    }

    override func tearDown() async throws {
        QuickDetourWindowController.askQuarantineDownload = previousAsk
        for controller in newQuickDetours() {
            controller.closeDisposition = .discard
            controller.close()
        }
        for wc in browserWindows() where !browserWindowsBefore.contains(ObjectIdentifier(wc)) {
            wc.sidebarSplitView.autosaveName = nil
            wc.window?.close()
        }
        for item in DownloadManager.shared.items where item.destinationURL?.path.hasPrefix(downloadsDirectory.path) == true
            || item.sourceURL?.host == "127.0.0.1" {
            DownloadManager.shared.cancelDownload(item)
            DownloadManager.shared.removeDownload(item)
        }
        DownloadManager.shared.downloadsDirectory = previousDownloadsDirectory
        try? FileManager.default.removeItem(at: downloadsDirectory)
        for (cookieStore, cookie) in cookiesToRemove { await cookieStore.deleteCookie(cookie) }
        cookiesToRemove.removeAll()
        for id in createdSpaceIDs {
            if let space = store.space(withID: id) {
                for tab in space.tabs { tab.teardown() }
            }
            store.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for profile in createdProfiles {
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func browserWindows() -> [BrowserWindowController] {
        NSApp.windows.compactMap { $0.windowController as? BrowserWindowController }.filter { $0.window?.isVisible == true }
    }

    private func newQuickDetours() -> [QuickDetourWindowController] {
        QuickDetourWindowController.openControllers.filter { !quickDetoursBefore.contains(ObjectIdentifier($0)) }
    }

    private func isOpen(_ controller: QuickDetourWindowController) -> Bool {
        QuickDetourWindowController.openControllers.contains { $0 === controller }
    }

    /// `/set` sets the `qd` cookie (a `Set-Cookie` header) and writes
    /// `localStorage`; `/probe` is titled by whether it sees either.
    private static let probeTitleScript = """
        <script>
        let stored = null;
        try { stored = localStorage.getItem('qd'); } catch (e) {}
        document.title = 'cookie:' + (document.cookie.includes('qd=') ? 'yes' : 'no')
            + ' storage:' + (stored ? 'yes' : 'no');
        </script>
        """

    private func serve() async throws -> (LoopbackHTTPServer, String) {
        let server = try LoopbackHTTPServer(routes: [
            "/set": """
            <html><head><script>
            try { localStorage.setItem('qd', 'quarantined'); } catch (e) {}
            document.title = 'Set';
            </script></head><body>set</body></html>
            """,
            "/probe": "<html><head>\(Self.probeTitleScript)</head><body>probe</body></html>",
            "/opener": """
            <html><head><title>Opener</title><script>
            window.openChild = () => { window.open('/probe'); return true; };
            </script></head><body>opener</body></html>
            """,
            "/download": """
            <html><head><title>Download</title></head><body>
            <a id="file" href="/report.txt" download="report.txt">report</a></body></html>
            """,
            "/report.txt": "quarantined report",
            "/tracked": """
            <html><head><title>Tracked</title></head><body>
            <a id="link" href="/probe?id=1&utm_source=newsletter&utm_medium=email">tracked</a></body></html>
            """,
            "/probe?id=1": "<html><head>\(Self.probeTitleScript)</head><body>probe</body></html>",
            "/bounce?utm_source=loop": "<html><head><title>Bounced</title></head><body>bounced</body></html>",
            // A client-side redirect back to the parameters (TASK-194 follow-up).
            "/replace": "<html><head><script>location.replace('/replace?utm_source=loop');</script></head></html>",
            "/replace?utm_source=loop": """
            <html><head><title>Replaced</title><script>window.marker = 'kept';</script></head><body>
            <a id="anchor" href="#section">section</a><p id="section">section</p></body></html>
            """,
            // A tracked download link (TASK-194 follow-up).
            "/tracked-download": """
            <html><head><title>Tracked download</title></head><body>
            <a id="file" href="/report.txt?utm_source=x" download="report.txt">report</a></body></html>
            """,
            "/report.txt?utm_source=x": "quarantined report",
            // A Cmd+click of the page's own, from a timer (no user gesture).
            "/cmdclick?auto": """
            <html><head><title>Cmd-click</title></head><body><a id="link" href="/probe">probe</a><script>
            window.cmdClick = () => document.getElementById('link').dispatchEvent(
                new MouseEvent('click', { bubbles: true, cancelable: true, metaKey: true }));
            setTimeout(() => window.cmdClick(), 300);
            </script></body></html>
            """,
        ], redirects: ["/bounce": "http://127.0.0.1:{port}/bounce?utm_source=loop"],
           setCookies: ["/set": "qd=quarantined; Path=/; Max-Age=3600"])
        servers.append(server)
        let port = try await server.start()
        return (server, "http://127.0.0.1:\(port)")
    }

    private func openQuarantine(_ url: String, sourceSpace: Space? = nil) -> QuickDetourWindowController {
        QuickDetourWindowController.openQuarantine(url: URL(string: url)!, privateProfile: store.ensureIncognitoProfile(),
                                                   sourceSpace: sourceSpace)
    }

    private func waitForTitle(_ title: String, in tab: @escaping () -> BrowserTab?) async throws {
        try await waitUntil("the page titled \(title)", timeout: 10) {
            tab()?.title == title && tab()?.isLoading == false
        }
    }

    private func lastCookie(forPath path: String, on server: LoopbackHTTPServer) -> String?? {
        server.requests.last { $0.path == path }.map(\.cookie)
    }

    /// A normal window on `space`, in front of the others.
    @discardableResult
    private func makeWindow(showing space: Space) -> BrowserWindowController {
        let wc = BrowserWindowController(incognito: false)
        wc.sidebarSplitView.autosaveName = nil
        wc.setActiveSpace(id: space.id, selectTab: false)
        wc.showWindow(nil)
        appDelegate.registerWindowController(wc)
        return wc
    }

    // MARK: - The window

    func testTheWindowIsMarkedAndKeepsTheSystemAppearance() throws {
        let controller = openQuarantine("https://quarantine-mark.invalid/")

        XCTAssertTrue(controller.isQuarantine)
        XCTAssertTrue(controller.titleBar.isQuarantine)
        XCTAssertEqual(controller.titleBar.profileName, Quarantine.displayName, "the badge in place of the profile pill")
        XCTAssertNil(controller.window?.appearance, "not a Private window's dark: a look of its own")
    }

    func testThePillSwitchesNoProfile() throws {
        let controller = openQuarantine("https://quarantine-switch.invalid/")
        let page = controller.tab

        XCTAssertFalse(controller.switchProfile(to: work), "leaving quarantine is Open in, a fresh load")
        XCTAssertTrue(controller.tab === page)
        XCTAssertTrue(controller.isQuarantine)
    }

    func testItNeverClosesForIdleness() throws {
        let controller = openQuarantine("https://quarantine-idle.invalid/")
        var state = controller.idleState
        state.isFrontmost = false
        XCTAssertFalse(QuickDetour.shouldAutoClose(state, now: Date().addingTimeInterval(365 * 24 * 3600), interval: 1),
                       "nothing would be archived: the timer would only lose the page")
    }

    func testClosingItArchivesNothing() throws {
        let controller = openQuarantine("https://quarantine-archive.invalid/page")
        controller.close()
        XCTAssertFalse(store.archiveEntries().contains { $0.url?.contains("quarantine-archive.invalid") == true })
    }

    // MARK: - Isolation

    func testTwoQuarantineWindowsShareNothing() async throws {
        let (server, base) = try await serve()
        let first = openQuarantine(base + "/set")
        try await waitForTitle("Set") { first.tab }
        first.load(URL(string: base + "/probe")!, typed: false)
        try await waitForTitle("cookie:yes storage:yes") { first.tab }
        XCTAssertEqual(lastCookie(forPath: "/probe", on: server), "qd=quarantined", "the fixture sets the cookie")

        let second = openQuarantine(base + "/probe")
        try await waitForTitle("cookie:no storage:no") { second.tab }
        XCTAssertEqual(lastCookie(forPath: "/probe", on: server), .some(nil), "no cookie sent from the second")
    }

    func testCookiesOfPrivateWindowsAndProfilesNeverReachIt() async throws {
        let (server, base) = try await serve()
        for (name, dataStore) in [("private", store.ensureIncognitoProfile().dataStore), ("work", work.dataStore)] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "qd",
                                                               .value: name, .expires: Date().addingTimeInterval(3600)]))
            await dataStore.httpCookieStore.setCookie(cookie)
            cookiesToRemove.append((dataStore.httpCookieStore, cookie))
        }

        let controller = openQuarantine(base + "/probe")
        try await waitForTitle("cookie:no storage:no") { controller.tab }
        XCTAssertEqual(lastCookie(forPath: "/probe", on: server), .some(nil))
    }

    func testAWindowThePageOpensSharesItsQuarantine() async throws {
        let (_, base) = try await serve()
        let opener = openQuarantine(base + "/opener")
        try await waitForTitle("Opener") { opener.tab }

        _ = try await XCTUnwrap(opener.tab?.webView).evaluateJavaScript("window.openChild()")
        try await waitUntil("the page's window to open") { self.newQuickDetours().count == 2 }

        let child = try XCTUnwrap(newQuickDetours().first { $0 !== opener })
        XCTAssertTrue(child.isQuarantine)
        XCTAssertTrue(child.quarantine === opener.quarantine, "it keeps its opener, so it keeps the store")
        XCTAssertTrue(child.tab?.webView?.configuration.websiteDataStore === opener.quarantine?.dataStore)
    }

    // MARK: - Link tracking parameters

    func testAClickedLinkLosesItsTrackingParameters() async throws {
        let (server, base) = try await serve()
        let controller = openQuarantine(base + "/tracked")
        try await waitForTitle("Tracked") { controller.tab }

        _ = try await XCTUnwrap(controller.tab?.webView).evaluateJavaScript("document.getElementById('link').click()")
        try await waitForTitle("cookie:no storage:no") { controller.tab }

        XCTAssertEqual(controller.tab?.url?.query, "id=1")
        XCTAssertFalse(server.requestedPaths.contains { $0.contains("utm_") }, "\(server.requestedPaths)")
    }

    /// A server that redirects the clean address back to one with tracking
    /// parameters is let through the second time rather than looping
    /// (code review, TASK-194).
    func testARedirectBackToTrackingParametersDoesNotLoop() async throws {
        let (server, base) = try await serve()
        let controller = openQuarantine(base + "/bounce")
        try await waitForTitle("Bounced") { controller.tab }
        XCTAssertLessThanOrEqual(server.requestedPaths.filter { $0.hasPrefix("/bounce") }.count, 3,
                                 "\(server.requestedPaths)")
    }

    /// A page that sends the clean address straight back to its parameters
    /// with `location.replace` (no redirect to WebKit, no user gesture) is let
    /// through the second time; the page settles (code review, TASK-194
    /// follow-up).
    func testAClientRedirectBackToTrackingParametersSettles() async throws {
        let (server, base) = try await serve()
        let controller = openQuarantine(base + "/replace")
        try await waitForTitle("Replaced") { controller.tab }
        try await Task.sleep(nanoseconds: 500_000_000)
        let loads = server.requestedPaths.filter { $0.hasPrefix("/replace") }
        XCTAssertLessThanOrEqual(loads.count, 3, "\(loads)")
        XCTAssertEqual(controller.tab?.title, "Replaced")
    }

    /// A jump to an anchor of a page whose address kept its parameters is
    /// not turned into a load of the page without them (code review, TASK-194
    /// follow-up).
    func testAnAnchorJumpIsNotReloaded() async throws {
        let (server, base) = try await serve()
        let controller = openQuarantine(base + "/replace")
        try await waitForTitle("Replaced") { controller.tab }
        let webView = try XCTUnwrap(controller.tab?.webView)
        let requests = server.requestedPaths.count

        _ = try await webView.evaluateJavaScript("document.getElementById('anchor').click()")
        try await waitUntil("the anchor") { webView.url?.fragment == "section" }
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(webView.url?.query, "utm_source=loop", "the same document")
        let marker = try await webView.evaluateJavaScript("window.marker") as? String
        XCTAssertEqual(marker, "kept", "not reloaded")
        XCTAssertEqual(server.requestedPaths.count, requests, "\(server.requestedPaths)")
    }

    // MARK: - Cmd+click

    /// Only the user's Cmd+click opens another quarantine: a page's script
    /// clicking with Command from a timer (no user gesture) opens no window
    /// and no store (code review, TASK-194 follow-up). WebKit also hands the
    /// policy no modifiers for a synthetic click (measured 2026-10-25), so
    /// the click is an ordinary one: the page follows it in place.
    func testAScriptsCmdClickOpensNoQuarantine() async throws {
        let (_, base) = try await serve()
        let controller = openQuarantine(base + "/cmdclick?auto")
        try await waitUntil("the timer's click to land") {
            controller.tab?.url?.path == "/probe" && controller.tab?.isLoading == false
        }
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(newQuickDetours().count, 1, "no window from the page's timer")
    }

    // MARK: - Fingerprinting protections (WebKit SPI, when present)

    private static let fingerprintPage = """
        <html><head><title>Fingerprint</title><script>
        window.fingerprint = () => {
            const canvas = document.createElement('canvas');
            canvas.width = 200; canvas.height = 50;
            const g = canvas.getContext('2d');
            g.fillStyle = '#f60'; g.fillRect(10, 10, 100, 30);
            g.fillStyle = '#069'; g.font = '14px Helvetica'; g.fillText('quarantine', 2, 15);
            return JSON.stringify({ canvas: canvas.toDataURL(), screenWidth: screen.width });
        };
        </script></head><body>fingerprint</body></html>
        """

    private func fingerprint(in controller: QuickDetourWindowController) async throws -> (canvas: String, screenWidth: Int) {
        let json = try await XCTUnwrap(controller.tab?.webView).evaluateJavaScript("window.fingerprint()") as? String
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(json).utf8)) as? [String: Any])
        return (try XCTUnwrap(object["canvas"] as? String), try XCTUnwrap(object["screenWidth"] as? Int))
    }

    /// Measured on macOS 26.7: with WebKit's fingerprinting protections a
    /// canvas read back is noised per session, and `screen` reports the
    /// window's size rather than the display's.
    func testCanvasReadbackIsNoisedAndTheScreenIsTheWindow() async throws {
        guard Quarantine.privacyProtectionsAvailable(on: WKWebpagePreferences()) else {
            throw XCTSkip("this WebKit has no _networkConnectionIntegrityPolicy")
        }
        let server = try LoopbackHTTPServer(routes: ["/fp": Self.fingerprintPage])
        servers.append(server)
        let port = try await server.start()
        let url = "http://127.0.0.1:\(port)/fp"
        let first = openQuarantine(url)
        let second = openQuarantine(url)
        try await waitForTitle("Fingerprint") { first.tab }
        try await waitForTitle("Fingerprint") { second.tab }

        let a = try await fingerprint(in: first)
        let b = try await fingerprint(in: second)
        XCTAssertFalse(a.canvas == b.canvas, "the same drawing reads back differently in two quarantines")
        let displayWidth = Int(try XCTUnwrap(first.window?.screen ?? NSScreen.main).frame.width)
        let windowWidth = Int(try XCTUnwrap(first.window).frame.width)
        XCTAssertLessThanOrEqual(a.screenWidth, windowWidth, "the display's width (\(displayWidth)) is not reported")
    }

    // MARK: - Open in

    func testOpenInListsEveryProfilesSpacesAndEachReloads() throws {
        let controller = openQuarantine("https://quarantine-open-in.invalid/", sourceSpace: desk)
        let menu = controller.openInMenu

        XCTAssertEqual(menu.defaultTarget, .space(desk.id), "the space the link came from")
        XCTAssertTrue(menu.defaultReloads)
        XCTAssertTrue(menu.sections.contains { $0.profileID == work.id && $0.items.contains { $0.spaceID == desk.id } })
        XCTAssertTrue(menu.sections.allSatisfy { $0.items.allSatisfy(\.reloads) })
    }

    /// AC #3: the address loads fresh in a tab of the chosen space, the
    /// window closes, and neither the quarantined cookie nor its storage
    /// reaches the space.
    func testOpenInLoadsTheAddressFreshAndNoQuarantinedCookieOrStorageReachesTheSpace() async throws {
        let (server, base) = try await serve()
        let deskWindow = makeWindow(showing: desk)
        let controller = openQuarantine(base + "/set")
        try await waitForTitle("Set") { controller.tab }
        controller.load(URL(string: base + "/probe")!, typed: false)
        try await waitForTitle("cookie:yes storage:yes") { controller.tab }
        XCTAssertEqual(lastCookie(forPath: "/probe", on: server), "qd=quarantined")
        let probeRequests = server.requests.filter { $0.path == "/probe" }.count

        controller.open(in: .space(desk.id))

        XCTAssertFalse(isOpen(controller), "the quarantine window closes")
        let moved = try XCTUnwrap(desk.tabs.first { $0.url?.path == "/probe" }, "a tab in the chosen space")
        XCTAssertEqual(deskWindow.selectedTabID, moved.id)
        XCTAssertTrue(moved.webView?.configuration.websiteDataStore === work.dataStore, "the space's own store")
        XCTAssertFalse(moved.isQuarantined)
        try await waitForTitle("cookie:no storage:no") { moved }
        XCTAssertEqual(server.requests.filter { $0.path == "/probe" }.count, probeRequests + 1, "loaded fresh")
        XCTAssertEqual(lastCookie(forPath: "/probe", on: server), .some(nil), "no quarantined cookie sent")
        let cookies = await work.dataStore.httpCookieStore.allCookies()
        XCTAssertFalse(cookies.contains { $0.name == "qd" }, "none stored in the space's profile")
    }

    /// Open in closes the window, so a download still running is asked
    /// about first, as closing it is (code review, TASK-194).
    func testOpenInAsksBeforeCancellingARunningDownload() throws {
        let controller = openQuarantine("https://quarantine-open-in-download.invalid/page")
        let tabID = try XCTUnwrap(controller.tab?.id)
        let item = DownloadManager.shared.addManualItem(filename: "secret.zip", sourceURL: nil,
                                                        scope: .incognito(spaceID: tabID))
        defer { DownloadManager.shared.removeDownload(item) }
        let previous = QuickDetourWindowController.runPrivateDownloadCloseAlert
        defer { QuickDetourWindowController.runPrivateDownloadCloseAlert = previous }
        var asked = 0
        QuickDetourWindowController.runPrivateDownloadCloseAlert = { _ in asked += 1; return false }

        controller.open(in: .space(desk.id))
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(isOpen(controller), "Continue Downloading keeps the window")
        XCTAssertEqual(item.state, .downloading)
        XCTAssertTrue(desk.tabs.isEmpty)

        QuickDetourWindowController.runPrivateDownloadCloseAlert = { _ in asked += 1; return true }
        controller.open(in: .space(desk.id))
        XCTAssertEqual(asked, 2)
        XCTAssertFalse(isOpen(controller))
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(desk.tabs.first?.url?.host, "quarantine-open-in-download.invalid")
    }

    /// Open in asks about a running download, but cancels it only once the
    /// address has a tab: when nothing takes it, the window and its download
    /// stay (code review, TASK-194 follow-up).
    func testOpenInThatPlacesNothingKeepsTheWindowAndItsDownload() throws {
        let controller = openQuarantine("https://quarantine-open-in-fails.invalid/page")
        let tabID = try XCTUnwrap(controller.tab?.id)
        let item = DownloadManager.shared.addManualItem(filename: "kept.zip", sourceURL: nil,
                                                        scope: .incognito(spaceID: tabID))
        defer { DownloadManager.shared.removeDownload(item) }
        let previousAlert = QuickDetourWindowController.runPrivateDownloadCloseAlert
        defer { QuickDetourWindowController.runPrivateDownloadCloseAlert = previousAlert }
        QuickDetourWindowController.runPrivateDownloadCloseAlert = { _ in true }
        let previousPlacement = QuickDetourWindowController.placement
        defer { QuickDetourWindowController.placement = previousPlacement }
        QuickDetourWindowController.placement = { _, _, _ in nil }

        controller.open(in: .space(desk.id))

        XCTAssertTrue(isOpen(controller), "nothing took the page: the window stays")
        XCTAssertEqual(item.state, .downloading, "and so does its download")
    }

    /// The download question runs a modal session, during which the page can
    /// put up a sheet WebKit waits on: Open in then leaves everything as it
    /// was rather than close the window under it (code review, TASK-194
    /// follow-up).
    func testOpenInRefusesWhenASheetCameUpDuringTheDownloadQuestion() throws {
        let controller = openQuarantine("https://quarantine-open-in-sheet.invalid/page")
        let window = try XCTUnwrap(controller.window)
        let tabID = try XCTUnwrap(controller.tab?.id)
        let item = DownloadManager.shared.addManualItem(filename: "sheet.zip", sourceURL: nil,
                                                        scope: .incognito(spaceID: tabID))
        defer { DownloadManager.shared.removeDownload(item) }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                             backing: .buffered, defer: false)
        defer { if let parent = sheet.sheetParent { parent.endSheet(sheet) } }
        let previousAlert = QuickDetourWindowController.runPrivateDownloadCloseAlert
        defer { QuickDetourWindowController.runPrivateDownloadCloseAlert = previousAlert }
        QuickDetourWindowController.runPrivateDownloadCloseAlert = { _ in
            window.beginSheet(sheet)
            return true
        }

        controller.open(in: .space(desk.id))

        XCTAssertTrue(isOpen(controller), "the page's sheet is still waiting for an answer")
        XCTAssertEqual(item.state, .downloading)
        XCTAssertTrue(desk.tabs.isEmpty)
    }

    // MARK: - Downloads

    /// A download link with tracking parameters is a download, asked about,
    /// not a page loaded without them (code review, TASK-194 follow-up).
    func testATrackedDownloadLinkIsStillADownload() async throws {
        let (server, base) = try await serve()
        var asked: [QuarantineDownloadQuestion] = []
        QuickDetourWindowController.askQuarantineDownload = { question, _, answer in
            asked.append(question)
            answer(false)
        }
        let controller = openQuarantine(base + "/tracked-download")
        try await waitForTitle("Tracked download") { controller.tab }

        _ = try await XCTUnwrap(controller.tab?.webView).evaluateJavaScript("document.getElementById('file').click()")
        try await waitUntil("the question") { !asked.isEmpty }

        XCTAssertEqual(asked, [QuarantineDownloadQuestion(filename: "report.txt", host: "127.0.0.1")])
        XCTAssertEqual(controller.tab?.url?.path, "/tracked-download", "the page stays")
        XCTAssertFalse(server.requestedPaths.contains("/report.txt"), "\(server.requestedPaths)")
    }

    func testADownloadIsAskedAboutAndCancelledOnNo() async throws {
        let (_, base) = try await serve()
        var asked: [QuarantineDownloadQuestion] = []
        QuickDetourWindowController.askQuarantineDownload = { question, _, answer in
            asked.append(question)
            answer(false)
        }
        let controller = openQuarantine(base + "/download")
        try await waitForTitle("Download") { controller.tab }

        _ = try await XCTUnwrap(controller.tab?.webView).evaluateJavaScript("document.getElementById('file').click()")
        try await waitUntil("the question") { !asked.isEmpty }
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(asked, [QuarantineDownloadQuestion(filename: "report.txt", host: "127.0.0.1")])
        XCTAssertFalse(DownloadManager.shared.items.contains { $0.filename == "report.txt" && $0.sourceURL?.host == "127.0.0.1" },
                       "nothing listed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path), [], "no file")
    }

    func testADownloadIsSavedOnYes() async throws {
        let (_, base) = try await serve()
        var asked = 0
        QuickDetourWindowController.askQuarantineDownload = { _, _, answer in
            asked += 1
            answer(true)
        }
        let controller = openQuarantine(base + "/download")
        try await waitForTitle("Download") { controller.tab }

        _ = try await XCTUnwrap(controller.tab?.webView).evaluateJavaScript("document.getElementById('file').click()")
        let saved = downloadsDirectory.appendingPathComponent("report.txt")
        try await waitUntil("the file to be saved") {
            DownloadManager.shared.items.contains { $0.destinationURL == saved && $0.state == .completed }
        }

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try String(contentsOf: saved, encoding: .utf8), "quarantined report")
        let item = try XCTUnwrap(DownloadManager.shared.items.first { $0.destinationURL == saved })
        XCTAssertEqual(item.scope, .incognito(spaceID: try XCTUnwrap(controller.tab?.id)),
                       "listed as the quarantine's own, as a Private window's are")
    }
}
