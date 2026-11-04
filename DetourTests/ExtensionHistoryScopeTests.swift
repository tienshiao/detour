import XCTest
import WebKit
import GRDB
@testable import Detour

/// TASK-138: `chrome.history.search` answers from the calling context's
/// profile only.
///
/// The handler used to read the shared `historyURL` table with no filter, so
/// an extension holding `history` in one profile read the URLs, titles and
/// visit counts of every other profile. These tests go through the production
/// wiring (`Profile.extensionController`, `Profile.loadExtensionContext`, the
/// `ExtensionManager` delegate for the worker transport) with the same
/// extension loaded into two profiles, and seed a history database of their
/// own through `ExtensionPolyfillHandler.historyDatabase` — nothing here reads
/// or writes the real history.
///
/// Three parts:
///  1. the query parser — which arguments are refused, with no WebKit at all;
///  2. the handler — scope, Private, permission and arguments through
///     `handleNativeMessage`, with real profiles and spaces;
///  3. real extension contexts — an extension page (`webkit.messageHandlers`)
///     and a service worker (`runtime.sendNativeMessage`), promise and callback
///     form, in both profiles.
nonisolated final class ExtensionHistoryScopeTests: XCTestCase {

    // MARK: - Fixture bookkeeping

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var createdSpaceIDs: [UUID] = []
    private var openWebViews: [WKWebView] = []
    private var previousLastActiveSpaceID: UUID?

    /// Profiles whose extension controller hosted a web view are kept alive for
    /// the rest of the test process: releasing one takes its process pool down
    /// with it, and WebKit traps when that happens inside an IPC dispatch (see
    /// `ExtensionPrivateStoreTests`).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
    }

    @MainActor override func tearDown() async throws {
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
        ExtensionManager.shared.lastActiveSpaceID = previousLastActiveSpaceID
        ExtensionManager.shared.permissionPromptAnswerOverride = nil
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            // Cascades to the permission rows a test saved (TASK-250).
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The worker under test: the polyfill (a test loads the context straight
    /// into the profile, so nothing has prepended it to the worker file the
    /// way an install does), then a listener that runs `chrome.history.search`
    /// in the promise form or the callback form and reports how it settled.
    /// `message.query` travels as JSON; a message with no `query` key calls
    /// `search(undefined)`.
    @MainActor private static let workerJS = ExtensionAPIPolyfill.polyfillJS + "\n" + gateJS + """

    const unhandled = [];
    self.addEventListener('unhandledrejection', (event) => {
        unhandled.push(String(event.reason && event.reason.message ? event.reason.message : event.reason));
    });
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'namespaceGate') {
            namespaceGate().then(
                (outcome) => sendResponse(outcome),
                (e) => sendResponse({ error: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'managementInfo') {
            managementInfo().then((outcome) => sendResponse(outcome));
            return true;
        }
        if (message.type === 'permissionsCall') {
            permissionsCall(message.method, message.details, message.form).then((outcome) => sendResponse(outcome));
            return true;
        }
        if (message.type === 'historyPromise') {
            let promise;
            try {
                promise = chrome.history.search(message.query);
            } catch (e) {
                sendResponse({ settled: 'threw', message: String(e && e.message ? e.message : e) });
                return true;
            }
            Promise.resolve(promise).then(
                (value) => sendResponse({ settled: 'resolved', value: value === undefined ? null : value }),
                (e) => sendResponse({ settled: 'rejected', message: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'historyCallback') {
            const outcome = {};
            const returned = chrome.history.search(message.query, function(...args) {
                outcome.argc = args.length;
                outcome.arg0 = args.length ? args[0] : null;
                const lastError = chrome.runtime.lastError;
                outcome.lastErrorInCallback = lastError ? String(lastError.message) : null;
                setTimeout(() => { outcome.unhandled = unhandled.slice(); sendResponse(outcome); }, 150);
            });
            outcome.returnedType = typeof returned;
            return true;
        }
        return false;
    });
    """

    /// What an extension can see of `chrome.history` and `chrome.management`,
    /// and how requests made past the namespaces — straight to the polyfill's
    /// transport — are answered, for the permission gates (TASK-251). Run the
    /// same way from the page and the worker.
    private static let gateJS = """
    async function managementInfo() {
        const pick = (info) => ({ id: info.id, permissions: info.permissions, hostPermissions: info.hostPermissions });
        const out = { self: pick(await chrome.management.getSelf()) };
        try { out.all = (await chrome.management.getAll()).map(pick); }
        catch (e) { out.allError = String(e && e.message ? e.message : e); }
        return out;
    }
    function permissionsCall(method, details, form) {
        const describe = (e) => String(e && e.message ? e.message : e);
        return new Promise((resolve) => {
            try {
                if (form === 'callback') {
                    chrome.permissions[method](details, function(...args) {
                        const lastError = chrome.runtime.lastError;
                        resolve(lastError
                            ? { settled: 'rejected', message: String(lastError.message), argc: args.length }
                            : { settled: 'resolved', value: args.length ? args[0] : null, argc: args.length });
                    });
                } else {
                    Promise.resolve(chrome.permissions[method](details)).then(
                        (value) => resolve({ settled: 'resolved', value: value === undefined ? null : value }),
                        (e) => resolve({ settled: 'rejected', message: describe(e) }));
                }
            } catch (e) {
                resolve({ settled: 'threw', message: describe(e) });
            }
        });
    }
    async function namespaceGate() {
        const settle = async (promise) => {
            try { return { resolved: await promise }; }
            catch (e) { return { rejected: String(e && e.message ? e.message : e) }; }
        };
        const out = {
            history: typeof chrome.history,
            browserHistory: typeof browser === 'undefined' ? 'no browser' : typeof browser.history,
            historyDiag: __detourPolyfillDiag.apis.history,
            management: typeof chrome.management,
            browserManagement: typeof browser === 'undefined' ? 'no browser' : typeof browser.management,
            managementMembers: chrome.management ? Object.keys(chrome.management).sort() : null
        };
        out.getSelf = chrome.management && chrome.management.getSelf
            ? await settle(chrome.management.getSelf().then((info) => info.id))
            : null;
        out.directSearch = await settle(globalThis.__detourPolyfillRequest('history.search', { query: { text: '' } }));
        out.directGetAll = await settle(globalThis.__detourPolyfillRequest('management.getAll', {}));
        return out;
    }
    """

    /// An MV3 extension with a module service worker and one page, registered
    /// in `ExtensionManager` the way an installed extension is (the handler's
    /// permission gate reads the manifest from there).
    @MainActor private func makeExtension(permissions: [String],
                                          optionalPermissions: [String] = [],
                                          hostPermissions: [String] = [],
                                          optionalHostPermissions: [String] = []) async throws -> WebExtension {
        let id = "history-scope-\(UUID().uuidString.prefix(8))"
        let permissionsJSON = String(decoding: try JSONSerialization.data(withJSONObject: permissions),
                                     as: UTF8.self)
        let optionalJSON = String(decoding: try JSONSerialization.data(withJSONObject: optionalPermissions),
                                  as: UTF8.self)
        let hostJSON = String(decoding: try JSONSerialization.data(withJSONObject: hostPermissions), as: UTF8.self)
        let optionalHostJSON = String(decoding: try JSONSerialization.data(withJSONObject: optionalHostPermissions),
                                      as: UTF8.self)
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "History Scope Test",
                "version": "1.0.0",
                "permissions": \(permissionsJSON),
                "optional_permissions": \(optionalJSON),
                "host_permissions": \(hostJSON),
                "optional_host_permissions": \(optionalHostJSON),
                "background": { "service_worker": "background.js", "type": "module" }
            }
            """,
            files: [
                "background.js": Self.workerJS,
                "test.html": "<html><body><div id=\"test\">history scope page</div></body></html>",
            ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    @MainActor private func makeDatabase() throws -> HistoryDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try HistoryDatabase(dbQueue: try DatabaseQueue(configuration: config)) // in-memory
    }

    /// A persistent profile with one space, its extension controller built and
    /// its handler reading `database`.
    @MainActor private func makeProfile(_ name: String, database: HistoryDatabase) throws -> (profile: Profile, space: Space) {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        let space = addSpace(for: profile, name: "\(name) Space")
        try useDatabase(database, in: profile)
        return (profile, space)
    }

    @MainActor private func addSpace(for profile: Profile, name: String) -> Space {
        let space = TabStore.shared.addSpace(name: name, emoji: "H", colorHex: "#000000", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
    }

    /// A Private profile of its own (a random id, never the built-in one whose
    /// rows other suites share), with the same `isIncognito` wiring.
    @MainActor private func makePrivateProfile(_ name: String, database: HistoryDatabase) throws -> Profile {
        let profile = Profile(name: name, isIncognito: true)
        createdProfiles.append(profile)
        try useDatabase(database, in: profile)
        return profile
    }

    @MainActor private func useDatabase(_ database: HistoryDatabase, in profile: Profile) throws {
        // Force the lazy controller, and with it the polyfill handler.
        _ = profile.extensionController
        try XCTUnwrap(profile.polyfillHandler, "extensionController must build a polyfill handler")
            .historyDatabase = database
    }

    /// Inserts a visit with a caller-chosen time, as `HistoryDatabaseTests`
    /// does: the shared `historyURL` row moves with every visit from anywhere,
    /// like the real upsert, so the aggregate and a profile's own values differ.
    @MainActor private func seedVisit(_ db: HistoryDatabase, url: String, title: String, space: String,
                           visitTime: Double, typed: Bool = false) throws {
        try db.dbQueue.write { conn in
            let urlID = try Int64.fetchOne(conn, sql: """
                INSERT INTO historyURL (url, title, faviconURL, visitCount, lastVisitTime)
                VALUES (?, ?, NULL, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = excluded.title,
                    visitCount = visitCount + 1,
                    lastVisitTime = MAX(lastVisitTime, excluded.lastVisitTime)
                RETURNING id
                """, arguments: [url, title, visitTime])!
            try conn.execute(sql: """
                INSERT INTO historyVisit (urlID, spaceID, visitTime, isTyped, title) VALUES (?, ?, ?, ?, ?)
                """, arguments: [urlID, space, visitTime, typed, title])
        }
    }

    private static let onlyA = "https://only-a.example/notes"
    private static let onlyB = "https://only-b.example/payroll"
    private static let shared = "https://shared.example/inbox"

    /// The history both profiles are tested against. `base` is a whole number
    /// of seconds, so the millisecond times an extension receives are exact.
    ///
    /// | URL | profile A | profile B |
    /// |---|---|---|
    /// | `onlyA` | 1 visit, base-500, "Only A notes" | never |
    /// | `onlyB` | never | 1 visit, base-400, "Payroll secrets" |
    /// | `shared` | 2 visits (1 typed), last base-200, "Inbox (2) - home" | 3 visits, last base-50, "Inbox (9) - work" |
    ///
    /// The shared `historyURL` row for `shared` therefore says: 5 visits, last
    /// at base-50, titled "Inbox (9) - work" — what profile A must never see.
    @MainActor private func seedTwoProfiles(_ db: HistoryDatabase, spaceA: Space, spaceB: Space, base: Double) throws {
        let a = spaceA.id.uuidString
        let b = spaceB.id.uuidString
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a, visitTime: base - 500)
        try seedVisit(db, url: Self.onlyB, title: "Payroll secrets", space: b, visitTime: base - 400)
        try seedVisit(db, url: Self.shared, title: "Inbox - home", space: a, visitTime: base - 300, typed: true)
        try seedVisit(db, url: Self.shared, title: "Inbox (2) - home", space: a, visitTime: base - 200)
        try seedVisit(db, url: Self.shared, title: "Inbox - work", space: b, visitTime: base - 150)
        try seedVisit(db, url: Self.shared, title: "Inbox (7) - work", space: b, visitTime: base - 100)
        try seedVisit(db, url: Self.shared, title: "Inbox (9) - work", space: b, visitTime: base - 50)
    }

    @MainActor private static func wholeSecondBase() -> Double {
        Date().timeIntervalSince1970.rounded(.down)
    }

    /// One history item as an extension receives it.
    @MainActor private struct Item: Equatable {
        var url: String
        var title: String
        var visitCount: Int
        var typedCount: Int
        var lastVisitTime: Double

        init?(_ value: Any) {
            guard let dict = value as? [String: Any],
                  let url = dict["url"] as? String,
                  let title = dict["title"] as? String,
                  let visitCount = (dict["visitCount"] as? NSNumber)?.intValue,
                  let typedCount = (dict["typedCount"] as? NSNumber)?.intValue,
                  let lastVisitTime = (dict["lastVisitTime"] as? NSNumber)?.doubleValue,
                  dict["id"] is String else { return nil }
            self.url = url
            self.title = title
            self.visitCount = visitCount
            self.typedCount = typedCount
            self.lastVisitTime = lastVisitTime
        }

        init(url: String, title: String, visitCount: Int, typedCount: Int, lastVisitTime: Double) {
            self.url = url
            self.title = title
            self.visitCount = visitCount
            self.typedCount = typedCount
            self.lastVisitTime = lastVisitTime
        }
    }

    @MainActor private func items(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [Item] {
        let array = try XCTUnwrap(value as? [Any], "expected an array of history items, got \(String(describing: value))",
                                  file: file, line: line)
        return try array.map { try XCTUnwrap(Item($0), "not a history item: \($0)", file: file, line: line) }
    }

    /// What profile A must get for `{ text: '' }`, newest of its own visits first.
    @MainActor private func expectedForA(base: Double) -> [Item] {
        [Item(url: Self.shared, title: "Inbox (2) - home", visitCount: 2, typedCount: 1,
              lastVisitTime: (base - 200) * 1000),
         Item(url: Self.onlyA, title: "Only A notes", visitCount: 1, typedCount: 0,
              lastVisitTime: (base - 500) * 1000)]
    }

    @MainActor private func expectedForB(base: Double) -> [Item] {
        [Item(url: Self.shared, title: "Inbox (9) - work", visitCount: 3, typedCount: 0,
              lastVisitTime: (base - 50) * 1000),
         Item(url: Self.onlyB, title: "Payroll secrets", visitCount: 1, typedCount: 0,
              lastVisitTime: (base - 400) * 1000)]
    }

    // MARK: Handler round trips

    /// Await one `handleNativeMessage` round trip for `history.search`.
    @MainActor private func search(_ handler: ExtensionPolyfillHandler, extensionID: String,
                        params: [String: Any]) async -> (result: Any?, error: String?) {
        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<BridgeReply, Never>) in
            handler.handleNativeMessage(
                ["type": "history.search", "extensionID": extensionID, "params": params],
                verifiedExtensionID: extensionID
            ) { result, error in
                continuation.resume(returning: BridgeReply(result: result, error: error?.localizedDescription))
            }
        }
        return (reply.result, reply.error)
    }

    @MainActor private func results(_ reply: (result: Any?, error: String?),
                         file: StaticString = #filePath, line: UInt = #line) throws -> [Item] {
        XCTAssertNil(reply.error, "history.search failed: \(reply.error ?? "")", file: file, line: line)
        return try items((reply.result as? [String: Any])?["results"], file: file, line: line)
    }

    // MARK: Real-context round trips

    @MainActor private func makePage(for context: WKWebExtensionContext) async throws -> WKWebView {
        let config = try XCTUnwrap(context.webViewConfiguration,
                                   "webViewConfiguration is nil — context not loaded in a controller")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        openWebViews.append(webView)
        try await loadAndWait(webView, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return webView
    }

    /// The extension loaded into `profile`, an extension page of it, and its
    /// worker awake.
    @MainActor private func loadPage(_ ext: WebExtension, in profile: Profile) async throws -> WKWebView {
        let context = try loadTestContext(ext, in: profile)
        let page = try await makePage(for: context)
        context.loadBackgroundContent { error in
            if let error { print("history scope: loadBackgroundContent failed: \(error)") }
        }
        try await waitUntil("the background worker of \(profile.name) to wake", timeout: 30) {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        return page
    }

    @MainActor private func evalObject(_ js: String, in webView: WKWebView) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// `chrome.history.search(<arguments>)` from the page itself, promise form.
    /// `arguments` is JS source, so a test can pass nothing at all.
    @MainActor private func pagePromise(_ arguments: String, in page: WKWebView) async throws -> [String: Any] {
        try await evalObject(promiseOutcomeJS("chrome.history.search(\(arguments))"), in: page)
    }

    /// The callback form from the page: `search(<arguments>, cb)`.
    @MainActor private func pageCallback(_ arguments: String, in page: WKWebView) async throws -> [String: Any] {
        try await evalObject(callbackOutcomeJS(call: "return chrome.history.search(\(arguments), cb);"), in: page)
    }

    /// One history call made by the worker, reported back through
    /// `runtime.sendMessage`. `query` nil sends no `query` key.
    @MainActor private func workerOutcome(_ form: String, query: Any?, via page: WKWebView,
                               file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        var message: [String: Any] = ["type": form]
        if let query { message["query"] = query }
        let answer = try await askWorker(from: page, message: message)
        XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker", file: file, line: line)
        return try XCTUnwrap(answer["reply"] as? [String: Any], "the worker must answer: \(answer)",
                             file: file, line: line)
    }

    /// The items a successful callback-form call from the page handed its callback.
    @MainActor private func callbackItems(_ outcome: [String: Any],
                               file: StaticString = #filePath, line: UInt = #line) throws -> [Item] {
        XCTAssertEqual(outcome["timedOut"] as? Bool, false, "the callback must run: \(outcome)", file: file, line: line)
        XCTAssertEqual(outcome["argc"] as? Int, 1, file: file, line: line)
        XCTAssertNil(outcome["lastErrorInCallback"] as? String, "no lastError on success: \(outcome)",
                     file: file, line: line)
        XCTAssertEqual(outcome["unhandled"] as? [String], [], file: file, line: line)
        let json = try XCTUnwrap(outcome["arg0"] as? String, file: file, line: line)
        return try items(try JSONSerialization.jsonObject(with: Data(json.utf8)), file: file, line: line)
    }

    /// Does `message` read exactly as the native refusal `expected`? Every
    /// leg — the page and the worker, the promise and the callback's
    /// `runtime.lastError` — gets the handler's text verbatim, without the
    /// "Invalid call to runtime.sendNativeMessage(). <Text>." rewrite WebKit
    /// applies to errors crossing `runtime.sendNativeMessage` (TASK-255).
    @MainActor private func carries(_ message: String, _ expected: String) -> Bool {
        message == expected
    }

    /// A callback-form call that must have failed: the callback ran with no
    /// arguments and `runtime.lastError` carried `expected`.
    @MainActor private func assertCallbackFailed(_ outcome: [String: Any], reading expected: String, _ what: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        if let timedOut = outcome["timedOut"] as? Bool {
            XCTAssertFalse(timedOut, "\(what): the callback must run on failure", file: file, line: line)
        }
        XCTAssertEqual(outcome["argc"] as? Int, 0, "\(what): a failed call hands the callback nothing: \(outcome)",
                       file: file, line: line)
        let message = outcome["lastErrorInCallback"] as? String ?? ""
        XCTAssertTrue(carries(message, expected),
                      "\(what): lastError should carry \"\(expected)\", got \"\(message)\"", file: file, line: line)
        XCTAssertEqual(outcome["unhandled"] as? [String], [], "\(what): no stray rejection", file: file, line: line)
    }

    @MainActor private func assertRejected(_ outcome: [String: Any], reading expected: String, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome["settled"] as? String, "rejected", "\(what): \(outcome)", file: file, line: line)
        let message = outcome["message"] as? String ?? ""
        XCTAssertTrue(carries(message, expected),
                      "\(what): the rejection should carry \"\(expected)\", got \"\(message)\"", file: file, line: line)
    }

    // MARK: - 1. The query parser

    /// The parser's clock in these tests: a fixed instant, so the default
    /// range is a number a test can state.
    private static let parserNow = 1_900_000_000.0
    private static let dayBeforeParserNow = parserNow - 86_400

    @MainActor private func parse(_ params: [String: Any]) -> Result<ExtensionPolyfillHandler.HistorySearchQuery,
                                                          ExtensionPolyfillHandler.PolyfillArgumentError> {
        ExtensionPolyfillHandler.historySearchQuery(from: params,
                                                    now: Date(timeIntervalSince1970: Self.parserNow))
    }

    @MainActor func testQueryParserAcceptsAChromeQuery() throws {
        let parsed = try parse([
            "query": ["text": "inbox", "maxResults": 25, "startTime": 1_000_000.0, "endTime": 2_500_000] as [String: Any],
        ]).get()
        XCTAssertEqual(parsed, .init(text: "inbox", maxResults: 25, startTime: 1000, endTime: 2500),
                       "times arrive in milliseconds and are stored in seconds")
    }

    @MainActor func testQueryParserAppliesChromesDefaults() throws {
        let parsed = try parse(["query": ["text": ""]]).get()
        XCTAssertEqual(parsed, .init(text: "", maxResults: 100, startTime: Self.dayBeforeParserNow, endTime: nil),
                       "100 results, from 24 hours before now, no upper bound")

        // An optional member sent as null is the same as leaving it out.
        let nulls = try parse([
            "query": ["text": "", "maxResults": NSNull(), "startTime": NSNull(), "endTime": NSNull()] as [String: Any],
        ]).get()
        XCTAssertEqual(nulls, parsed)

        // JS numbers arrive as doubles; a whole one is an integer.
        let whole = try parse(["query": ["text": "", "maxResults": 7.0] as [String: Any]]).get()
        XCTAssertEqual(whole.maxResults, 7)
    }

    /// TASK-153: Chrome's rule for `startTime`. Left out, it is 24 hours
    /// before now, whatever else the query says; given, it is taken as given,
    /// and 0 — how an extension asks for all of the history — is no lower
    /// bound at all.
    @MainActor func testQueryParserReadsAnOmittedStartTimeAsTheLastDay() throws {
        func startTime(_ query: [String: Any]) throws -> Double? {
            try parse(["query": query]).get().startTime
        }
        XCTAssertEqual(try startTime(["text": ""]), Self.dayBeforeParserNow)
        XCTAssertEqual(try startTime(["text": "inbox"]), Self.dayBeforeParserNow,
                       "a typed query has the same default")
        XCTAssertEqual(try startTime(["text": "", "maxResults": 5_000]), Self.dayBeforeParserNow,
                       "asking for more results does not widen the range")
        XCTAssertEqual(try startTime(["text": "", "endTime": 5_000_000]), Self.dayBeforeParserNow,
                       "endTime does not move the default: Chrome sets the two independently")

        XCTAssertEqual(try startTime(["text": "", "startTime": 1_000_000.0]), 1000, "given, it is taken as given")
        XCTAssertEqual(try startTime(["text": "", "startTime": (Self.parserNow + 60) * 1000]), Self.parserNow + 60)
        XCTAssertNil(try startTime(["text": "", "startTime": 0]), "0 is all of the history: no lower bound")
        XCTAssertNil(try startTime(["text": "", "startTime": 0.0]))
        XCTAssertNil(try startTime(["text": "", "startTime": -1]), "nothing was visited before 1970 either")
    }

    @MainActor func testQueryParserRefusesBadArguments() {
        let cases: [(params: [String: Any], expected: String)] = [
            ([:], "query must be an object"),
            (["query": "inbox"], "query must be an object"),
            (["query": NSNull()], "query must be an object"),
            (["query": [String: Any]()], "query.text must be a string"),
            (["query": ["text": 5]], "query.text must be a string"),
            (["query": ["text": NSNull()]], "query.text must be a string"),
            (["query": ["text": "", "maxResults": -1] as [String: Any]], "query.maxResults must be a non-negative integer"),
            (["query": ["text": "", "maxResults": 2.5] as [String: Any]], "query.maxResults must be a non-negative integer"),
            (["query": ["text": "", "maxResults": "ten"] as [String: Any]], "query.maxResults must be a non-negative integer"),
            (["query": ["text": "", "maxResults": true] as [String: Any]], "query.maxResults must be a non-negative integer"),
            (["query": ["text": "", "startTime": "yesterday"] as [String: Any]], "query.startTime must be a number"),
            (["query": ["text": "", "endTime": false] as [String: Any]], "query.endTime must be a number"),
            (["query": ["text": "", "endTime": Double.nan] as [String: Any]], "query.endTime must be a number"),
        ]
        for (params, expected) in cases {
            switch parse(params) {
            case .success(let parsed):
                XCTFail("\(params) must be refused, parsed as \(parsed)")
            case .failure(let error):
                XCTAssertTrue(error.message.contains(expected), "\(params): got \"\(error.message)\"")
            }
        }
    }

    // MARK: - 2. The handler

    /// AC #1 at the handler: profile A's request returns A's URLs with A's own
    /// count, last-visit time and title; profile B's the mirror image.
    @MainActor func testHandlerAnswersFromItsOwnProfileOnly() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope A", database: db)
        let b = try makeProfile("History Scope B", database: db)
        let base = Self.wholeSecondBase()
        try seedTwoProfiles(db, spaceA: a.space, spaceB: b.space, base: base)
        // The global "active" space is B's: A's handler must not follow it.
        ExtensionManager.shared.lastActiveSpaceID = b.space.id

        let handlerA = try XCTUnwrap(a.profile.polyfillHandler)
        let handlerB = try XCTUnwrap(b.profile.polyfillHandler)

        let allA = try results(await search(handlerA, extensionID: ext.id, params: ["query": ["text": ""]]))
        XCTAssertEqual(allA, expectedForA(base: base))
        let allB = try results(await search(handlerB, extensionID: ext.id, params: ["query": ["text": ""]]))
        XCTAssertEqual(allB, expectedForB(base: base))

        // NEGATIVE: B's URL and B's title find nothing from A.
        for text in ["payroll", "secrets", "work"] {
            let found = try results(await search(handlerA, extensionID: ext.id, params: ["query": ["text": text]]))
            XCTAssertEqual(found, [], "\"\(text)\" exists only in profile B's history")
        }
        // POSITIVE control: the same words from B.
        let payroll = try results(await search(handlerB, extensionID: ext.id, params: ["query": ["text": "payroll"]]))
        XCTAssertEqual(payroll.map(\.url), [Self.onlyB])
        let work = try results(await search(handlerB, extensionID: ext.id, params: ["query": ["text": "work"]]))
        XCTAssertEqual(work.map(\.title), ["Inbox (9) - work"])
    }

    /// A profile is every space that currently uses it.
    @MainActor func testHandlerScopeIsEverySpaceOfTheProfile() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Two Spaces", database: db)
        let second = addSpace(for: a.profile, name: "History Scope Second Space")
        let b = try makeProfile("History Scope Other", database: db)
        let base = Self.wholeSecondBase()
        try seedVisit(db, url: Self.shared, title: "First space", space: a.space.id.uuidString, visitTime: base - 300)
        try seedVisit(db, url: Self.shared, title: "Second space", space: second.id.uuidString, visitTime: base - 200)
        try seedVisit(db, url: Self.shared, title: "Other profile", space: b.space.id.uuidString, visitTime: base - 100)

        let handler = try XCTUnwrap(a.profile.polyfillHandler)
        let found = try results(await search(handler, extensionID: ext.id, params: ["query": ["text": ""]]))
        XCTAssertEqual(found, [Item(url: Self.shared, title: "Second space", visitCount: 2, typedCount: 0,
                                    lastVisitTime: (base - 200) * 1000)])
    }

    /// `startTime` / `endTime` are milliseconds, select by the profile's own
    /// visits, and `maxResults` caps the list.
    @MainActor func testHandlerAppliesTheTimeRangeAndTheLimitInScope() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Range A", database: db)
        let b = try makeProfile("History Scope Range B", database: db)
        let base = Self.wholeSecondBase()
        try seedTwoProfiles(db, spaceA: a.space, spaceB: b.space, base: base)
        let handler = try XCTUnwrap(a.profile.polyfillHandler)

        // Only B visited anything in the last 160 s.
        let recent = try results(await search(handler, extensionID: ext.id, params: [
            "query": ["text": "", "startTime": (base - 160) * 1000] as [String: Any],
        ]))
        XCTAssertEqual(recent, [], "B's visits inside the range must not qualify the URL for A")

        // A's visit at base-300 is inside [base-350, base-250); the row still
        // reports all of A's visits of the URL.
        let window = try results(await search(handler, extensionID: ext.id, params: [
            "query": ["text": "", "startTime": (base - 350) * 1000, "endTime": (base - 250) * 1000] as [String: Any],
        ]))
        XCTAssertEqual(window, [Item(url: Self.shared, title: "Inbox - home", visitCount: 2, typedCount: 1,
                                     lastVisitTime: (base - 200) * 1000)])

        let capped = try results(await search(handler, extensionID: ext.id, params: [
            "query": ["text": "", "maxResults": 1] as [String: Any],
        ]))
        XCTAssertEqual(capped.map(\.url), [Self.shared])
    }

    /// TASK-153: a query without `startTime` covers the 24 hours before now,
    /// as Chrome's does, with the handler's clock injected so the edge is
    /// exact. `startTime: 0` is how an extension asks for everything.
    @MainActor func testHandlerReadsAnOmittedStartTimeAsTheLastDay() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Default Range", database: db)
        let handler = try XCTUnwrap(a.profile.polyfillHandler)
        let now = 1_900_000_000.0
        handler.now = { Date(timeIntervalSince1970: now) }

        let space = a.space.id.uuidString
        let recent = "https://recent.example/"
        let edge = "https://edge.example/"
        let old = "https://old.example/"
        try seedVisit(db, url: recent, title: "Recent notes", space: space, visitTime: now - 3_600)
        try seedVisit(db, url: edge, title: "Edge notes", space: space, visitTime: now - 86_400)
        try seedVisit(db, url: old, title: "Old notes", space: space, visitTime: now - 86_401)

        func urls(_ query: [String: Any]) async throws -> [String] {
            try results(await search(handler, extensionID: ext.id, params: ["query": query])).map(\.url)
        }

        let listed = try await urls(["text": ""])
        XCTAssertEqual(listed, [recent, edge],
                       "a visit exactly 24 hours old is inside the range, one a second older is not")
        let nulled = try await urls(["text": "", "startTime": NSNull()])
        XCTAssertEqual(nulled, [recent, edge], "null is the same as leaving it out")
        let typed = try await urls(["text": "notes"])
        XCTAssertEqual(typed, [recent, edge], "a typed query has the same default")
        let more = try await urls(["text": "", "maxResults": 1_000])
        XCTAssertEqual(more, [recent, edge], "asking for more results does not widen the range")

        // POSITIVE control: the old visit is there for a query that asks for it.
        let everything = try await urls(["text": "", "startTime": 0])
        XCTAssertEqual(everything, [recent, edge, old], "startTime 0 is all of the history")
        let everythingTyped = try await urls(["text": "notes", "startTime": 0])
        XCTAssertEqual(everythingTyped, [recent, edge, old])
        let explicit = try await urls(["text": "", "startTime": (now - 86_401) * 1000])
        XCTAssertEqual(explicit, [recent, edge, old], "a given startTime is taken as given")

        // The default lower bound stands next to an explicit upper one.
        let capped = try await urls(["text": "", "endTime": (now - 7_200) * 1000])
        XCTAssertEqual(capped, [edge])
        let before = try await urls(["text": "", "endTime": (now - 86_401) * 1000])
        XCTAssertEqual(before, [], "the default range ends before it starts: nothing, as in Chrome")
    }

    /// The Private profile records no history, so its extensions get none —
    /// and never another profile's, whatever the database holds.
    @MainActor func testHandlerInThePrivateProfileGetsNothing() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Regular", database: db)
        let privateProfile = try makePrivateProfile("History Scope Private", database: db)
        let base = Self.wholeSecondBase()
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString, visitTime: base - 100)
        ExtensionManager.shared.lastActiveSpaceID = a.space.id

        let handler = try XCTUnwrap(privateProfile.polyfillHandler)
        for text in ["", "notes"] {
            let reply = await search(handler, extensionID: ext.id, params: ["query": ["text": text]])
            XCTAssertEqual(try results(reply), [], "Private must get an empty list for \"\(text)\"")
        }

        // POSITIVE control: the regular profile sees its visit.
        let regular = try XCTUnwrap(a.profile.polyfillHandler)
        let found = try results(await search(regular, extensionID: ext.id, params: ["query": ["text": ""]]))
        XCTAssertEqual(found.map(\.url), [Self.onlyA])
    }

    /// A profile no space uses has no history; the handler must not fall
    /// through to the last-active space's profile.
    @MainActor func testHandlerInAProfileWithoutSpacesGetsNothing() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Populated", database: db)
        let empty = TabStore.shared.addProfile(name: "History Scope Spaceless")
        createdProfiles.append(empty)
        try useDatabase(db, in: empty)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        ExtensionManager.shared.lastActiveSpaceID = a.space.id

        let handler = try XCTUnwrap(empty.polyfillHandler)
        let reply = await search(handler, extensionID: ext.id, params: ["query": ["text": ""]])
        XCTAssertEqual(try results(reply), [])
    }

    /// Permission gate, both ways: without `history` in the manifest the
    /// request is refused before anything is read.
    @MainActor func testHandlerRefusesAnExtensionWithoutTheHistoryPermission() async throws {
        let db = try makeDatabase()
        let without = try await makeExtension(permissions: ["storage"])
        let with = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Gate", database: db)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        let handler = try XCTUnwrap(a.profile.polyfillHandler)

        let refused = await search(handler, extensionID: without.id, params: ["query": ["text": ""]])
        XCTAssertNil(refused.result)
        XCTAssertEqual(refused.error, "history permission not declared")

        let allowed = try results(await search(handler, extensionID: with.id, params: ["query": ["text": ""]]))
        XCTAssertEqual(allowed.map(\.url), [Self.onlyA])
    }

    @MainActor func testHandlerRejectsBadArguments() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Arguments", database: db)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        let handler = try XCTUnwrap(a.profile.polyfillHandler)

        let cases: [(params: [String: Any], expected: String)] = [
            ([:], "query must be an object"),
            (["query": "notes"], "query must be an object"),
            (["query": [String: Any]()], "query.text must be a string"),
            (["query": ["text": "", "maxResults": -5] as [String: Any]], "query.maxResults must be a non-negative integer"),
            (["query": ["text": "", "startTime": "yesterday"] as [String: Any]], "query.startTime must be a number"),
        ]
        for (params, expected) in cases {
            let reply = await search(handler, extensionID: ext.id, params: params)
            XCTAssertNil(reply.result, "\(params) must not be answered with history")
            XCTAssertTrue((reply.error ?? "").contains(expected), "\(params): got \(reply.error ?? "no error")")
        }
    }

    // MARK: - 3. Real extension contexts

    /// AC #1 and #3: the same extension in two profiles, asked from an
    /// extension page and from its service worker, in the promise and the
    /// callback form. Each profile gets its own URLs with its own counts,
    /// times and titles, and nothing of the other's.
    @MainActor func testBothTransportsReturnOnlyTheCallingProfilesHistory() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Live A", database: db)
        let b = try makeProfile("History Scope Live B", database: db)
        let base = Self.wholeSecondBase()
        try seedTwoProfiles(db, spaceA: a.space, spaceB: b.space, base: base)
        // The global "active" space is B's throughout.
        ExtensionManager.shared.lastActiveSpaceID = b.space.id

        let pageA = try await loadPage(ext, in: a.profile)
        let pageB = try await loadPage(ext, in: b.profile)

        for (name, page, expected, foreign) in [
            ("profile A", pageA, expectedForA(base: base), "payroll"),
            ("profile B", pageB, expectedForB(base: base), "notes"),
        ] {
            // Extension page, promise form.
            let promise = try await pagePromise("{ text: '' }", in: page)
            XCTAssertEqual(promise["settled"] as? String, "resolved", "\(name), page promise: \(promise)")
            XCTAssertEqual(try items(promise["value"]), expected, "\(name), page promise")

            // Extension page, callback form.
            let callback = try await pageCallback("{ text: '' }", in: page)
            XCTAssertEqual(callback["returnedType"] as? String, "undefined", "\(name), page callback")
            XCTAssertEqual(try callbackItems(callback), expected, "\(name), page callback")

            // Service worker, promise form.
            let workerPromise = try await workerOutcome("historyPromise", query: ["text": ""], via: page)
            XCTAssertEqual(workerPromise["settled"] as? String, "resolved", "\(name), worker promise: \(workerPromise)")
            XCTAssertEqual(try items(workerPromise["value"]), expected, "\(name), worker promise")

            // Service worker, callback form.
            let workerCallback = try await workerOutcome("historyCallback", query: ["text": ""], via: page)
            XCTAssertEqual(workerCallback["argc"] as? Int, 1, "\(name), worker callback: \(workerCallback)")
            XCTAssertNil(workerCallback["lastErrorInCallback"] as? String, "\(name), worker callback")
            XCTAssertEqual(workerCallback["unhandled"] as? [String], [], "\(name), worker callback")
            XCTAssertEqual(try items(workerCallback["arg0"]), expected, "\(name), worker callback")

            // NEGATIVE: a word only the other profile's history has.
            let pageMiss = try await pagePromise("{ text: '\(foreign)' }", in: page)
            XCTAssertEqual(try items(pageMiss["value"]), [], "\(name), page: \"\(foreign)\" is the other profile's")
            let workerMiss = try await workerOutcome("historyPromise", query: ["text": foreign], via: page)
            XCTAssertEqual(try items(workerMiss["value"]), [], "\(name), worker: \"\(foreign)\" is the other profile's")
        }
    }

    /// TASK-153 in real contexts: `search({ text: '' })` answers with the last
    /// 24 hours, `startTime: 0` with everything, from an extension page and
    /// from the worker, in both forms. The clock is the real one here, so the
    /// two visits sit hours away from the edge.
    @MainActor func testAnOmittedStartTimeCoversTheLastDayFromBothTransports() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Live Range", database: db)
        let base = Self.wholeSecondBase()
        let space = a.space.id.uuidString
        try seedVisit(db, url: Self.onlyA, title: "Today", space: space, visitTime: base - 2 * 3_600)
        try seedVisit(db, url: Self.shared, title: "The day before", space: space, visitTime: base - 30 * 3_600)
        let today = [Item(url: Self.onlyA, title: "Today", visitCount: 1, typedCount: 0,
                          lastVisitTime: (base - 2 * 3_600) * 1000)]
        let everything = today + [Item(url: Self.shared, title: "The day before", visitCount: 1, typedCount: 0,
                                       lastVisitTime: (base - 30 * 3_600) * 1000)]

        let page = try await loadPage(ext, in: a.profile)

        // Extension page, promise and callback form.
        let promise = try await pagePromise("{ text: '' }", in: page)
        XCTAssertEqual(try items(promise["value"]), today, "page promise: \(promise)")
        let callback = try await pageCallback("{ text: '' }", in: page)
        XCTAssertEqual(try callbackItems(callback), today, "page callback")
        let allPromise = try await pagePromise("{ text: '', startTime: 0 }", in: page)
        XCTAssertEqual(try items(allPromise["value"]), everything, "page promise, startTime 0: \(allPromise)")
        let allCallback = try await pageCallback("{ text: '', startTime: 0 }", in: page)
        XCTAssertEqual(try callbackItems(allCallback), everything, "page callback, startTime 0")
        let typed = try await pagePromise("{ text: 'day' }", in: page)
        XCTAssertEqual(try items(typed["value"]), [], "page promise: the matching visit is older than a day")

        // Service worker, promise and callback form.
        let workerPromise = try await workerOutcome("historyPromise", query: ["text": ""], via: page)
        XCTAssertEqual(try items(workerPromise["value"]), today, "worker promise: \(workerPromise)")
        let workerCallback = try await workerOutcome("historyCallback", query: ["text": ""], via: page)
        XCTAssertNil(workerCallback["lastErrorInCallback"] as? String, "worker callback: \(workerCallback)")
        XCTAssertEqual(try items(workerCallback["arg0"]), today, "worker callback")
        let workerAll = try await workerOutcome("historyPromise", query: ["text": "", "startTime": 0] as [String: Any],
                                                via: page)
        XCTAssertEqual(try items(workerAll["value"]), everything, "worker promise, startTime 0: \(workerAll)")
        let workerAllCallback = try await workerOutcome("historyCallback",
                                                        query: ["text": "", "startTime": 0] as [String: Any], via: page)
        XCTAssertEqual(try items(workerAllCallback["arg0"]), everything, "worker callback, startTime 0")
        let workerTyped = try await workerOutcome("historyPromise", query: ["text": "day", "startTime": 0] as [String: Any],
                                                  via: page)
        XCTAssertEqual(try items(workerTyped["value"]).map(\.url), [Self.shared], "worker promise, typed, startTime 0")
    }

    /// AC #3, permission gating: an extension that does not declare `history`
    /// has no `chrome.history` in its page or its worker (TASK-251), and a
    /// request made past the namespace is refused from both transports, in a
    /// profile whose history has something to leak. The positive half is the
    /// test above, and `testDeclaredPermissionsInstallBothNamespaces`.
    @MainActor func testAnExtensionWithoutTheHistoryPermissionIsRefusedFromBothTransports() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"])
        let a = try makeProfile("History Scope Ungranted", database: db)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        let page = try await loadPage(ext, in: a.profile)

        for transport in [GateTransport.page, .worker] {
            let outcome = try await gate(via: transport, in: page)
            XCTAssertEqual(outcome["history"] as? String, "undefined", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["browserHistory"] as? String, "undefined", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["historyDiag"] as? String, "absent", "\(transport): \(outcome)")
            let direct = try XCTUnwrap(outcome["directSearch"] as? [String: Any], "\(transport): \(outcome)")
            XCTAssertNil(direct["resolved"], "\(transport): the request must be refused: \(outcome)")
            XCTAssertTrue(carries(direct["rejected"] as? String ?? "", "history permission not declared"),
                          "\(transport): \(outcome)")
        }
    }

    /// AC #3, bad arguments: rejected in the promise form, `runtime.lastError`
    /// in the callback form, from both transports — never answered with the
    /// whole history, which is what a lenient parse of `{}` used to do.
    @MainActor func testBadArgumentsAreRefusedFromBothTransportsInBothForms() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Bad Arguments", database: db)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        let page = try await loadPage(ext, in: a.profile)

        // (JS arguments for the page, the same query as JSON for the worker — nil
        // sends none — and the refusal.)
        let cases: [(js: String, json: Any?, expected: String)] = [
            ("{}", [String: Any](), "history.search: query.text must be a string"),
            ("{ text: 5 }", ["text": 5] as [String: Any], "history.search: query.text must be a string"),
            ("'notes'", "notes", "history.search: query must be an object"),
            ("{ text: '', maxResults: -1 }", ["text": "", "maxResults": -1] as [String: Any],
             "history.search: query.maxResults must be a non-negative integer"),
            ("{ text: '', startTime: 'yesterday' }", ["text": "", "startTime": "yesterday"] as [String: Any],
             "history.search: query.startTime must be a number"),
        ]
        for (js, json, expected) in cases {
            assertRejected(try await pagePromise(js, in: page), reading: expected, "page promise \(js)")
            assertCallbackFailed(try await pageCallback(js, in: page), reading: expected, "page callback \(js)")
            assertRejected(try await workerOutcome("historyPromise", query: json, via: page),
                           reading: expected, "worker promise \(js)")
            assertCallbackFailed(try await workerOutcome("historyCallback", query: json, via: page),
                                 reading: expected, "worker callback \(js)")
        }

        // No query at all: the polyfill sends an empty object in its place.
        assertRejected(try await pagePromise("", in: page), reading: "history.search: query.text must be a string",
                       "page promise, no arguments")
        assertRejected(try await workerOutcome("historyPromise", query: nil, via: page),
                       reading: "history.search: query.text must be a string", "worker promise, no arguments")

        // POSITIVE control: the same page and worker answer a valid query.
        let good = try await pagePromise("{ text: 'notes', maxResults: 5 }", in: page)
        XCTAssertEqual(try items(good["value"]).map(\.url), [Self.onlyA])
        let goodWorker = try await workerOutcome("historyPromise", query: ["text": "notes", "maxResults": 5] as [String: Any], via: page)
        XCTAssertEqual(try items(goodWorker["value"]).map(\.url), [Self.onlyA])
    }

    /// TASK-255: one native error reads the same from the page and the worker,
    /// in the promise rejection and in the callback's `runtime.lastError` —
    /// the handler's own text, without WebKit's "Invalid call to
    /// runtime.sendNativeMessage()." prefix, its capital or its full stop.
    /// A permission refusal (history declared only as optional, not granted)
    /// and a bad-argument refusal.
    @MainActor func testANativeErrorReadsTheSameFromBothTransportsInBothForms() async throws {
        let db = try makeDatabase()
        let refused = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history"])
        let granted = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Error Text", database: db)
        installTestExtension(refused, in: AppDatabase.shared)
        let refusedPage = try await loadPage(refused, in: a.profile)
        let grantedPage = try await loadPage(granted, in: a.profile)

        let cases: [(page: WKWebView, js: String, json: [String: Any], expected: String)] = [
            (refusedPage, "{ text: '' }", ["text": ""], Refusal.optionalNotGranted.text("history")),
            (grantedPage, "{ text: 5 }", ["text": 5], "history.search: query.text must be a string"),
        ]
        for (page, js, json, expected) in cases {
            let pagePromiseOutcome = try await pagePromise(js, in: page)
            let pageCallbackOutcome = try await pageCallback(js, in: page)
            let workerPromiseOutcome = try await workerOutcome("historyPromise", query: json, via: page)
            let workerCallbackOutcome = try await workerOutcome("historyCallback", query: json, via: page)
            let texts = [
                "page promise": pagePromiseOutcome["message"] as? String,
                "page callback": pageCallbackOutcome["lastErrorInCallback"] as? String,
                "worker promise": workerPromiseOutcome["message"] as? String,
                "worker callback": workerCallbackOutcome["lastErrorInCallback"] as? String,
            ]
            for (leg, text) in texts {
                XCTAssertEqual(text, expected, "\(leg) \(js): \(texts)")
                XCTAssertFalse(text?.contains("Invalid call to") ?? false, "\(leg) \(js): \(texts)")
            }
            XCTAssertEqual(pagePromiseOutcome["settled"] as? String, "rejected", "page promise \(js)")
            XCTAssertEqual(workerPromiseOutcome["settled"] as? String, "rejected", "worker promise \(js)")
            for (leg, outcome) in [("page callback", pageCallbackOutcome), ("worker callback", workerCallbackOutcome)] {
                XCTAssertEqual(outcome["argc"] as? Int, 0, "\(leg) \(js): \(outcome)")
                XCTAssertEqual(outcome["unhandled"] as? [String], [], "\(leg) \(js): \(outcome)")
            }
        }
    }

    /// An extension running in the Private profile gets an empty list from
    /// both transports while a regular profile has history to leak.
    @MainActor func testAnExtensionInThePrivateProfileGetsNoHistoryFromEitherTransport() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Beside Private", database: db)
        let privateProfile = try makePrivateProfile("History Scope Live Private", database: db)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        ExtensionManager.shared.lastActiveSpaceID = a.space.id

        let page = try await loadPage(ext, in: privateProfile)

        let promise = try await pagePromise("{ text: '' }", in: page)
        XCTAssertEqual(promise["settled"] as? String, "resolved", "page promise: \(promise)")
        XCTAssertEqual(try items(promise["value"]), [])
        let callback = try await pageCallback("{ text: 'notes' }", in: page)
        XCTAssertEqual(try callbackItems(callback), [])

        let worker = try await workerOutcome("historyPromise", query: ["text": ""], via: page)
        XCTAssertEqual(worker["settled"] as? String, "resolved", "worker promise: \(worker)")
        XCTAssertEqual(try items(worker["value"]), [])
    }

    // MARK: - 4. Namespace gates (TASK-251)

    private enum GateTransport { case page, worker }

    /// `namespaceGate` from `transport`.
    @MainActor private func gate(via transport: GateTransport, in page: WKWebView,
                                 file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let object: [String: Any]
        switch transport {
        case .page:
            object = try await evalObject(Self.gateJS + "\nreturn JSON.stringify(await namespaceGate());", in: page)
        case .worker:
            object = try await workerOutcome("namespaceGate", query: nil, via: page, file: file, line: line)
        }
        XCTAssertNil(object["error"], "\(transport): \(object)", file: file, line: line)
        return object
    }

    /// NEGATIVE: without the `management` permission the page and the worker
    /// see a `chrome.management` holding the three permission-free methods
    /// (Chromium's `_api_features.json`: getSelf, uninstallSelf,
    /// getPermissionWarningsByManifest) and getSelf answers; a
    /// `management.getAll` made past the
    /// namespace is refused. With neither permission there is no history
    /// namespace either, which also shows WebKit vends neither of its own.
    @MainActor func testWithoutTheManagementPermissionOnlyThePermissionFreeMethodsAreThere() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"])
        let a = try makeProfile("Management Gate Denied", database: db)
        let page = try await loadPage(ext, in: a.profile)

        for transport in [GateTransport.page, .worker] {
            let outcome = try await gate(via: transport, in: page)
            XCTAssertEqual(outcome["management"] as? String, "object", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["browserManagement"] as? String, "object", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["managementMembers"] as? [String],
                           ["getPermissionWarningsByManifest", "getSelf", "uninstallSelf"], "\(transport): \(outcome)")
            XCTAssertEqual((outcome["getSelf"] as? [String: Any])?["resolved"] as? String, ext.id,
                           "\(transport): \(outcome)")
            let direct = try XCTUnwrap(outcome["directGetAll"] as? [String: Any], "\(transport): \(outcome)")
            XCTAssertNil(direct["resolved"], "\(transport): the request must be refused: \(outcome)")
            XCTAssertTrue(carries(direct["rejected"] as? String ?? "", "management permission not declared"),
                          "\(transport): \(outcome)")
        }
    }

    /// POSITIVE: an extension that declares `history` and `management` gets
    /// both whole namespaces under both names in its page and its worker, and
    /// requests past them are served.
    @MainActor func testDeclaredPermissionsInstallBothNamespaces() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history", "management"])
        let a = try makeProfile("Namespace Gate Allowed", database: db)
        let page = try await loadPage(ext, in: a.profile)

        for transport in [GateTransport.page, .worker] {
            let outcome = try await gate(via: transport, in: page)
            XCTAssertEqual(outcome["history"] as? String, "object", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["browserHistory"] as? String, "object", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["historyDiag"] as? String, "function", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["management"] as? String, "object", "\(transport): \(outcome)")
            XCTAssertEqual(outcome["managementMembers"] as? [String],
                           ["getAll", "getPermissionWarningsByManifest", "getSelf", "onDisabled", "onEnabled", "onInstalled",
                        "onUninstalled", "setEnabled", "uninstallSelf"],
                           "\(transport): \(outcome)")
            XCTAssertEqual((outcome["getSelf"] as? [String: Any])?["resolved"] as? String, ext.id,
                           "\(transport): \(outcome)")
            let search = try XCTUnwrap(outcome["directSearch"] as? [String: Any], "\(transport): \(outcome)")
            XCTAssertNotNil((search["resolved"] as? [String: Any])?["results"], "\(transport): \(outcome)")
            let getAll = try XCTUnwrap(outcome["directGetAll"] as? [String: Any], "\(transport): \(outcome)")
            XCTAssertNotNil(getAll["resolved"] as? [Any], "\(transport): \(outcome)")
        }
    }

    // MARK: - 5. Optional permissions granted at runtime (TASK-250)

    /// The full management namespace, as `testDeclaredPermissionsInstallBothNamespaces` lists it.
    private static let fullManagement =
        ["getAll", "getPermissionWarningsByManifest", "getSelf", "onDisabled", "onEnabled", "onInstalled",
                        "onUninstalled", "setEnabled", "uninstallSelf"]

    /// Saved decisions for `keys`, as a prompt or the Settings switch leaves
    /// them. The rows reference the extension's own row, so that is saved
    /// first; tearDown's `deleteExtension` removes both.
    @MainActor private func saveDecisions(_ keys: [String], of ext: WebExtension, status: ExtensionPermissionStatus) {
        installTestExtension(ext, in: AppDatabase.shared)
        AppDatabase.shared.savePermissions(keys.map {
            ExtensionPermissionRecord(extensionID: ext.id, key: $0, type: .apiPermission, status: status)
        })
        XCTAssertEqual(AppDatabase.shared.loadPermissions(extensionID: ext.id).count, keys.count, "the rows were saved")
    }

    /// The three refusals of a call whose permission is not active (TASK-260).
    private enum Refusal {
        case notDeclared, optionalNotGranted, denied
        func text(_ permission: String) -> String {
            switch self {
            case .notDeclared: "\(permission) permission not declared"
            case .optionalNotGranted: "\(permission) permission is optional and has not been granted"
            case .denied: "\(permission) permission denied by the user"
            }
        }
    }

    /// Both namespaces are there (they are built at injection, before any
    /// grant can arrive) and the requests made past them are `served` or
    /// refused, from the page and from the worker.
    @MainActor private func assertOptionalGate(served: Bool, in page: WKWebView, _ label: String,
                                               refusal: Refusal = .optionalNotGranted,
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        for transport in [GateTransport.page, .worker] {
            let outcome = try await gate(via: transport, in: page, file: file, line: line)
            let where_ = "\(label), \(transport): \(outcome)"
            XCTAssertEqual(outcome["history"] as? String, "object", where_, file: file, line: line)
            XCTAssertEqual(outcome["browserHistory"] as? String, "object", where_, file: file, line: line)
            XCTAssertEqual(outcome["managementMembers"] as? [String], Self.fullManagement, where_, file: file, line: line)
            let search = try XCTUnwrap(outcome["directSearch"] as? [String: Any], where_, file: file, line: line)
            let getAll = try XCTUnwrap(outcome["directGetAll"] as? [String: Any], where_, file: file, line: line)
            if served {
                XCTAssertNotNil((search["resolved"] as? [String: Any])?["results"], where_, file: file, line: line)
                XCTAssertNotNil(getAll["resolved"] as? [Any], where_, file: file, line: line)
            } else {
                XCTAssertNil(search["resolved"], "must be refused: \(where_)", file: file, line: line)
                XCTAssertTrue(carries(search["rejected"] as? String ?? "", refusal.text("history")),
                              where_, file: file, line: line)
                XCTAssertNil(getAll["resolved"], "must be refused: \(where_)", file: file, line: line)
                XCTAssertTrue(carries(getAll["rejected"] as? String ?? "", refusal.text("management")),
                              where_, file: file, line: line)
            }
        }
    }

    /// NEGATIVE, then POSITIVE, then NEGATIVE in one running context: an
    /// extension that lists `history` and `management` only as optional is
    /// refused until the user grants them, is served from the same page and
    /// worker as soon as the grant is made — through the Settings switch,
    /// `setPermissionDecision`, the scriptable approval path, which applies the
    /// grant to every loaded context — and is refused again once the switch is
    /// turned off. Chrome likewise updates the bindings of running contexts on
    /// a permission change.
    @MainActor func testOptionalHistoryAndManagementFollowTheLiveGrant() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history", "management"])
        let a = try makeProfile("Optional Gate Live", database: db)
        installTestExtension(ext, in: AppDatabase.shared)
        let page = try await loadPage(ext, in: a.profile)

        try await assertOptionalGate(served: false, in: page, "before the grant")
        // The namespace is there before the grant, so the public call itself
        // must refuse in both forms: a rejection, and a callback with lastError.
        // The refusal says the permission is optional and not granted, not
        // that it is undeclared (TASK-260).
        assertRejected(try await pagePromise("{ text: '' }", in: page),
                       reading: Refusal.optionalNotGranted.text("history"), "promise, before the grant")
        assertCallbackFailed(try await pageCallback("{ text: '' }", in: page),
                             reading: Refusal.optionalNotGranted.text("history"), "callback, before the grant")

        for key in ["history", "management"] {
            ExtensionManager.shared.setPermissionDecision(extensionID: ext.id, key: key, type: .apiPermission, granted: true)
        }
        try await assertOptionalGate(served: true, in: page, "after the grant")
        let granted = try await pagePromise("{ text: '' }", in: page)
        XCTAssertEqual(granted["settled"] as? String, "resolved", "promise, after the grant: \(granted)")

        for key in ["history", "management"] {
            ExtensionManager.shared.setPermissionDecision(extensionID: ext.id, key: key, type: .apiPermission, granted: false)
        }
        try await assertOptionalGate(served: false, in: page, "after the revocation", refusal: .denied)
    }

    /// POSITIVE, new context: a grant saved earlier is restored when the
    /// context loads, although WebKit leaves both names out of its own
    /// optional permissions, so the page and the worker are served at once.
    @MainActor func testSavedOptionalGrantIsRestoredIntoANewContext() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history", "management"])
        XCTAssertFalse(ext.askablePermissions.contains(WKWebExtension.Permission(rawValue: "history")),
                       "WebKit does not parse history; the restore must add it itself")
        saveDecisions(["history", "management"], of: ext, status: .granted)
        let a = try makeProfile("Optional Gate Restored", database: db)
        let page = try await loadPage(ext, in: a.profile)

        try await assertOptionalGate(served: true, in: page, "restored grant")
    }

    /// NEGATIVE, new context: a saved denial is restored as a denial, and a
    /// grant in another profile does not reach this one.
    @MainActor func testSavedOptionalDenialIsRefusedInANewContext() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history", "management"])
        saveDecisions(["history", "management"], of: ext, status: .denied)
        let a = try makeProfile("Optional Gate Denied A", database: db)
        let pageA = try await loadPage(ext, in: a.profile)
        let b = try makeProfile("Optional Gate Denied B", database: db)
        let pageB = try await loadPage(ext, in: b.profile)
        try XCTUnwrap(b.profile.extensionContext(for: ext.id))
            .setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "history"))

        try await assertOptionalGate(served: false, in: pageA, "saved denial", refusal: .denied)
        let outcomeB = try await gate(via: .page, in: pageB)
        XCTAssertNotNil(((outcomeB["directSearch"] as? [String: Any])?["resolved"] as? [String: Any])?["results"],
                        "the grant in B serves B: \(outcomeB)")
    }

    // MARK: - 6. Required permissions switched off in Settings (TASK-259)

    /// POSITIVE, NEGATIVE, POSITIVE, NEGATIVE: an extension that requires
    /// `history` and `management` is served while their install-time grants
    /// stand, refused from the page and the worker once the Settings switch
    /// (`setPermissionDecision`, the call the pane makes) turns them off,
    /// served again when it turns them back on, and still refused after a
    /// context reload once switched off, because the saved denial is restored.
    /// The saved row of a required permission is never deleted (TASK-258).
    @MainActor func testRequiredHistoryAndManagementFollowTheSettingsSwitch() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history", "management"])
        // What install records for the manifest's permissions.
        saveDecisions(["history", "management"], of: ext, status: .granted)
        let a = try makeProfile("Required Gate Switch", database: db)
        let page = try await loadPage(ext, in: a.profile)

        try await assertOptionalGate(served: true, in: page, "install-time grant")

        func setSwitch(_ on: Bool) {
            for key in ["history", "management"] {
                ExtensionManager.shared.setPermissionDecision(extensionID: ext.id, key: key,
                                                              type: .apiPermission, granted: on)
            }
        }
        setSwitch(false)
        try await assertOptionalGate(served: false, in: page, "switched off", refusal: .denied)
        assertRejected(try await pagePromise("{ text: '' }", in: page),
                       reading: Refusal.denied.text("history"), "promise, switched off")
        assertCallbackFailed(try await pageCallback("{ text: '' }", in: page),
                             reading: Refusal.denied.text("history"), "callback, switched off")

        setSwitch(true)
        try await assertOptionalGate(served: true, in: page, "switched on again")

        setSwitch(false)
        a.profile.unloadExtension(id: ext.id)
        let reloaded = try await loadPage(ext, in: a.profile)
        try await assertOptionalGate(served: false, in: reloaded, "switched off, after a reload", refusal: .denied)
        for key in ["history", "management"] {
            XCTAssertEqual(AppDatabase.shared.permissionStatus(extensionID: ext.id, key: key, type: .apiPermission),
                           .denied, "the denial of required \(key) is kept")
        }
    }

    /// NEGATIVE, new context: a required permission's saved denial is restored
    /// into a context loaded later, while an extension with the same manifest
    /// and no decision at all is served, as before.
    @MainActor func testSavedDenialOfRequiredHistoryIsRefusedInANewContext() async throws {
        let db = try makeDatabase()
        let denied = try await makeExtension(permissions: ["history", "management"])
        saveDecisions(["history", "management"], of: denied, status: .denied)
        let undecided = try await makeExtension(permissions: ["history", "management"])
        let a = try makeProfile("Required Gate Denied", database: db)

        try await assertOptionalGate(served: false, in: try await loadPage(denied, in: a.profile), "saved denial",
                                     refusal: .denied)
        try await assertOptionalGate(served: true, in: try await loadPage(undecided, in: a.profile), "no decision")
    }

    // MARK: - 7. permissions.request, contains and remove for history and management (TASK-260)

    private enum CallForm: String { case promise, callback }

    /// `chrome.permissions[method]({ permissions })` from `transport`, in
    /// `form`: `settled` is "resolved" (with `value`) or "rejected" (with
    /// `message`; for the callback form that is `runtime.lastError`).
    @MainActor private func permissionsCall(_ method: String, _ permissions: [String], via transport: GateTransport,
                                            _ form: CallForm = .promise, in page: WKWebView,
                                            file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let details: [String: Any] = ["permissions": permissions]
        switch transport {
        case .page:
            let raw = try await page.callAsyncJavaScript(
                Self.gateJS + "\nreturn JSON.stringify(await permissionsCall(method, details, form));",
                arguments: ["method": method, "details": details, "form": form.rawValue], contentWorld: .page)
            let json = try XCTUnwrap(raw as? String, "expected a JSON string", file: file, line: line)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                                 file: file, line: line)
        case .worker:
            let answer = try await askWorker(from: page, message: [
                "type": "permissionsCall", "method": method, "details": details, "form": form.rawValue,
            ])
            XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker", file: file, line: line)
            return try XCTUnwrap(answer["reply"] as? [String: Any], "the worker must answer: \(answer)",
                                 file: file, line: line)
        }
    }

    /// The call resolved with `expected`.
    @MainActor private func assertAnswer(_ outcome: [String: Any], _ expected: Bool, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome["settled"] as? String, "resolved", "\(what): \(outcome)", file: file, line: line)
        XCTAssertEqual(outcome["value"] as? Bool, expected, "\(what): \(outcome)", file: file, line: line)
    }

    /// The call was refused with exactly `expected`.
    @MainActor private func assertRefusal(_ outcome: [String: Any], _ expected: String, _ what: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome["settled"] as? String, "rejected", "\(what): \(outcome)", file: file, line: line)
        XCTAssertEqual(outcome["message"] as? String, expected, "\(what): \(outcome)", file: file, line: line)
    }

    /// Answer every permission prompt, Detour's and WebKit's, with `answer`
    /// given its items, and record each prompt's items, sorted.
    @MainActor private func recordPrompts(_ answer: @escaping ([String]) -> Bool) -> () -> [[String]] {
        var prompts: [[String]] = []
        ExtensionManager.shared.permissionPromptAnswerOverride = { items in
            prompts.append(items.sorted())
            return answer(items)
        }
        return { prompts }
    }

    @MainActor private func savedStatus(_ ext: WebExtension, _ key: String) -> ExtensionPermissionStatus? {
        AppDatabase.shared.permissionStatus(extensionID: ext.id, key: key, type: .apiPermission)
    }

    @MainActor private static func describe(_ permission: String) -> String {
        ExtensionPermissionDescriptions.describe(permission)
    }

    /// POSITIVE: `history` requested from the page (promise form) and
    /// `management` from the worker (callback form) each show Detour's
    /// prompt, with the wording WebKit's prompts use, and are granted on
    /// Allow: `contains` turns from false to true, the decision is saved as
    /// the Settings switch saves it, and the APIs are served from both
    /// transports. A request for what is already held asks nothing.
    @MainActor func testRequestGrantsOptionalHistoryAndManagementFromBothTransports() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history", "management"])
        let a = try makeProfile("Permissions Request Grant", database: db)
        installTestExtension(ext, in: AppDatabase.shared)
        let page = try await loadPage(ext, in: a.profile)
        let prompts = recordPrompts { _ in true }

        let legs: [(String, GateTransport, CallForm)] = [("history", .page, .promise), ("management", .worker, .callback)]
        for (name, transport, form) in legs {
            let label = "\(name), \(transport), \(form)"
            assertAnswer(try await permissionsCall("contains", [name], via: transport, form, in: page), false,
                         "\(label): contains before")
            assertAnswer(try await permissionsCall("request", [name], via: transport, form, in: page), true,
                         "\(label): request")
            assertAnswer(try await permissionsCall("contains", [name], via: transport, form, in: page), true,
                         "\(label): contains after")
            XCTAssertEqual(savedStatus(ext, name), .granted, "\(label): the grant is saved")
        }
        XCTAssertEqual(prompts(), [[Self.describe("history")], [Self.describe("management")]],
                       "one Detour prompt per request")
        try await assertOptionalGate(served: true, in: page, "granted through permissions.request")

        assertAnswer(try await permissionsCall("request", ["history", "management"], via: .worker, in: page), true,
                     "a request for what is held")
        XCTAssertEqual(prompts().count, 2, "a request for what is held asks nothing")
    }

    /// NEGATIVE: a request answered Deny resolves false from the page
    /// (callback form) and saves the denial, as WebKit's prompt saves one; a
    /// later request from the worker is answered false without asking again,
    /// and the calls are refused as denied.
    @MainActor func testDeniedRequestIsSavedAndNotAskedAgain() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history", "management"])
        let a = try makeProfile("Permissions Request Deny", database: db)
        installTestExtension(ext, in: AppDatabase.shared)
        let page = try await loadPage(ext, in: a.profile)
        let prompts = recordPrompts { _ in false }

        assertAnswer(try await permissionsCall("request", ["history", "management"], via: .page, .callback, in: page),
                     false, "page, callback: request denied")
        XCTAssertEqual(prompts(), [[Self.describe("history"), Self.describe("management")].sorted()],
                       "one prompt for the whole request")
        XCTAssertEqual(savedStatus(ext, "history"), .denied)
        XCTAssertEqual(savedStatus(ext, "management"), .denied)

        assertAnswer(try await permissionsCall("request", ["management"], via: .worker, in: page), false,
                     "worker: request after a denial")
        XCTAssertEqual(prompts().count, 1, "a denied permission is not asked about again")
        assertAnswer(try await permissionsCall("contains", ["history"], via: .worker, .callback, in: page), false,
                     "worker, callback: contains")
        try await assertOptionalGate(served: false, in: page, "denied through permissions.request", refusal: .denied)
    }

    /// POSITIVE then NEGATIVE: `remove` from the page (promise form) and the
    /// worker (callback form) revokes the grant everywhere and deletes the
    /// saved row, so a relaunch keeps it revoked; the next request prompts
    /// again (TASK-258's rule: the row is deleted, not saved as denied).
    @MainActor func testRemoveIsSavedAndARelaunchKeepsItRevoked() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history", "management"])
        saveDecisions(["history", "management"], of: ext, status: .granted)
        let a = try makeProfile("Permissions Remove", database: db)
        let page = try await loadPage(ext, in: a.profile)
        try await assertOptionalGate(served: true, in: page, "restored grant")

        assertAnswer(try await permissionsCall("remove", ["history"], via: .page, in: page), true, "page: remove")
        assertAnswer(try await permissionsCall("remove", ["management"], via: .worker, .callback, in: page), true,
                     "worker, callback: remove")
        assertAnswer(try await permissionsCall("contains", ["history"], via: .worker, in: page), false,
                     "worker: contains after the page's remove")
        assertAnswer(try await permissionsCall("contains", ["management"], via: .page, .callback, in: page), false,
                     "page: contains after the worker's remove")
        XCTAssertNil(savedStatus(ext, "history"), "the saved grant is deleted, not saved as denied")
        XCTAssertNil(savedStatus(ext, "management"))
        try await assertOptionalGate(served: false, in: page, "removed")

        a.profile.unloadExtension(id: ext.id)
        let reloaded = try await loadPage(ext, in: a.profile)
        try await assertOptionalGate(served: false, in: reloaded, "removed, after a relaunch")
        assertAnswer(try await permissionsCall("contains", ["history", "management"], via: .page, in: reloaded), false,
                     "contains after a relaunch")

        let prompts = recordPrompts { _ in true }
        assertAnswer(try await permissionsCall("request", ["history"], via: .worker, in: reloaded), true,
                     "worker: request after the relaunch")
        XCTAssertEqual(prompts(), [[Self.describe("history")]], "the request prompts again")
    }

    /// A request naming `history` and WebKit's own `notifications` is granted
    /// whole or not at all, as in Chrome. WebKit's prompt comes first, inside
    /// the caller's user gesture, which WebKit requires: a denial there never
    /// reaches Detour's prompt, and a denial in Detour's prompt takes back
    /// what WebKit's just granted. Both approved, both are granted. From the
    /// worker, which has no gesture, WebKit refuses the request and Detour
    /// asks nothing.
    @MainActor func testMixedRequestWithAWebKitPermissionIsGrantedWholeOrNotAtAll() async throws {
        let db = try makeDatabase()
        let a = try makeProfile("Permissions Mixed", database: db)
        let history = Self.describe("history")
        let notifications = Self.describe("notifications")
        let mixed = ["history", "notifications"]
        func makeLoaded() async throws -> (WebExtension, WKWebView) {
            let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: mixed)
            installTestExtension(ext, in: AppDatabase.shared)
            return (ext, try await loadPage(ext, in: a.profile))
        }

        // WebKit's prompt denied.
        let (webKitDenied, pageA) = try await makeLoaded()
        var prompts = recordPrompts { items in !items.contains(notifications) }
        assertAnswer(try await permissionsCall("request", mixed, via: .page, in: pageA), false, "WebKit's prompt denied")
        XCTAssertEqual(prompts(), [[notifications]], "Detour's prompt is never shown")
        XCTAssertNil(savedStatus(webKitDenied, "history"), "Detour was not asked")
        XCTAssertEqual(savedStatus(webKitDenied, "notifications"), .denied)

        // Detour's prompt denied: WebKit's grant is taken back.
        let (detourDenied, pageB) = try await makeLoaded()
        prompts = recordPrompts { items in !items.contains(history) }
        assertAnswer(try await permissionsCall("request", mixed, via: .page, .callback, in: pageB), false,
                     "Detour's prompt denied")
        XCTAssertEqual(prompts(), [[notifications], [history]], "WebKit's prompt first, then Detour's")
        XCTAssertEqual(savedStatus(detourDenied, "history"), .denied)
        assertAnswer(try await permissionsCall("contains", ["notifications"], via: .worker, in: pageB), false,
                     "WebKit's grant was taken back")
        try await waitUntil("the taken-back notifications grant to be cleared") {
            savedStatus(detourDenied, "notifications") == nil
        }

        // Both approved.
        let (approved, pageC) = try await makeLoaded()
        prompts = recordPrompts { _ in true }
        assertAnswer(try await permissionsCall("request", mixed, via: .page, in: pageC), true, "both approved")
        XCTAssertEqual(prompts(), [[notifications], [history]])
        XCTAssertEqual(savedStatus(approved, "history"), .granted)
        XCTAssertEqual(savedStatus(approved, "notifications"), .granted)
        assertAnswer(try await permissionsCall("contains", mixed, via: .worker, in: pageC), true, "a mixed contains")
        let search = try await pagePromise("{ text: '' }", in: pageC)
        XCTAssertEqual(search["settled"] as? String, "resolved", "history.search is served: \(search)")

        // A mixed removal: WebKit removes its part, then Detour removes its own.
        assertAnswer(try await permissionsCall("remove", mixed, via: .page, in: pageC), true, "a mixed remove")
        assertAnswer(try await permissionsCall("contains", ["history"], via: .worker, in: pageC), false,
                     "history removed")
        assertAnswer(try await permissionsCall("contains", ["notifications"], via: .worker, in: pageC), false,
                     "notifications removed")
        XCTAssertNil(savedStatus(approved, "history"), "Detour's saved grant is deleted")
        try await waitUntil("the removed notifications grant to be cleared") {
            savedStatus(approved, "notifications") == nil
        }

        // From the worker: no gesture, so WebKit refuses before anyone is asked.
        let (fromWorker, pageD) = try await makeLoaded()
        prompts = recordPrompts { _ in true }
        let outcome = try await permissionsCall("request", mixed, via: .worker, in: pageD)
        XCTAssertEqual(outcome["settled"] as? String, "rejected", "worker: \(outcome)")
        XCTAssertTrue((outcome["message"] as? String ?? "").contains("user gesture"), "worker: \(outcome)")
        XCTAssertEqual(prompts(), [], "nothing is asked")
        XCTAssertNil(savedStatus(fromWorker, "history"))
    }

    /// NEGATIVE: only manifest names may be requested or removed, as in
    /// Chrome, from both transports in both forms, with no prompt. A required
    /// name is held, so its request is granted without asking and its removal
    /// refused; an undeclared one is refused, and `contains` answers false.
    @MainActor func testOnlyOptionalPermissionsCanBeRequestedOrRemoved() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage", "management"])
        let a = try makeProfile("Permissions Not Optional", database: db)
        installTestExtension(ext, in: AppDatabase.shared)
        let page = try await loadPage(ext, in: a.profile)
        let prompts = recordPrompts { _ in true }

        for transport in [GateTransport.page, .worker] {
            for form in [CallForm.promise, .callback] {
                let label = "\(transport), \(form)"
                assertRefusal(try await permissionsCall("request", ["history"], via: transport, form, in: page),
                              ExtensionPolyfillHandler.permissionRequestNotInManifestError, "\(label): request undeclared")
                assertRefusal(try await permissionsCall("request", ["history", "storage"], via: transport, form, in: page),
                              ExtensionPolyfillHandler.permissionRequestNotInManifestError, "\(label): mixed, undeclared")
                assertAnswer(try await permissionsCall("request", ["management"], via: transport, form, in: page), true,
                             "\(label): request required")
                assertAnswer(try await permissionsCall("contains", ["history"], via: transport, form, in: page), false,
                             "\(label): contains undeclared")
                assertAnswer(try await permissionsCall("contains", ["management"], via: transport, form, in: page), true,
                             "\(label): contains required")
                assertRefusal(try await permissionsCall("remove", ["management"], via: transport, form, in: page),
                              ExtensionPolyfillHandler.permissionRemoveRequiredError, "\(label): remove required")
                assertRefusal(try await permissionsCall("remove", ["history"], via: transport, form, in: page),
                              ExtensionPolyfillHandler.permissionRemoveNotInManifestError, "\(label): remove undeclared")
            }
        }
        XCTAssertEqual(prompts(), [], "nothing is asked")
        let gated = try await gate(via: .page, in: page)
        XCTAssertEqual((gated["directSearch"] as? [String: Any])?["rejected"] as? String,
                       Refusal.notDeclared.text("history"), "an undeclared permission's refusal: \(gated)")
    }

    /// A second request while the first one's prompt is pending is refused,
    /// not stacked, and the first is granted once answered.
    @MainActor func testPendingPromptRefusesASecondRequest() async throws {
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history"])
        installTestExtension(ext, in: AppDatabase.shared)
        let prompts = recordPrompts { _ in true }
        let manager = ExtensionManager.shared

        var outcomes: [ExtensionManager.OutsideWebKitPermissionRequestOutcome] = []
        for _ in 0..<2 {
            manager.requestOutsideWebKitPermissions(extensionID: ext.id, names: ["history"]) { outcomes.append($0) }
        }
        XCTAssertEqual(outcomes, [.refused(ExtensionManager.permissionRequestPendingError)],
                       "the second request is refused at once")
        try await waitUntil("the first request to be answered") { outcomes.count == 2 }
        XCTAssertEqual(outcomes.last, .approved)
        XCTAssertEqual(prompts().count, 1, "one prompt")
        XCTAssertEqual(savedStatus(ext, "history"), .granted)
    }

    // MARK: - 8. ExtensionInfo lists the active permissions (TASK-261)

    /// `managementInfo` from `transport`: getSelf's and getAll's `id`,
    /// `permissions` and `hostPermissions` (`allError` when getAll refuses).
    @MainActor private func managementInfo(via transport: GateTransport, in page: WKWebView,
                                           file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        switch transport {
        case .page:
            return try await evalObject(Self.gateJS + "\nreturn JSON.stringify(await managementInfo());", in: page)
        case .worker:
            let answer = try await askWorker(from: page, message: ["type": "managementInfo"])
            XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker", file: file, line: line)
            return try XCTUnwrap(answer["reply"] as? [String: Any], "the worker must answer: \(answer)",
                                 file: file, line: line)
        }
    }

    /// getSelf's lists, from the page and the worker, equal `permissions` and `hosts`.
    @MainActor private func assertSelfInfo(_ permissions: [String], _ hosts: [String], in page: WKWebView,
                                           _ label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for transport in [GateTransport.page, .worker] {
            let outcome = try await managementInfo(via: transport, in: page, file: file, line: line)
            let info = try XCTUnwrap(outcome["self"] as? [String: Any], "\(label), \(transport): \(outcome)",
                                     file: file, line: line)
            XCTAssertEqual(info["permissions"] as? [String], permissions, "\(label), \(transport)", file: file, line: line)
            XCTAssertEqual(info["hostPermissions"] as? [String], hosts, "\(label), \(transport)", file: file, line: line)
        }
    }

    /// Saved decisions for host `patterns`, as install records the required
    /// ones (`recordDeclaredPermissions`).
    @MainActor private func saveHostGrants(_ patterns: [String], of ext: WebExtension) {
        installTestExtension(ext, in: AppDatabase.shared)
        AppDatabase.shared.savePermissions(patterns.map {
            ExtensionPermissionRecord(extensionID: ext.id, key: $0, type: .matchPattern, status: .granted)
        })
    }

    /// POSITIVE then NEGATIVE, from the page and the worker: getSelf lists
    /// the active API permissions and granted hosts, as Chromium's
    /// `CreateExtensionInfo` lists `active_permissions()`. An optional
    /// permission and an optional origin appear once granted and go once
    /// revoked; a required permission switched off in Settings goes too.
    @MainActor func testGetSelfListsTheActivePermissions() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage", "management"],
                                          optionalPermissions: ["history", "notifications"],
                                          hostPermissions: ["https://required.example/*"],
                                          optionalHostPermissions: ["https://optional.example/*"])
        saveHostGrants(["https://required.example/*"], of: ext)
        let a = try makeProfile("Management Info Self", database: db)
        let page = try await loadPage(ext, in: a.profile)

        try await assertSelfInfo(["storage", "management"], ["https://required.example/*"], in: page, "before")

        let manager = ExtensionManager.shared
        manager.setPermissionDecision(extensionID: ext.id, key: "history", type: .apiPermission, granted: true)
        manager.setPermissionDecision(extensionID: ext.id, key: "notifications", type: .apiPermission, granted: true)
        manager.setPermissionDecision(extensionID: ext.id, key: "https://optional.example/*",
                                      type: .matchPattern, granted: true)
        try await assertSelfInfo(["storage", "management", "history", "notifications"],
                                 ["https://optional.example/*", "https://required.example/*"], in: page, "granted")

        manager.setPermissionDecision(extensionID: ext.id, key: "history", type: .apiPermission, granted: false)
        manager.setPermissionDecision(extensionID: ext.id, key: "notifications", type: .apiPermission, granted: false)
        manager.setPermissionDecision(extensionID: ext.id, key: "https://optional.example/*",
                                      type: .matchPattern, granted: false)
        manager.setPermissionDecision(extensionID: ext.id, key: "management", type: .apiPermission, granted: false)
        try await assertSelfInfo(["storage"], ["https://required.example/*"], in: page, "revoked")
    }

    /// POSITIVE: a grant through `permissions.request` (the prompt answered
    /// Allow) shows in getSelf, and `permissions.remove` takes it out again.
    @MainActor func testGetSelfFollowsPermissionsRequestAndRemove() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history"])
        let a = try makeProfile("Management Info Request", database: db)
        installTestExtension(ext, in: AppDatabase.shared)
        let page = try await loadPage(ext, in: a.profile)
        _ = recordPrompts { _ in true }

        try await assertSelfInfo(["storage"], [], in: page, "before")
        assertAnswer(try await permissionsCall("request", ["history"], via: .worker, in: page), true, "request")
        try await assertSelfInfo(["storage", "history"], [], in: page, "requested")
        assertAnswer(try await permissionsCall("remove", ["history"], via: .page, in: page), true, "remove")
        try await assertSelfInfo(["storage"], [], in: page, "removed")
    }

    /// getAll's entry for another extension lists that extension's active
    /// set in the caller's profile: its optional grant appears, and its
    /// optional origin, once granted.
    @MainActor func testGetAllListsAnotherExtensionsActivePermissions() async throws {
        let db = try makeDatabase()
        let caller = try await makeExtension(permissions: ["management"])
        let other = try await makeExtension(permissions: ["storage"], optionalPermissions: ["history"],
                                            optionalHostPermissions: ["https://other.example/*"])
        installTestExtension(caller, in: AppDatabase.shared)
        installTestExtension(other, in: AppDatabase.shared)
        let a = try makeProfile("Management Info All", database: db)
        let page = try await loadPage(caller, in: a.profile)
        _ = try loadTestContext(other, in: a.profile)

        func otherEntry(_ label: String) async throws -> [String: Any] {
            let outcome = try await managementInfo(via: .worker, in: page)
            let all = try XCTUnwrap(outcome["all"] as? [[String: Any]], "\(label): \(outcome)")
            return try XCTUnwrap(all.first { $0["id"] as? String == other.id }, "\(label): \(all)")
        }
        var entry = try await otherEntry("before")
        XCTAssertEqual(entry["permissions"] as? [String], ["storage"], "before")
        XCTAssertEqual(entry["hostPermissions"] as? [String], [], "before")

        let manager = ExtensionManager.shared
        manager.setPermissionDecision(extensionID: other.id, key: "history", type: .apiPermission, granted: true)
        manager.setPermissionDecision(extensionID: other.id, key: "https://other.example/*",
                                      type: .matchPattern, granted: true)
        entry = try await otherEntry("granted")
        XCTAssertEqual(entry["permissions"] as? [String], ["storage", "history"], "granted")
        XCTAssertEqual(entry["hostPermissions"] as? [String], ["https://other.example/*"], "granted")
    }

    /// The host rule on its own: a grant also held as a denial and an
    /// expired grant are left out, and so is a grant no manifest host pattern
    /// covers (the content-script patterns granted for `activeTab`), as
    /// Chromium's `explicit_hosts()` leaves out scriptable hosts.
    @MainActor func testActiveHostPermissionsRule() throws {
        let pattern = { (s: String) in try WKWebExtension.MatchPattern(string: s) }
        let now = Date()
        let later = now.addingTimeInterval(60), earlier = now.addingTimeInterval(-60)
        let granted: [WKWebExtension.MatchPattern: Date] = [
            try pattern("https://a.example/*"): later,
            try pattern("https://b.example/*"): later,
            try pattern("https://content.example/*"): later,
            try pattern("https://expired.example/*"): earlier,
        ]
        let denied = [try pattern("https://b.example/*"): later]
        let askable: Set = [try pattern("https://*.example/*")]
        XCTAssertEqual(ExtensionPolyfillHandler.activeHostPermissions(
            granted: granted, denied: denied, askable: askable, now: now),
            ["https://a.example/*", "https://content.example/*"],
            "denied and expired grants are left out")
        XCTAssertEqual(ExtensionPolyfillHandler.activeHostPermissions(
            granted: granted, denied: denied, askable: [try pattern("https://a.example/*")], now: now),
            ["https://a.example/*"], "a content-script-only grant is left out")
        XCTAssertEqual(ExtensionPolyfillHandler.activeHostPermissions(
            granted: granted, denied: denied, askable: askable, implicit: ["https://content.example/*"], now: now),
            ["https://a.example/*"], "an activeTab content-script grant a manifest pattern covers is left out")
        XCTAssertEqual(ExtensionPolyfillHandler.activeHostPermissions(
            granted: granted, denied: [try pattern("<all_urls>"): later], askable: [try pattern("<all_urls>")],
            now: now),
            [], "a broader denial covers the narrower grants WebKit keeps under it")
    }

    /// The activeTab content-script patterns not also declared as hosts, and
    /// Manifest V2 origins kept out of `permissions`.
    @MainActor func testImplicitContentScriptPatternsAndV2Origins() throws {
        let manifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data("""
            {"manifest_version": 2, "name": "N", "version": "1",
             "permissions": ["activeTab", "storage", "<all_urls>", "https://declared.example/*"],
             "content_scripts": [{"matches": ["https://*/*", "https://declared.example/*"], "js": ["c.js"]}]}
            """.utf8))
        XCTAssertEqual(ExtensionPolyfillHandler.implicitContentScriptPatterns(manifest), ["https://*/*"])
        XCTAssertEqual(ExtensionPolyfillHandler.activeAPIPermissions(manifest: manifest, context: nil),
                       ["activeTab", "storage"], "origins belong in hostPermissions")
    }
}
