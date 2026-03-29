import XCTest
import WebKit
@testable import Detour

/// Tests for the extension API polyfill bridge.
/// Verifies that the JS polyfills can communicate with the native
/// `ExtensionPolyfillHandler` and receive correct responses.
@MainActor
final class ExtensionPolyfillTests: XCTestCase {

    private var webView: WKWebView!
    private var handler: ExtensionPolyfillHandler!

    override func setUp() async throws {
        try await super.setUp()

        handler = ExtensionPolyfillHandler()

        let config = WKWebViewConfiguration()
        let ucc = config.userContentController

        // Register the polyfill message handler
        ucc.addScriptMessageHandler(handler, contentWorld: .page, name: ExtensionPolyfillHandler.handlerName)

        // Inject polyfill JS at document start
        let polyfillScript = WKUserScript(
            source: ExtensionAPIPolyfill.polyfillJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(polyfillScript)

        // Inject a shim for chrome.runtime.id since we're not in a real extension context
        let shimScript = WKUserScript(
            source: """
            if (!globalThis.chrome) globalThis.chrome = {};
            if (!globalThis.chrome.runtime) globalThis.chrome.runtime = {};
            if (!globalThis.chrome.runtime.id) globalThis.chrome.runtime.id = 'test-polyfill-extension';
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        // Inject before polyfill so chrome.runtime.id is available
        ucc.addUserScript(shimScript)

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.loadHTMLString("<html><body>test</body></html>", baseURL: URL(string: "https://test.example.com")!)
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    override func tearDown() {
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
        handler = nil
        super.tearDown()
    }

    /// Evaluate JS that returns a JSON-serializable value, parsed back to Swift.
    /// Uses callAsyncJavaScript so Promises are automatically awaited.
    private func evalJSON(_ js: String) async throws -> Any? {
        let result = try await webView.callAsyncJavaScript(
            js, arguments: [:], contentWorld: .page
        )
        if let jsonString = result as? String,
           let data = jsonString.data(using: .utf8) {
            return try JSONSerialization.jsonObject(with: data)
        }
        return result
    }

    /// Evaluate a JS expression that may return a Promise.
    /// Uses callAsyncJavaScript so Promises are automatically awaited.
    private func eval(_ js: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            js, arguments: [:], contentWorld: .page
        )
    }

    // MARK: - Polyfill Namespace Existence

    func testIdleNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.idle") as? String
        XCTAssertEqual(exists, "object")
    }

    func testNotificationsNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.notifications") as? String
        XCTAssertEqual(exists, "object")
    }

    func testHistoryNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.history") as? String
        XCTAssertEqual(exists, "object")
    }

    func testManagementNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.management") as? String
        XCTAssertEqual(exists, "object")
    }

    func testFontSettingsNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.fontSettings") as? String
        XCTAssertEqual(exists, "object")
    }

    func testSessionsNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.sessions") as? String
        XCTAssertEqual(exists, "object")
    }

    func testSearchNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.search") as? String
        XCTAssertEqual(exists, "object")
    }

    func testOffscreenNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.offscreen") as? String
        XCTAssertEqual(exists, "object")
    }

    func testExtensionNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.extension") as? String
        XCTAssertEqual(exists, "object")
    }

    func testWebRequestNamespaceExists() async throws {
        let exists = try await eval("return typeof chrome.webRequest") as? String
        XCTAssertEqual(exists, "object")
    }

    // MARK: - chrome.idle

    func testIdleQueryState() async throws {
        let state = try await eval("return await chrome.idle.queryState(60)") as? String
        XCTAssertNotNil(state)
        XCTAssertTrue(["active", "idle", "locked"].contains(state!),
                       "idle.queryState should return active, idle, or locked but got: \(state!)")
    }

    func testIdleSetDetectionInterval() async throws {
        // Should not throw — setDetectionInterval is fire-and-forget
        _ = try await eval("chrome.idle.setDetectionInterval(30)")
    }

    func testIdleOnStateChangedIsEventEmitter() async throws {
        let hasAddListener = try await eval("return typeof chrome.idle.onStateChanged.addListener") as? String
        XCTAssertEqual(hasAddListener, "function")
        let hasRemoveListener = try await eval("return typeof chrome.idle.onStateChanged.removeListener") as? String
        XCTAssertEqual(hasRemoveListener, "function")
    }

    func testIdleStateConstants() async throws {
        let active = try await eval("return chrome.idle.IdleState.ACTIVE") as? String
        XCTAssertEqual(active, "active")
        let idle = try await eval("return chrome.idle.IdleState.IDLE") as? String
        XCTAssertEqual(idle, "idle")
        let locked = try await eval("return chrome.idle.IdleState.LOCKED") as? String
        XCTAssertEqual(locked, "locked")
    }

    // MARK: - chrome.notifications

    func testNotificationsCreate() async throws {
        let result = try await evalJSON("""
            var id = await chrome.notifications.create('test-notif', {
                type: 'basic', title: 'Test', message: 'Hello'
            });
            return JSON.stringify({ notificationId: id });
        """) as? [String: Any]
        let notifId = result?["notificationId"] as? String
        XCTAssertNotNil(notifId, "notifications.create should return a notification ID")
        XCTAssertFalse(notifId?.isEmpty ?? true)
    }

    func testNotificationsGetAll() async throws {
        _ = try await eval("""
            await chrome.notifications.create('getall-test', {
                type: 'basic', title: 'Test', message: 'Hello'
            })
        """)

        let result = try await evalJSON("""
            var all = await chrome.notifications.getAll();
            return JSON.stringify(all);
        """) as? [String: Any]
        XCTAssertNotNil(result)
    }

    func testNotificationsClear() async throws {
        _ = try await eval("""
            await chrome.notifications.create('clear-test', {
                type: 'basic', title: 'Test', message: 'Hello'
            })
        """)

        let result = try await evalJSON("""
            var cleared = await chrome.notifications.clear('clear-test');
            return JSON.stringify({ cleared: cleared });
        """) as? [String: Any]
        XCTAssertEqual(result?["cleared"] as? Bool, true)
    }

    func testNotificationsEventEmitters() async throws {
        let onClicked = try await eval("return typeof chrome.notifications.onClicked.addListener") as? String
        XCTAssertEqual(onClicked, "function")
        let onClosed = try await eval("return typeof chrome.notifications.onClosed.addListener") as? String
        XCTAssertEqual(onClosed, "function")
    }

    // MARK: - chrome.history

    func testHistorySearchReturnsArray() async throws {
        let result = try await evalJSON("""
            var items = await chrome.history.search({ text: '' });
            return JSON.stringify({ count: items.length, isArray: Array.isArray(items) });
        """) as? [String: Any]
        XCTAssertEqual(result?["isArray"] as? Bool, true)
    }

    func testHistoryGetVisitsStub() async throws {
        let result = try await evalJSON("""
            var visits = await chrome.history.getVisits({ url: 'https://example.com' });
            return JSON.stringify({ count: visits.length });
        """) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 0)
    }

    func testHistoryEventEmitters() async throws {
        let onVisited = try await eval("return typeof chrome.history.onVisited.addListener") as? String
        XCTAssertEqual(onVisited, "function")
    }

    // MARK: - chrome.fontSettings

    func testFontSettingsGetFontList() async throws {
        let result = try await evalJSON("""
            var fonts = await chrome.fontSettings.getFontList();
            return JSON.stringify({ count: fonts.length, hasItems: fonts.length > 0 });
        """) as? [String: Any]
        XCTAssertEqual(result?["hasItems"] as? Bool, true, "Should return system fonts")
    }

    func testFontSettingsGetFontListFormat() async throws {
        let result = try await evalJSON("""
            var fonts = await chrome.fontSettings.getFontList();
            var first = fonts[0];
            return JSON.stringify({ hasFontId: 'fontId' in first, hasDisplayName: 'displayName' in first });
        """) as? [String: Any]
        XCTAssertEqual(result?["hasFontId"] as? Bool, true)
        XCTAssertEqual(result?["hasDisplayName"] as? Bool, true)
    }

    // MARK: - chrome.management

    func testManagementGetSelf() async throws {
        let result = try await evalJSON("""
            var info = await chrome.management.getSelf();
            return JSON.stringify(info);
        """) as? [String: Any]
        XCTAssertNotNil(result?["id"])
        XCTAssertNotNil(result?["type"])
    }

    func testManagementGetAll() async throws {
        let result = try await evalJSON("""
            var all = await chrome.management.getAll();
            return JSON.stringify({ isArray: Array.isArray(all) });
        """) as? [String: Any]
        XCTAssertEqual(result?["isArray"] as? Bool, true)
    }

    // MARK: - chrome.sessions

    func testSessionsMaxSessionResults() async throws {
        let result = try await eval("return chrome.sessions.MAX_SESSION_RESULTS") as? Int
        XCTAssertEqual(result, 25)
    }

    func testSessionsGetRecentlyClosedStub() async throws {
        let result = try await evalJSON("""
            var sessions = await chrome.sessions.getRecentlyClosed();
            return JSON.stringify({ count: sessions.length });
        """) as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 0)
    }

    // MARK: - chrome.offscreen

    func testOffscreenReasonConstants() async throws {
        let result = try await eval("return chrome.offscreen.Reason.DOM_PARSER") as? String
        XCTAssertEqual(result, "DOM_PARSER")
    }

    func testOffscreenHasDocumentInitiallyFalse() async throws {
        let result = try await eval("return await chrome.offscreen.hasDocument()")
        XCTAssertEqual(result as? Bool, false)
    }

    // MARK: - chrome.extension

    func testExtensionGetBackgroundPageReturnsNull() async throws {
        let result = try await eval("return chrome.extension.getBackgroundPage()")
        // JS null comes through as NSNull, not Swift nil
        XCTAssertTrue(result is NSNull || result == nil,
                       "getBackgroundPage() should return null, got: \(String(describing: result))")
    }

    func testExtensionIsAllowedFileSchemeAccess() async throws {
        let result = try await eval("return await chrome.extension.isAllowedFileSchemeAccess()")
        XCTAssertEqual(result as? Bool, false)
    }

    func testExtensionIsAllowedIncognitoAccess() async throws {
        let result = try await eval("return await chrome.extension.isAllowedIncognitoAccess()")
        XCTAssertEqual(result as? Bool, false)
    }

    // MARK: - chrome.webRequest

    func testWebRequestEventEmitters() async throws {
        let onBefore = try await eval("return typeof chrome.webRequest.onBeforeRequest.addListener") as? String
        XCTAssertEqual(onBefore, "function")
        let onHeaders = try await eval("return typeof chrome.webRequest.onHeadersReceived.addListener") as? String
        XCTAssertEqual(onHeaders, "function")
    }

    func testWebRequestHasListenerReturnsFalse() async throws {
        let result = try await eval("return chrome.webRequest.onBeforeRequest.hasListener(function(){})") as? Bool
        XCTAssertEqual(result, false)
    }

    // MARK: - Event Emitter Utility

    func testEventEmitterAddAndHasListener() async throws {
        let result = try await eval("""
            var fn = function() {};
            chrome.idle.onStateChanged.addListener(fn);
            return chrome.idle.onStateChanged.hasListener(fn);
        """) as? Bool
        XCTAssertEqual(result, true)
    }

    func testEventEmitterRemoveListener() async throws {
        let result = try await eval("""
            var fn = function() {};
            chrome.idle.onStateChanged.addListener(fn);
            chrome.idle.onStateChanged.removeListener(fn);
            return chrome.idle.onStateChanged.hasListener(fn);
        """) as? Bool
        XCTAssertEqual(result, false)
    }

    // MARK: - chrome.search

    func testSearchQueryFunctionExists() async throws {
        let exists = try await eval("return typeof chrome.search.query") as? String
        XCTAssertEqual(exists, "function")
    }

    // MARK: - Native Message Bridge (service worker fallback)

    /// Test the handleNativeMessage path directly — this is the path used by
    /// service workers where webkit.messageHandlers is unavailable.
    func testNativeMessageBridgeIdleQueryState() {
        let handler = ExtensionPolyfillHandler()
        let expectation = expectation(description: "idle.queryState via native bridge")

        handler.handleNativeMessage(
            ["type": "idle.queryState", "extensionID": "test", "params": ["detectionIntervalInSeconds": 60]]
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertNotNil(result as? String)
            XCTAssertTrue(["active", "idle", "locked"].contains(result as? String ?? ""))
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeFontSettings() {
        let handler = ExtensionPolyfillHandler()
        let expectation = expectation(description: "fontSettings via native bridge")

        handler.handleNativeMessage(
            ["type": "fontSettings.getFontList", "extensionID": "test", "params": [:] as [String: Any]]
        ) { result, error in
            XCTAssertNil(error)
            let fonts = result as? [[String: String]]
            XCTAssertNotNil(fonts)
            XCTAssertGreaterThan(fonts?.count ?? 0, 0, "Should return system fonts")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeHistorySearch() {
        let handler = ExtensionPolyfillHandler()
        let expectation = expectation(description: "history.search via native bridge")

        handler.handleNativeMessage(
            ["type": "history.search", "extensionID": "test",
             "params": ["query": ["text": "", "maxResults": 10]]]
        ) { result, error in
            XCTAssertNil(error)
            let dict = result as? [String: Any]
            XCTAssertNotNil(dict?["results"])
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeOffscreenHasDocument() {
        let handler = ExtensionPolyfillHandler()
        let expectation = expectation(description: "offscreen.hasDocument via native bridge")

        handler.handleNativeMessage(
            ["type": "offscreen.hasDocument", "extensionID": "test", "params": [:] as [String: Any]]
        ) { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? Bool, false)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeInvalidType() {
        let handler = ExtensionPolyfillHandler()
        let expectation = expectation(description: "unknown type via native bridge")

        handler.handleNativeMessage(
            ["type": "nonexistent.api", "extensionID": "test", "params": [:] as [String: Any]]
        ) { result, error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testNativeMessageBridgeMissingType() {
        let handler = ExtensionPolyfillHandler()
        let expectation = expectation(description: "missing type via native bridge")

        handler.handleNativeMessage(
            ["extensionID": "test"]
        ) { result, error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    // MARK: - Service Worker Fallback Detection

    func testPolyfillUsesWebkitHandlerWhenAvailable() async throws {
        // In a WKWebView with the handler registered, the polyfill should work
        // via webkit.messageHandlers (already tested above). Verify the bridge
        // actually resolves — if it fell back to sendNativeMessage, idle.queryState
        // would fail since browser.runtime.sendNativeMessage isn't available here.
        let state = try await eval("return await chrome.idle.queryState(60)") as? String
        XCTAssertNotNil(state, "Polyfill should work via webkit.messageHandlers in WKWebView")
    }

    func testPolyfillFallsBackToNativeMessageWhenNoHandler() async throws {
        // Create a web view WITHOUT the webkit handler but WITH browser.runtime.sendNativeMessage stubbed.
        // This simulates the service worker environment.
        let config = WKWebViewConfiguration()
        let polyfillScript = WKUserScript(
            source: """
            if (!globalThis.chrome) globalThis.chrome = {};
            if (!globalThis.chrome.runtime) globalThis.chrome.runtime = {};
            globalThis.chrome.runtime.id = 'test';
            if (!globalThis.browser) globalThis.browser = {};
            if (!globalThis.browser.runtime) globalThis.browser.runtime = {};
            globalThis.browser.runtime.id = 'test';
            // Stub sendNativeMessage to capture the call
            globalThis.__nativeMessageCalls = [];
            globalThis.browser.runtime.sendNativeMessage = function(appId, msg) {
                globalThis.__nativeMessageCalls.push({ appId: appId, type: msg.type });
                return Promise.resolve('active');
            };
            """ + "\n" + ExtensionAPIPolyfill.polyfillJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(polyfillScript)

        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        wv.loadHTMLString("<html><body>test</body></html>", baseURL: URL(string: "https://test.example.com")!)
        try await Task.sleep(nanoseconds: 500_000_000)

        // Call a polyfill API — should fall back to sendNativeMessage since no handler is registered
        _ = try await wv.callAsyncJavaScript(
            "return await chrome.idle.queryState(60)",
            arguments: [:], contentWorld: .page
        )

        // Verify sendNativeMessage was called with the right appId
        let calls = try await wv.callAsyncJavaScript(
            "return JSON.stringify(globalThis.__nativeMessageCalls)",
            arguments: [:], contentWorld: .page
        ) as? String
        XCTAssertTrue(calls?.contains("detourPolyfill") ?? false,
                       "Should have called sendNativeMessage('detourPolyfill', ...), got: \(calls ?? "nil")")
        XCTAssertTrue(calls?.contains("idle.queryState") ?? false,
                       "Should have passed the message type, got: \(calls ?? "nil")")
    }
}
