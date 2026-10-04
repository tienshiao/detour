import XCTest
import WebKit
@testable import Detour

/// TASK-132.6, the page shim by itself: `ExternallyConnectable.userScriptSource`
/// run in a bare web view against a stand-in for WebKit's `browser.runtime`, so
/// every call the shim makes to WebKit — and every call it must *not* make — is
/// recorded. Pages are HTML strings loaded under the URL being tested; nothing
/// is fetched. Plus the pure pieces: which manifest patterns are offered, which
/// ids a URL may reach, and how the script is kept on a content controller.
///
/// Delivery through a real extension context is `ExtensionExternallyConnectableTests`.
@MainActor
final class ExternallyConnectableShimTests: XCTestCase {

    private var views: [WKWebView] = []
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for view in views { view.stopLoading() }
        views.removeAll()
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    private static let claudeID = "fcoeoabgfenejglbffodgkkbkcdhcgfn"
    private static let otherID = "abcdefghijklmnopabcdefghijklmnop"
    private static let noReceiver = "Could not establish connection. Receiving end does not exist."

    /// What WebKit puts on a web page, reduced to a recorder. `sendMessage`
    /// answers `{ native: true, … }`, rejects for `{ type: 'reject' }` and
    /// throws for `{ type: 'throw' }`; `connect` returns a port whose events the
    /// test fires through `port.__fire`. `console.error` is recorded too.
    private static let browserStubJS = """
        window.__nativeCalls = [];
        window.__consoleErrors = [];
        console.error = function(...args) { window.__consoleErrors.push(args.map(String).join(' ')); };
        window.browser = { runtime: {
            sendMessage(id, message) {
                window.__nativeCalls.push({ fn: 'sendMessage', id: id, message: message, argc: arguments.length });
                if (message && message.type === 'throw') throw new Error('native threw');
                if (message && message.type === 'reject') return Promise.reject(new Error('native failure'));
                if (message && message.type === 'silent') return Promise.resolve(undefined);
                return Promise.resolve({ native: true, id: id, message: message });
            },
            connect(id, info) {
                window.__nativeCalls.push({ fn: 'connect', id: id, info: info === undefined ? null : info, argc: arguments.length });
                const listeners = [];
                const port = {
                    name: info && info.name ? info.name : '', error: null,
                    onMessage: { addListener() {} },
                    onDisconnect: { addListener(listener) { listeners.push(listener); } },
                    postMessage() {}, disconnect() {},
                    __fire() { for (const listener of listeners) listener(port); }
                };
                return port;
            }
        } };
        """

    private func table(_ entries: [String: [String]]) throws -> ExternallyConnectable.Table {
        try entries.mapValues { try $0.map { try WKWebExtension.MatchPattern(string: $0) } }
    }

    private static let claudeTable = [claudeID: ["https://claude.ai/*", "https://*.claude.ai/*"]]

    /// A web view with the stand-in (unless `stub` is false), then `before`,
    /// then the shim for `table` — all at document start, in that order — showing
    /// `html` under `url`.
    private func makePage(_ url: String, table entries: [String: [String]] = claudeTable, stub: Bool = true,
                          before: String? = nil, html: String = "<html><body>page</body></html>") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        for source in [stub ? Self.browserStubJS : nil, before].compactMap({ $0 }) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        if let shim = ExternallyConnectable.userScriptSource(for: try table(entries)) {
            controller.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        views.append(view)
        try await loadHTMLStringAndWait(view, html: html, baseURL: URL(string: url)!)
        return view
    }

    private func evaluate(_ view: WKWebView, _ body: String, _ arguments: [String: Any] = [:],
                          file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        let raw = try await view.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page", file: file, line: line)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], file: file, line: line)
    }

    /// The callback form, and everything around it: what the callback got,
    /// `lastError` inside and after it, what reached WebKit, what was logged.
    private func callbackOutcome(_ view: WKWebView, id: String, message: [String: Any],
                                 readLastError: Bool = true) async throws -> [String: Any] {
        try await evaluate(view, """
            const out = await new Promise((resolve) => {
                const timer = setTimeout(() => resolve({ timedOut: true }), 4000);
                const returned = chrome.runtime.sendMessage(id, message, function() {
                    clearTimeout(timer);
                    const seen = { argc: arguments.length, reply: arguments.length ? arguments[0] : null };
                    if (readLastError) seen.lastError = chrome.runtime.lastError ? chrome.runtime.lastError.message : null;
                    setTimeout(() => { seen.returned = typeof returned; resolve(seen); }, 0);
                });
            });
            await new Promise((resolve) => setTimeout(resolve, 20));
            out.lastErrorAfter = chrome.runtime.lastError === undefined ? null : 'still set';
            out.nativeCalls = window.__nativeCalls;
            out.consoleErrors = window.__consoleErrors;
            return JSON.stringify(out);
            """, ["id": id, "message": message, "readLastError": readLastError])
    }

    private func promiseOutcome(_ view: WKWebView, id: String, message: [String: Any]) async throws -> [String: Any] {
        try await evaluate(view, """
            const out = {};
            try {
                const value = await chrome.runtime.sendMessage(id, message);
                out.settled = 'resolved'; out.value = value === undefined ? null : value;
            } catch (e) {
                out.settled = 'rejected'; out.isError = e instanceof Error; out.message = String(e && e.message ? e.message : e);
            }
            out.nativeCalls = window.__nativeCalls;
            return JSON.stringify(out);
            """, ["id": id, "message": message])
    }

    // MARK: - Which pages get it

