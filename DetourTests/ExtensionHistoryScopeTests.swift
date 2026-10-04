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
@MainActor
final class ExtensionHistoryScopeTests: XCTestCase {

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
    private static var retainedProfiles: [Profile] = []

    override func setUp() async throws {
        try await super.setUp()
        previousLastActiveSpaceID = ExtensionManager.shared.lastActiveSpaceID
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
        ExtensionManager.shared.lastActiveSpaceID = previousLastActiveSpaceID
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
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
    private static let workerJS = ExtensionAPIPolyfill.polyfillJS + """

    const unhandled = [];
    self.addEventListener('unhandledrejection', (event) => {
        unhandled.push(String(event.reason && event.reason.message ? event.reason.message : event.reason));
    });
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
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

    /// An MV3 extension with a module service worker and one page, registered
    /// in `ExtensionManager` the way an installed extension is (the handler's
    /// permission gate reads the manifest from there).
    private func makeExtension(permissions: [String]) async throws -> WebExtension {
        let id = "history-scope-\(UUID().uuidString.prefix(8))"
        let permissionsJSON = String(decoding: try JSONSerialization.data(withJSONObject: permissions),
                                     as: UTF8.self)
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "History Scope Test",
                "version": "1.0.0",
                "permissions": \(permissionsJSON),
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
        let space = addSpace(for: profile, name: "\(name) Space")
        try useDatabase(database, in: profile)
        return (profile, space)
    }

    private func addSpace(for profile: Profile, name: String) -> Space {
        let space = TabStore.shared.addSpace(name: name, emoji: "H", colorHex: "#000000", profileID: profile.id)
        createdSpaceIDs.append(space.id)
        return space
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

    /// Inserts a visit with a caller-chosen time, as `HistoryDatabaseTests`
    /// does: the shared `historyURL` row moves with every visit from anywhere,
    /// like the real upsert, so the aggregate and a profile's own values differ.
    private func seedVisit(_ db: HistoryDatabase, url: String, title: String, space: String,
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
    private func seedTwoProfiles(_ db: HistoryDatabase, spaceA: Space, spaceB: Space, base: Double) throws {
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

    private static func wholeSecondBase() -> Double {
        Date().timeIntervalSince1970.rounded(.down)
    }

    /// One history item as an extension receives it.
    private struct Item: Equatable {
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

    private func items(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [Item] {
        let array = try XCTUnwrap(value as? [Any], "expected an array of history items, got \(String(describing: value))",
                                  file: file, line: line)
        return try array.map { try XCTUnwrap(Item($0), "not a history item: \($0)", file: file, line: line) }
    }

    /// What profile A must get for `{ text: '' }`, newest of its own visits first.
    private func expectedForA(base: Double) -> [Item] {
        [Item(url: Self.shared, title: "Inbox (2) - home", visitCount: 2, typedCount: 1,
              lastVisitTime: (base - 200) * 1000),
         Item(url: Self.onlyA, title: "Only A notes", visitCount: 1, typedCount: 0,
              lastVisitTime: (base - 500) * 1000)]
    }

    private func expectedForB(base: Double) -> [Item] {
        [Item(url: Self.shared, title: "Inbox (9) - work", visitCount: 3, typedCount: 0,
              lastVisitTime: (base - 50) * 1000),
         Item(url: Self.onlyB, title: "Payroll secrets", visitCount: 1, typedCount: 0,
              lastVisitTime: (base - 400) * 1000)]
    }

    // MARK: Handler round trips

    /// Await one `handleNativeMessage` round trip for `history.search`.
    private func search(_ handler: ExtensionPolyfillHandler, extensionID: String,
                        params: [String: Any]) async -> (result: Any?, error: String?) {
        await withCheckedContinuation { continuation in
            handler.handleNativeMessage(
                ["type": "history.search", "extensionID": extensionID, "params": params],
                verifiedExtensionID: extensionID
            ) { result, error in
                continuation.resume(returning: (result, error?.localizedDescription))
            }
        }
    }

    private func results(_ reply: (result: Any?, error: String?),
                         file: StaticString = #filePath, line: UInt = #line) throws -> [Item] {
        XCTAssertNil(reply.error, "history.search failed: \(reply.error ?? "")", file: file, line: line)
        return try items((reply.result as? [String: Any])?["results"], file: file, line: line)
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
    private func loadPage(_ ext: WebExtension, in profile: Profile) async throws -> WKWebView {
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

    private func evalObject(_ js: String, in webView: WKWebView) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// `chrome.history.search(<arguments>)` from the page itself, promise form.
    /// `arguments` is JS source, so a test can pass nothing at all.
    private func pagePromise(_ arguments: String, in page: WKWebView) async throws -> [String: Any] {
        try await evalObject(promiseOutcomeJS("chrome.history.search(\(arguments))"), in: page)
    }

    /// The callback form from the page: `search(<arguments>, cb)`.
    private func pageCallback(_ arguments: String, in page: WKWebView) async throws -> [String: Any] {
        try await evalObject(callbackOutcomeJS(call: "return chrome.history.search(\(arguments), cb);"), in: page)
    }

    /// One history call made by the worker, reported back through
    /// `runtime.sendMessage`. `query` nil sends no `query` key.
    private func workerOutcome(_ form: String, query: Any?, via page: WKWebView,
                               file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        var message: [String: Any] = ["type": form]
        if let query { message["query"] = query }
        let answer = try await askWorker(from: page, message: message)
        XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker", file: file, line: line)
        return try XCTUnwrap(answer["reply"] as? [String: Any], "the worker must answer: \(answer)",
                             file: file, line: line)
    }

    /// The items a successful callback-form call from the page handed its callback.
    private func callbackItems(_ outcome: [String: Any],
                               file: StaticString = #filePath, line: UInt = #line) throws -> [Item] {
        XCTAssertEqual(outcome["timedOut"] as? Bool, false, "the callback must run: \(outcome)", file: file, line: line)
        XCTAssertEqual(outcome["argc"] as? Int, 1, file: file, line: line)
        XCTAssertNil(outcome["lastErrorInCallback"] as? String, "no lastError on success: \(outcome)",
                     file: file, line: line)
        XCTAssertEqual(outcome["unhandled"] as? [String], [], file: file, line: line)
        let json = try XCTUnwrap(outcome["arg0"] as? String, file: file, line: line)
        return try items(try JSONSerialization.jsonObject(with: Data(json.utf8)), file: file, line: line)
    }

    /// Does `message` carry the native refusal `expected`? A substring test
    /// that ignores case, because the text does not always arrive verbatim:
    /// whatever travels through WebKit's `runtime.sendNativeMessage` — every
    /// worker request, and the `runtime.lastError` relay from a page — comes
    /// back as `Invalid call to runtime.sendNativeMessage(). <Text>.`, with
    /// the first letter capitalised and a full stop added (seen 2026-10-04:
    /// "History permission not declared.").
    private func carries(_ message: String, _ expected: String) -> Bool {
        message.range(of: expected, options: .caseInsensitive) != nil
    }

    /// A callback-form call that must have failed: the callback ran with no
    /// arguments and `runtime.lastError` carried `expected`.
    private func assertCallbackFailed(_ outcome: [String: Any], containing expected: String, _ what: String,
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

    private func assertRejected(_ outcome: [String: Any], containing expected: String, _ what: String,
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

    private func parse(_ params: [String: Any]) -> Result<ExtensionPolyfillHandler.HistorySearchQuery,
                                                          ExtensionPolyfillHandler.PolyfillArgumentError> {
        ExtensionPolyfillHandler.historySearchQuery(from: params,
                                                    now: Date(timeIntervalSince1970: Self.parserNow))
    }

    func testQueryParserAcceptsAChromeQuery() throws {
        let parsed = try parse([
            "query": ["text": "inbox", "maxResults": 25, "startTime": 1_000_000.0, "endTime": 2_500_000] as [String: Any],
        ]).get()
        XCTAssertEqual(parsed, .init(text: "inbox", maxResults: 25, startTime: 1000, endTime: 2500),
                       "times arrive in milliseconds and are stored in seconds")
    }

    func testQueryParserAppliesChromesDefaults() throws {
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
    func testQueryParserReadsAnOmittedStartTimeAsTheLastDay() throws {
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

    func testQueryParserRefusesBadArguments() {
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
    func testHandlerAnswersFromItsOwnProfileOnly() async throws {
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
    func testHandlerScopeIsEverySpaceOfTheProfile() async throws {
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
    func testHandlerAppliesTheTimeRangeAndTheLimitInScope() async throws {
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
    func testHandlerReadsAnOmittedStartTimeAsTheLastDay() async throws {
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
    func testHandlerInThePrivateProfileGetsNothing() async throws {
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
    func testHandlerInAProfileWithoutSpacesGetsNothing() async throws {
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
    func testHandlerRefusesAnExtensionWithoutTheHistoryPermission() async throws {
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

    func testHandlerRejectsBadArguments() async throws {
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
    func testBothTransportsReturnOnlyTheCallingProfilesHistory() async throws {
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
    func testAnOmittedStartTimeCoversTheLastDayFromBothTransports() async throws {
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
    /// is refused from both transports and in both forms, in a profile whose
    /// history has something to leak. The positive half is the test above.
    func testAnExtensionWithoutTheHistoryPermissionIsRefusedFromBothTransports() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["storage"])
        let a = try makeProfile("History Scope Ungranted", database: db)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        let page = try await loadPage(ext, in: a.profile)
        let refusal = "history permission not declared"

        assertRejected(try await pagePromise("{ text: '' }", in: page), containing: refusal, "page promise")
        assertCallbackFailed(try await pageCallback("{ text: '' }", in: page), containing: refusal, "page callback")
        assertRejected(try await workerOutcome("historyPromise", query: ["text": ""], via: page),
                       containing: refusal, "worker promise")
        assertCallbackFailed(try await workerOutcome("historyCallback", query: ["text": ""], via: page),
                             containing: refusal, "worker callback")
    }

    /// AC #3, bad arguments: rejected in the promise form, `runtime.lastError`
    /// in the callback form, from both transports — never answered with the
    /// whole history, which is what a lenient parse of `{}` used to do.
    func testBadArgumentsAreRefusedFromBothTransportsInBothForms() async throws {
        let db = try makeDatabase()
        let ext = try await makeExtension(permissions: ["history"])
        let a = try makeProfile("History Scope Bad Arguments", database: db)
        try seedVisit(db, url: Self.onlyA, title: "Only A notes", space: a.space.id.uuidString,
                      visitTime: Self.wholeSecondBase() - 100)
        let page = try await loadPage(ext, in: a.profile)

        // (JS arguments for the page, the same query as JSON for the worker — nil
        // sends none — and the refusal.)
        let cases: [(js: String, json: Any?, expected: String)] = [
            ("{}", [String: Any](), "query.text must be a string"),
            ("{ text: 5 }", ["text": 5] as [String: Any], "query.text must be a string"),
            ("'notes'", "notes", "query must be an object"),
            ("{ text: '', maxResults: -1 }", ["text": "", "maxResults": -1] as [String: Any],
             "query.maxResults must be a non-negative integer"),
            ("{ text: '', startTime: 'yesterday' }", ["text": "", "startTime": "yesterday"] as [String: Any],
             "query.startTime must be a number"),
        ]
        for (js, json, expected) in cases {
            assertRejected(try await pagePromise(js, in: page), containing: expected, "page promise \(js)")
            assertCallbackFailed(try await pageCallback(js, in: page), containing: expected, "page callback \(js)")
            assertRejected(try await workerOutcome("historyPromise", query: json, via: page),
                           containing: expected, "worker promise \(js)")
            assertCallbackFailed(try await workerOutcome("historyCallback", query: json, via: page),
                                 containing: expected, "worker callback \(js)")
        }

        // No query at all: the polyfill sends an empty object in its place.
        assertRejected(try await pagePromise("", in: page), containing: "query.text must be a string",
                       "page promise, no arguments")
        assertRejected(try await workerOutcome("historyPromise", query: nil, via: page),
                       containing: "query.text must be a string", "worker promise, no arguments")

        // POSITIVE control: the same page and worker answer a valid query.
        let good = try await pagePromise("{ text: 'notes', maxResults: 5 }", in: page)
        XCTAssertEqual(try items(good["value"]).map(\.url), [Self.onlyA])
        let goodWorker = try await workerOutcome("historyPromise", query: ["text": "notes", "maxResults": 5] as [String: Any], via: page)
        XCTAssertEqual(try items(goodWorker["value"]).map(\.url), [Self.onlyA])
    }

    /// An extension running in the Private profile gets an empty list from
    /// both transports while a regular profile has history to leak.
    func testAnExtensionInThePrivateProfileGetsNoHistoryFromEitherTransport() async throws {
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
}
