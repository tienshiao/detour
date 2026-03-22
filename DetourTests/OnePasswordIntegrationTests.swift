import XCTest
import WebKit
@testable import Detour

/// Integration tests for 1Password extension loading and popup functionality.
/// Uses a bundled CRX from TestExtensions/1password/ (no network dependency).
final class OnePasswordIntegrationTests: XCTestCase {

    static let onePasswordChromeID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

    private var ext: WebExtension?

    // MARK: - Shared one-time setup

    private struct SharedState {
        let crxData: Data
        let ext: WebExtension
    }

    private nonisolated(unsafe) static var shared: SharedState?

    override func setUp() {
        super.setUp()
        if Self.shared == nil {
            Self.createSharedState()
        }
        ext = Self.shared?.ext
    }

    private static func createSharedState() {
        // Load bundled CRX from TestExtensions/1password/
        let crxPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DetourTests/
            .deletingLastPathComponent() // MyBrowser/
            .appendingPathComponent("TestExtensions/1password/1password.crx")

        guard let crxData = try? Data(contentsOf: crxPath), !crxData.isEmpty else {
            // CRX not bundled — tests will be skipped via guard in each test
            return
        }

        // Install if not already installed
        if ExtensionManager.shared.extension(withID: onePasswordChromeID) == nil {
            do {
                let result = try CRXUnpacker.unpack(data: crxData)
                defer { try? FileManager.default.removeItem(at: result.directory) }

                let ext = try ExtensionInstaller.install(from: result.directory, publicKey: result.publicKey)
                ExtensionManager.shared.extensions.append(ext)
                ExtensionManager.shared.startBackground(for: ext, isFirstRun: true)
            } catch {
                return
            }
        }

        guard let ext = ExtensionManager.shared.extension(withID: onePasswordChromeID) else { return }
        shared = SharedState(crxData: crxData, ext: ext)
    }

    override class func tearDown() {
        if let ext = shared?.ext {
            ExtensionManager.shared.extensions.removeAll { $0.id == ext.id }
            ExtensionManager.shared.backgroundHosts[ext.id]?.stop()
            ExtensionManager.shared.backgroundHosts.removeValue(forKey: ext.id)
        }
        shared = nil
        super.tearDown()
    }

    // MARK: - CRX ID Derivation

    func testCRXProducesCorrectExtensionID() {
        guard let crxData = Self.shared?.crxData else {
            XCTFail("1Password CRX not bundled at TestExtensions/1password/1password.crx")
            return
        }

        let result = try! CRXUnpacker.unpack(data: crxData)
        defer { try? FileManager.default.removeItem(at: result.directory) }

        XCTAssertNotNil(result.publicKey, "Should extract public key from CRX")
        guard let pubKey = result.publicKey else { return }

        let derivedID = ExtensionInstaller.deriveExtensionID(from: pubKey)
        XCTAssertEqual(derivedID, Self.onePasswordChromeID,
                       "Derived ID should match 1Password's Chrome Web Store ID")
    }

    // MARK: - Background Host

    func testBackgroundHostLoads() {
        guard let ext else { XCTFail("Extension not installed"); return }
        XCTAssertEqual(ext.manifest.background?.serviceWorker, "background/background.js")
        XCTAssertTrue(ext.manifest.background?.isModule == true, "1Password background should be a module")

        let host = BackgroundHost(extension: ext)
        let loadExpectation = XCTestExpectation(description: "Background loads")

        host.start(isFirstRun: false) {
            loadExpectation.fulfill()
        }

        wait(for: [loadExpectation], timeout: 10)
        XCTAssertTrue(host.isLoaded, "Background host should be loaded")

        // Check for JS errors
        let errorCheckExpectation = XCTestExpectation(description: "Error check")
        var bgErrors: [String] = []
        var hasChromeRuntime = false

        host.evaluateJavaScript("""
            JSON.stringify({
                errors: window.__bgErrors || [],
                hasChrome: typeof chrome !== 'undefined' && typeof chrome.runtime !== 'undefined',
                hasWebkit: typeof window.webkit !== 'undefined'
            })
        """) { result, error in
            if let json = result as? String,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bgErrors = dict["errors"] as? [String] ?? []
                hasChromeRuntime = dict["hasChrome"] as? Bool ?? false
            }
            errorCheckExpectation.fulfill()
        }

