import XCTest
import WebKit
@testable import Detour

/// TASK-132.8: the `chrome.sidePanel` polyfill module by itself
/// (`ExtensionAPIPolyfill.sidePanelJS`) — what it defines and when, what it
/// sends over the bridge and in which order, and how a call settles — against
/// a recording bridge. WebKit's wrappers, the tab id bridge and the panels
/// themselves are `ExtensionSidePanelTests`' business.
@MainActor
final class ExtensionSidePanelPolyfillTests: XCTestCase {

    private var bridge: RecordingPolyfillBridge!
    private var webViews: [WKWebView] = []

    override func setUp() async throws {
        try await super.setUp()
        bridge = RecordingPolyfillBridge()
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

    /// Fakes for what the module asks of the rest of the polyfill and of
    /// WebKit: tab `n` resolves to handle `1000 + n` (tab 1 slowly, tab 404
    /// not at all), and three windows — 7 with tabs 1 (active) and 2, 8 with
    /// none, and no window 9.
    private static let fakes = """
    globalThis.__detourResolveTab = function(tabId) {
        if (tabId === 404) return Promise.reject(new Error('No tab with id: 404.'));
        const delay = tabId === 1 ? 120 : 0;
        return new Promise((resolve) => setTimeout(() => resolve(1000 + tabId), delay));
    };
    globalThis.chrome.windows = {
        get: function(windowId, options) {
            if (windowId === 7) {
                return Promise.resolve({ id: 7, tabs: [{ id: 2, active: false }, { id: 1, active: true }] });
            }
            if (windowId === 8) return Promise.resolve({ id: 8, tabs: [] });
            return Promise.reject(new Error('Invalid call to windows.get(). Window not found.'));
        }
    };
    """

    private func makeWebView(permissions: [String] = ["sidePanel"], shim: String = "") async throws -> WKWebView {
        let webView = try await makeRecordingPolyfillWebView(
            bridge: bridge, manifest: ["manifest_version": 3, "permissions": permissions],
            shim: shim, afterPolyfill: Self.fakes)
        webViews.append(webView)
        bridge.reset()
        return webView
    }

    private func dict(_ body: String, in webView: WKWebView) async throws -> [String: Any] {
        let value = try await evaluateJSON(body, in: webView)
        return try XCTUnwrap(value as? [String: Any], "expected an object, got \(value)")
    }

    /// How a promise-form call settled.
    private func outcome(_ call: String, in webView: WKWebView) async throws -> (resolved: Any?, rejected: String?) {
        let result = try await dict("""
            try {
                const value = await (\(call));
                return { settled: 'resolved', value: value === undefined ? null : value, isUndefined: value === undefined };
            } catch (e) {
                return { settled: 'rejected', message: String(e && e.message ? e.message : e), name: e && e.name };
            }
            """, in: webView)
        if result["settled"] as? String == "rejected" { return (nil, result["message"] as? String ?? "") }
        return (result["value"], nil)
    }

    // MARK: What is defined

    func testNothingIsDefinedWithoutThePermission() async throws {
        let webView = try await makeWebView(permissions: ["storage", "tabs"])
        let state = try await dict("""
            return { type: typeof chrome.sidePanel, browserType: typeof browser.sidePanel,
                     install: globalThis.__detourSidePanelInstall,
                     closeWrapped: window.close._detourSidePanelClose === true,
                     diag: __detourPolyfillDiag.apis.sidePanel };
            """, in: webView)
        XCTAssertEqual(state["type"] as? String, "undefined", "Chrome leaves an undeclared namespace out")
        XCTAssertEqual(state["browserType"] as? String, "undefined")
        XCTAssertEqual(state["install"] as? String, "absent")
        XCTAssertEqual(state["diag"] as? String, "absent")
        XCTAssertEqual(state["closeWrapped"] as? Bool, false, "window.close is only wrapped for an extension that can have a panel")
    }

    func testTheNamespaceIsDefinedWithThePermission() async throws {
        let webView = try await makeWebView()
        let state = try await dict("""
            return { keys: Object.keys(chrome.sidePanel).sort(),
                     types: Object.keys(chrome.sidePanel).map((k) => typeof chrome.sidePanel[k]),
                     viaBrowser: browser.sidePanel === chrome.sidePanel,
                     install: globalThis.__detourSidePanelInstall,
                     marker: chrome.sidePanel._detourPolyfill === true,
                     own: Object.prototype.hasOwnProperty.call(chrome, 'sidePanel'),
                     closeWrapped: window.close._detourSidePanelClose === true,
                     diag: __detourPolyfillDiag.apis.sidePanel };
            """, in: webView)
        XCTAssertEqual(state["keys"] as? [String],
                       ["close", "getOptions", "getPanelBehavior", "open", "setOptions", "setPanelBehavior"],
                       "the marker must not be an enumerable member")
        XCTAssertEqual(Set(state["types"] as? [String] ?? []), ["function"])
        XCTAssertEqual(state["viaBrowser"] as? Bool, true)
        XCTAssertEqual(state["install"] as? String, "polyfill")
        XCTAssertEqual(state["diag"] as? String, "polyfill")
        XCTAssertEqual(state["marker"] as? Bool, true)
        XCTAssertEqual(state["own"] as? Bool, true, "an own property on chrome, never a replaced global")
        XCTAssertEqual(state["closeWrapped"] as? Bool, true)
        XCTAssertTrue(bridge.calls.isEmpty, "defining the namespace asks Detour nothing")
    }

    func testAnExistingNamespaceIsLeftAlone() async throws {
        let webView = try await makeWebView(shim: """
            globalThis.chrome.sidePanel = { open: function() { return 'theirs'; } };
            """)
        let state = try await dict("""
            return { install: globalThis.__detourSidePanelInstall, open: chrome.sidePanel.open(),
                     keys: Object.keys(chrome.sidePanel) };
            """, in: webView)
        XCTAssertEqual(state["install"] as? String, "native")
        XCTAssertEqual(state["open"] as? String, "theirs")
        XCTAssertEqual(state["keys"] as? [String], ["open"])
    }

    func testASecondRunOfThePolyfillKeepsTheNamespace() async throws {
        let webView = try await makeWebView()
        let state = try await dict("""
            const before = chrome.sidePanel;
            const closeBefore = window.close;
            \(ExtensionAPIPolyfill.polyfillJS)
            return { same: chrome.sidePanel === before, install: globalThis.__detourSidePanelInstall,
                     closeSame: window.close === closeBefore };
            """, in: webView)
        XCTAssertEqual(state["same"] as? Bool, true)
        XCTAssertEqual(state["install"] as? String, "polyfill")
        XCTAssertEqual(state["closeSame"] as? Bool, true, "window.close must not be wrapped twice")
    }

    // MARK: setOptions / getOptions

    func testSetOptionsSendsTheTabsHandleAndOnlyTheFieldsGiven() async throws {
        let webView = try await makeWebView()
        let first = try await outcome("chrome.sidePanel.setOptions({ tabId: 5, path: 'p.html?tabId=5', enabled: true })", in: webView)
        XCTAssertNil(first.rejected)
        XCTAssertTrue(first.resolved is NSNull, "setOptions resolves with nothing")
        _ = try await outcome("chrome.sidePanel.setOptions({ enabled: false })", in: webView)
        _ = try await outcome("chrome.sidePanel.setOptions({ path: 'q.html' })", in: webView)

        let calls = bridge.calls(ofType: "sidePanel.setOptions")
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].params["tabHandle"] as? Int, 1005, "the handle, never WebKit's tab id")
        XCTAssertNil(calls[0].params["tabId"])
        XCTAssertEqual(calls[0].params["path"] as? String, "p.html?tabId=5")
        XCTAssertEqual(calls[0].params["enabled"] as? Bool, true)
        XCTAssertEqual(Set(calls[1].params.keys), ["enabled"])
        XCTAssertEqual(calls[1].params["enabled"] as? Bool, false)
        XCTAssertEqual(Set(calls[2].params.keys), ["path"])
    }

    func testGetOptionsNamesTheTabOnlyWhenItHasOptionsOfItsOwn() async throws {
        let webView = try await makeWebView()
        bridge.replies["sidePanel.getOptions"] = { call in
            call.params["tabHandle"] as? Int == 1005
                ? (["enabled": true, "path": "tab.html", "tabSpecific": true], nil)
                : (["enabled": false, "tabSpecific": false], nil)
        }
        let own = try await outcome("chrome.sidePanel.getOptions({ tabId: 5 })", in: webView)
        XCTAssertEqual(own.resolved as? NSDictionary, ["enabled": true, "path": "tab.html", "tabId": 5])
        let other = try await outcome("chrome.sidePanel.getOptions({ tabId: 6 })", in: webView)
        XCTAssertEqual(other.resolved as? NSDictionary, ["enabled": false], "no path set, and not this tab's own options")
        let general = try await outcome("chrome.sidePanel.getOptions({})", in: webView)
        XCTAssertEqual(general.resolved as? NSDictionary, ["enabled": false])
    }

    // MARK: open / close

    func testOpenNeedsATabOrAWindow() async throws {
        let webView = try await makeWebView()
        let none = try await outcome("chrome.sidePanel.open({})", in: webView)
        XCTAssertEqual(none.rejected, "At least one of \"tabId\" and \"windowId\" must be provided")
        let missing = try await outcome("chrome.sidePanel.open()", in: webView)
        XCTAssertNotNil(missing.rejected)
        let wrongType = try await outcome("chrome.sidePanel.open({ tabId: '5' })", in: webView)
        XCTAssertEqual(wrongType.rejected, "Error in invocation of sidePanel.open: tabId must be an integer")
        XCTAssertTrue(bridge.calls.isEmpty, "a call that cannot be made is not sent")
    }

    func testOpenForATabSendsItsHandle() async throws {
        let webView = try await makeWebView()
        let opened = try await outcome("chrome.sidePanel.open({ tabId: 5 })", in: webView)
        XCTAssertNil(opened.rejected)
        XCTAssertTrue(opened.resolved is NSNull)
        let call = try XCTUnwrap(bridge.calls(ofType: "sidePanel.open").first)
        XCTAssertEqual(call.params["tabHandle"] as? Int, 1005)
        XCTAssertNil(call.params["hasWindow"])
        XCTAssertNil(call.params["windowTabHandle"])
    }

    func testOpenForAnUnknownTabFailsWithChromesError() async throws {
        let webView = try await makeWebView()
        let opened = try await outcome("chrome.sidePanel.open({ tabId: 404 })", in: webView)
        XCTAssertEqual(opened.rejected, "No tab with id: 404.")
        XCTAssertTrue(bridge.calls.isEmpty)
    }

    func testAWindowIsNamedByItsActiveTab() async throws {
        let webView = try await makeWebView()
        _ = try await outcome("chrome.sidePanel.open({ windowId: 7 })", in: webView)
        let call = try XCTUnwrap(bridge.calls(ofType: "sidePanel.open").first)
        XCTAssertEqual(call.params["windowTabHandle"] as? Int, 1001, "tab 1 is window 7's active tab")
        XCTAssertEqual(call.params["hasWindow"] as? Bool, true)
        XCTAssertNil(call.params["tabHandle"])
    }

    func testAWindowWithNoTabIsSentAsAWindowDetourMustFind() async throws {
        let webView = try await makeWebView()
        _ = try await outcome("chrome.sidePanel.open({ windowId: 8 })", in: webView)
        let call = try XCTUnwrap(bridge.calls(ofType: "sidePanel.open").first)
        XCTAssertEqual(call.params["hasWindow"] as? Bool, true)
        XCTAssertNil(call.params["windowTabHandle"])
    }

    func testAnUnknownWindowAndATabOfAnotherWindowAreRefused() async throws {
        let webView = try await makeWebView()
        let unknown = try await outcome("chrome.sidePanel.open({ windowId: 9 })", in: webView)
        XCTAssertEqual(unknown.rejected, "No window with id: 9.")
        let elsewhere = try await outcome("chrome.sidePanel.open({ tabId: 5, windowId: 7 })", in: webView)
        XCTAssertEqual(elsewhere.rejected, "The specified tab does not belong to the specified window.")
        XCTAssertTrue(bridge.calls.isEmpty)

        let both = try await outcome("chrome.sidePanel.open({ tabId: 2, windowId: 7 })", in: webView)
        XCTAssertNil(both.rejected)
        let call = try XCTUnwrap(bridge.calls(ofType: "sidePanel.open").first)
        XCTAssertEqual(call.params["tabHandle"] as? Int, 1002)
        XCTAssertEqual(call.params["windowTabHandle"] as? Int, 1001)
    }

    func testDetoursNoPanelErrorsGetWebKitsIds() async throws {
        let webView = try await makeWebView()
        bridge.replies["sidePanel.open"] = { call in
            (nil, call.params["tabHandle"] != nil ? "No active side panel for the tab" : "No active side panel for the window")
        }
        let tab = try await outcome("chrome.sidePanel.open({ tabId: 5 })", in: webView)
        XCTAssertEqual(tab.rejected, "No active side panel for tabId: 5")
        let window = try await outcome("chrome.sidePanel.open({ windowId: 7 })", in: webView)
        XCTAssertEqual(window.rejected, "No active side panel for windowId: 7")
    }

    func testCloseNamesItsTargetLikeOpen() async throws {
        let webView = try await makeWebView()
        _ = try await outcome("chrome.sidePanel.close({ tabId: 5 })", in: webView)
        _ = try await outcome("chrome.sidePanel.close({ windowId: 7 })", in: webView)
        let none = try await outcome("chrome.sidePanel.close({})", in: webView)
        XCTAssertEqual(none.rejected, "At least one of \"tabId\" and \"windowId\" must be provided")
        let calls = bridge.calls(ofType: "sidePanel.close")
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].params["tabHandle"] as? Int, 1005)
        XCTAssertEqual(calls[1].params["windowTabHandle"] as? Int, 1001)
    }

    // MARK: Order

    func testCallsReachDetourInCallOrderThoughEachResolvesItsTabFirst() async throws {
        let webView = try await makeWebView()
        // Tab 1 resolves slowly, and nothing is awaited between the calls: the
        // open must still not overtake the setOptions it follows.
        let settled = try await evaluateJSON("""
            const a = chrome.sidePanel.setOptions({ tabId: 1, path: 'p.html', enabled: true });
            const b = chrome.sidePanel.open({ tabId: 5 });
            const c = chrome.sidePanel.getOptions({});
            const d = chrome.sidePanel.close({ tabId: 1 });
            return (await Promise.allSettled([a, b, c, d])).map((s) => s.status);
            """, in: webView)
        XCTAssertEqual(settled as? [String], ["fulfilled", "fulfilled", "fulfilled", "fulfilled"])
        XCTAssertEqual(bridge.types, ["sidePanel.setOptions", "sidePanel.open", "sidePanel.getOptions", "sidePanel.close"])
    }

    func testAFailedCallDoesNotStopTheOnesBehindIt() async throws {
        let webView = try await makeWebView()
        let settled = try await evaluateJSON("""
            const a = chrome.sidePanel.open({ tabId: 404 });
            const b = chrome.sidePanel.open({ tabId: 5 });
            return (await Promise.allSettled([a, b])).map((s) => s.status);
            """, in: webView)
        XCTAssertEqual(settled as? [String], ["rejected", "fulfilled"])
        XCTAssertEqual(bridge.types, ["sidePanel.open"])
    }

    // MARK: Panel behaviour

    func testPanelBehaviourRoundTrip() async throws {
        let webView = try await makeWebView()
        bridge.replies["sidePanel.getPanelBehavior"] = { _ in (["openPanelOnActionClick": true], nil) }
        let set = try await outcome("chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true })", in: webView)
        XCTAssertNil(set.rejected)
        XCTAssertEqual(bridge.calls(ofType: "sidePanel.setPanelBehavior").first?.params["openPanelOnActionClick"] as? Bool, true)
        let got = try await outcome("chrome.sidePanel.getPanelBehavior()", in: webView)
        XCTAssertEqual(got.resolved as? NSDictionary, ["openPanelOnActionClick": true])
        let bad = try await outcome("chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: 'yes' })", in: webView)
        XCTAssertEqual(bad.rejected, "Error in invocation of sidePanel.setPanelBehavior: openPanelOnActionClick must be a boolean")
    }

    // MARK: Callback form

    func testCallbackFormsRunTheCallbackAndReturnNothing() async throws {
        let webView = try await makeWebView()
        bridge.replies["sidePanel.getOptions"] = { _ in (["enabled": true, "path": "panel.html", "tabSpecific": false], nil) }
        let result = try await dict("""
            const run = (invoke) => new Promise((resolve) => {
                const returned = invoke(function() {
                    resolve({ argc: arguments.length, arg0: arguments.length ? arguments[0] : null,
                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null,
                              returned: typeof returned });
                });
            });
            return {
                set: await run((cb) => chrome.sidePanel.setOptions({ path: 'panel.html' }, cb)),
                get: await run((cb) => chrome.sidePanel.getOptions({}, cb)),
                open: await run((cb) => chrome.sidePanel.open({ tabId: 5 }, cb)),
                behavior: await run((cb) => chrome.sidePanel.getPanelBehavior(cb))
            };
            """, in: webView)
        let set = try XCTUnwrap(result["set"] as? [String: Any])
        XCTAssertEqual(set["argc"] as? Int, 0, "a void call's callback gets no argument")
        XCTAssertTrue(set["lastError"] is NSNull)
        XCTAssertEqual(set["returned"] as? String, "undefined", "with a callback nothing is returned")
        let get = try XCTUnwrap(result["get"] as? [String: Any])
        XCTAssertEqual(get["arg0"] as? NSDictionary, ["enabled": true, "path": "panel.html"])
        XCTAssertEqual((result["open"] as? [String: Any])?["argc"] as? Int, 0)
        XCTAssertEqual((result["behavior"] as? [String: Any])?["arg0"] as? NSDictionary, ["openPanelOnActionClick": false])
    }

    func testAFailedCallbackCallSetsLastError() async throws {
        let webView = try await makeWebView()
        bridge.replies["sidePanel.open"] = { _ in (nil, "No active side panel for the tab") }
        let result = try await dict("""
            return await new Promise((resolve) => {
                chrome.sidePanel.open({ tabId: 5 }, function() {
                    resolve({ argc: arguments.length,
                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                });
            });
            """, in: webView)
        XCTAssertEqual(result["argc"] as? Int, 0)
        XCTAssertEqual(result["lastError"] as? String, "No active side panel for tabId: 5")
    }

    // MARK: tabs.getCurrent

    /// WebKit answers null for a page that is not a tab; Chrome answers undefined.
    private static let tabsShim = """
    globalThis.__currentTab = null;
    globalThis.chrome.tabs = {
        getCurrent: function(callback) {
            if (typeof callback === 'function') { setTimeout(() => callback(globalThis.__currentTab), 0); return undefined; }
            return Promise.resolve(globalThis.__currentTab);
        }
    };
    """

    func testGetCurrentAnswersUndefinedWhereWebKitAnswersNull() async throws {
        let webView = try await makeWebView(shim: Self.tabsShim)
        let result = try await dict("""
            const kind = (value) => value === undefined ? 'undefined' : (value === null ? 'null' : 'tab');
            const viaCallback = () => new Promise((resolve) => chrome.tabs.getCurrent(function(tab) {
                resolve({ argc: arguments.length, kind: kind(tab) });
            }));
            const out = { promise: kind(await chrome.tabs.getCurrent()), callback: await viaCallback(),
                          native: kind(await chrome.tabs.getCurrent._detourNative.call(chrome.tabs)),
                          wrapped: chrome.tabs.getCurrent._detourGetCurrentWrapper === true,
                          held: __detourHeldWrappers.tabs === chrome.tabs };
            // A page that is a tab still gets its tab.
            globalThis.__currentTab = { id: 7 };
            out.tabPromise = await chrome.tabs.getCurrent();
            out.tabCallback = await new Promise((resolve) => chrome.tabs.getCurrent((tab) => resolve(tab)));
            return out;
            """, in: webView)
        XCTAssertEqual(result["promise"] as? String, "undefined")
        XCTAssertEqual((result["callback"] as? [String: Any])?["kind"] as? String, "undefined")
        XCTAssertEqual((result["callback"] as? [String: Any])?["argc"] as? Int, 1)
        XCTAssertEqual(result["native"] as? String, "null", "WebKit's own function is kept, unchanged")
        XCTAssertEqual(result["wrapped"] as? Bool, true)
        XCTAssertEqual(result["held"] as? Bool, true, "the tabs namespace must be rooted")
        XCTAssertEqual(result["tabPromise"] as? NSDictionary, ["id": 7])
        XCTAssertEqual(result["tabCallback"] as? NSDictionary, ["id": 7])
    }

    func testGetCurrentIsLeftAloneWithoutThePermission() async throws {
        let webView = try await makeWebView(permissions: [], shim: Self.tabsShim)
        let result = try await dict("""
            return { wrapped: chrome.tabs.getCurrent._detourGetCurrentWrapper === true,
                     answer: (await chrome.tabs.getCurrent()) === null };
            """, in: webView)
        XCTAssertEqual(result["wrapped"] as? Bool, false)
        XCTAssertEqual(result["answer"] as? Bool, true)
    }

    // MARK: window.close

    func testWindowCloseTellsDetourAndStillClosesTheWindow() async throws {
        // WebKit's own close is replaced by a counter before the polyfill runs.
        let webView = try await makeWebView(shim: """
            globalThis.__nativeCloses = 0;
            window.close = function() { globalThis.__nativeCloses += 1; };
            """)
        let closes = try await evaluateJSON("""
            window.close();
            await new Promise((resolve) => setTimeout(resolve, 50));
            return globalThis.__nativeCloses;
            """, in: webView)
        XCTAssertEqual(closes as? Int, 1, "WebKit's close must still run")
        XCTAssertEqual(bridge.types, ["sidePanel.closeSelf"])
    }
}
