import XCTest
import WebKit
@testable import Detour

/// Tests that the extension popup correctly intercepts link navigations and
/// posts `extensionPopupOpenURL` notifications instead of navigating in-place.
///
/// Uses a standalone WKWebView with the popover controller as delegate (no NSPopover)
/// to avoid headless test environment instabilities with popover lifecycle.
@MainActor
final class ExtensionPopupLinkTests: XCTestCase {

    private var tempDir: URL!
    private var ext: WebExtension!
    private var controller: ExtensionPopoverController!
    private var webView: WKWebView!
    private var navDelegate: TestPopupNavDelegate!
    private var receivedURLs: [URL] = []
    private var observer: NSObjectProtocol?

    @MainActor
    override func setUp() {
        super.setUp()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-popup-link-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "Popup Link Test",
            "version": "1.0",
            "permissions": ["storage"],
            "action": { "default_popup": "popup.html" }
        }
        """
        try! manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)

        let popupHTML = """
        <!DOCTYPE html>
        <html>
        <body>
          <a id="https-link" href="https://example.com/page" target="_blank">HTTPS Link</a>
          <a id="http-link" href="http://example.com/page">HTTP Link</a>
          <a id="file-link" href="local.html">Local Link</a>
        </body>
        </html>
        """
        try! popupHTML.write(to: tempDir.appendingPathComponent("popup.html"),
                             atomically: true, encoding: .utf8)

        try! "<html><body>local</body></html>".write(
            to: tempDir.appendingPathComponent("local.html"),
            atomically: true, encoding: .utf8)

        let manifest = try! ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let extID = "popup-link-test-\(UUID().uuidString)"
        ext = WebExtension(id: extID, manifest: manifest, basePath: tempDir)
        ExtensionManager.shared.extensions.append(ext)

        let record = ExtensionRecord(
            id: extID, name: manifest.name, version: manifest.version,
            manifestJSON: try! manifest.toJSONData(), basePath: tempDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(record)

        // Create the controller (it acts as WKNavigationDelegate + WKUIDelegate)
        controller = ExtensionPopoverController(extension: ext)

        // Create a WKWebView directly and assign the controller as delegate
        // (avoids NSPopover lifecycle issues in test environments)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let apiBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: false)
        config.userContentController.addUserScript(
            WKUserScript(source: apiBundle, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ExtensionMessageBridge.shared.register(on: config.userContentController)

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 480), configuration: config)
        webView.navigationDelegate = controller
        webView.uiDelegate = controller

        // Observe the notification
        receivedURLs = []
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("extensionPopupOpenURL"),
            object: nil, queue: .main
        ) { [weak self] notification in
            if let url = notification.userInfo?["url"] as? URL {
                self?.receivedURLs.append(url)
            }
        }

        // Load the popup HTML
        let popupURL = tempDir.appendingPathComponent("popup.html")
        let navExp = expectation(description: "Popup loaded")
        navDelegate = TestPopupNavDelegate { navExp.fulfill() }

        // Temporarily set nav delegate to wait for load, then switch back
        let origDelegate = webView.navigationDelegate
        webView.navigationDelegate = navDelegate
        webView.loadFileURL(popupURL, allowingReadAccessTo: tempDir)
        wait(for: [navExp], timeout: 10.0)
        webView.navigationDelegate = origDelegate
    }

    @MainActor
    override func tearDown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        webView = nil
        navDelegate = nil
        controller = nil
        ExtensionManager.shared.extensions.removeAll { $0.id == ext.id }
        AppDatabase.shared.deleteExtension(id: ext.id)
        ext = nil
        if let d = tempDir { try? FileManager.default.removeItem(at: d) }
        super.tearDown()
    }

    // MARK: - Tests

    func testPopupHTMLLoadsSuccessfully() {
        let exp = expectation(description: "Check popup content")
        webView.evaluateJavaScript("document.getElementById('https-link').textContent") { result, error in
            XCTAssertNil(error)
            XCTAssertEqual(result as? String, "HTTPS Link")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
    }

    func testNavigationDelegateIsPopoverController() {
        XCTAssertTrue(webView.navigationDelegate is ExtensionPopoverController)
    }

    func testUIDelegateIsPopoverController() {
        XCTAssertTrue(webView.uiDelegate is ExtensionPopoverController)
    }

    func testHTTPSLinkPostsNotification() {
        receivedURLs = []

        let exp = expectation(description: "HTTPS link clicked")
        webView.evaluateJavaScript("document.getElementById('https-link').click();") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertEqual(receivedURLs.count, 1, "Should have received exactly one URL notification")
        XCTAssertEqual(receivedURLs.first?.absoluteString, "https://example.com/page")
    }

    func testHTTPLinkPostsNotification() {
        receivedURLs = []

        let exp = expectation(description: "HTTP link clicked")
        webView.evaluateJavaScript("document.getElementById('http-link').click();") { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5.0)

        XCTAssertFalse(receivedURLs.isEmpty, "Should have received a URL notification for http link")
        if let url = receivedURLs.first {
            XCTAssertEqual(url.scheme, "http")
        }
    }

    func testNotificationContainsURLInUserInfo() {
        receivedURLs = []
        let testURL = URL(string: "https://test.example.com/verify")!

        NotificationCenter.default.post(
            name: Notification.Name("extensionPopupOpenURL"),
            object: nil,
            userInfo: ["url": testURL]
        )

        let exp = expectation(description: "notification processed")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(receivedURLs.count, 1)
        XCTAssertEqual(receivedURLs.first, testURL)
    }
}

private class TestPopupNavDelegate: NSObject, WKNavigationDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
}
