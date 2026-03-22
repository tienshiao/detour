import XCTest
import WebKit
@testable import Detour

/// Integration tests verifying that chrome.webNavigation events are dispatched
/// from native code through ExtensionManager.fireWebNavigationEvent and received
/// by background host listeners.
@MainActor
final class WebNavigationEventTests: XCTestCase {

    private var tempDir: URL!
    private var ext: WebExtension!
    private var backgroundHost: BackgroundHost!

    // MARK: - Shared one-time setup

    private static let extensionID = "webnav-test"

    private struct SharedState {
        let tempDir: URL
        let ext: WebExtension
        let backgroundHost: BackgroundHost
    }

    private nonisolated(unsafe) static var shared: SharedState?

    /// Create the shared test infrastructure once. Called from the first test's setUp.
    private func createSharedStateIfNeeded() {
        guard Self.shared == nil else { return }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-webnav-test")
        try? FileManager.default.removeItem(at: tempDir)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let manifestJSON = """
        {
            "manifest_version": 3,
            "name": "WebNav Test",
            "version": "1.0",
            "permissions": ["webNavigation"],
            "background": {"service_worker": "background.js"}
        }
        """
        try! manifestJSON.write(to: tempDir.appendingPathComponent("manifest.json"),
                                atomically: true, encoding: .utf8)

        // Background script: registers listeners for all four webNavigation events
        // and stores the last received details for each.
        let backgroundJS = """
        window.__webNavEvents = {};
        chrome.webNavigation.onBeforeNavigate.addListener(function(details) {
            window.__webNavEvents.onBeforeNavigate = details;
        });
        chrome.webNavigation.onCommitted.addListener(function(details) {
            window.__webNavEvents.onCommitted = details;
        });
        chrome.webNavigation.onCompleted.addListener(function(details) {
            window.__webNavEvents.onCompleted = details;
        });
        chrome.webNavigation.onErrorOccurred.addListener(function(details) {
            window.__webNavEvents.onErrorOccurred = details;
        });
        """
        try! backgroundJS.write(to: tempDir.appendingPathComponent("background.js"),
                                atomically: true, encoding: .utf8)

        let manifest = try! ExtensionManifest.parse(at: tempDir.appendingPathComponent("manifest.json"))
        let extID = Self.extensionID
        let ext = WebExtension(id: extID, manifest: manifest, basePath: tempDir)
        ExtensionManager.shared.extensions.append(ext)

        let record = ExtensionRecord(
            id: extID, name: manifest.name, version: manifest.version,
            manifestJSON: try! manifest.toJSONData(), basePath: tempDir.path,
            isEnabled: true, installedAt: Date().timeIntervalSince1970)
        AppDatabase.shared.saveExtension(record)

        let backgroundHost = BackgroundHost(extension: ext)
        ExtensionManager.shared.backgroundHosts[extID] = backgroundHost

        // Start background host and wait for it to be ready via completion handler
        let bgExp = expectation(description: "BG ready")
        backgroundHost.start { bgExp.fulfill() }
        wait(for: [bgExp], timeout: 5.0)

        Self.shared = SharedState(
            tempDir: tempDir,
            ext: ext,
            backgroundHost: backgroundHost
        )
    }

    @MainActor
    override func setUp() {
        super.setUp()
        createSharedStateIfNeeded()

        let s = Self.shared!
        tempDir = s.tempDir
        ext = s.ext
        backgroundHost = s.backgroundHost

        // Reset stored event data between tests
        let resetExp = expectation(description: "Reset events")
        backgroundHost.evaluateJavaScript("window.__webNavEvents = {}; true") { _, _ in
            resetExp.fulfill()
        }
        wait(for: [resetExp], timeout: 5.0)
    }

    @MainActor
    override func tearDown() {
        // Don't tear down shared state — it's reused across tests
        super.tearDown()
    }

    override class func tearDown() {
        MainActor.assumeIsolated {
            guard let s = shared else { return }
            s.backgroundHost.stop()
            ExtensionManager.shared.extensions.removeAll { $0.id == extensionID }
            ExtensionManager.shared.backgroundHosts.removeValue(forKey: extensionID)
            AppDatabase.shared.deleteExtension(id: extensionID)
            try? FileManager.default.removeItem(at: s.tempDir)
            shared = nil
        }
        super.tearDown()
    }

