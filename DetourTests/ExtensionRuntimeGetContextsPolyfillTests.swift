import XCTest
import WebKit
@testable import Detour

/// TASK-132.9: `runtime.getContexts` / `runtime.ContextType` as the polyfill
/// module defines them (`ExtensionAPIPolyfill.runtimeGetContextsJS`), against a
/// recording bridge that plays Detour: the enum, the filters, how tab handles
/// become ids, and when the request is sent. The real contexts are
/// `ExtensionRuntimeGetContextsTests`' business.
@MainActor
final class ExtensionRuntimeGetContextsPolyfillTests: XCTestCase {

    private var bridge: RecordingPolyfillBridge!
    private var webViews: [WKWebView] = []

    override func setUp() async throws {
        try await super.setUp()
        bridge = RecordingPolyfillBridge()
        bridge.replies["runtime.getContexts"] = { _ in (["contexts": Self.contexts], nil) }
    }

    override func tearDown() async throws {
        for webView in webViews {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: ExtensionPolyfillHandler.handlerName, contentWorld: .page)
        }
        webViews.removeAll()
        bridge = nil
        try await super.tearDown()
    }

    private static let origin = "webkit-extension://fixture"

    /// What Detour answers: a worker, two pages in tabs (one in a tab WebKit
    /// does not list), a popup, an offscreen document and two side panels.
    private static let contexts: [[String: Any]] = [
        ["contextType": "BACKGROUND", "contextId": "bg", "frameId": -1, "incognito": false],
        ["contextType": "TAB", "contextId": "tab-a", "frameId": 0, "incognito": false,
         "documentUrl": "\(origin)/options.html", "documentOrigin": origin, "tabHandle": 11, "windowTabHandle": 11],
        ["contextType": "TAB", "contextId": "tab-b", "frameId": 0, "incognito": false,
         "documentUrl": "\(origin)/page.html?x=1", "documentOrigin": origin, "tabHandle": 99, "windowTabHandle": 99],
        ["contextType": "POPUP", "contextId": "popup", "frameId": 0, "incognito": false,
         "documentUrl": "\(origin)/popup.html", "documentOrigin": origin, "windowTabHandle": 12],
        ["contextType": "OFFSCREEN_DOCUMENT", "contextId": "offscreen", "frameId": 0, "incognito": false,
         "documentUrl": "\(origin)/offscreen.html", "documentOrigin": origin],
        ["contextType": "SIDE_PANEL", "contextId": "panel-1", "frameId": 0, "incognito": false,
         "documentUrl": "\(origin)/sidepanel.html?tabId=101", "documentOrigin": origin, "windowTabHandle": 11],
        ["contextType": "SIDE_PANEL", "contextId": "panel-2", "frameId": 0, "incognito": false,
         "documentUrl": "\(origin)/sidepanel.html?tabId=102", "documentOrigin": origin, "windowTabHandle": 12],
    ]

    /// Handle 11 is tab 101 in window 7 and handle 12 is tab 102 in window 8;
    /// WebKit lists no tab for handle 99.
    private static let fakes = """
    globalThis.__handleLookups = 0;
    globalThis.__detourFindTabIdForHandle = async function(handle) {
        globalThis.__handleLookups += 1;
        return ({ 11: 101, 12: 102 })[handle];
    };
    globalThis.chrome.tabs = {
        get: async function(tabId) {
            if (tabId === 101) return { id: 101, windowId: 7 };
            if (tabId === 102) return { id: 102, windowId: 8 };
            throw new Error('No tab with id: ' + tabId + '.');
        }
    };
    """

    private func makeWebView(shim: String = "") async throws -> WKWebView {
        let webView = try await makeRecordingPolyfillWebView(
            bridge: bridge, manifest: ["manifest_version": 3, "permissions": [String]()],
            shim: shim, afterPolyfill: Self.fakes)
        webViews.append(webView)
        bridge.reset()
        return webView
    }

    private func getContexts(_ filter: String, in webView: WKWebView) async throws -> [[String: Any]] {
        let value = try await evaluateJSON("return await chrome.runtime.getContexts(\(filter));", in: webView)
        return try XCTUnwrap(value as? [[String: Any]], "expected an array, got \(value)")
    }

    private func ids(_ filter: String, in webView: WKWebView) async throws -> [String] {
        try await getContexts(filter, in: webView).compactMap { $0["contextId"] as? String }
    }

    // MARK: AC #1: the enum

    func testContextTypeHasChromesTypes() async throws {
        let webView = try await makeWebView()
        let state = try await evaluateJSONObject("""
            return { type: chrome.runtime.ContextType, values: Object.values(chrome.runtime.ContextType),
                     frozen: Object.isFrozen(chrome.runtime.ContextType),
                     getContexts: typeof chrome.runtime.getContexts,
                     install: globalThis.__detourRuntimeGetContextsInstall,
                     diag: __detourPolyfillDiag.apis.runtimeGetContexts,
                     held: __detourHeldWrappers.runtime === chrome.runtime };
            """, in: webView)
        XCTAssertEqual(state["type"] as? [String: String], [
            "TAB": "TAB", "POPUP": "POPUP", "BACKGROUND": "BACKGROUND",
            "OFFSCREEN_DOCUMENT": "OFFSCREEN_DOCUMENT", "SIDE_PANEL": "SIDE_PANEL", "DEVELOPER_TOOLS": "DEVELOPER_TOOLS",
        ])
        XCTAssertEqual((state["values"] as? [String])?.count, 6, "the marker must not be an enumerable member")
        XCTAssertEqual(state["frozen"] as? Bool, true)
        XCTAssertEqual(state["getContexts"] as? String, "function")
        XCTAssertEqual(state["install"] as? String, "polyfill")
        XCTAssertEqual(state["diag"] as? String, "polyfill")
        XCTAssertEqual(state["held"] as? Bool, true, "the patched runtime wrapper is rooted")
    }

    func testANativeGetContextsAndEnumAreLeftAlone() async throws {
        let webView = try await makeWebView(shim: """
            globalThis.chrome.runtime.getContexts = function() { return 'theirs'; };
            globalThis.chrome.runtime.ContextType = { TAB: 'theirs' };
            """)
        let state = try await evaluateJSONObject("""
            return { answer: chrome.runtime.getContexts({}), type: chrome.runtime.ContextType,
                     install: globalThis.__detourRuntimeGetContextsInstall };
            """, in: webView)
        XCTAssertEqual(state["answer"] as? String, "theirs")
        XCTAssertEqual(state["type"] as? [String: String], ["TAB": "theirs"])
        XCTAssertEqual(state["install"] as? String, "native")
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testASecondRunOfThePolyfillKeepsThePatch() async throws {
        let webView = try await makeWebView()
        let state = try await evaluateJSONObject("""
            const before = chrome.runtime.getContexts;
            const typeBefore = chrome.runtime.ContextType;
            \(ExtensionAPIPolyfill.polyfillJS)
            return { same: chrome.runtime.getContexts === before, sameType: chrome.runtime.ContextType === typeBefore,
                     install: globalThis.__detourRuntimeGetContextsInstall };
            """, in: webView)
        XCTAssertEqual(state["same"] as? Bool, true)
        XCTAssertEqual(state["sameType"] as? Bool, true)
        XCTAssertEqual(state["install"] as? String, "polyfill")
    }

    // MARK: AC #2: what a context looks like, and the filters

    func testEveryContextComesBackWithItsIdsResolved() async throws {
        let webView = try await makeWebView()
        let all = try await getContexts("{}", in: webView)
        XCTAssertEqual(all.compactMap { $0["contextId"] as? String },
                       ["bg", "tab-a", "tab-b", "popup", "offscreen", "panel-1", "panel-2"])
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0["contextId"] as! String, $0) })

        let background = try XCTUnwrap(byID["bg"])
        XCTAssertEqual(background["contextType"] as? String, "BACKGROUND")
        XCTAssertEqual(background["tabId"] as? Int, -1)
        XCTAssertEqual(background["windowId"] as? Int, -1)
        XCTAssertEqual(background["frameId"] as? Int, -1)
        XCTAssertNil(background["documentUrl"], "a worker has no document")
        XCTAssertNil(background["documentId"])
        XCTAssertEqual(background["incognito"] as? Bool, false)

        let tab = try XCTUnwrap(byID["tab-a"])
        XCTAssertEqual(tab["tabId"] as? Int, 101)
        XCTAssertEqual(tab["windowId"] as? Int, 7)
        XCTAssertEqual(tab["frameId"] as? Int, 0)
        XCTAssertEqual(tab["documentUrl"] as? String, "\(Self.origin)/options.html")
        XCTAssertEqual(tab["documentOrigin"] as? String, Self.origin)
        XCTAssertNil(tab["tabHandle"], "handles are Detour's and stay inside the polyfill")
        XCTAssertNil(tab["windowTabHandle"])

        let unlisted = try XCTUnwrap(byID["tab-b"])
        XCTAssertEqual(unlisted["tabId"] as? Int, -1, "a tab WebKit lists nowhere has no id to give")
        XCTAssertEqual(unlisted["windowId"] as? Int, -1)

        let popup = try XCTUnwrap(byID["popup"])
        XCTAssertEqual(popup["tabId"] as? Int, -1, "a popup is not a tab")
        XCTAssertEqual(popup["windowId"] as? Int, 8)

        let panel = try XCTUnwrap(byID["panel-1"])
        XCTAssertEqual(panel["contextType"] as? String, "SIDE_PANEL")
        XCTAssertEqual(panel["tabId"] as? Int, -1, "a panel is not a tab")
        XCTAssertEqual(panel["windowId"] as? Int, 7)
        XCTAssertEqual(panel["documentUrl"] as? String, "\(Self.origin)/sidepanel.html?tabId=101", "the query is part of the URL")

        XCTAssertEqual(byID["offscreen"]?["windowId"] as? Int, -1)
    }

    func testFilters() async throws {
        let webView = try await makeWebView()
        let panels = try await ids("{ contextTypes: [chrome.runtime.ContextType.SIDE_PANEL] }", in: webView)
        XCTAssertEqual(panels, ["panel-1", "panel-2"])
        let several = try await ids("{ contextTypes: ['TAB', 'POPUP'] }", in: webView)
        XCTAssertEqual(several, ["tab-a", "tab-b", "popup"])
        let none = try await ids("{ contextTypes: [] }", in: webView)
        XCTAssertEqual(none, [], "an empty list matches nothing")

        let byTab = try await ids("{ tabIds: [101] }", in: webView)
        XCTAssertEqual(byTab, ["tab-a"])
        let notInATab = try await ids("{ tabIds: [-1], contextTypes: ['SIDE_PANEL', 'TAB'] }", in: webView)
        XCTAssertEqual(notInATab, ["tab-b", "panel-1", "panel-2"])
        let byWindow = try await ids("{ windowIds: [8] }", in: webView)
        XCTAssertEqual(byWindow, ["popup", "panel-2"])
        let byURL = try await ids("{ documentUrls: ['\(Self.origin)/sidepanel.html?tabId=102', '\(Self.origin)/popup.html'] }", in: webView)
        XCTAssertEqual(byURL, ["popup", "panel-2"])
        let urlWithoutQuery = try await ids("{ documentUrls: ['\(Self.origin)/sidepanel.html'] }", in: webView)
        XCTAssertEqual(urlWithoutQuery, [], "documentUrl is matched whole")
        let byOrigin = try await ids("{ documentOrigins: ['\(Self.origin)'] }", in: webView)
        XCTAssertEqual(byOrigin.count, 6, "everything but the worker has a document")
        let byContextID = try await ids("{ contextIds: ['popup', 'bg', 'nope'] }", in: webView)
        XCTAssertEqual(byContextID, ["bg", "popup"])
        let byDocumentID = try await ids("{ documentIds: ['anything'] }", in: webView)
        XCTAssertEqual(byDocumentID, [], "no context has a documentId, so none matches one")
        let byFrame = try await ids("{ frameIds: [-1] }", in: webView)
        XCTAssertEqual(byFrame, ["bg"])
        let incognito = try await ids("{ incognito: true }", in: webView)
        XCTAssertEqual(incognito, [])
        let notIncognito = try await ids("{ incognito: false, contextTypes: ['BACKGROUND'] }", in: webView)
        XCTAssertEqual(notIncognito, ["bg"])
        let combined = try await ids("{ contextTypes: ['SIDE_PANEL'], windowIds: [7] }", in: webView)
        XCTAssertEqual(combined, ["panel-1"], "every filter given must match")
    }

    func testIdsAreResolvedOnlyForContextsTheOtherFiltersKeep() async throws {
        let webView = try await makeWebView()
        let lookups = try await evaluateJSON("""
            globalThis.__handleLookups = 0;
            await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT', 'BACKGROUND'] });
            const none = globalThis.__handleLookups;
            await chrome.runtime.getContexts({ contextTypes: ['SIDE_PANEL'] });
            return [none, globalThis.__handleLookups];
            """, in: webView)
        XCTAssertEqual(lookups as? [Int], [0, 2], "one lookup per distinct handle of the contexts that are kept")
    }

    func testABadFilterRejectsWithoutAskingDetour() async throws {
        let webView = try await makeWebView()
        let messages = try await evaluateJSON("""
            const failure = async (call) => { try { await call(); return null; } catch (e) { return e.name + ': ' + e.message; } };
            return [
                await failure(() => chrome.runtime.getContexts()),
                await failure(() => chrome.runtime.getContexts('SIDE_PANEL')),
                await failure(() => chrome.runtime.getContexts({ contextTypes: 'SIDE_PANEL' })),
                await failure(() => chrome.runtime.getContexts({ incognito: 1 }))
            ];
            """, in: webView)
        XCTAssertEqual(messages as? [String], [
            "TypeError: Error in invocation of runtime.getContexts: a filter object is required",
            "TypeError: Error in invocation of runtime.getContexts: a filter object is required",
            "TypeError: Error in invocation of runtime.getContexts: contextTypes must be an array",
            "TypeError: Error in invocation of runtime.getContexts: incognito must be a boolean",
        ])
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testCallbackFormAndLastError() async throws {
        let webView = try await makeWebView()
        let good = try await evaluateJSONObject("""
            return await new Promise((resolve) => {
                const returned = chrome.runtime.getContexts({ contextTypes: ['POPUP'] }, function(contexts) {
                    resolve({ argc: arguments.length, ids: contexts.map((c) => c.contextId),
                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null,
                              returned: typeof returned });
                });
            });
            """, in: webView)
        XCTAssertEqual(good["ids"] as? [String], ["popup"])
        XCTAssertTrue(good["lastError"] is NSNull)
        XCTAssertEqual(good["returned"] as? String, "undefined")

        bridge.replies["runtime.getContexts"] = { _ in (nil, "the profile is gone") }
        let bad = try await evaluateJSONObject("""
            return await new Promise((resolve) => {
                chrome.runtime.getContexts({}, function() {
                    resolve({ argc: arguments.length,
                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                });
            });
            """, in: webView)
        XCTAssertEqual(bad["argc"] as? Int, 0)
        XCTAssertEqual(bad["lastError"] as? String, "the profile is gone")
    }

    // MARK: Timing

    func testTheRequestLeavesInTheCallItself() async throws {
        // The Claude extension's shortcut handler asks for the contexts, then
        // changes them, then reads the answer: the question must already be on
        // its way when the next statement runs.
        let webView = try await makeWebView()
        let order = try await evaluateJSON("""
            const asked = chrome.runtime.getContexts({ contextTypes: ['SIDE_PANEL'] });
            const next = __detourPolyfillRequest('test.afterGetContexts', {});
            await Promise.all([asked, next]);
            return true;
            """, in: webView)
        XCTAssertEqual(order as? Bool, true)
        XCTAssertEqual(bridge.types, ["runtime.getContexts", "test.afterGetContexts"])
    }
}
