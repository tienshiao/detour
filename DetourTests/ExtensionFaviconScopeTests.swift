import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-152: the favicons an extension can ask for
/// (`chrome.runtime.getURL('/_favicon/?pageUrl=…')`, served by
/// `FaviconSchemeHandler` on `detour-favicon://`) come from the calling
/// profile's history only, and only for an extension that holds `favicon` in
/// that profile.
///
/// Before the fix the handler looked a page up in the shared `historyURL`
/// table with no scope, and accepted the WebKit host of any extension loaded
/// in any profile; an icon instead of the transparent pixel told the caller
/// that some profile had visited the page (or its host). A second route, the
/// `favicon.lookup` polyfill message, answered the same question with no
/// permission check at all and handed back the icon's URL.
///
/// These tests go through the production wiring (`Profile.extensionController`,
/// `Profile.loadExtensionContext`, `Space.makeWebViewConfiguration`, the
/// `ExtensionManager` delegate for the worker transport), with a history
/// database of their own behind `ExtensionPolyfillHandler.historyDatabase` and
/// the icon download replaced, so nothing reads the real history or the
/// network.
///
/// What a caller observes is the image it gets: the stub icon is 4×4, "no
/// icon" is the 1×1 transparent pixel.
@MainActor
final class ExtensionFaviconScopeTests: XCTestCase {

    // MARK: - Fixture bookkeeping

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var openWebViews: [WKWebView] = []
    private var defaultFaviconFetch: ((URL, @escaping (Data?) -> Void) -> Void)!
    private let fetchedIconURLs = FetchLog()

    /// Profiles whose extension controller hosted a web view are kept alive for
    /// the rest of the test process (see `ExtensionHistoryScopeTests`).
    private static var retainedProfiles: [Profile] = []

    private final class FetchLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func record(_ url: URL) { lock.lock(); urls.append(url.absoluteString); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    override func setUp() async throws {
        try await super.setUp()
        defaultFaviconFetch = FaviconPNGLoader.shared.fetch
        FaviconPNGLoader.shared.resetForTesting()
        let log = fetchedIconURLs
        FaviconPNGLoader.shared.fetch = { url, completion in
            log.record(url)
            completion(Self.iconPNG)
        }
    }

    override func tearDown() async throws {
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
        for id in createdSpaceIDs {
            TabStore.shared.forceRemoveSpace(id: id)
        }
        createdSpaceIDs.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        FaviconPNGLoader.shared.fetch = defaultFaviconFetch
        FaviconPNGLoader.shared.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private static let iconSide = 4

    /// What every stubbed icon download returns.
    private static let iconPNG: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: iconSide, pixelsHigh: iconSide,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()

    /// The worker under test: the polyfill (a test loads the context straight
    /// into the profile, so nothing has prepended it the way an install does),
    /// then a listener for the two things a worker can try: fetch the
    /// `_favicon` URL, and send the retired `favicon.lookup` message over the
    /// worker's own bridge.
    private static let workerJS = ExtensionAPIPolyfill.polyfillJS + """

    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'faviconFetch') {
            const url = chrome.runtime.getURL('/_favicon/?pageUrl=' + encodeURIComponent(message.pageUrl));
            fetch(url).then((response) => response.arrayBuffer().then((buffer) => {
                sendResponse({ outcome: 'fetched', status: response.status, bytes: buffer.byteLength });
            })).catch((e) => sendResponse({ outcome: 'failed', message: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'rawLookup') {
            chrome.runtime.sendNativeMessage('detourPolyfill', {
                type: 'favicon.lookup', extensionID: chrome.runtime.id, params: { pageUrl: message.pageUrl }
            }, (response) => {
                const lastError = chrome.runtime.lastError;
                sendResponse({ response: response === undefined ? null : response,
                               lastError: lastError ? String(lastError.message) : null });
            });
            return true;
        }
        return false;
    });
    """

    /// An MV3 extension with a module service worker and one page, registered
    /// in `ExtensionManager` the way an installed extension is (the permission
    /// gate reads the manifest from there).
    private func makeExtension(permissions: [String]) async throws -> WebExtension {
        let id = "favicon-scope-\(UUID().uuidString.prefix(8))"
        let permissionsJSON = String(decoding: try JSONSerialization.data(withJSONObject: permissions),
                                     as: UTF8.self)
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Favicon Scope Test",
                "version": "1.0.0",
                "permissions": \(permissionsJSON),
                "background": { "service_worker": "background.js", "type": "module" }
            }
            """,
            files: [
                "background.js": Self.workerJS,
                "test.html": "<html><body><div id=\"test\">favicon scope page</div></body></html>",
            ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config)) // in-memory
    }

    /// A persistent profile with one space, its extension controller built and
    /// its handler reading `database`.
    private func makeProfile(_ name: String, database: HistoryDatabase) throws -> (profile: Profile, space: Space) {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        let space = TabStore.shared.addSpace(name: "\(name) Space", emoji: "F", colorHex: "#000000",
                                             profileID: profile.id)
        createdSpaceIDs.append(space.id)
        try useDatabase(database, in: profile)
        return (profile, space)
    }

    /// A Private profile of its own (a random id, never the built-in one whose
    /// rows other suites share), with the same `isIncognito` wiring.
    private func makePrivateProfile(_ name: String, database: HistoryDatabase) throws -> Profile {
        let profile = Profile(name: name, isIncognito: true)
        createdProfiles.append(profile)
        try useDatabase(database, in: profile)
        return profile
    }

    private func useDatabase(_ database: HistoryDatabase, in profile: Profile) throws {
        // Force the lazy controller, and with it the polyfill handler.
        _ = profile.extensionController
        try XCTUnwrap(profile.polyfillHandler, "extensionController must build a polyfill handler")
            .historyDatabase = database
    }

    private func seedVisit(_ db: HistoryDatabase, url: String, favicon: String, space: Space,
                           visitTime: Double) throws {
        try db.dbQueue.write { conn in
            let urlID = try Int64.fetchOne(conn, sql: """
                INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                VALUES (?, '', ?, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    faviconURL = excluded.faviconURL,
                    visitCount = visitCount + 1,
                    lastVisitTime = MAX(lastVisitTime, excluded.lastVisitTime)
                RETURNING id
                """, arguments: [url, favicon, visitTime])!
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title) VALUES (?, ?, ?, 0, '')
                """, arguments: [urlID, space.id.uuidString, visitTime])
        }
    }