        wait(for: [errorCheckExpectation], timeout: 5)

        XCTAssertTrue(hasChromeRuntime, "chrome.runtime should be available")
        if !bgErrors.isEmpty {
            XCTFail("Background script errors: \(bgErrors.joined(separator: "; "))")
        }

        // Wait for module to fully initialize (3 seconds)
        let moduleWait = XCTestExpectation(description: "Module init wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { moduleWait.fulfill() }
        wait(for: [moduleWait], timeout: 5)

        // Check if the module actually executed (look for side effects)
        let moduleExecExpectation = XCTestExpectation(description: "Module exec check")
        host.evaluateJavaScript("""
            (function() {
                var moduleScript = document.querySelector('script[type="module"]');
                return JSON.stringify({
                    moduleSrc: moduleScript ? moduleScript.src : null,
                    hasSentryDebugIds: typeof window._sentryDebugIds !== 'undefined',
                    globalKeys: Object.keys(window).filter(function(k) {
                        return k.indexOf('_sentry') === 0 || k.indexOf('__1p') >= 0;
                    }),
                    detourGlobals: Object.keys(window).filter(function(k) {
                        return k.indexOf('__extension') === 0 || k.indexOf('__detour') === 0;
                    }),
                });
            })()
        """) { result, error in
            print("[Test] Module execution check: \(result ?? "nil")")
            moduleExecExpectation.fulfill()
        }
        wait(for: [moduleExecExpectation], timeout: 5)
    }