    /// The shim's own match must agree with WebKit's for every pattern and URL
    /// here: WebKit's decides delivery, the shim's decides what a page is shown.
    func testShimMatchesTheURLsWebKitsMatchPatternsMatch() async throws {
        let patterns = [
            "https://claude.ai/*", "https://*.claude.ai/*", "*://claude.ai/*", "http://claude.ai/*",
            "https://claude.ai/login*", "https://claude.ai/*/chat", "https://CLAUDE.ai/*",
            "https://claude.ai/", "https://*.ai/*", "https://claude.ai/a*b*c",
        ]
        let urls = [
            "https://claude.ai/", "https://claude.ai/login?returnTo=%2Foauth", "https://claude.ai:8443/login",
            "https://sub.claude.ai/a/chat", "https://a.b.claude.ai/", "https://notclaude.ai/", "https://claude.ai.evil.example/",
            "http://claude.ai/", "https://claude.ai/a/b/chat", "https://claude.ai/LOGIN", "https://claude.ai/login/chat#x",
            "https://claude.ai/axxbyyc", "https://claude.ai/abc/d", "https://example.com/claude.ai/",
        ]
        // One id per pattern, so one page load answers for all of them.
        var entries: [String: [String]] = [:]
        var idForPattern: [String: String] = [:]
        for (index, pattern) in patterns.enumerated() {
            let id = String(repeating: "abcdefghijklmnop"[String.Index(utf16Offset: index, in: "abcdefghijklmnop")], count: 32)
            entries[id] = [pattern]
            idForPattern[pattern] = id
        }
        for url in urls {
            let view = try await makePage(url, table: entries)
            let outcome = try await evaluate(view, """
                const out = { chrome: typeof globalThis.chrome, reached: [] };
                if (out.chrome === 'undefined') return JSON.stringify(out);
                await Promise.all(ids.map((id) => chrome.runtime.sendMessage(id, { type: 'hello' }).catch(() => {})));
                out.reached = window.__nativeCalls.map((call) => call.id);
                return JSON.stringify(out);
                """, ["ids": Array(entries.keys)])
            let reached = Set(outcome["reached"] as? [String] ?? [])
            for pattern in patterns {
                let expected = try WKWebExtension.MatchPattern(string: pattern).matches(URL(string: url)!)
                XCTAssertEqual(reached.contains(idForPattern[pattern]!), expected,
                               "\(pattern) against \(url): WebKit says \(expected)")
            }
            XCTAssertEqual(outcome["chrome"] as? String, reached.isEmpty ? "undefined" : "object",
                           "\(url): chrome exists exactly when some extension lists the page")
        }
    }

    /// Claude's two patterns, spelled out: claude.ai and its subdomains over
    /// https, and nothing that merely looks like them.
    func testClaudePatternsCoverClaudeAIAndItsSubdomainsOnly() async throws {
        for (url, listed) in [
            ("https://claude.ai/login?returnTo=%2Foauth%2Fauthorize", true),
            ("https://claude.ai/oauth/authorize?client_id=x", true),
            ("https://console.claude.ai/", true),
            ("http://claude.ai/", false),
            ("https://claude.ai.example.com/", false),
            ("https://fakeclaude.ai/", false),
            ("https://example.com/?next=https://claude.ai/", false),
        ] {
            let view = try await makePage(url)
            let seen = try await evaluate(view, """
                return JSON.stringify({ chrome: typeof globalThis.chrome,
                    send: typeof (globalThis.chrome && chrome.runtime && chrome.runtime.sendMessage) });
                """)
            XCTAssertEqual(seen["send"] as? String, listed ? "function" : "undefined", "\(url): \(seen)")
            XCTAssertEqual(seen["chrome"] as? String, listed ? "object" : "undefined", "\(url): \(seen)")
        }
    }

    /// The shim only exposes what WebKit vends: without WebKit's
    /// `browser.runtime` (a web view with no extension controller) it defines
    /// nothing, even on a listed page.
    func testNothingIsDefinedWithoutWebKitsBrowserRuntime() async throws {
        let view = try await makePage("https://claude.ai/", stub: false)
        let seen = try await evaluate(view, "return JSON.stringify({ chrome: typeof globalThis.chrome, browser: typeof globalThis.browser });")
        XCTAssertEqual(seen["chrome"] as? String, "undefined")
        XCTAssertEqual(seen["browser"] as? String, "undefined", "precondition: a bare web view has no browser global")
    }

    // MARK: - window.chrome

    /// A `chrome` that is already there when the shim runs (another script
    /// defined it at document start) keeps every member; `runtime` is added
    /// only if it has none.
    func testAnExistingChromeObjectIsExtendedAndNeverReplaced() async throws {
        let withoutRuntime = try await makePage("https://claude.ai/",
            before: "window.chrome = { webstore: { install() { return 'own'; } } }; window.__own = window.chrome;")
        let extended = try await evaluate(withoutRuntime, """
            return JSON.stringify({ same: window.chrome === window.__own, webstore: chrome.webstore.install(),
                send: typeof chrome.runtime.sendMessage, keys: Object.keys(chrome).sort() });
            """)
        XCTAssertEqual(extended["same"] as? Bool, true, "the object itself is kept")
        XCTAssertEqual(extended["webstore"] as? String, "own")
        XCTAssertEqual(extended["send"] as? String, "function")
        XCTAssertEqual(extended["keys"] as? [String], ["runtime", "webstore"])

        let withRuntime = try await makePage("https://claude.ai/",
            before: "window.chrome = { runtime: { mine: true, sendMessage() { return 'own'; } } };")
        let untouched = try await evaluate(withRuntime, """
            return JSON.stringify({ mine: chrome.runtime.mine, send: chrome.runtime.sendMessage(),
                connect: typeof chrome.runtime.connect, calls: window.__nativeCalls.length });
            """)
        XCTAssertEqual(untouched["mine"] as? Bool, true, "a runtime that is already there is left alone: \(untouched)")
        XCTAssertEqual(untouched["send"] as? String, "own")
        XCTAssertEqual(untouched["connect"] as? String, "undefined", "…not even completed")
    }