    private static let onlyA = "https://only-a.example/notes"
    private static let onlyB = "https://only-b.example/payroll"
    private static let shared = "https://shared.example/inbox"
    /// Never visited, on a host only B visited: the same-host fallback's leak.
    private static let hostOfB = "https://only-b.example/"
    private static let never = "https://never-visited.example/"

    /// | URL | profile A | profile B |
    /// |---|---|---|
    /// | `onlyA` | visited | never |
    /// | `onlyB` | never | visited |
    /// | `shared` | visited | visited |
    private func seedTwoProfiles(_ db: HistoryDatabase, spaceA: Space, spaceB: Space) throws {
        try seedVisit(db, url: Self.onlyA, favicon: "https://only-a.example/icon.png", space: spaceA, visitTime: 100)
        try seedVisit(db, url: Self.onlyB, favicon: "https://only-b.example/icon.png", space: spaceB, visitTime: 200)
        try seedVisit(db, url: Self.shared, favicon: "https://shared.example/icon.png", space: spaceA, visitTime: 300)
        try seedVisit(db, url: Self.shared, favicon: "https://shared.example/icon.png", space: spaceB, visitTime: 400)
    }

    // MARK: Real-context round trips

    private func makePage(for context: WKWebExtensionContext) async throws -> WKWebView {
        let config = try XCTUnwrap(context.webViewConfiguration,
                                   "webViewConfiguration is nil — context not loaded in a controller")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        openWebViews.append(webView)
        try await loadAndWait(webView, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return webView
    }

    /// The extension loaded into `profile`, an extension page of it, and its
    /// worker awake.
    private func loadPage(_ ext: WebExtension, in profile: Profile) async throws
        -> (page: WKWebView, context: WKWebExtensionContext) {
        let context = try loadTestContext(ext, in: profile)
        let page = try await makePage(for: context)
        context.loadBackgroundContent { error in
            if let error { print("favicon scope: loadBackgroundContent failed: \(error)") }
        }
        try await waitUntil("the background worker of \(profile.name) to wake", timeout: 30) {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        return (page, context)
    }

    /// What an `<img>` in `webView` gets for `pageURL`: the icon's side in
    /// pixels (1 is the transparent pixel, i.e. no icon), or nil when the image
    /// did not load at all. With `host` the `detour-favicon://` URL is written
    /// by hand for that WebKit host; without it the page builds the URL the way
    /// an extension does, through `chrome.runtime.getURL`.
    private func iconSide(for pageURL: String, in webView: WKWebView, host: String? = nil,
                          file: StaticString = #filePath, line: UInt = #line) async throws -> Int? {
        let js = """
            const url = host
                ? 'detour-favicon://' + host + '/_favicon/?pageUrl=' + encodeURIComponent(pageUrl)
                : chrome.runtime.getURL('/_favicon/?pageUrl=' + encodeURIComponent(pageUrl));
            return await new Promise((resolve) => {
                const img = new Image();
                const timer = setTimeout(() => resolve(JSON.stringify({ outcome: 'timeout', url: url })), 8000);
                img.onload = () => {
                    clearTimeout(timer);
                    resolve(JSON.stringify({ outcome: 'loaded', width: img.naturalWidth, height: img.naturalHeight, url: url }));
                };
                img.onerror = () => { clearTimeout(timer); resolve(JSON.stringify({ outcome: 'error', url: url })); };
                img.src = url;
            });
        """
        let raw = try await webView.callAsyncJavaScript(js, arguments: ["pageUrl": pageURL, "host": host ?? ""],
                                                        contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string", file: file, line: line)
        let outcome = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertTrue((outcome["url"] as? String ?? "").hasPrefix("detour-favicon://"),
                      "the request must go to the favicon scheme: \(outcome)", file: file, line: line)
        guard outcome["outcome"] as? String == "loaded" else { return nil }
        XCTAssertEqual(outcome["width"] as? Int, outcome["height"] as? Int, file: file, line: line)
        return outcome["width"] as? Int
    }

    private func workerReply(_ message: [String: Any], via page: WKWebView,
                             file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let answer = try await askWorker(from: page, message: message)
        XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker", file: file, line: line)
        return try XCTUnwrap(answer["reply"] as? [String: Any], "the worker must answer: \(answer)",
                             file: file, line: line)
    }

    private static let icon = iconSide
    private static let noIcon = 1

    // MARK: - Isolation across two profiles

    /// AC #2: the same extension, holding `favicon`, in two profiles. Each
    /// gets the icons of the pages its own profile visited, and for a page —
    /// or a host — only the other profile visited exactly what it gets for a
    /// page nobody visited.
    func testAnExtensionPageGetsOnlyItsOwnProfilesFavicons() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["favicon"])
        let a = try makeProfile("Favicon Scope A", database: db)
        let b = try makeProfile("Favicon Scope B", database: db)
        try seedTwoProfiles(db, spaceA: a.space, spaceB: b.space)

        let pageA = try await loadPage(ext, in: a.profile).page
        let pageB = try await loadPage(ext, in: b.profile).page

        // POSITIVE: each profile's own pages, and the page both visited.
        let ownA = try await iconSide(for: Self.onlyA, in: pageA)
        XCTAssertEqual(ownA, Self.icon, "A visited it")
        let sharedA = try await iconSide(for: Self.shared, in: pageA)
        XCTAssertEqual(sharedA, Self.icon, "A visited it too")
        let ownB = try await iconSide(for: Self.onlyB, in: pageB)
        XCTAssertEqual(ownB, Self.icon, "B visited it")
        let hostB = try await iconSide(for: Self.hostOfB, in: pageB)
        XCTAssertEqual(hostB, Self.icon, "B visited a page of that host")

        // NEGATIVE: the other profile's page, its host, and a page nobody
        // visited all look the same.
        let neverA = try await iconSide(for: Self.never, in: pageA)
        XCTAssertEqual(neverA, Self.noIcon)
        let foreignA = try await iconSide(for: Self.onlyB, in: pageA)
        XCTAssertEqual(foreignA, Self.noIcon, "only B visited it: A must get what a never-visited page gets")
        let foreignHostA = try await iconSide(for: Self.hostOfB, in: pageA)
        XCTAssertEqual(foreignHostA, Self.noIcon, "only B visited that host")
        let foreignB = try await iconSide(for: Self.onlyA, in: pageB)
        XCTAssertEqual(foreignB, Self.noIcon, "only A visited it")

        // A refused lookup never reaches the network either: only the three
        // icons that were answered were downloaded.
        XCTAssertEqual(Set(fetchedIconURLs.all),
                       ["https://only-a.example/icon.png", "https://only-b.example/icon.png",
                        "https://shared.example/icon.png"])
    }

    /// The WebKit host in a `detour-favicon://` URL names an extension context
    /// of *one* profile. A page of profile B that writes profile A's host gets
    /// nothing — neither A's history nor its own: the host is not an extension
    /// of B.
    func testAnotherProfilesExtensionHostIsRefused() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["favicon"])
        let a = try makeProfile("Favicon Host A", database: db)
        let b = try makeProfile("Favicon Host B", database: db)
        try seedTwoProfiles(db, spaceA: a.space, spaceB: b.space)

