import XCTest
import WebKit
@testable import Detour

/// `chrome.runtime.onUpdateAvailable` and `chrome.runtime.reload()` (TASK-123),
/// exercised from real extension contexts loaded through
/// `Profile.loadExtensionContext`, so every request travels the production
/// polyfill bridge to `ExtensionPolyfillHandler` / `ExtensionManager`.
///
/// `onUpdateAvailable` parks a `runtime.awaitUpdateAvailable` request that only
/// the background context may hold; `ExtensionManager.notifyUpdateAvailable`
/// answers it (what `stageUpdate` does after staging a verified update), the
/// listeners run and the request is parked again. Each test uses a fresh
/// extension id, so waiters parked by one test never count in another.
@MainActor
final class ExtensionRuntimeUpdateAvailablePolyfillTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []

    override func tearDown() {
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    // MARK: - Fixtures

    /// The worker: listens for `onUpdateAvailable` at top level (as a real
    /// extension would) and answers `ping` and `seen` from the page.
    private static let workerJS = ExtensionAPIPolyfill.polyfillJS + """


    globalThis.__seen = null;
    globalThis.__seenCount = 0;
    chrome.runtime.onUpdateAvailable.addListener((details) => {
        globalThis.__seen = details;
        globalThis.__seenCount += 1;
    });
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) return false;
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'seen') {
            sendResponse({ seen: globalThis.__seen, count: globalThis.__seenCount });
            return true;
        }
        return false;
    });
    """

    /// An unpacked extension registered in ExtensionManager (so the handler can
    /// resolve its manifest's background) and loaded in a fresh profile, with
    /// one extension page open. With `withWorker`, it declares a service worker
    /// running `workerJS`.
    private func makeExtension(withWorker: Bool) async throws
        -> (ext: WebExtension, profile: Profile, context: WKWebExtensionContext, page: WKWebView) {
        let id = "update-available-\(UUID().uuidString.prefix(8))"
        let background = withWorker
            ? #","background": {"service_worker": "background.js", "type": "module"}"#
            : ""
        var files = ["test.html": "<html><body>update available</body></html>"]
        if withWorker { files["background.js"] = Self.workerJS }
        let ext = try await makeTestExtension(id: id, manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Update Available Test",
                "version": "1.0.0"\(background)
            }
            """, files: files)
        tempDirs.append(ext.basePath)
        ext.source = .unpacked
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)

        let profile = TabStore.shared.addProfile(name: "Update Available Profile")
        createdProfiles.append(profile)
        _ = profile.extensionController
        let context = try loadTestContext(ext, in: profile)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadAndWait(webView, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return (ext, profile, context, webView)
    }

    private func evalObject(_ js: String, in webView: WKWebView) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func waiterCount(_ ext: WebExtension) -> Int {
        ExtensionManager.shared.updateAvailableWaiterCountForTesting(extensionID: ext.id)
    }

    // MARK: - onUpdateAvailable from the background worker

    /// The worker's `addListener` parks one request; staging an update (here the
    /// notification `stageUpdate` sends) runs the listener with `{version}`, and
    /// the request is parked again for the next one.
    func testBackgroundListenerParksAWaiterAndReceivesTheStagedVersion() async throws {
        let (ext, _, _, page) = try await makeExtension(withWorker: true)

        try await waitUntil("the background worker to wake") {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        try await waitUntil("the worker to park its runtime.awaitUpdateAvailable request") {
            self.waiterCount(ext) == 1
        }

        ExtensionManager.shared.notifyUpdateAvailable(extensionID: ext.id, version: "9.9")

        var seenReply: [String: Any] = [:]
        try await waitUntil("the worker's onUpdateAvailable listener to run") {
            let answer = try await askWorker(from: page, message: ["type": "seen"], timeout: 5)
            seenReply = answer["reply"] as? [String: Any] ?? [:]
            return (seenReply["count"] as? Int ?? 0) > 0
        }
        XCTAssertEqual(seenReply["count"] as? Int, 1, "the listener runs once per update: \(seenReply)")
        let seen = try XCTUnwrap(seenReply["seen"] as? [String: Any], "details must be an object: \(seenReply)")
        XCTAssertEqual(seen["version"] as? String, "9.9")
        XCTAssertEqual(seen.count, 1, "details carry only the version: \(seen)")

        try await waitUntil("the worker to park its request again") {
            self.waiterCount(ext) == 1
        }
    }

    // MARK: - onUpdateAvailable from an extension page

    /// A page is not the background context: its `addListener` works as an
    /// event, but the native side refuses its wait, quietly.
    func testPageListenerDoesNotParkAWaiter() async throws {
        let (ext, _, _, page) = try await makeExtension(withWorker: false)

        let result = try await evalObject("""
            const unhandled = [];
            const onUnhandled = (event) => {
                unhandled.push(String(event.reason && event.reason.message ? event.reason.message : event.reason));
                event.preventDefault();
            };
            globalThis.addEventListener('unhandledrejection', onUnhandled);
            const out = {};
            try {
                const fn = () => {};
                chrome.runtime.onUpdateAvailable.addListener(fn);
                out.hasListener = chrome.runtime.onUpdateAvailable.hasListener(fn);
                out.threw = null;
            } catch (e) {
                out.threw = String(e && e.message ? e.message : e);
            }
            // Let the refused request settle.
            await new Promise((resolve) => setTimeout(resolve, 300));
            globalThis.removeEventListener('unhandledrejection', onUnhandled);
            out.unhandled = unhandled;
            return JSON.stringify(out);
        """, in: page)
        XCTAssertNil(result["threw"] as? String, "addListener must not throw: \(result)")
        XCTAssertEqual(result["hasListener"] as? Bool, true)
        XCTAssertEqual(result["unhandled"] as? [String], [], "the refusal must stay quiet: \(result)")
        XCTAssertEqual(waiterCount(ext), 0, "a page must never park a waiter")
    }

    /// The same from a page of an extension that does have a worker: the page's
    /// request arrives as a frame message from a non-background URL.
    func testPageOfAWorkerExtensionDoesNotParkAWaiter() async throws {
        let (ext, _, _, page) = try await makeExtension(withWorker: true)
        // Wake the worker so its own waiter is in place, then add the page's.
        try await waitUntil("the background worker to wake") {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        try await waitUntil("the worker to park its request") { self.waiterCount(ext) == 1 }

        _ = try await page.callAsyncJavaScript("""
            chrome.runtime.onUpdateAvailable.addListener(() => {});
            await new Promise((resolve) => setTimeout(resolve, 300));
            return true;
        """, arguments: [:], contentWorld: .page)
        XCTAssertEqual(waiterCount(ext), 1, "the page's request must not park beside the worker's")
    }

    // MARK: - runtime.reload

    /// With nothing staged, `runtime.reload()` asks Detour first, is told
    /// `{applied: false}`, and falls through to WebKit's own reload, which
    /// leaves the extension loaded.
     /// `chrome.runtime.reload` is WebKit's and stays so: `reload` is a read-only
    /// static value of the runtime wrapper, and an own property defined over it
    /// is masked (unlike the static functions the polyfill shadows). The
    /// polyfill therefore does not pretend to patch it; a reload that follows an
    /// `onUpdateAvailable` delivery is recognised natively instead
    /// (`ExtensionManager.backgroundContextDidStart`, ExtensionUpdaterTests).
    func testRuntimeReloadStaysWebKitsAndCannotBeShadowed() async throws {
        let (ext, profile, _, page) = try await makeExtension(withWorker: false)
        let result = try await evalObject("""
            const runtime = chrome.runtime;
            const before = String(runtime.reload);
            let defineThrew = null;
            try {
                Object.defineProperty(runtime, 'reload', { value: function() {}, writable: true, configurable: true });
            } catch (e) { defineThrew = String(e && e.message ? e.message : e); }
            return JSON.stringify({
                nativeBefore: /\\[native code\\]/.test(before),
                nativeAfter: /\\[native code\\]/.test(String(runtime.reload)),
                defineThrew: defineThrew
            });
        """, in: page)
        XCTAssertEqual(result["nativeBefore"] as? Bool, true, "\(result)")
        XCTAssertEqual(result["nativeAfter"] as? Bool, true, "an own property never takes over WebKit's reload: \(result)")
        XCTAssertNotNil(profile.extensionContext(for: ext.id))
    }

   func testRequestUpdateCheckReplyForADeferredUpdate() {
        let reply = ExtensionPolyfillHandler.requestUpdateCheckReply(for: .deferred(version: "2.0"))
        XCTAssertEqual(reply["status"] as? String, "update_available")
        XCTAssertEqual(reply["version"] as? String, "2.0")
    }
}