    func testBackgroundReceivesBridgeMessages() {
        guard let ext else { XCTFail("Extension not installed"); return }

        let host = BackgroundHost(extension: ext)
        let loadExpectation = XCTestExpectation(description: "Background loads")
        host.start(isFirstRun: false) { loadExpectation.fulfill() }
        wait(for: [loadExpectation], timeout: 10)

        // Wait for module to fully initialize
        let initWait = XCTestExpectation(description: "Init wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { initWait.fulfill() }
        wait(for: [initWait], timeout: 5)

        // Test 1: Check if chrome API is available and functional
        let apiCheckExpectation = XCTestExpectation(description: "API check")
        host.evaluateJavaScript("""
            JSON.stringify({
                hasChrome: typeof chrome !== 'undefined',
                hasChromeRuntime: typeof chrome !== 'undefined' && typeof chrome.runtime !== 'undefined',
                runtimeId: (chrome && chrome.runtime) ? chrome.runtime.id : null,
                hasStorage: typeof chrome !== 'undefined' && typeof chrome.storage !== 'undefined',
                hasWebkitHandlers: typeof window.webkit !== 'undefined' && !!window.webkit.messageHandlers && !!window.webkit.messageHandlers.extensionMessage,
                canPostMessage: typeof window.webkit !== 'undefined' && !!window.webkit.messageHandlers && !!window.webkit.messageHandlers.extensionMessage && typeof window.webkit.messageHandlers.extensionMessage.postMessage === 'function'
            })
        """) { result, error in
            print("[Test] API check: \(result ?? "nil"), error: \(error?.localizedDescription ?? "none")")
            apiCheckExpectation.fulfill()
        }
        wait(for: [apiCheckExpectation], timeout: 5)

        // Test 2: Try posting a raw message directly to the bridge
        let bridgeExpectation = XCTestExpectation(description: "Bridge test")
        host.evaluateJavaScript("""
            (function() {
                try {
                    window.webkit.messageHandlers.extensionMessage.postMessage({
                        extensionID: '\(ext.id)',
                        type: 'storage.get',
                        params: { keys: [], getAll: false },
                        callbackID: 'test_bridge_123',
                        isContentScript: false
                    });
                    return 'posted';
                } catch(e) {
                    return 'error: ' + e.message;
                }
            })()
        """) { result, error in
            print("[Test] Bridge post result: \(result ?? "nil"), error: \(error?.localizedDescription ?? "none")")
            bridgeExpectation.fulfill()
        }
        wait(for: [bridgeExpectation], timeout: 5)

        // Wait for bridge to process
        let processWait = XCTestExpectation(description: "Process wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { processWait.fulfill() }
        wait(for: [processWait], timeout: 3)

        // Test 3: Check if callback was delivered
        let callbackExpectation = XCTestExpectation(description: "Callback check")
        host.evaluateJavaScript("""
            (function() {
                return JSON.stringify({
                    hasCallbacks: typeof window.__extensionCallbacks !== 'undefined',
                    callbackKeys: window.__extensionCallbacks ? Object.keys(window.__extensionCallbacks) : [],
                    hasTestCallback: window.__extensionCallbacks && window.__extensionCallbacks['test_bridge_123'] !== undefined
                });
            })()
        """) { result, error in
            print("[Test] Callback check: \(result ?? "nil")")
            callbackExpectation.fulfill()
        }
        wait(for: [callbackExpectation], timeout: 5)
    }

    // MARK: - Popup

    func testPopupDoesNotShowOops() {
        guard let ext else { XCTFail("Extension not installed"); return }
        guard let popupURL = ext.popupURL else {
            XCTFail("1Password should have a popup URL")
            return
        }

        // Ensure background is running
        if ExtensionManager.shared.backgroundHost(for: ext.id) == nil {
            let loadExpectation = XCTestExpectation(description: "Background loads")
            ExtensionManager.shared.startBackground(for: ext, isFirstRun: false) {
                loadExpectation.fulfill()
            }
            wait(for: [loadExpectation], timeout: 10)
        }

        // Wait for background to initialize
        let initWait = XCTestExpectation(description: "Init wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { initWait.fulfill() }
        wait(for: [initWait], timeout: 5)

        // Create a popup webView
        let config = ext.makePageConfiguration()

        // Add a console capture script to intercept JS console output
        let consoleCapture = WKUserScript(source: """
            (function() {
                window.__consoleLog = [];
                var origError = console.error;
                var origWarn = console.warn;
                var origLog = console.log;
                console.error = function() {
                    var msg = Array.from(arguments).map(function(a) { return String(a); }).join(' ');
                    window.__consoleLog.push('ERROR: ' + msg);
                    origError.apply(console, arguments);
                };
                console.warn = function() {
                    var msg = Array.from(arguments).map(function(a) { return String(a); }).join(' ');
                    window.__consoleLog.push('WARN: ' + msg);
                    origWarn.apply(console, arguments);
                };
                window.addEventListener('error', function(e) {
                    window.__consoleLog.push('UNCAUGHT: ' + e.message + ' at ' + (e.filename || '') + ':' + (e.lineno || ''));
                });
                window.addEventListener('unhandledrejection', function(e) {
                    window.__consoleLog.push('UNHANDLED_REJECTION: ' + (e.reason ? (e.reason.message || String(e.reason)) : 'unknown'));
                });
            })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(consoleCapture)

        let popupWV = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600), configuration: config)
        popupWV.isInspectable = true
        ExtensionManager.shared.registerPopupWebView(popupWV, for: ext.id)

        let popupLoadExpectation = XCTestExpectation(description: "Popup loads")

        class PopupDelegate: NSObject, WKNavigationDelegate {
            let expectation: XCTestExpectation
            init(_ e: XCTestExpectation) { self.expectation = e }
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
                expectation.fulfill()
            }
            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
                expectation.fulfill()
            }
            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
                expectation.fulfill()
            }
        }

        let delegate = PopupDelegate(popupLoadExpectation)
        popupWV.navigationDelegate = delegate

        popupWV.load(URLRequest(url: popupURL))
        wait(for: [popupLoadExpectation], timeout: 15)

        // Poll for Oops or successful content every second for up to 15 seconds
        var foundOops = false
        var foundContent = false
        for i in 0..<15 {
            let pollWait = XCTestExpectation(description: "Poll \(i)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { pollWait.fulfill() }
            wait(for: [pollWait], timeout: 2)

            let checkExp = XCTestExpectation(description: "Check \(i)")
            popupWV.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, _ in
                let text = result as? String ?? ""
                if text.contains("Oops") { foundOops = true }
                if text.count > 200 && !text.contains("Oops") { foundContent = true }
                checkExp.fulfill()
            }
            wait(for: [checkExp], timeout: 3)
            if foundOops || foundContent { break }
        }
        print("[Test] Poll result: oops=\(foundOops), content=\(foundContent)")

        // Check for "Oops" text
        let oopsCheckExpectation = XCTestExpectation(description: "Oops check")
        var bodyText = ""
        var hasOops = false

        popupWV.evaluateJavaScript("document.body ? document.body.innerText : ''") { result, error in
            bodyText = result as? String ?? ""
            hasOops = bodyText.contains("Oops")
            oopsCheckExpectation.fulfill()
        }

        wait(for: [oopsCheckExpectation], timeout: 5)

        print("[Test] Popup body text (first 500 chars): \(String(bodyText.prefix(500)))")
        print("[Test] Contains 'Oops': \(hasOops)")

        // Also check for additional error indicators
        let extraCheckExpectation = XCTestExpectation(description: "Extra check")
        popupWV.evaluateJavaScript("""
            JSON.stringify({
                url: document.URL,
                title: document.title,
                bodyLen: (document.body ? document.body.innerHTML.length : 0),
                scriptErrors: window.__bgErrors || [],
                hasChromeRuntime: typeof chrome !== 'undefined' && typeof chrome.runtime !== 'undefined',
                runtimeId: (typeof chrome !== 'undefined' && chrome.runtime) ? chrome.runtime.id : null
            })
        """) { result, error in
            print("[Test] Popup extra: \(result ?? "nil")")
            extraCheckExpectation.fulfill()
        }
        wait(for: [extraCheckExpectation], timeout: 5)

        // Dump JS console output
        let consoleExp = XCTestExpectation(description: "Console dump")
        popupWV.evaluateJavaScript("JSON.stringify(window.__consoleLog || [])") { result, error in
            if let json = result as? String {
                // Parse and print each line
                if let data = json.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    for line in arr.prefix(30) {
                        print("[Test] POPUP CONSOLE: \(line)")
                    }
                    print("[Test] Total console lines: \(arr.count)")
                }
            }
            consoleExp.fulfill()
        }
        wait(for: [consoleExp], timeout: 5)

        // Check popup's pending callbacks
        let cbCheckExp = XCTestExpectation(description: "CB check")
        popupWV.evaluateJavaScript("""
            JSON.stringify({
                pendingCallbacks: window.__extensionCallbacks ? Object.keys(window.__extensionCallbacks).length : -1,
                hasPorts: window.__extensionPorts ? Object.keys(window.__extensionPorts).length : -1,
                lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null
            })
        """) { result, error in
            print("[Test] Popup callbacks: \(result ?? "nil")")
            cbCheckExp.fulfill()
        }
        wait(for: [cbCheckExp], timeout: 5)

        if hasOops {
            // Get more diagnostic info
            let diagExpectation = XCTestExpectation(description: "Diagnostics")
            popupWV.evaluateJavaScript("""
                JSON.stringify({
                    url: document.URL,
                    title: document.title,
                    scripts: document.querySelectorAll('script').length,
                    hasChrome: typeof chrome !== 'undefined',
                    hasChromeRuntime: typeof chrome !== 'undefined' && typeof chrome.runtime !== 'undefined',
                    errors: window.__bgErrors || [],
                    bodyPreview: (document.body ? document.body.innerText : '').substring(0, 500)
                })
            """) { result, error in
                print("[Test] Popup diagnostics: \(result ?? "nil")")
                diagExpectation.fulfill()
            }
            wait(for: [diagExpectation], timeout: 5)

            XCTFail("1Password popup shows 'Oops' error")
        }

        ExtensionManager.shared.unregisterPopupWebView(for: ext.id)
        _ = delegate // prevent deallocation
    }
}