    // MARK: - fireWebNavigationEvent delivers to background host

    func testOnBeforeNavigateDelivered() {
        ExtensionManager.shared.fireWebNavigationEvent("onBeforeNavigate", details: [
            "tabId": 1, "url": "https://before.test/page", "frameId": 0,
            "timeStamp": 1000.0
        ])

        let result = bgEval("window.__webNavEvents.onBeforeNavigate ? window.__webNavEvents.onBeforeNavigate.url : null")
        XCTAssertEqual(result as? String, "https://before.test/page")
    }

    func testOnCommittedDelivered() {
        ExtensionManager.shared.fireWebNavigationEvent("onCommitted", details: [
            "tabId": 2, "url": "https://committed.test/page", "frameId": 0,
            "timeStamp": 2000.0
        ])

        let result = bgEval("window.__webNavEvents.onCommitted ? window.__webNavEvents.onCommitted.url : null")
        XCTAssertEqual(result as? String, "https://committed.test/page")
    }

    func testOnCompletedDelivered() {
        ExtensionManager.shared.fireWebNavigationEvent("onCompleted", details: [
            "tabId": 3, "url": "https://completed.test/page", "frameId": 0,
            "timeStamp": 3000.0
        ])

        let result = bgEval("window.__webNavEvents.onCompleted ? window.__webNavEvents.onCompleted.url : null")
        XCTAssertEqual(result as? String, "https://completed.test/page")
    }

    func testOnErrorOccurredDelivered() {
        ExtensionManager.shared.fireWebNavigationEvent("onErrorOccurred", details: [
            "tabId": 4, "url": "https://error.test/page", "frameId": 0,
            "error": "Connection refused", "timeStamp": 4000.0
        ])

        let result = bgEval("window.__webNavEvents.onErrorOccurred ? window.__webNavEvents.onErrorOccurred.url : null")
        XCTAssertEqual(result as? String, "https://error.test/page")
    }

    func testOnErrorOccurredIncludesError() {
        ExtensionManager.shared.fireWebNavigationEvent("onErrorOccurred", details: [
            "tabId": 5, "url": "https://error2.test/", "frameId": 0,
            "error": "DNS lookup failed", "timeStamp": 5000.0
        ])

        let result = bgEval("window.__webNavEvents.onErrorOccurred ? window.__webNavEvents.onErrorOccurred.error : null")
        XCTAssertEqual(result as? String, "DNS lookup failed")
    }

    func testEventDetailsIncludeTabId() {
        ExtensionManager.shared.fireWebNavigationEvent("onBeforeNavigate", details: [
            "tabId": 42, "url": "https://tabid.test/", "frameId": 0,
            "timeStamp": 6000.0
        ])

        let result = bgEval("window.__webNavEvents.onBeforeNavigate ? window.__webNavEvents.onBeforeNavigate.tabId : null")
        XCTAssertEqual(result as? Int, 42)
    }

    func testEventDetailsIncludeFrameId() {
        ExtensionManager.shared.fireWebNavigationEvent("onCommitted", details: [
            "tabId": 1, "url": "https://frame.test/", "frameId": 0,
            "timeStamp": 7000.0
        ])

        let result = bgEval("window.__webNavEvents.onCommitted ? window.__webNavEvents.onCommitted.frameId : null")
        XCTAssertEqual(result as? Int, 0)
    }

    func testEventDetailsIncludeTimeStamp() {
        ExtensionManager.shared.fireWebNavigationEvent("onCompleted", details: [
            "tabId": 1, "url": "https://ts.test/", "frameId": 0,
            "timeStamp": 12345.0
        ])

        let result = bgEval("window.__webNavEvents.onCompleted ? window.__webNavEvents.onCompleted.timeStamp : null")
        XCTAssertEqual(result as? Double, 12345.0)
    }

    // MARK: - Helpers

    private func bgEval(_ js: String) -> Any? {
        // Small delay to let async JS dispatch complete
        let delayExp = expectation(description: "Delay")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { delayExp.fulfill() }
        wait(for: [delayExp], timeout: 5.0)

        let exp = expectation(description: "BG eval")
        var result: Any?
        backgroundHost.evaluateJavaScript(js) { val, _ in
            result = val
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        return result
    }
}