    /// A `chrome` the shim cannot extend — a primitive, a frozen object — is
    /// left exactly as it is, and the shim does not throw.
    func testAChromeTheShimCannotExtendIsLeftAlone() async throws {
        let errors = "window.__errors = []; window.addEventListener('error', (e) => window.__errors.push(String(e.message)));"
        let primitive = try await makePage("https://claude.ai/", before: errors + "window.chrome = 'a string';")
        let primitiveSeen = try await evaluate(primitive, "return JSON.stringify({ chrome: window.chrome, errors: window.__errors });")
        XCTAssertEqual(primitiveSeen["chrome"] as? String, "a string")
        XCTAssertEqual(primitiveSeen["errors"] as? [String], [])

        let frozen = try await makePage("https://claude.ai/", before: errors + "window.chrome = Object.freeze({ mine: 1 });")
        let frozenSeen = try await evaluate(frozen, """
            return JSON.stringify({ mine: chrome.mine, runtime: typeof chrome.runtime, errors: window.__errors });
            """)
        XCTAssertEqual(frozenSeen["mine"] as? Int, 1)
        XCTAssertEqual(frozenSeen["runtime"] as? String, "undefined")
        XCTAssertEqual(frozenSeen["errors"] as? [String], [])
    }

    /// The global is an ordinary property: writable, configurable, and what the
    /// shim adds is messaging only.
    func testChromeIsAnOrdinaryGlobalWithMessagingOnly() async throws {
        let view = try await makePage("https://claude.ai/")
        let seen = try await evaluate(view, """
            const d = Object.getOwnPropertyDescriptor(globalThis, 'chrome');
            const source = String(chrome.runtime.sendMessage) + String(chrome.runtime.connect);
            return JSON.stringify({ writable: d.writable, configurable: d.configurable, enumerable: d.enumerable,
                chromeKeys: Object.keys(chrome), runtimeKeys: Object.keys(chrome.runtime).sort(),
                id: chrome.runtime.id === undefined ? null : chrome.runtime.id,
                getURL: typeof chrome.runtime.getURL,
                leaksID: source.includes(id), leaksPattern: source.includes('claude.ai') });
            """, ["id": Self.claudeID])
        XCTAssertEqual(seen["writable"] as? Bool, true)
        XCTAssertEqual(seen["configurable"] as? Bool, true)
        XCTAssertEqual(seen["chromeKeys"] as? [String], ["runtime"])
        XCTAssertEqual(seen["runtimeKeys"] as? [String], ["connect", "lastError", "sendMessage"])
        XCTAssertTrue(seen["id"] is NSNull, "a web page has no extension id")
        XCTAssertEqual(seen["getURL"] as? String, "undefined", "no extension URLs for a web page")
        XCTAssertEqual(seen["leaksID"] as? Bool, false, "the table is not readable from the functions' source")
        XCTAssertEqual(seen["leaksPattern"] as? Bool, false)
    }

    // MARK: - sendMessage

    /// A listed id is forwarded to WebKit's function with the id and the
    /// message only, and its answer comes back in both forms.
    func testListedIDIsForwardedToWebKitInBothForms() async throws {
        let view = try await makePage("https://claude.ai/login")
        let viaCallback = try await callbackOutcome(view, id: Self.claudeID,
                                                    message: ["type": "oauth_redirect", "redirect_uri": "x"])
        XCTAssertEqual(viaCallback["argc"] as? Int, 1)
        XCTAssertEqual((viaCallback["reply"] as? [String: Any])?["native"] as? Bool, true, "\(viaCallback)")
        XCTAssertTrue(viaCallback["lastError"] is NSNull)
        XCTAssertEqual(viaCallback["returned"] as? String, "undefined")
        let calls = try XCTUnwrap(viaCallback["nativeCalls"] as? [[String: Any]])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?["id"] as? String, Self.claudeID)
        XCTAssertEqual(calls.first?["argc"] as? Int, 2, "WebKit gets the id and the message, not the page's callback")
        XCTAssertEqual((calls.first?["message"] as? [String: Any])?["type"] as? String, "oauth_redirect")
        XCTAssertEqual(viaCallback["consoleErrors"] as? [String], [])

        let viaPromise = try await promiseOutcome(view, id: Self.claudeID, message: ["type": "ping"])
        XCTAssertEqual(viaPromise["settled"] as? String, "resolved")
        XCTAssertEqual((viaPromise["value"] as? [String: Any])?["native"] as? Bool, true)

        // An options argument is accepted and not passed on.
        let withOptions = try await evaluate(view, """
            window.__nativeCalls.length = 0;
            const viaPromise = await chrome.runtime.sendMessage(id, { n: 1 }, { includeTlsChannelId: false });
            const viaCallback = await new Promise((resolve) => chrome.runtime.sendMessage(id, { n: 2 }, {}, resolve));
            return JSON.stringify({ viaPromise: viaPromise.message.n, viaCallback: viaCallback.message.n,
                argcs: window.__nativeCalls.map((call) => call.argc) });
            """, ["id": Self.claudeID])
        XCTAssertEqual(withOptions["viaPromise"] as? Int, 1)
        XCTAssertEqual(withOptions["viaCallback"] as? Int, 2)
        XCTAssertEqual(withOptions["argcs"] as? [Int], [2, 2])