        let loadedA = try await loadPage(ext, in: a.profile)
        let pageB = try await loadPage(ext, in: b.profile).page
        let hostA = try XCTUnwrap(loadedA.context.baseURL.host)

        // POSITIVE: A's host works where it belongs.
        let ownA = try await iconSide(for: Self.onlyA, in: loadedA.page, host: hostA)
        XCTAssertEqual(ownA, Self.icon)

        // NEGATIVE: from B's page it opens nothing.
        for pageURL in [Self.onlyA, Self.onlyB, Self.shared] {
            let side = try await iconSide(for: pageURL, in: pageB, host: hostA)
            XCTAssertEqual(side, Self.noIcon, "\(pageURL) through another profile's extension host")
        }
    }

    /// The tab route: `Space.makeWebViewConfiguration` registers the scheme so
    /// an extension frame inside a tab can show favicons. A tab answers for
    /// its own profile's extension hosts and its own profile's history.
    func testATabAnswersForItsOwnProfileOnly() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["favicon"])
        let a = try makeProfile("Favicon Tab A", database: db)
        let b = try makeProfile("Favicon Tab B", database: db)
        try seedTwoProfiles(db, spaceA: a.space, spaceB: b.space)
        let contextA = try await loadPage(ext, in: a.profile).context
        let contextB = try await loadPage(ext, in: b.profile).context
        let hostA = try XCTUnwrap(contextA.baseURL.host)
        let hostB = try XCTUnwrap(contextB.baseURL.host)

        func makeTab(in space: Space) async throws -> WKWebView {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300),
                                    configuration: space.makeWebViewConfiguration())
            openWebViews.append(webView)
            try await loadHTMLStringAndWait(webView, html: "<html><body>tab</body></html>", baseURL: nil)
            return webView
        }
        let tabA = try await makeTab(in: a.space)
        let tabB = try await makeTab(in: b.space)

        // POSITIVE: the frame's own profile, host and history.
        let ownA = try await iconSide(for: Self.onlyA, in: tabA, host: hostA)
        XCTAssertEqual(ownA, Self.icon)
        let ownB = try await iconSide(for: Self.onlyB, in: tabB, host: hostB)
        XCTAssertEqual(ownB, Self.icon)

        // NEGATIVE: the other profile's history, and the other profile's host.
        let foreignA = try await iconSide(for: Self.onlyB, in: tabA, host: hostA)
        XCTAssertEqual(foreignA, Self.noIcon, "A's tab, B's page")
        let foreignHost = try await iconSide(for: Self.onlyB, in: tabA, host: hostB)
        XCTAssertEqual(foreignHost, Self.noIcon, "A's tab naming B's extension host")
        let foreignHostOwnPage = try await iconSide(for: Self.onlyA, in: tabA, host: hostB)
        XCTAssertEqual(foreignHostOwnPage, Self.noIcon, "B's extension host is not an extension of A")
    }

    // MARK: - Permission gating

    /// AC #3: `favicon` is the permission Chrome requires for `_favicon`. An
    /// extension without it gets the transparent pixel for a page its own
    /// profile visited. The positive half is the isolation test above.
    func testAnExtensionWithoutTheFaviconPermissionGetsNoIcon() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage", "history"])
        let a = try makeProfile("Favicon Ungranted", database: db)
        try seedVisit(db, url: Self.onlyA, favicon: "https://only-a.example/icon.png", space: a.space, visitTime: 100)
        let page = try await loadPage(ext, in: a.profile).page

        let side = try await iconSide(for: Self.onlyA, in: page)
        XCTAssertEqual(side, Self.noIcon)
        XCTAssertEqual(fetchedIconURLs.all, [], "no lookup, so no download")
    }

    /// AC #3: the Private profile records no history and must learn nothing of
    /// anyone else's.
    func testAnExtensionInThePrivateProfileGetsNoIcon() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["favicon"])
        let a = try makeProfile("Favicon Private Neighbour", database: db)
        try seedVisit(db, url: Self.onlyA, favicon: "https://only-a.example/icon.png", space: a.space, visitTime: 100)
        let privateProfile = try makePrivateProfile("Favicon Private", database: db)
        let page = try await loadPage(ext, in: privateProfile).page

        for pageURL in [Self.onlyA, "https://only-a.example/", Self.never] {
            let side = try await iconSide(for: pageURL, in: page)
            XCTAssertEqual(side, Self.noIcon, "\(pageURL) from the Private profile")
        }
        let worker = try await workerReply(["type": "faviconFetch", "pageUrl": Self.onlyA], via: page)
        let workerNever = try await workerReply(["type": "faviconFetch", "pageUrl": Self.never], via: page)
        XCTAssertEqual(worker as NSDictionary, workerNever as NSDictionary)
        XCTAssertEqual(fetchedIconURLs.all, [])
    }

    // MARK: - The service worker

    /// The worker transport. A worker has no `<img>`; it can only `fetch` the
    /// `_favicon` URL. Measured 2026-10-04: that fetch rejects ("Load failed")
    /// for every page, yet the request does reach the scheme handler — with the
    /// scope taken out, the other profile's icon was downloaded for it. So the
    /// handler's answer is what must not differ: a page only another profile
    /// visited is indistinguishable from one nobody visited, down to no icon
    /// being fetched. Should the fetch ever return bytes, they are the scoped
    /// answer.
    func testTheServiceWorkerLearnsNothingAboutAnotherProfile() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["favicon"])
        let a = try makeProfile("Favicon Worker A", database: db)
        let b = try makeProfile("Favicon Worker B", database: db)
        try seedTwoProfiles(db, spaceA: a.space, spaceB: b.space)
        let pageA = try await loadPage(ext, in: a.profile).page
        _ = try await loadPage(ext, in: b.profile)

        let own = try await workerReply(["type": "faviconFetch", "pageUrl": Self.onlyA], via: pageA)
        let foreign = try await workerReply(["type": "faviconFetch", "pageUrl": Self.onlyB], via: pageA)
        let never = try await workerReply(["type": "faviconFetch", "pageUrl": Self.never], via: pageA)
        print("favicon scope: worker fetch — own: \(own), foreign: \(foreign), never: \(never)")

        XCTAssertEqual(foreign as NSDictionary, never as NSDictionary,
                       "the other profile's page must look like a page nobody visited")
        if own["outcome"] as? String == "fetched" {
            XCTAssertEqual(own["bytes"] as? Int, Self.iconPNG.count)
            XCTAssertEqual(foreign["bytes"] as? Int, FaviconPNGLoader.transparentPixel.count)
        }
        XCTAssertFalse(fetchedIconURLs.all.contains("https://only-b.example/icon.png"))
    }

    // MARK: - The retired favicon.lookup message

    /// `favicon.lookup` handed the icon's *URL* to any extension that sent the
    /// message, with no permission check and no scope; no polyfill API ever
    /// sent it. It is gone: both transports are refused, for an extension that
    /// holds `favicon` and a page its own profile visited.
    func testTheFaviconLookupMessageIsRefusedFromBothTransports() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["favicon"])
        let a = try makeProfile("Favicon Lookup", database: db)
        try seedVisit(db, url: Self.onlyA, favicon: "https://only-a.example/icon.png", space: a.space, visitTime: 100)
        let page = try await loadPage(ext, in: a.profile).page
        let refusal = "Unknown polyfill message type"

        // Extension page: webkit.messageHandlers.
        let fromPage = try await postRawPolyfillEnvelope(from: page, type: "favicon.lookup", claimedID: ext.id,
                                                         params: ["pageUrl": Self.onlyA])
        XCTAssertNil(fromPage.result, "favicon.lookup must not answer: \(String(describing: fromPage.result))")
        XCTAssertTrue((fromPage.error ?? "").range(of: refusal, options: .caseInsensitive) != nil,
                      "page: \(fromPage.error ?? "no error")")

        // Service worker: runtime.sendNativeMessage.
        let fromWorker = try await workerReply(["type": "rawLookup", "pageUrl": Self.onlyA], via: page)
        XCTAssertTrue(fromWorker["response"] is NSNull, "favicon.lookup must not answer: \(fromWorker)")
        XCTAssertTrue((fromWorker["lastError"] as? String ?? "").range(of: refusal, options: .caseInsensitive) != nil,
                      "worker: \(fromWorker)")
    }
}
