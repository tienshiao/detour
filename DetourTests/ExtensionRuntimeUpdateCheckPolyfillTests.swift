import XCTest
import WebKit
@testable import Detour

/// `chrome.runtime.requestUpdateCheck` and `chrome.runtime.onUpdateAvailable`
/// (TASK-113), exercised from a real extension page loaded through
/// `Profile.loadExtensionContext`, so the request travels the production
/// polyfill bridge to `ExtensionUpdater.shared`.
///
/// The fixtures are unpacked extensions, which never update: a check answers
/// `no_update` without touching the network, and a second one inside the
/// throttle window answers `throttled`. Each test uses a fresh extension id, so
/// the updater's per-extension throttle never carries over between tests.
@MainActor
final class ExtensionRuntimeUpdateCheckPolyfillTests: XCTestCase {

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

    /// An unpacked extension page, registered in ExtensionManager and loaded in
    /// a fresh profile, ready for `evalObject`.
    private func makeExtensionPage() async throws -> (ext: WebExtension, webView: WKWebView) {
        let id = "update-check-\(UUID().uuidString.prefix(8))"
        let ext = try await makeTestExtension(id: id, manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Update Check Test",
                "version": "1.0.0"
            }
            """, files: ["test.html": "<html><body>update check</body></html>"])
        tempDirs.append(ext.basePath)
        ext.source = .unpacked
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)

        let profile = TabStore.shared.addProfile(name: "Update Check Profile")
        createdProfiles.append(profile)
        _ = profile.extensionController
        let context = try loadTestContext(ext, in: profile)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        try await loadAndWait(webView, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        return (ext, webView)
    }

    private func evalObject(_ js: String, in webView: WKWebView) async throws -> [String: Any] {
        let raw = try await webView.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
        let json = try XCTUnwrap(raw as? String, "expected a JSON string, got \(String(describing: raw))")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - requestUpdateCheck

    /// Promise form: an unpacked extension resolves `{status: 'no_update'}` with
    /// no version; asking again inside the throttle window resolves `throttled`.
    func testRequestUpdateCheckPromiseResolvesNoUpdateThenThrottled() async throws {
        let (_, webView) = try await makeExtensionPage()

        let shape = try await evalObject("""
            return JSON.stringify({ type: typeof chrome.runtime.requestUpdateCheck });
        """, in: webView)
        XCTAssertEqual(shape["type"] as? String, "function")

        let first = try await evalObject(promiseOutcomeJS("chrome.runtime.requestUpdateCheck()"), in: webView)
        XCTAssertEqual(first["settled"] as? String, "resolved", "unexpected outcome: \(first)")
        let value = try XCTUnwrap(first["value"] as? [String: Any], "expected an object: \(first)")
        XCTAssertEqual(value["status"] as? String, "no_update")
        XCTAssertNil(value["version"], "no version without an update: \(value)")

        let second = try await evalObject(promiseOutcomeJS("chrome.runtime.requestUpdateCheck()"), in: webView)
        XCTAssertEqual((second["value"] as? [String: Any])?["status"] as? String, "throttled",
                       "a second check inside the throttle window must be throttled: \(second)")
    }

    /// Callback form: Chrome's current `callback(result)` with one
    /// `{status, version?}` object — here `{status: 'no_update'}` — no lastError,
    /// and nothing returned.
    func testRequestUpdateCheckCallbackReceivesStatus() async throws {
        let (_, webView) = try await makeExtensionPage()

        let outcome = try await evalObject(callbackOutcomeJS(call: """
            return chrome.runtime.requestUpdateCheck(cb);
        """), in: webView)
        XCTAssertEqual(outcome["timedOut"] as? Bool, false, "the callback must run: \(outcome)")
        XCTAssertEqual(outcome["returnedType"] as? String, "undefined")
        XCTAssertEqual(outcome["arg0"] as? String, "{\"status\":\"no_update\"}", "one result object: \(outcome)")
        XCTAssertEqual(outcome["argc"] as? Int, 1, "one argument: \(outcome)")
        XCTAssertNil(outcome["lastErrorInCallback"] as? String, "no lastError on success: \(outcome)")
        XCTAssertEqual(outcome["unhandled"] as? [String], [])
    }

    // MARK: - Native reply mapping

    func testRequestUpdateCheckReplyMapping() {
        func status(_ outcome: ExtensionUpdateOutcome) -> String? {
            ExtensionPolyfillHandler.requestUpdateCheckReply(for: outcome)["status"] as? String
        }
        XCTAssertEqual(status(.throttled), "throttled")
        XCTAssertEqual(status(.upToDate), "no_update")
        XCTAssertEqual(status(.notUpdatable("unpacked")), "no_update")
        XCTAssertEqual(status(.failed("HTTP 500")), "no_update")
        XCTAssertNil(ExtensionPolyfillHandler.requestUpdateCheckReply(for: .upToDate)["version"])

        let updated = ExtensionPolyfillHandler.requestUpdateCheckReply(for: .updated(version: "2.0"))
        XCTAssertEqual(updated["status"] as? String, "update_available")
        XCTAssertEqual(updated["version"] as? String, "2.0")

        let pending = ExtensionPolyfillHandler.requestUpdateCheckReply(
            for: .updatedPendingPermissions(version: "3.1", delta: .init(permissions: ["tabs"], hostPermissions: [])))
        XCTAssertEqual(pending["status"] as? String, "update_available")
        XCTAssertEqual(pending["version"] as? String, "3.1")
    }

    // MARK: - onUpdateAvailable

    /// The event exists and its listener bookkeeping works; Detour never fires it.
    func testOnUpdateAvailableIsAnEventObject() async throws {
        let (_, webView) = try await makeExtensionPage()

        let result = try await evalObject("""
            const event = chrome.runtime.onUpdateAvailable;
            const fn = function() {};
            const other = function() {};
            const out = { exists: !!event, hasBefore: event.hasListener(fn) };
            event.addListener(fn);
            out.hasAfterAdd = event.hasListener(fn);
            out.hasOther = event.hasListener(other);
            out.hasListeners = event.hasListeners();
            // Re-read through the namespace: the pinned runtime must keep it.
            out.sameObject = chrome.runtime.onUpdateAvailable === event;
            event.removeListener(fn);
            out.hasAfterRemove = event.hasListener(fn);
            return JSON.stringify(out);
        """, in: webView)
        XCTAssertEqual(result["exists"] as? Bool, true)
        XCTAssertEqual(result["hasBefore"] as? Bool, false)
        XCTAssertEqual(result["hasAfterAdd"] as? Bool, true)
        XCTAssertEqual(result["hasOther"] as? Bool, false)
        XCTAssertEqual(result["hasListeners"] as? Bool, true)
        XCTAssertEqual(result["sameObject"] as? Bool, true)
        XCTAssertEqual(result["hasAfterRemove"] as? Bool, false)
    }
}