        // A listener that answers nothing: undefined, no error.
        let silent = try await callbackOutcome(view, id: Self.claudeID, message: ["type": "silent"])
        XCTAssertNil(silent["timedOut"])
        XCTAssertTrue(silent["lastError"] is NSNull)
    }

    /// An id this page may not reach is never passed to WebKit, and fails with
    /// Chrome's error in both forms.
    func testUnlistedIDFailsLikeChromeAndNeverReachesWebKit() async throws {
        let view = try await makePage("https://claude.ai/", table: [
            Self.claudeID: ["https://claude.ai/*"], Self.otherID: ["https://example.com/*"],
        ])
        for id in [Self.otherID, "ponmlkjihgfedcbaponmlkjihgfedcba", "", "__proto__", "constructor"] {
            let viaCallback = try await callbackOutcome(view, id: id, message: ["type": "hello"])
            XCTAssertEqual(viaCallback["lastError"] as? String, Self.noReceiver, "id \(id): \(viaCallback)")
            XCTAssertEqual(viaCallback["argc"] as? Int, 0)
            XCTAssertNil(viaCallback["lastErrorAfter"] as? String, "lastError is cleared after the callback")
            XCTAssertEqual(viaCallback["returned"] as? String, "undefined")
            XCTAssertEqual(viaCallback["consoleErrors"] as? [String], [], "a lastError that was read is not logged")
            let viaPromise = try await promiseOutcome(view, id: id, message: ["type": "hello"])
            XCTAssertEqual(viaPromise["settled"] as? String, "rejected", "id \(id): \(viaPromise)")
            XCTAssertEqual(viaPromise["message"] as? String, Self.noReceiver)
            XCTAssertEqual(viaPromise["isError"] as? Bool, true)
            XCTAssertEqual((viaPromise["nativeCalls"] as? [Any])?.count, 0, "WebKit is never asked about id \(id)")
        }
    }

    /// The failure is asynchronous — the call returns first — exactly as a
    /// delivered message's answer is.
    func testFailureIsReportedAfterTheCallReturns() async throws {
        let view = try await makePage("https://claude.ai/")
        let order = try await evaluate(view, """
            const events = [];
            await new Promise((resolve) => {
                chrome.runtime.sendMessage(id, {}, () => { void chrome.runtime.lastError; events.push('callback'); resolve(); });
                events.push('returned');
            });
            return JSON.stringify({ events: events });
            """, ["id": Self.otherID])
        XCTAssertEqual(order["events"] as? [String], ["returned", "callback"])
    }

    /// A WebKit failure for a listed id surfaces the same two ways; a
    /// synchronous throw from WebKit (a message it cannot serialise) stays a
    /// synchronous throw.
    func testWebKitFailureSurfacesAsLastErrorRejectionOrThrow() async throws {
        let view = try await makePage("https://claude.ai/")
        let viaCallback = try await callbackOutcome(view, id: Self.claudeID, message: ["type": "reject"])
        XCTAssertEqual(viaCallback["lastError"] as? String, "native failure", "\(viaCallback)")
        XCTAssertEqual(viaCallback["argc"] as? Int, 0)
        let viaPromise = try await promiseOutcome(view, id: Self.claudeID, message: ["type": "reject"])
        XCTAssertEqual(viaPromise["settled"] as? String, "rejected")
        XCTAssertEqual(viaPromise["message"] as? String, "native failure")
        let thrown = try await evaluate(view, """
            try { chrome.runtime.sendMessage(id, { type: 'throw' }); return JSON.stringify({ threw: null }); }
            catch (e) { return JSON.stringify({ threw: e.message }); }
            """, ["id": Self.claudeID])
        XCTAssertEqual(thrown["threw"] as? String, "native threw")
    }

    /// Chrome logs a `lastError` nobody read; so does the shim, and a callback
    /// that throws is reported as an uncaught error rather than swallowed.
    func testUnreadLastErrorIsLoggedAndACallbackExceptionIsReported() async throws {
        let view = try await makePage("https://claude.ai/")
        let unread = try await callbackOutcome(view, id: Self.otherID, message: [:], readLastError: false)
        XCTAssertEqual(unread["consoleErrors"] as? [String], ["Unchecked runtime.lastError: \(Self.noReceiver)"])

        // The callbacks live in a script of the page itself, as a site's do:
        // an error thrown from code without a URL is reported as "Script error.".
        let page = try await makePage("https://claude.ai/", html: """
            <html><body><script>
            window.__outcomes = [];
            window.__send = (listed, unlisted) => {
                chrome.runtime.sendMessage(listed, { n: 1 }, () => { window.__outcomes.push('delivered'); throw new Error('from the delivered callback'); });
                chrome.runtime.sendMessage(unlisted, { n: 2 }, () => { void chrome.runtime.lastError; window.__outcomes.push('failed'); throw new Error('from the failed callback'); });
            };
            </script></body></html>
            """)
        let thrown = try await evaluate(page, """
            const errors = [];
            const rejections = [];
            const onError = (event) => { errors.push(String(event.message)); event.preventDefault(); };
            const onRejection = (event) => { rejections.push(String(event.reason)); event.preventDefault(); };
            window.addEventListener('error', onError);
            window.addEventListener('unhandledrejection', onRejection);
            window.__send(listed, unlisted);
            await new Promise((resolve) => setTimeout(resolve, 150));
            window.removeEventListener('error', onError);
            window.removeEventListener('unhandledrejection', onRejection);
            return JSON.stringify({ errors: errors.sort(), rejections: rejections, outcomes: window.__outcomes.sort(),
                lastErrorAfter: chrome.runtime.lastError === undefined ? null : 'still set' });
            """, ["listed": Self.claudeID, "unlisted": Self.otherID])
        XCTAssertEqual(thrown["outcomes"] as? [String], ["delivered", "failed"])
        let errors = try XCTUnwrap(thrown["errors"] as? [String])
        XCTAssertEqual(errors.count, 2, "\(errors)")
        XCTAssertTrue(errors[0].contains("from the delivered callback"), "\(errors)")
        XCTAssertTrue(errors[1].contains("from the failed callback"), "\(errors)")
        XCTAssertEqual(thrown["rejections"] as? [String], [], "never as a rejection of one of the shim's promises")
        XCTAssertTrue(thrown["lastErrorAfter"] is NSNull, "lastError is cleared even when the callback throws")
    }

    /// The argument forms Chrome refuses from a web page throw a TypeError
    /// before anything is sent.
    func testCallsWithoutAnExtensionIDThrow() async throws {
        let view = try await makePage("https://claude.ai/")
        let outcome = try await evaluate(view, """
            const attempt = (run) => { try { run(); return 'no throw'; } catch (e) { return (e instanceof TypeError ? 'TypeError: ' : 'Error: ') + e.message; } };
            const forms = {
                noArguments: attempt(() => chrome.runtime.sendMessage()),
                messageOnly: attempt(() => chrome.runtime.sendMessage({ type: 'hello' })),
                idOnly: attempt(() => chrome.runtime.sendMessage(id)),
                messageAndCallback: attempt(() => chrome.runtime.sendMessage({ type: 'hello' }, () => {})),
                messageAndOptions: attempt(() => chrome.runtime.sendMessage({ type: 'hello' }, {})),
                nullID: attempt(() => chrome.runtime.sendMessage(null, { type: 'hello' })),
                tooMany: attempt(() => chrome.runtime.sendMessage(id, {}, {}, {})),
                connectNoArguments: attempt(() => chrome.runtime.connect()),
                connectInfoOnly: attempt(() => chrome.runtime.connect({ name: 'x' })),
                connectBadInfo: attempt(() => chrome.runtime.connect(id, 'name'))
            };
            return JSON.stringify({ forms: forms, calls: window.__nativeCalls.length });
            """, ["id": Self.claudeID])
        let forms = try XCTUnwrap(outcome["forms"] as? [String: String])
        XCTAssertEqual(forms.count, 10)
        for (form, result) in forms {
            XCTAssertTrue(result.hasPrefix("TypeError: Error in invocation of runtime."), "\(form): \(result)")
        }
        XCTAssertTrue(forms["messageOnly"]?.contains(
            "chrome.runtime.sendMessage() called from a webpage must specify an Extension ID (string) for its first argument.") == true)
        XCTAssertTrue(forms["connectNoArguments"]?.contains(
            "chrome.runtime.connect() called from a webpage must specify an Extension ID (string) for its first argument.") == true)
        XCTAssertEqual(outcome["calls"] as? Int, 0, "a refused call reaches WebKit with nothing")
    }

    // MARK: - connect

    /// A listed id gets WebKit's own port; a connection WebKit reports as
    /// failed (`port.error`) shows as `runtime.lastError` in `onDisconnect`.
    func testConnectForwardsAListedIDAndMapsWebKitsPortError() async throws {
        let view = try await makePage("https://claude.ai/")
        let outcome = try await evaluate(view, """
            const port = chrome.runtime.connect(id, { name: 'p' });
            const bare = chrome.runtime.connect(id);
            const calls = window.__nativeCalls.map((call) => ({ fn: call.fn, id: call.id, argc: call.argc, info: call.info }));
            const seen = [];
            port.onDisconnect.addListener(() => seen.push(chrome.runtime.lastError ? chrome.runtime.lastError.message : null));
            port.__fire();                       // an ordinary disconnect
            port.error = { message: 'no runtime.onConnectExternal listeners found' };
            port.__fire();                       // a failed connection
            await new Promise((resolve) => setTimeout(resolve, 20));
            return JSON.stringify({ name: port.name, isNative: typeof port.__fire, calls: calls, seen: seen,
                lastErrorAfter: chrome.runtime.lastError === undefined ? null : 'still set',
                consoleErrors: window.__consoleErrors });
            """, ["id": Self.claudeID])
        XCTAssertEqual(outcome["isNative"] as? String, "function", "the page gets the port WebKit made")
        let calls = try XCTUnwrap(outcome["calls"] as? [[String: Any]])
        XCTAssertEqual(calls.map { $0["argc"] as? Int }, [2, 1])
        XCTAssertEqual((calls.first?["info"] as? [String: Any])?["name"] as? String, "p")
        let seen = try XCTUnwrap(outcome["seen"] as? [Any])
        XCTAssertTrue(seen.first is NSNull, "no lastError for an ordinary disconnect: \(seen)")
        XCTAssertEqual(seen.last as? String, Self.noReceiver)
        XCTAssertTrue(outcome["lastErrorAfter"] is NSNull)
        XCTAssertEqual(outcome["consoleErrors"] as? [String], [])
    }

    /// An unlisted id gets a port that never reaches WebKit: it accepts a post
    /// until it reports the disconnect with `lastError`, then refuses; a port
    /// the page disconnects first reports nothing.
    func testConnectToAnUnlistedIDGivesAPortThatDisconnectsWithLastError() async throws {
        let view = try await makePage("https://claude.ai/")
        let outcome = try await evaluate(view, """
            const out = { events: [] };
            const port = chrome.runtime.connect(id, { name: 'claude' });
            out.name = port.name;
            const removed = () => out.events.push('removed listener ran');
            port.onDisconnect.addListener(removed);
            out.hasListener = port.onDisconnect.hasListener(removed);
            port.onDisconnect.removeListener(removed);
            port.onMessage.addListener(() => out.events.push('message'));
            try { port.postMessage({ early: true }); out.earlyPost = 'ok'; } catch (e) { out.earlyPost = e.message; }
            await new Promise((resolve) => {
                port.onDisconnect.addListener((p) => {
                    out.events.push({ samePort: p === port, lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                    resolve();
                });
            });
            try { port.postMessage({ late: true }); out.latePost = 'ok'; } catch (e) { out.latePost = e.message; }
            out.lastErrorAfter = chrome.runtime.lastError === undefined ? null : 'still set';

            const closedFirst = chrome.runtime.connect(id);
            out.defaultName = closedFirst.name;
            let fired = false;
            closedFirst.onDisconnect.addListener(() => { fired = true; });
            closedFirst.disconnect();
            await new Promise((resolve) => setTimeout(resolve, 50));
            out.firedAfterOwnDisconnect = fired;
            out.calls = window.__nativeCalls.length;
            out.consoleErrors = window.__consoleErrors;
            return JSON.stringify(out);
            """, ["id": Self.otherID])
        XCTAssertEqual(outcome["name"] as? String, "claude")
        XCTAssertEqual(outcome["defaultName"] as? String, "")
        XCTAssertEqual(outcome["hasListener"] as? Bool, true)
        XCTAssertEqual(outcome["earlyPost"] as? String, "ok")
        XCTAssertEqual(outcome["latePost"] as? String, "Attempting to use a disconnected port object")
        let events = try XCTUnwrap(outcome["events"] as? [Any])
        XCTAssertEqual(events.count, 1, "only the remaining onDisconnect listener ran: \(events)")
        XCTAssertEqual((events.first as? [String: Any])?["lastError"] as? String, Self.noReceiver)
        XCTAssertEqual((events.first as? [String: Any])?["samePort"] as? Bool, true)
        XCTAssertTrue(outcome["lastErrorAfter"] is NSNull)
        XCTAssertEqual(outcome["firedAfterOwnDisconnect"] as? Bool, false)
        XCTAssertEqual(outcome["calls"] as? Int, 0, "WebKit is never asked to connect to an unlisted id")
        XCTAssertEqual(outcome["consoleErrors"] as? [String], [])
    }

    // MARK: - Live updates

    /// `updateJS` replaces the ids an open document may reach: a revoked id
    /// fails like any unlisted one, an added id is forwarded.
    func testUpdateEventReplacesTheReachableIDs() async throws {
        let view = try await makePage("https://claude.ai/")
        _ = try await view.evaluateJavaScript(ExternallyConnectable.updateJS(ids: []))
        let revoked = try await promiseOutcome(view, id: Self.claudeID, message: ["n": 1])
        XCTAssertEqual(revoked["message"] as? String, Self.noReceiver, "\(revoked)")
        XCTAssertEqual((revoked["nativeCalls"] as? [Any])?.count, 0)

        _ = try await view.evaluateJavaScript(ExternallyConnectable.updateJS(ids: [Self.otherID]))
        let added = try await promiseOutcome(view, id: Self.otherID, message: ["n": 2])
        XCTAssertEqual(added["settled"] as? String, "resolved", "\(added)")
        let stillRevoked = try await promiseOutcome(view, id: Self.claudeID, message: ["n": 3])
        XCTAssertEqual(stillRevoked["settled"] as? String, "rejected")

        // Anything that is not a list of strings reaches nothing.
        _ = try await view.evaluateJavaScript(
            "window.dispatchEvent(new CustomEvent('\(ExternallyConnectable.updateEventName)', { detail: { '\(Self.claudeID)': true } })); 0")
        let garbage = try await promiseOutcome(view, id: Self.claudeID, message: ["n": 4])
        XCTAssertEqual(garbage["settled"] as? String, "rejected")
    }

    /// The update is for one document: `WKWebView.url` is the pending URL
    /// during a provisional navigation, and the page still showing must not
    /// be handed the ids of the extensions that list the page being loaded.
    func testUpdateForAnotherDocumentIsNotDispatched() async throws {
        let view = try await makePage("https://example.com/", before: """
            window.__updates = [];
            window.addEventListener('\(ExternallyConnectable.updateEventName)', (event) => { window.__updates.push(event.detail); });
            """)
        let pending = try XCTUnwrap(URL(string: "https://claude.ai/"))
        _ = try await view.evaluateJavaScript(ExternallyConnectable.updateJS(ids: [Self.claudeID], forDocumentAt: pending))
        let unseen = try await evaluate(view, "return JSON.stringify({ updates: window.__updates });")
        XCTAssertEqual((unseen["updates"] as? [Any])?.count, 0, "\(unseen)")

        let own = try XCTUnwrap(view.url)
        _ = try await view.evaluateJavaScript(ExternallyConnectable.updateJS(ids: [Self.otherID], forDocumentAt: own))
        let seen = try await evaluate(view, "return JSON.stringify({ updates: window.__updates });")
        XCTAssertEqual(seen["updates"] as? [[String]], [[Self.otherID]], "the document the ids were matched for gets them: \(seen)")
    }

    /// Trailing optional arguments passed as `undefined` are the same as
    /// leaving them out, as in Chrome.
    func testTrailingUndefinedArgumentsAreAccepted() async throws {
        let view = try await makePage("https://claude.ai/")
        let outcome = try await evaluate(view, """
            const a = await chrome.runtime.sendMessage(id, { n: 1 }, undefined, undefined);
            const b = await new Promise((resolve) => chrome.runtime.sendMessage(id, { n: 2 }, undefined, resolve));
            return JSON.stringify({ a: a, b: b, calls: window.__nativeCalls.length });
            """, ["id": Self.claudeID])
        XCTAssertEqual((outcome["a"] as? [String: Any])?["native"] as? Bool, true, "\(outcome)")
        XCTAssertEqual((outcome["b"] as? [String: Any])?["native"] as? Bool, true, "\(outcome)")
        XCTAssertEqual(outcome["calls"] as? Int, 2)
    }

    // MARK: - The table

    private func pattern(_ string: String) throws -> WKWebExtension.MatchPattern {
        try WKWebExtension.MatchPattern(string: string)
    }

    func testOnlyPatternsWebKitHonoursAreOffered() throws {
        let accepted: Set = [try pattern("https://claude.ai/*"), try pattern("https://*.claude.ai/*"),
                             try pattern("<all_urls>"), try pattern("*://*/*")]
        let offered = ExternallyConnectable.matchPatterns(
            ["https://claude.ai/*", "<all_urls>", "*://*/*", "https://*/*", "not a pattern", "ftp://claude.ai/*",
             "https://unlisted.example/*", "https://*.claude.ai/*", "https://claude.ai/*"],
            acceptedByWebKit: accepted)
        XCTAssertEqual(offered.map(\.string), ["https://claude.ai/*", "https://*.claude.ai/*"],
                       "all-URL and all-host patterns, bad ones, ones WebKit did not accept and repeats are dropped")
    }

    /// Against a real `WKWebExtension`: WebKit drops `<all_urls>` and a public
    /// suffix from `externally_connectable`, and so does the table.
    func testMatchPatternsOfARealExtensionFollowWebKit() async throws {
        let manifest = """
        { "manifest_version": 3, "name": "EC", "version": "1.0",
          "externally_connectable": { "matches": ["https://claude.ai/*", "https://*.claude.ai/*", "<all_urls>", "*://*.com/*"] } }
        """
        let ext = try await makeTestExtension(id: "ec-\(UUID().uuidString.prefix(8))", manifestJSON: manifest)
        tempDirs.append(ext.basePath)
        XCTAssertEqual(ExternallyConnectable.matchPatterns(for: ext).map(\.string),
                       ["https://claude.ai/*", "https://*.claude.ai/*"])

        let none = try await makeTestExtension(id: "ec-\(UUID().uuidString.prefix(8))",
                                               manifestJSON: #"{ "manifest_version": 3, "name": "None", "version": "1.0" }"#)
        tempDirs.append(none.basePath)
        XCTAssertEqual(ExternallyConnectable.matchPatterns(for: none), [])

        let malformed = try await makeTestExtension(
            id: "ec-\(UUID().uuidString.prefix(8))",
            manifestJSON: #"{ "manifest_version": 3, "name": "Bad", "version": "1.0", "externally_connectable": { "matches": "https://claude.ai/*" } }"#)
        tempDirs.append(malformed.basePath)
        XCTAssertEqual(ExternallyConnectable.matchPatterns(for: malformed), [], "a malformed entry offers nothing")
    }

    func testConnectableIDsAreTheOnesWhosePatternsMatchTheURL() throws {
        let table = try table([Self.claudeID: ["https://claude.ai/*", "https://*.claude.ai/*"],
                               Self.otherID: ["https://example.com/app/*"]])
        XCTAssertEqual(ExternallyConnectable.connectableIDs(in: table, for: URL(string: "https://claude.ai/login")), [Self.claudeID])
        XCTAssertEqual(ExternallyConnectable.connectableIDs(in: table, for: URL(string: "https://example.com/app/x")), [Self.otherID])
        XCTAssertEqual(ExternallyConnectable.connectableIDs(in: table, for: URL(string: "https://example.com/")), [])
        XCTAssertEqual(ExternallyConnectable.connectableIDs(in: table, for: nil), [])
    }

    func testNoScriptWithoutAnyPattern() throws {
        XCTAssertNil(ExternallyConnectable.userScriptSource(for: [:]))
        XCTAssertNil(ExternallyConnectable.userScriptSource(for: [Self.claudeID: []]))
        let source = try XCTUnwrap(ExternallyConnectable.userScriptSource(for: try table(Self.claudeTable)))
        XCTAssertTrue(source.hasPrefix(ExternallyConnectable.scriptMarker))
        XCTAssertFalse(source.contains("__DETOUR_"), "every placeholder is filled in")
    }

    // MARK: - Keeping the script on a content controller

    private func shimCount(_ controller: WKUserContentController) -> Int {
        controller.userScripts.filter { $0.source.hasPrefix(ExternallyConnectable.scriptMarker) }.count
    }

    /// The script follows the loaded extensions: absent with none, one copy
    /// with some, replaced when the table changes, gone when the last listing
    /// extension unloads — and the controller's other scripts stay, in order.
    func testPagesKeepsOneCurrentScriptAndEveryOtherScript() throws {
        let pages = ExternallyConnectablePages()
        let controller = WKUserContentController()
        let world = WKContentWorld.world(name: "DetourTestWorld")
        controller.addUserScript(WKUserScript(source: "/* first */", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: "/* second */", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        func others() -> [String] {
            controller.userScripts.map(\.source).filter { !$0.hasPrefix(ExternallyConnectable.scriptMarker) }
        }

        pages.install(on: controller)
        XCTAssertEqual(shimCount(controller), 0, "nothing is installed while no extension lists a page")
        XCTAssertEqual(controller.userScripts.count, 2)

        pages.extensionDidLoad(Self.claudeID, matchPatterns: [try pattern("https://claude.ai/*")])
        XCTAssertEqual(shimCount(controller), 1, "a controller installed earlier is brought up to date")
        XCTAssertEqual(others(), ["/* first */", "/* second */"])
        let first = try XCTUnwrap(controller.userScripts.last)
        XCTAssertEqual(first.injectionTime, .atDocumentStart)
        XCTAssertFalse(first.isForMainFrameOnly, "frames get it too")
        XCTAssertTrue(first.source.contains(Self.claudeID))

        pages.install(on: controller)
        XCTAssertEqual(shimCount(controller), 1, "installing twice does not add a second copy")

        pages.extensionDidLoad(Self.otherID, matchPatterns: [try pattern("https://example.com/*")])
        XCTAssertEqual(shimCount(controller), 1)
        XCTAssertEqual(others(), ["/* first */", "/* second */"], "the other scripts survive a replacement, in order")
        let second = try XCTUnwrap(controller.userScripts.last)
        XCTAssertTrue(second.source.contains(Self.otherID) && second.source.contains(Self.claudeID))
        XCTAssertEqual(controller.userScripts.filter { $0.isForMainFrameOnly }.map(\.source), ["/* second */"])

        // An extension that lists nothing changes nothing.
        pages.extensionDidLoad("nopatternsnopatternsnopatternsno", matchPatterns: [])
        XCTAssertTrue(controller.userScripts.last === second, "an unchanged table leaves the script object in place")

        pages.extensionDidUnload(Self.claudeID)
        XCTAssertEqual(shimCount(controller), 1)
        XCTAssertFalse(try XCTUnwrap(controller.userScripts.last).source.contains(Self.claudeID),
                       "an unloaded extension's id is gone from the script")
        pages.extensionDidUnload(Self.otherID)
        XCTAssertEqual(shimCount(controller), 0, "no listing extension, no script")
        XCTAssertEqual(others(), ["/* first */", "/* second */"])

        // A controller installed while a table exists gets the script at once.
        pages.extensionDidLoad(Self.claudeID, matchPatterns: [try pattern("https://claude.ai/*")])
        let late = WKUserContentController()
        pages.install(on: late)
        XCTAssertEqual(shimCount(late), 1)
        XCTAssertEqual(pages.table.keys.sorted(), [Self.claudeID])
    }

    /// The profile wiring: a tab configuration built by `Space` carries the
    /// script exactly when an extension loaded in that profile lists a page,
    /// and another profile's configuration never does.
    func testSpaceConfigurationCarriesTheScriptOfItsOwnProfileOnly() async throws {
        let manifest = """
        { "manifest_version": 3, "name": "EC", "version": "1.0",
          "externally_connectable": { "matches": ["https://claude.ai/*"] } }
        """
        let ext = try await makeTestExtension(id: Self.chromeStyleID(), manifestJSON: manifest)
        tempDirs.append(ext.basePath)
        // Incognito, so neither profile creates storage on disk.
        let home = Profile(name: "ec-home", isIncognito: true)
        let other = Profile(name: "ec-other", isIncognito: true)
        home.extensionController = WKWebExtensionController(configuration: .nonPersistent())
        other.extensionController = WKWebExtensionController(configuration: .nonPersistent())
        defer { home.unloadAllExtensions() }
        let homeSpace = Space(name: "h", emoji: "h", colorHex: "007AFF", profileID: home.id)
        homeSpace.profile = home
        let otherSpace = Space(name: "o", emoji: "o", colorHex: "007AFF", profileID: other.id)
        otherSpace.profile = other

        let before = homeSpace.makeWebViewConfiguration().userContentController
        XCTAssertEqual(shimCount(before), 0)

        _ = try loadTestContext(ext, in: home)
        XCTAssertEqual(home.externallyConnectablePages.table[ext.id]?.map(\.string), ["https://claude.ai/*"])
        XCTAssertEqual(shimCount(before), 1, "a configuration built before the extension loaded is brought up to date")
        XCTAssertEqual(shimCount(homeSpace.makeWebViewConfiguration().userContentController), 1)
        XCTAssertEqual(shimCount(otherSpace.makeWebViewConfiguration().userContentController), 0,
                       "a profile where the extension is not loaded gets nothing")
        XCTAssertTrue(other.externallyConnectablePages.table.isEmpty)

        home.unloadExtension(id: ext.id)
        XCTAssertEqual(shimCount(before), 0, "unloading (disable, uninstall) takes the script away")
        XCTAssertEqual(shimCount(homeSpace.makeWebViewConfiguration().userContentController), 0)
    }

    private static func chromeStyleID() -> String {
        String((0..<32).map { _ in "abcdefghijklmnop".randomElement()! })
    }
}
