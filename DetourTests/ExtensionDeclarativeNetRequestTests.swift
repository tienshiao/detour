import XCTest
import WebKit
@testable import Detour

/// TASK-132.4: `chrome.declarativeNetRequest` session rules that modify request
/// headers, end to end — a real extension context (its service worker over the
/// native-message transport and an extension page over the script message
/// handler), the real polyfill, and a loopback HTTP server that records the
/// headers each request arrived with. Nothing here talks to a real API host.
///
/// The rule under test has the shape of the Claude extension's start-up rule:
/// `modifyHeaders` setting `User-Agent`, `anthropic-client-platform` and
/// `anthropic-client-version` for `<api host>/*`, resource types
/// `xmlhttprequest` and `other`.
///
/// Three tests are *canaries* for the WebKit behaviour the fallback rests on
/// (see `ExtensionAPIPolyfill.declarativeNetRequestJS`): WebKit refuses a header
/// name outside its own list, applies an accepted rule to a page's requests,
/// and does not apply it to the worker's. If one fails, WebKit changed and the
/// fallback has to be looked at again — the failure message says which way.
///
/// The pure matching and combining rules are `ExtensionHeaderRulesTests`.
@MainActor
final class ExtensionDeclarativeNetRequestTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var pages: [WKWebView] = []
    private var createdSpaceIDs: [UUID] = []
    private var servers: [LoopbackHTTPServer] = []
    /// The fixture standing in for the API host.
    private var server: LoopbackHTTPServer!
    private var serverPort: UInt16 = 0

    /// Profiles whose extension controller hosted a web view stay alive for the
    /// rest of the test process: releasing one takes its process pool down, and
    /// WebKit traps when that lands inside an IPC dispatch (as in
    /// `ExtensionTabResolveTests`).
    private static var retainedProfiles: [Profile] = []

    override func setUp() async throws {
        try await super.setUp()
        (server, serverPort) = try await startServer()
    }

    override func tearDown() async throws {
        for page in pages { page.stopLoading() }
        pages.removeAll()
        for id in createdSpaceIDs {
            guard let space = TabStore.shared.space(withID: id) else { continue }
            for tab in space.tabs {
                TabStore.shared.closeTab(id: tab.id, in: space, undoable: false, registersUndo: false)
            }
            TabStore.shared.forceRemoveSpace(id: id)
        }
        if !createdSpaceIDs.isEmpty {
            TabStore.shared.undoManager.removeAllActions()
            TabStore.shared.saveNow()
        }
        createdSpaceIDs.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            TabStore.shared.forceRemoveProfile(id: profile.id)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for server in servers { server.stop() }
        servers.removeAll()
        server = nil
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    private func startServer() async throws -> (LoopbackHTTPServer, UInt16) {
        let server = try LoopbackHTTPServer(routes: [
            "/api": "fixture",
            "/blocked": "fixture",
            "/page": "<html><head><title>tab page</title></head><body>tab page</body></html>",
        ])
        let port = try await server.start()
        servers.append(server)
        return (server, port)
    }

    // MARK: - Fixture extension

    /// What a test asks a JS context to do, written once and run in both
    /// contexts: the worker carries it in its script, the page gets it with
    /// each `callAsyncJavaScript`.
    private static let opJS = """
    async function __detourTestDnrOp(message) {
        const settle = async (make) => {
            try {
                const value = await make();
                return { settled: 'resolved', value: value === undefined ? null : value };
            } catch (e) {
                return { settled: 'rejected', message: String(e && e.message ? e.message : e) };
            }
        };
        const dnr = chrome.declarativeNetRequest;
        switch (message.op) {
        case 'state': {
            const out = {
                dnrType: typeof dnr,
                diag: globalThis.__detourDeclarativeNetRequest,
                contextKind: globalThis.__detourContextKind,
                runtimeConstants: globalThis.__detourRuntimeConstantsInstall,
                onInstalledReason: chrome.runtime.OnInstalledReason || null,
                onInstalledReasonViaBrowser: browser.runtime.OnInstalledReason
                    ? browser.runtime.OnInstalledReason.INSTALL : null,
                fetchWrapped: fetch._detourHeaderRulesWrapper === true,
                xhrType: typeof XMLHttpRequest,
                xhrWrapped: typeof XMLHttpRequest === 'function'
                    && XMLHttpRequest.prototype.send._detourHeaderRulesWrapper === true
            };
            if (dnr) {
                out.ruleActionType = dnr.RuleActionType || null;
                out.headerOperation = dnr.HeaderOperation || null;
                out.resourceType = dnr.ResourceType || null;
                out.sessionRulesetID = dnr.SESSION_RULESET_ID || null;
                out.frozen = Object.isFrozen(dnr.RuleActionType);
                out.held = globalThis.__detourHeldWrappers.declarativeNetRequest === chrome.declarativeNetRequest;
                out.updateWrapped = dnr.updateSessionRules._detourHeaderRulesWrapper === true;
                out.getWrapped = dnr.getSessionRules._detourHeaderRulesWrapper === true;
                out.nativeUpdateKept = __detourNativeness(dnr.updateSessionRules._detourNative);
                out.nativeFetchKept = __detourNativeness(fetch._detourNative);
                out.maxRulesType = typeof dnr.MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES;
                out.viaBrowser = browser.declarativeNetRequest.RuleActionType
                    ? browser.declarativeNetRequest.RuleActionType.MODIFY_HEADERS : null;
                out.browserUpdateWrapped = browser.declarativeNetRequest.updateSessionRules._detourHeaderRulesWrapper === true;
            }
            return out;
        }
        case 'update':
            return await settle(() => dnr.updateSessionRules(message.options));
        case 'updateWithEnums':
            // The rule as the Claude extension builds it: out of the enums.
            return await settle(() => dnr.updateSessionRules({
                removeRuleIds: [1],
                addRules: [{
                    id: 1, priority: 1,
                    action: {
                        type: dnr.RuleActionType.MODIFY_HEADERS,
                        requestHeaders: [
                            { header: 'User-Agent', operation: dnr.HeaderOperation.SET, value: message.userAgent },
                            { header: 'anthropic-client-platform', operation: dnr.HeaderOperation.SET, value: 'claude_browser_extension' },
                            { header: 'anthropic-client-version', operation: dnr.HeaderOperation.SET, value: '1.0.98' }
                        ]
                    },
                    condition: {
                        urlFilter: message.base + '/*',
                        resourceTypes: [dnr.ResourceType.XMLHTTPREQUEST, dnr.ResourceType.OTHER]
                    }
                }]
            }));
        case 'updateCallback':
            return await new Promise((resolve) => {
                const returned = dnr.updateSessionRules(message.options, function() {
                    resolve({
                        argc: arguments.length,
                        lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null,
                        returnedType: typeof returned
                    });
                });
            });
        case 'nativeUpdate':
            return await settle(() => dnr.updateSessionRules._detourNative.call(dnr, message.options));
        case 'getRules':
            return await settle(() => message.filter ? dnr.getSessionRules(message.filter) : dnr.getSessionRules());
        case 'getRulesCallback':
            return await new Promise((resolve) => dnr.getSessionRules((rules) => resolve({ rules: rules })));
        case 'nativeGetRules':
            return await settle(() => dnr.getSessionRules._detourNative.call(dnr));
        case 'fetch':
            return await settle(async () => {
                const init = { cache: 'no-store' };
                if (message.headers) init.headers = message.headers;
                if (message.method) init.method = message.method;
                if (message.body) init.body = message.body;
                const doFetch = message.native ? fetch._detourNative : fetch;
                const target = message.asRequest ? new Request(message.url, init) : message.url;
                const response = message.asRequest ? await doFetch(target) : await doFetch(target, init);
                return { status: response.status, text: (await response.text()).slice(0, 40) };
            });
        case 'xhr':
            return await settle(() => new Promise((resolve, reject) => {
                const xhr = new XMLHttpRequest();
                xhr.open('GET', message.url);
                for (const name of Object.keys(message.headers || {})) xhr.setRequestHeader(name, message.headers[name]);
                xhr.onload = () => resolve({ status: xhr.status, text: String(xhr.responseText).slice(0, 40) });
                xhr.onerror = () => reject(new Error('xhr error'));
                const events = [];
                xhr.onabort = () => events.push('abort');
                xhr.onloadend = () => { events.push('loadend'); if (events[0] === 'abort') reject(new Error('xhr aborted: ' + events.join(','))); };
                xhr.send();
                if (message.abort) xhr.abort();
            }));
        case 'xhrReopen':
            // send(), then open() again at once: the first send is still
            // waiting for Detour's answer and must never go out.
            return await settle(() => new Promise((resolve, reject) => {
                const xhr = new XMLHttpRequest();
                xhr.open('GET', message.first);
                xhr.send();
                xhr.open('GET', message.url);
                xhr.onload = () => resolve({ status: xhr.status, text: String(xhr.responseText).slice(0, 40), responseURL: xhr.responseURL });
                xhr.onerror = () => reject(new Error('xhr error'));
                xhr.send();
            }));
        case 'xhrMisuse':
            // What a page must still get as exceptions from the calls
            // themselves while (and after) send() waits for Detour's answer.
            return await settle(() => new Promise((resolve, reject) => {
                const name = (run) => { try { run(); return 'no throw'; } catch (e) { return e.name; } };
                const xhr = new XMLHttpRequest();
                xhr.open('GET', message.url);
                xhr.onerror = () => reject(new Error('xhr error'));
                xhr.send();
                const secondSend = name(() => xhr.send());
                const lateHeader = name(() => xhr.setRequestHeader('x-late', '1'));
                // A failing open() changes nothing: the waiting send still goes.
                const badOpen = name(() => xhr.open('BAD METHOD', message.url));
                xhr.onload = () => resolve({
                    status: xhr.status, secondSend: secondSend, lateHeader: lateHeader, badOpen: badOpen,
                    unopened: name(() => new XMLHttpRequest().send())
                });
            }));
        case 'raw':
            return await settle(() => __detourPolyfillRequest(message.type, message.params || {}));
        }
        throw new Error('unknown op ' + message.op);
    }
    """

    /// An MV3 extension with a (module) service worker and one page. The worker
    /// carries the polyfill itself — the user script `Profile.extensionController`
    /// installs reaches web views, not workers. Its declared permissions are
    /// recorded as granted, as `ExtensionManager.install` records them.
    private func makeExtension(permissions: [String], hostPermissions: [String] = ["<all_urls>"]) async throws -> WebExtension {
        let id = "dnr-\(UUID().uuidString.prefix(8).lowercased())"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("detour-test-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let manifestObject: [String: Any] = [
            "manifest_version": 3, "name": "DNR Test", "version": "1.0.0",
            "permissions": permissions, "host_permissions": hostPermissions,
            "background": ["service_worker": "background.js", "type": "module"],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        try "<html><body>dnr test page</body></html>"
            .write(to: dir.appendingPathComponent("test.html"), atomically: true, encoding: .utf8)
        try (ExtensionAPIPolyfill.polyfillJS + "\n\n" + Self.opJS + """


        chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
            if (!message || message.type !== 'dnrOp') return false;
            __detourTestDnrOp(message.payload).then(
                (value) => sendResponse({ ok: true, value: value === undefined ? null : value }),
                (error) => sendResponse({ ok: false, error: String(error && error.message ? error.message : error) }));
            return true;
        });
        """).write(to: dir.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)

        let wkExt = try await WKWebExtension(resourceBaseURL: dir)
        let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
        let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
        ext.wkExtension = wkExt
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        installTestExtension(ext, in: AppDatabase.shared, manifestJSON: manifestData)
        AppDatabase.shared.recordDeclaredPermissions(
            permissions.map { ExtensionPermissionRecord(extensionID: id, key: $0, type: .apiPermission, status: .granted) }
            + hostPermissions.map { ExtensionPermissionRecord(extensionID: id, key: $0, type: .matchPattern, status: .granted) })
        return ext
    }

    private static let permission = "declarativeNetRequestWithHostAccess"

    // MARK: - Fixture world

    /// One profile with the extension loaded: an extension page and the
    /// started worker.
    private struct World {
        let ext: WebExtension
        let profile: Profile
        let context: WKWebExtensionContext
        let page: WKWebView

        var handler: ExtensionPolyfillHandler { profile.polyfillHandler! }
        var heldRules: ExtensionHeaderRuleSet { handler.sessionHeaderRulesForTesting(extensionID: ext.id) }
    }

    private enum Via: String, CaseIterable { case page, worker }

    /// Loads `ext` into `profile`, or into a new profile of its own.
    private func makeWorld(_ ext: WebExtension, in existing: Profile? = nil) async throws -> World {
        let profile: Profile
        if let existing {
            profile = existing
        } else {
            profile = TabStore.shared.addProfile(name: "DNR \(ext.id) \(createdProfiles.count)")
            createdProfiles.append(profile)
        }
        _ = profile.extensionController
        let context = try loadTestContext(ext, in: profile)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        pages.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { error in
            if let error { print("loadBackgroundContent failed: \(error)") }
        }
        let world = World(ext: ext, profile: profile, context: context, page: page)
        // The worker is still starting; an unreachable worker answers nothing.
        try await waitUntil("the worker to answer", timeout: 30) {
            (try? await self.run(.worker, in: world, ["op": "state"])) != nil
        }
        return world
    }

    private func makeWorld(permissions: [String] = [permission],
                           hostPermissions: [String] = ["<all_urls>"]) async throws -> World {
        try await makeWorld(try await makeExtension(permissions: permissions, hostPermissions: hostPermissions))
    }

    // MARK: - Running an op

    private struct OpFailed: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// Runs one op in the page or the worker and returns its value.
    private func run(_ via: Via, in world: World, _ message: [String: Any]) async throws -> [String: Any] {
        let envelope: [String: Any]
        switch via {
        case .page:
            let raw = try await world.page.callAsyncJavaScript(Self.opJS + """

                try {
                    const value = await __detourTestDnrOp(message);
                    return JSON.stringify({ ok: true, value: value === undefined ? null : value });
                } catch (e) {
                    return JSON.stringify({ ok: false, error: String(e && e.message ? e.message : e) });
                }
                """, arguments: ["message": message], contentWorld: .page)
            let json = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
            envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        case .worker:
            let asked = try await askWorker(from: world.page,
                                            message: ["type": "dnrOp", "payload": message], timeout: 20)
            guard let reply = asked["reply"] as? [String: Any] else {
                throw OpFailed(message: "the worker did not answer: \(asked)")
            }
            envelope = reply
        }
        guard envelope["ok"] as? Bool == true else {
            throw OpFailed(message: envelope["error"] as? String ?? "no error text: \(envelope)")
        }
        return try XCTUnwrap(envelope["value"] as? [String: Any], "expected an object, got \(envelope)")
    }

    /// Asserts a `settle`d op resolved and returns its value.
    @discardableResult
    private func resolved(_ outcome: [String: Any], _ what: String,
                          file: StaticString = #filePath, line: UInt = #line) -> Any? {
        XCTAssertEqual(outcome["settled"] as? String, "resolved",
                       "\(what) should resolve, got: \(outcome)", file: file, line: line)
        return outcome["value"]
    }

    /// Asserts a `settle`d op rejected and returns the message.
    private func rejection(_ outcome: [String: Any], _ what: String,
                           file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertEqual(outcome["settled"] as? String, "rejected",
                       "\(what) should reject, got: \(outcome)", file: file, line: line)
        return outcome["message"] as? String ?? ""
    }

    // MARK: - Requests and what the server saw

    private var apiBase: String { "http://127.0.0.1:\(serverPort)" }

    private static let userAgent = "claude-browser-extension/1.0.98 (external) fixture-agent "

    /// The three headers of the Claude extension's rule, lower-cased as the
    /// server reports them. The extension's User-Agent value ends in a space
    /// (so does the fixture's); a field value's trailing whitespace is not
    /// part of it on the wire.
    private static let ruleHeaders = [
        "user-agent": userAgent.trimmingCharacters(in: .whitespaces),
        "anthropic-client-platform": "claude_browser_extension",
        "anthropic-client-version": "1.0.98",
    ]

    private func claudeRule(base: String? = nil, id: Int = 1,
                            condition extra: [String: Any] = [:]) -> [String: Any] {
        var condition: [String: Any] = ["urlFilter": "\(base ?? apiBase)/*",
                                        "resourceTypes": ["xmlhttprequest", "other"]]
        condition.merge(extra) { _, new in new }
        return [
            "id": id, "priority": 1,
            "action": ["type": "modifyHeaders", "requestHeaders": [
                ["header": "User-Agent", "operation": "set", "value": Self.userAgent],
                ["header": "anthropic-client-platform", "operation": "set", "value": "claude_browser_extension"],
                ["header": "anthropic-client-version", "operation": "set", "value": "1.0.98"],
            ]],
            "condition": condition,
        ]
    }

    /// A rule WebKit accepts as it stands: `User-Agent` is in its own list.
    private func userAgentRule(_ value: String, id: Int = 1) -> [String: Any] {
        [
            "id": id, "priority": 1,
            "action": ["type": "modifyHeaders", "requestHeaders": [
                ["header": "User-Agent", "operation": "set", "value": value]]],
            "condition": ["urlFilter": "\(apiBase)/*", "resourceTypes": ["xmlhttprequest", "other"]],
        ]
    }

    private var requestCounter = 0

    /// Makes one request to the fixture and returns the headers it arrived
    /// with. Each request carries its own marker, so what the server recorded
    /// for it is found whatever else was sent.
    private func requestHeaders(_ via: Via, in world: World, kind: String = "fetch", on server: LoopbackHTTPServer? = nil,
                                port: UInt16? = nil, extra: [String: Any] = [:],
                                file: StaticString = #filePath, line: UInt = #line) async throws -> [String: String] {
        requestCounter += 1
        let marker = "m\(requestCounter)-\(via.rawValue)-\(kind)"
        var message: [String: Any] = ["op": kind, "url": "http://127.0.0.1:\(port ?? serverPort)/api?\(marker)"]
        message.merge(extra) { _, new in new }
        let outcome = try await run(via, in: world, message)
        let value = resolved(outcome, "the \(kind) from the \(via)", file: file, line: line) as? [String: Any]
        XCTAssertEqual(value?["status"] as? Int, 200, file: file, line: line)
        XCTAssertEqual(value?["text"] as? String, "fixture",
                       "with host access the response is readable without CORS headers", file: file, line: line)
        let seen = (server ?? self.server).receivedRequests.filter { $0.path.contains(marker) }
        XCTAssertEqual(seen.count, 1, "the server should have seen the request once: \(seen)", file: file, line: line)
        return seen.first?.headers ?? [:]
    }

    private func assertCarriesRuleHeaders(_ headers: [String: String], _ what: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        for (name, value) in Self.ruleHeaders {
            XCTAssertEqual(headers[name], value, "\(what): `\(name)` should be the rule's value; got \(headers)",
                           file: file, line: line)
        }
    }

    private func assertCarriesNoRuleHeaders(_ headers: [String: String], _ what: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(headers["anthropic-client-platform"], "\(what): \(headers)", file: file, line: line)
        XCTAssertNil(headers["anthropic-client-version"], "\(what): \(headers)", file: file, line: line)
        XCTAssertNotEqual(headers["user-agent"], Self.ruleHeaders["user-agent"], "\(what): \(headers)", file: file, line: line)
        XCTAssertNotNil(headers["user-agent"], "\(what): the browser's own User-Agent should be there", file: file, line: line)
    }

    private func ruleIDs(_ value: Any?) -> [Int] {
        ((value as? [[String: Any]]) ?? []).compactMap { ExtensionHeaderRule.integer($0["id"]) }.sorted()
    }

    /// The ids `getSessionRules` answers with in a context — through Detour's
    /// wrapper, or (`webKitOnly`) from WebKit's own function.
    private func sessionRuleIDs(_ via: Via, in world: World, webKitOnly: Bool = false, filter: [String: Any]? = nil,
                                file: StaticString = #filePath, line: UInt = #line) async throws -> [Int] {
        var message: [String: Any] = ["op": webKitOnly ? "nativeGetRules" : "getRules"]
        if let filter { message["filter"] = filter }
        let outcome = try await run(via, in: world, message)
        return ruleIDs(resolved(outcome, "getSessionRules in the \(via)", file: file, line: line))
    }

    /// One header of one request to the fixture.
    private func requestHeader(_ name: String, _ via: Via, in world: World, kind: String = "fetch",
                               file: StaticString = #filePath, line: UInt = #line) async throws -> String? {
        try await requestHeaders(via, in: world, kind: kind, file: file, line: line)[name]
    }

    // MARK: - Install state

    /// With the permission, both contexts get the enums WebKit lacks, the
    /// wrapped session-rule methods on a rooted namespace, and a `fetch` that
    /// applies header rules; only a page has `XMLHttpRequest`.
    func testEnumsAndWrappersAreInstalledInThePageAndTheWorker() async throws {
        let world = try await makeWorld()
        for via in Via.allCases {
            let state = try await run(via, in: world, ["op": "state"])
            XCTAssertEqual(state["dnrType"] as? String, "object", "\(via): WebKit vends the namespace with the permission")
            let diag = try XCTUnwrap(state["diag"] as? [String: Any], "\(via)")
            XCTAssertEqual(diag["install"] as? String, "polyfill", "\(via)")
            XCTAssertEqual(diag["fetch"] as? String, "wrapped", "\(via)")
            XCTAssertEqual(diag["xhr"] as? String, via == .page ? "wrapped" : "none", "\(via)")
            let defined = Set((diag["enums"] as? String ?? "").split(separator: ",").map(String.init))
            XCTAssertTrue(defined.isSuperset(of: ["RuleActionType", "HeaderOperation", "ResourceType"]),
                          "\(via): WebKit vended these enums itself (\(defined)); the polyfill's copies can go")

            let actions = try XCTUnwrap(state["ruleActionType"] as? [String: String], "\(via)")
            XCTAssertEqual(actions["MODIFY_HEADERS"], "modifyHeaders")
            XCTAssertEqual(actions["BLOCK"], "block")
            XCTAssertEqual((state["headerOperation"] as? [String: String])?["SET"], "set")
            let resources = try XCTUnwrap(state["resourceType"] as? [String: String], "\(via)")
            XCTAssertEqual(resources["XMLHTTPREQUEST"], "xmlhttprequest")
            XCTAssertEqual(resources["OTHER"], "other")
            XCTAssertEqual(state["sessionRulesetID"] as? String, "_session")
            XCTAssertEqual(state["frozen"] as? Bool, true)
            XCTAssertEqual(state["viaBrowser"] as? String, "modifyHeaders", "\(via): browser.* must see the enums too")

            XCTAssertEqual(state["held"] as? Bool, true, "\(via): the patched namespace wrapper must be rooted")
            XCTAssertEqual(state["updateWrapped"] as? Bool, true, "\(via)")
            XCTAssertEqual(state["getWrapped"] as? Bool, true, "\(via)")
            XCTAssertEqual(state["browserUpdateWrapped"] as? Bool, true, "\(via)")
            XCTAssertEqual(state["nativeUpdateKept"] as? String, "native", "\(via): WebKit's own function must be kept")
            XCTAssertEqual(state["nativeFetchKept"] as? String, "native", "\(via)")
            XCTAssertEqual(state["fetchWrapped"] as? Bool, true, "\(via)")
            XCTAssertEqual(state["maxRulesType"] as? String, "number", "\(via): WebKit's own constants stay")
            XCTAssertEqual(state["xhrType"] as? String, via == .page ? "function" : "undefined", "\(via)")
            XCTAssertEqual(state["xhrWrapped"] as? Bool, via == .page, "\(via)")

            // runtime.OnInstalledReason, which the Claude extension reads right
            // after its updateSessionRules call.
            XCTAssertEqual(state["runtimeConstants"] as? String, "polyfill",
                           "\(via): WebKit vends runtime.OnInstalledReason itself now; the polyfill's copy can go")
            XCTAssertEqual(state["onInstalledReason"] as? [String: String],
                           ["INSTALL": "install", "UPDATE": "update",
                            "CHROME_UPDATE": "chrome_update", "SHARED_MODULE_UPDATE": "shared_module_update"], "\(via)")
            XCTAssertEqual(state["onInstalledReasonViaBrowser"] as? String, "install", "\(via)")
        }
    }

    // MARK: - The Claude extension's rule

    /// The rule WebKit refuses resolves, is reported back by `getSessionRules`,
    /// and its three headers are on every `fetch` and XHR the extension's own
    /// contexts send to the rule's host — and on nothing else.
    func testClaudeShapedRuleResolvesAndItsHeadersReachTheServer() async throws {
        let world = try await makeWorld()

        // Before the rule: the browser's own User-Agent, no custom headers.
        for via in Via.allCases {
            assertCarriesNoRuleHeaders(try await requestHeaders(via, in: world), "\(via) before the rule")
        }

        // Set from the worker, built from the enums, as the extension does.
        resolved(try await run(.worker, in: world,
                               ["op": "updateWithEnums", "base": apiBase, "userAgent": Self.userAgent]),
                 "updateSessionRules with the Claude-shaped rule")

        // Detour holds it alone: WebKit's own store has nothing.
        XCTAssertEqual(world.heldRules.rules[1]?.acceptedByWebKit, false)
        let inWebKit = try await sessionRuleIDs(.worker, in: world, webKitOnly: true)
        XCTAssertEqual(inWebKit, [], "WebKit refused the rule, so its own store must not have it")

        // getSessionRules answers with the rule as it was passed, in both contexts.
        for via in Via.allCases {
            let outcome = try await run(via, in: world, ["op": "getRules"])
            let rules = try XCTUnwrap(resolved(outcome, "getSessionRules in the \(via)") as? [[String: Any]])
            XCTAssertEqual(rules.count, 1, "\(via)")
            XCTAssertEqual(rules.first as NSDictionary?, claudeRule() as NSDictionary, "\(via)")
        }
        let viaCallback = try await run(.page, in: world, ["op": "getRulesCallback"])
        XCTAssertEqual(ruleIDs(viaCallback["rules"]), [1], "the callback form")
        let filteredIn = try await sessionRuleIDs(.page, in: world, filter: ["ruleIds": [1, 2]])
        XCTAssertEqual(filteredIn, [1], "a filter naming the rule")
        let filteredOut = try await sessionRuleIDs(.page, in: world, filter: ["ruleIds": [2]])
        XCTAssertEqual(filteredOut, [], "a filter that does not name it")

        // Every request from the extension's own contexts to the host carries them.
        assertCarriesRuleHeaders(try await requestHeaders(.worker, in: world), "worker fetch")
        assertCarriesRuleHeaders(try await requestHeaders(.page, in: world), "page fetch")
        assertCarriesRuleHeaders(try await requestHeaders(.page, in: world, kind: "xhr"), "page XHR")
        assertCarriesRuleHeaders(try await requestHeaders(.worker, in: world, extra: ["asRequest": true]),
                                 "worker fetch of a Request object")
        let post = try await requestHeaders(.worker, in: world, extra: [
            "method": "POST", "body": "{}", "headers": ["content-type": "application/json", "x-own": "kept"]])
        assertCarriesRuleHeaders(post, "worker POST with its own headers")
        XCTAssertEqual(post["x-own"], "kept", "the caller's own headers must survive")
        XCTAssertEqual(post["content-type"], "application/json")
        // `set` replaces what the caller put there, as in Chrome.
        let overridden = try await requestHeaders(.page, in: world, extra: ["headers": ["anthropic-client-version": "0.0.1"]])
        XCTAssertEqual(overridden["anthropic-client-version"], "1.0.98")

        // With host access none of this needs a CORS preflight.
        XCTAssertFalse(server.receivedRequests.contains { $0.method == "OPTIONS" },
                       "no request should have been preflighted")

        // NEGATIVE: a host the rule's urlFilter does not cover gets none of them.
        let (other, otherPort) = try await startServer()
        for via in Via.allCases {
            assertCarriesNoRuleHeaders(try await requestHeaders(via, in: world, on: other, port: otherPort),
                                       "\(via) fetch to another host")
        }
        assertCarriesNoRuleHeaders(try await requestHeaders(.page, in: world, kind: "xhr", on: other, port: otherPort),
                                   "page XHR to another host")
    }

    /// Removing the rule stops the headers, and unloading the context drops
    /// whatever is left: session rules do not outlive the session.
    func testRemovingTheRuleStopsItsHeadersAndUnloadDropsTheRest() async throws {
        let world = try await makeWorld()
        resolved(try await run(.page, in: world,
                               ["op": "update", "options": ["addRules": [claudeRule(), claudeRule(id: 2)]]]),
                 "adding two rules from the page")
        XCTAssertEqual(world.heldRules.rules.keys.sorted(), [1, 2])
        assertCarriesRuleHeaders(try await requestHeaders(.worker, in: world), "worker fetch with the rules")

        resolved(try await run(.worker, in: world, ["op": "update", "options": ["removeRuleIds": [1, 2]]]),
                 "removing both rules from the worker")
        XCTAssertTrue(world.heldRules.isEmpty)
        let afterRemoval = try await sessionRuleIDs(.page, in: world)
        XCTAssertEqual(afterRemoval, [])
        for via in Via.allCases {
            assertCarriesNoRuleHeaders(try await requestHeaders(via, in: world), "\(via) fetch after the removal")
        }

        // One id, one keeper, whichever way a rule is replaced: WebKit holds
        // rule 1, then the same id arrives with headers it refuses (Detour's
        // now, and gone from WebKit), then with headers it accepts again.
        resolved(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [userAgentRule("rule-agent/1")]]]),
                 "rule 1 as WebKit accepts it")
        var keepers = try await sessionRuleIDs(.page, in: world, webKitOnly: true)
        XCTAssertEqual(keepers, [1])
        XCTAssertEqual(world.heldRules.rules[1]?.acceptedByWebKit, true)
        resolved(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [claudeRule()]]]),
                 "rule 1 again, with headers WebKit refuses")
        keepers = try await sessionRuleIDs(.page, in: world, webKitOnly: true)
        XCTAssertEqual(keepers, [], "WebKit must not keep the rule Detour replaced")
        XCTAssertEqual(world.heldRules.rules[1]?.acceptedByWebKit, false)
        let listed = try await sessionRuleIDs(.page, in: world)
        XCTAssertEqual(listed, [1])
        resolved(try await run(.worker, in: world, ["op": "update", "options": [
            "removeRuleIds": [1], "addRules": [userAgentRule("rule-agent/2")]]]), "rule 1 back with WebKit")
        keepers = try await sessionRuleIDs(.page, in: world, webKitOnly: true)
        XCTAssertEqual(keepers, [1])
        XCTAssertEqual(world.heldRules.rules[1]?.acceptedByWebKit, true)
        XCTAssertEqual(world.heldRules.originalsKeptByDetourAlone().count, 0)

        XCTAssertFalse(world.heldRules.isEmpty)
        world.profile.unloadExtension(id: world.ext.id)
        XCTAssertTrue(world.heldRules.isEmpty, "an unloaded context's session rules must be forgotten")
    }

    // MARK: - Canaries for the WebKit behaviour the fallback rests on

    /// CANARY: WebKit's own `updateSessionRules` refuses a header name outside
    /// its list. If it starts accepting the rule, Detour no longer has to keep
    /// it alone.
    func testWebKitItselfStillRefusesTheRulesCustomHeaders() async throws {
        let world = try await makeWorld()
        for via in Via.allCases {
            let outcome = try await run(via, in: world, ["op": "nativeUpdate", "options": ["addRules": [claudeRule()]]])
            guard outcome["settled"] as? String == "rejected" else {
                XCTFail("""
                    WebKit's own declarativeNetRequest.updateSessionRules now ACCEPTS a modifyHeaders rule \
                    with custom header names (\(via): \(outcome)). The Detour-held path in \
                    ExtensionAPIPolyfill.declarativeNetRequestJS exists because it threw: re-check it.
                    """)
                continue
            }
            let message = outcome["message"] as? String ?? ""
            XCTAssertTrue(message.contains("anthropic-client-platform") && message.contains("not recognized"),
                          "unexpected error from WebKit's updateSessionRules: \(message)")
        }
        XCTAssertTrue(world.heldRules.isEmpty, "calling WebKit's function directly must not involve Detour")
    }

    /// CANARIES, and the split they justify. A rule WebKit accepts changes a
    /// *page's* requests in WebKit, and not the *worker's*; so Detour applies
    /// it in the worker and leaves the page to WebKit.
    func testARuleWebKitAcceptsIsAppliedByDetourInTheWorkerAndByWebKitInAPage() async throws {
        let world = try await makeWorld()
        resolved(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [userAgentRule("rule-agent/1")]]]),
                 "a rule naming only User-Agent")
        XCTAssertEqual(world.heldRules.rules[1]?.acceptedByWebKit, true)
        let inWebKit = try await sessionRuleIDs(.page, in: world, webKitOnly: true)
        XCTAssertEqual(inWebKit, [1], "WebKit holds the rule")
        let reported = try await sessionRuleIDs(.page, in: world)
        XCTAssertEqual(reported, [1], "and it is reported once, not once per keeper")

        // WebKit compiles the rule list asynchronously after the call resolves.
        try await waitUntil("WebKit to apply the rule to the page's requests", timeout: 10, pollInterval: 0.25) {
            (try await self.requestHeaders(.page, in: world, extra: ["native": true]))["user-agent"] == "rule-agent/1"
        }

        // CANARY: WebKit's fetch alone, in the worker — the rule is NOT applied.
        let workerNative = try await requestHeaders(.worker, in: world, extra: ["native": true])
        XCTAssertNotEqual(workerNative["user-agent"], "rule-agent/1", """
            WebKit now applies a declarativeNetRequest modifyHeaders session rule to the service \
            worker's own fetch. Detour applies accepted rules there too (headerChanges answers a \
            native-message sender with them), so an `append` would now be applied twice: re-check \
            ExtensionPolyfillHandler's "declarativeNetRequest.headerChanges".
            """)
        // CANARY: WebKit's fetch alone, in the page — the rule IS applied.
        let pageNative = try await requestHeaders(.page, in: world, extra: ["native": true])
        XCTAssertEqual(pageNative["user-agent"], "rule-agent/1", """
            WebKit no longer applies an accepted modifyHeaders session rule to an extension page's \
            requests. Detour leaves accepted rules to WebKit there (headerChanges answers a frame \
            sender with the Detour-held rules only): re-check that split.
            """)

        // Through Detour's wrapper both carry it.
        let workerAgent = try await requestHeader("user-agent", .worker, in: world)
        XCTAssertEqual(workerAgent, "rule-agent/1", "worker fetch: applied by Detour")
        let pageAgent = try await requestHeader("user-agent", .page, in: world)
        XCTAssertEqual(pageAgent, "rule-agent/1", "page fetch: applied by WebKit")
        let pageXHRAgent = try await requestHeader("user-agent", .page, in: world, kind: "xhr")
        XCTAssertEqual(pageXHRAgent, "rule-agent/1", "page XHR: applied by WebKit")

        // The split itself: what Detour answers each context for this request.
        let question: [String: Any] = ["op": "raw", "type": "declarativeNetRequest.headerChanges",
                                       "params": ["url": "\(apiBase)/api", "method": "GET"]]
        let forWorker = resolved(try await run(.worker, in: world, question), "headerChanges from the worker") as? [String: Any]
        XCTAssertEqual((forWorker?["changes"] as? [[String: Any]])?.count, 1)
        let forPage = resolved(try await run(.page, in: world, question), "headerChanges from the page") as? [String: Any]
        XCTAssertEqual((forPage?["changes"] as? [[String: Any]])?.count, 0,
                       "a page's requests get an accepted rule from WebKit, so Detour must not add it again")
    }

    // MARK: - Web pages in tabs

    /// What session rules do for a *web page* in a real tab (added through the
    /// store, so its web view is configured as the app configures one), which
    /// is what docs/extensions.md states: WebKit applies the rules it holds —
    /// `block`, and `modifyHeaders` for the header names it recognises — and a
    /// rule only Detour holds is not applied there, because Detour's wrappers
    /// run in the extension's own contexts only.
    ///
    /// The two header rules arrive in ONE call, which WebKit refuses as a
    /// whole (one of them names custom headers): each must still end up with
    /// the right keeper, or the tab would lose the rule WebKit can apply.
    func testWebKitHeldRulesReachWebPagesInTabsAndDetourHeldOnesDoNot() async throws {
        let world = try await makeWorld()
        let space = TabStore.shared.addSpace(name: "DNR tab", emoji: "D", colorHex: "007AFF", profileID: world.profile.id)
        createdSpaceIDs.append(space.id)
        let previousLastActive = TabStore.shared.lastActiveSpaceID
        defer { TabStore.shared.lastActiveSpaceID = previousLastActive }

        var webKitRule = userAgentRule("rule-agent/tab")
        webKitRule["action"] = ["type": "modifyHeaders", "requestHeaders": [
            ["header": "User-Agent", "operation": "set", "value": "rule-agent/tab"],
            ["header": "DNT", "operation": "set", "value": "7"]]]
        let block: [String: Any] = ["id": 2, "action": ["type": "block"],
                                    "condition": ["urlFilter": "\(apiBase)/blocked", "resourceTypes": ["xmlhttprequest"]]]
        resolved(try await run(.worker, in: world, ["op": "update", "options": [
            "addRules": [webKitRule, block, claudeRule(id: 3)]]]),
                 "a header rule WebKit accepts, a block rule and a header rule it refuses, in one call")

        // One id, one keeper — and each rule with the keeper that can apply it.
        XCTAssertEqual(world.heldRules.rules.mapValues(\.acceptedByWebKit), [1: true, 3: false])
        let inWebKit = try await sessionRuleIDs(.page, in: world, webKitOnly: true)
        XCTAssertEqual(inWebKit, [1, 2], "WebKit holds the block rule and the header rule it accepts")
        let reported = try await sessionRuleIDs(.page, in: world)
        XCTAssertEqual(reported, [1, 2, 3], "getSessionRules reports every rule once")

        // WebKit compiles its rule list asynchronously after the call resolves.
        try await waitUntil("WebKit to apply its rules", timeout: 10, pollInterval: 0.25) {
            (try await self.requestHeaders(.page, in: world, extra: ["native": true]))["user-agent"] == "rule-agent/tab"
        }

        let tab = TabStore.shared.addTab(in: space, url: URL(string: "\(apiBase)/page")!)
        let tabView = try XCTUnwrap(tab.webView, "a tab added through the store has a web view")
        try await waitUntil("the tab to load its page", timeout: 30, pollInterval: 0.25) {
            !tabView.isLoading && tabView.url?.path == "/page"
        }
        func pageFetch(_ path: String) async throws -> String {
            let raw = try await tabView.callAsyncJavaScript("""
                try {
                    const response = await fetch(path, { cache: 'no-store' });
                    return 'status ' + response.status;
                } catch (e) {
                    return 'failed';
                }
                """, arguments: ["path": path], contentWorld: .page)
            return raw as? String ?? "nil"
        }

        let allowed = try await pageFetch("/api?tab-page")
        XCTAssertEqual(allowed, "status 200")
        let fromTab = try XCTUnwrap(server.receivedRequests.first { $0.path == "/api?tab-page" }?.headers)
        XCTAssertEqual(fromTab["user-agent"], "rule-agent/tab",
                       "WebKit applies the header rule it holds to a web page's request")
        XCTAssertEqual(fromTab["dnt"], "7")
        XCTAssertNil(fromTab["anthropic-client-platform"],
                     "a rule only Detour holds does not reach a web page (documented limit)")
        XCTAssertNil(fromTab["anthropic-client-version"])

        let blocked = try await pageFetch("/blocked?tab-page")
        XCTAssertEqual(blocked, "failed", "WebKit applies the block rule to a web page's request")
        XCTAssertFalse(server.receivedRequests.contains { $0.path == "/blocked?tab-page" },
                       "a blocked request must never reach the server")

        // The extension's own worker gets both rules from Detour (WebKit
        // applies none there).
        let fromWorker = try await requestHeaders(.worker, in: world)
        XCTAssertEqual(fromWorker["anthropic-client-platform"], "claude_browser_extension")
        // Both rules set User-Agent at the same priority: the lower id wins.
        XCTAssertEqual(fromWorker["user-agent"], "rule-agent/tab")
        // LIMIT: Detour changes headers through the Fetch API, which does not
        // let a script set a forbidden header name — DNT is one — so that part
        // of a rule reaches web pages (WebKit, above) but not the worker.
        XCTAssertNil(fromWorker["dnt"], "the Fetch API now lets a script set DNT; update the documented limit")
    }

    // MARK: - Refusals

    /// A rule WebKit refuses that Detour cannot match either (a condition its
    /// matching does not implement) fails with WebKit's own error and leaves
    /// nothing behind; so does a call whose *other* rules WebKit refuses.
    func testWhatNeitherKeeperCanApplyFailsWithWebKitsError() async throws {
        let world = try await makeWorld()

        let unmatched = claudeRule(condition: ["initiatorDomains": ["example.com"]])
        let first = rejection(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [unmatched]]]),
                              "a custom-header rule with initiatorDomains")
        XCTAssertTrue(first.contains("not recognized"), "the error should be WebKit's own: \(first)")

        // A header rule Detour could keep, next to a rule WebKit refuses for
        // its own reasons: the call still fails, and Detour keeps nothing.
        let bogus: [String: Any] = ["id": 7, "action": ["type": "noSuchAction"], "condition": ["urlFilter": "x"]]
        let second = rejection(try await run(.page, in: world,
                                             ["op": "update", "options": ["addRules": [claudeRule(), bogus]]]),
                               "a call with a rule WebKit refuses for another reason")
        XCTAssertFalse(second.isEmpty)

        // A value that tries to smuggle a second header line is refused too.
        var injecting = claudeRule()
        injecting["action"] = ["type": "modifyHeaders", "requestHeaders": [
            ["header": "x-custom", "operation": "set", "value": "a\r\nX-Injected: 1"]]]
        let third = rejection(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [injecting]]]),
                              "a header value with a line break")
        XCTAssertFalse(third.isEmpty)

        XCTAssertTrue(world.heldRules.isEmpty, "a failed call must not leave a rule with Detour")
        let afterFailures = try await sessionRuleIDs(.page, in: world)
        XCTAssertEqual(afterFailures, [])
        assertCarriesNoRuleHeaders(try await requestHeaders(.worker, in: world), "worker fetch after the failed calls")
    }

    /// The callback form settles through `runtime.lastError`, as WebKit's does.
    func testCallbackFormReportsSuccessAndFailure() async throws {
        let world = try await makeWorld()
        for via in Via.allCases {
            let ok = try await run(via, in: world, ["op": "updateCallback",
                                                    "options": ["removeRuleIds": [1], "addRules": [claudeRule()]]])
            XCTAssertEqual(ok["argc"] as? Int, 0, "\(via): \(ok)")
            XCTAssertTrue(ok["lastError"] is NSNull, "\(via): \(ok)")
            XCTAssertEqual(ok["returnedType"] as? String, "undefined", "\(via): a callback call returns nothing")

            let failed = try await run(via, in: world, ["op": "updateCallback", "options": [
                "removeRuleIds": [1], "addRules": [claudeRule(condition: ["initiatorDomains": ["example.com"]])]]])
            XCTAssertEqual(failed["argc"] as? Int, 0, "\(via): \(failed)")
            XCTAssertTrue((failed["lastError"] as? String ?? "").contains("not recognized"), "\(via): \(failed)")
        }
        // The failed calls changed nothing: the rule from the successful ones is still there.
        XCTAssertEqual(world.heldRules.rules.keys.sorted(), [1])
    }

    // MARK: - XMLHttpRequest details

    /// `send()` waits for Detour's answer before WebKit sends anything. A page
    /// that aborts, or opens the request again, in that moment must get what it
    /// would have got from WebKit: the abort events, and only the second request.
    func testXHRAbortedOrReopenedBeforeItIsSentNeverGoesOut() async throws {
        let world = try await makeWorld()
        resolved(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [claudeRule()]]]), "the rule")

        let aborted = rejection(try await run(.page, in: world, ["op": "xhr", "url": "\(apiBase)/api?aborted", "abort": true]),
                                "an XHR aborted right after send()")
        XCTAssertEqual(aborted, "xhr aborted: abort,loadend", "the page is owed abort and then loadend")

        let reopened = resolved(try await run(.page, in: world, [
            "op": "xhrReopen", "first": "\(apiBase)/api?reopened-first", "url": "\(apiBase)/api?reopened-second"]),
                                "an XHR opened again after send()") as? [String: Any]
        XCTAssertEqual(reopened?["status"] as? Int, 200)
        XCTAssertEqual(reopened?["responseURL"] as? String, "\(apiBase)/api?reopened-second")

        // Give a wrongly sent request time to arrive before looking.
        let after = try await requestHeaders(.page, in: world, kind: "xhr")
        assertCarriesRuleHeaders(after, "a plain XHR afterwards")
        let paths = server.receivedRequests.map(\.path)
        XCTAssertFalse(paths.contains { $0.contains("aborted") }, "the aborted request must not reach the server: \(paths)")
        XCTAssertFalse(paths.contains { $0.contains("reopened-first") }, "the superseded request must not reach the server: \(paths)")
        let second = try XCTUnwrap(server.receivedRequests.first { $0.path.contains("reopened-second") })
        assertCarriesRuleHeaders(second.headers, "the reopened XHR")
    }

    /// A send() that is waiting for Detour's answer is, to the page, a request
    /// in flight: the calls WebKit refuses then still throw from the call
    /// itself, and an open() that throws does not cancel the waiting send.
    func testXHRMisuseStillThrowsWhileSendWaits() async throws {
        let world = try await makeWorld()
        resolved(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [claudeRule()]]]), "the rule")

        let result = resolved(try await run(.page, in: world, ["op": "xhrMisuse", "url": "\(apiBase)/api?misuse"]),
                              "an XHR misused after send()") as? [String: Any]
        XCTAssertEqual(result?["status"] as? Int, 200, "the first send still goes out")
        XCTAssertEqual(result?["secondSend"] as? String, "InvalidStateError")
        XCTAssertEqual(result?["lateHeader"] as? String, "InvalidStateError")
        XCTAssertEqual(result?["badOpen"] as? String, "SyntaxError")
        XCTAssertEqual(result?["unopened"] as? String, "InvalidStateError")

        let sent = server.receivedRequests.filter { $0.path.contains("misuse") }
        XCTAssertEqual(sent.count, 1, "one request, sent once")
        XCTAssertNil(sent.first?.headers["x-late"], "the refused header is not on it")
        if let headers = sent.first?.headers { assertCarriesRuleHeaders(headers, "the misused XHR") }
    }

    // MARK: - Isolation

    /// NEGATIVE: a rule belongs to the extension that set it, in the profile it
    /// set it in. Another extension in the same profile — holding the same
    /// permission — and the same extension in another profile neither see the
    /// rule nor have it applied to their requests.
    func testRulesAreNotSharedWithAnotherExtensionOrAnotherProfile() async throws {
        let owner = try await makeWorld()
        let neighbour = try await makeWorld(try await makeExtension(permissions: [Self.permission]), in: owner.profile)
        let elsewhere = try await makeWorld(owner.ext)
        XCTAssertFalse(owner.profile === elsewhere.profile)

        resolved(try await run(.worker, in: owner, ["op": "update", "options": ["addRules": [claudeRule()]]]),
                 "the owner's rule")
        assertCarriesRuleHeaders(try await requestHeaders(.worker, in: owner), "the owner's worker")
        assertCarriesRuleHeaders(try await requestHeaders(.page, in: owner), "the owner's page")

        for (who, world) in [("another extension in the profile", neighbour), ("the extension in another profile", elsewhere)] {
            XCTAssertTrue(world.heldRules.isEmpty, who)
            for via in Via.allCases {
                let visible = try await sessionRuleIDs(via, in: world)
                XCTAssertEqual(visible, [], "\(who), \(via): the owner's rule must not be listed")
                assertCarriesNoRuleHeaders(try await requestHeaders(via, in: world), "\(who), \(via) fetch")
                let answer = resolved(try await run(via, in: world, ["op": "raw", "type": "declarativeNetRequest.headerChanges",
                                                                     "params": ["url": "\(apiBase)/api", "method": "GET"]]),
                                      "\(who), \(via): headerChanges") as? [String: Any]
                XCTAssertEqual((answer?["changes"] as? [[String: Any]])?.count, 0, "\(who), \(via)")
            }
        }

        // Nor can one remove it: the neighbour's removal of "rule 1" is its own.
        resolved(try await run(.worker, in: neighbour, ["op": "update", "options": ["removeRuleIds": [1]]]),
                 "the neighbour removing its own (absent) rule 1")
        resolved(try await run(.worker, in: elsewhere, ["op": "update", "options": ["removeRuleIds": [1]]]),
                 "the other profile removing its own (absent) rule 1")
        XCTAssertEqual(owner.heldRules.rules.keys.sorted(), [1])
        assertCarriesRuleHeaders(try await requestHeaders(.worker, in: owner), "the owner's worker afterwards")

        // A body that claims the owner's id from the neighbour's page is
        // refused by the bridge, as every polyfill message is.
        let impersonated = try await postRawPolyfillEnvelope(
            from: neighbour.page, type: "declarativeNetRequest.getHeaderRules", claimedID: owner.ext.id, params: [:])
        XCTAssertNil(impersonated.result)
        XCTAssertEqual(impersonated.error, "Extension identity mismatch")
    }

    // MARK: - Permission (negative)

    /// NEGATIVE: an extension that did not ask for declarativeNetRequest gets no
    /// namespace, no wrapped `fetch`, and the bridge refuses it outright — so
    /// it cannot have Detour keep or apply a rule by posting the messages itself.
    func testWithoutThePermissionNothingIsInstalledAndTheBridgeRefuses() async throws {
        let world = try await makeWorld(permissions: ["storage"])
        for via in Via.allCases {
            let state = try await run(via, in: world, ["op": "state"])
            XCTAssertEqual(state["dnrType"] as? String, "undefined", "\(via)")
            XCTAssertEqual((state["diag"] as? [String: Any])?["install"] as? String, "absent", "\(via)")
            XCTAssertEqual((state["diag"] as? [String: Any])?["fetch"] as? String, "none", "\(via)")
            XCTAssertEqual(state["fetchWrapped"] as? Bool, false, "\(via): fetch must stay WebKit's")
            XCTAssertEqual(state["xhrWrapped"] as? Bool, false, "\(via)")
            // Not gated on the permission: every extension has runtime.onInstalled.
            XCTAssertEqual((state["onInstalledReason"] as? [String: String])?["INSTALL"], "install", "\(via)")

            for (type, params) in [
                ("declarativeNetRequest.updateHeaderRules",
                 ["addRules": [claudeRule()], "acceptedByWebKit": false] as [String: Any]),
                ("declarativeNetRequest.getHeaderRules", [:]),
                ("declarativeNetRequest.headerChanges", ["url": "\(apiBase)/api", "method": "GET"]),
            ] {
                let message = rejection(try await run(via, in: world, ["op": "raw", "type": type, "params": params]),
                                        "\(type) from the \(via) without the permission")
                XCTAssertTrue(message.contains("does not hold the declarativeNetRequest permission"), "\(via) \(type): \(message)")
            }
            assertCarriesNoRuleHeaders(try await requestHeaders(via, in: world), "\(via) fetch without the permission")
        }
        XCTAssertTrue(world.heldRules.isEmpty)
    }

    /// The gate follows the user's decision in Settings: denied, Detour stops
    /// answering for the extension's requests at once (the rule stays, so
    /// granting it again brings the headers back); the plain permission
    /// `declarativeNetRequest` is as good as the host-access one.
    func testDenyingThePermissionInSettingsStopsTheHeadersAndGrantingRestoresThem() async throws {
        for permission in ["declarativeNetRequestWithHostAccess", "declarativeNetRequest"] {
            let world = try await makeWorld(permissions: [permission])
            resolved(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [claudeRule()]]]),
                     "the rule with \(permission)")
            assertCarriesRuleHeaders(try await requestHeaders(.worker, in: world), "\(permission): granted")

            ExtensionManager.shared.setPermissionDecision(
                extensionID: world.ext.id, key: permission, type: .apiPermission, granted: false)
            XCTAssertFalse(world.context.hasPermission(WKWebExtension.Permission(rawValue: permission)))
            for via in Via.allCases {
                assertCarriesNoRuleHeaders(try await requestHeaders(via, in: world), "\(permission): \(via) fetch while denied")
            }
            let refused = rejection(try await run(.page, in: world, ["op": "raw", "type": "declarativeNetRequest.headerChanges",
                                                                     "params": ["url": "\(apiBase)/api"]]),
                                    "headerChanges while denied")
            XCTAssertTrue(refused.contains("does not hold the declarativeNetRequest permission"), refused)

            ExtensionManager.shared.setPermissionDecision(
                extensionID: world.ext.id, key: permission, type: .apiPermission, granted: true)
            assertCarriesRuleHeaders(try await requestHeaders(.worker, in: world), "\(permission): granted again")
        }
    }

    /// As in Chrome, a header rule changes nothing for a URL the extension has
    /// no host access to. Asked of the bridge directly, so nothing is sent to
    /// the host the extension may not reach.
    func testNoChangesAreAnsweredForAURLWithoutHostAccess() async throws {
        let world = try await makeWorld(hostPermissions: ["http://127.0.0.1/*"])
        // No urlFilter: the rule matches every URL, so only host access decides.
        var everywhere = claudeRule()
        everywhere["condition"] = ["resourceTypes": ["xmlhttprequest"]]
        resolved(try await run(.worker, in: world, ["op": "update", "options": ["addRules": [everywhere]]]),
                 "a rule for every URL")

        func changes(_ via: Via, _ url: String) async throws -> Int? {
            let value = resolved(try await run(via, in: world, ["op": "raw", "type": "declarativeNetRequest.headerChanges",
                                                                "params": ["url": url, "method": "GET"]]),
                                 "headerChanges for \(url)") as? [String: Any]
            return (value?["changes"] as? [[String: Any]])?.count
        }
        for via in Via.allCases {
            let granted = try await changes(via, "\(apiBase)/api")
            XCTAssertEqual(granted, 3, "\(via): the granted host gets the rule's three changes")
            let ungranted = try await changes(via, "https://api.example.com/v1/messages")
            XCTAssertEqual(ungranted, 0, "\(via): a host outside host_permissions gets none")
            let extensionOwn = try await changes(via, world.context.baseURL.appendingPathComponent("test.html").absoluteString)
            XCTAssertEqual(extensionOwn, 0, "\(via): the extension's own files are never changed")
        }
        assertCarriesRuleHeaders(try await requestHeaders(.worker, in: world), "worker fetch to the granted host")
    }
}
