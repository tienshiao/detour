import XCTest
import WebKit
@testable import Detour

/// TASK-257: `chrome.management.uninstallSelf` and
/// `chrome.management.getPermissionWarningsByManifest`, the two methods Chrome
/// offers without the `management` permission besides `getSelf` (Chromium
/// `extensions/common/api/_api_features.json`).
///
/// Every test runs in a real extension context loaded through the production
/// wiring (`Profile.extensionController`, `Profile.loadExtensionContext`): an
/// extension page (`webkit.messageHandlers`) and its module service worker
/// (`runtime.sendNativeMessage`), in the promise and the callback form. The
/// fixture declares only `storage`, so both methods are reached the way an
/// extension without the permission reaches them.
///
/// `uninstallSelf` goes through `ExtensionManager.uninstall(id:)`, the path
/// Settings uses: Detour installs an extension once for all profiles, so it
/// leaves every profile. The confirmation is answered through
/// `ExtensionManager.uninstallSelfConfirmationAnswerOverride`.
nonisolated final class ExtensionManagementSelfTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var registeredExtensionIDs: [String] = []
    private var createdProfiles: [Profile] = []
    private var openWebViews: [WKWebView] = []

    /// Profiles whose extension controller hosted a web view are kept alive for
    /// the rest of the test process: releasing one takes its process pool down
    /// with it, and WebKit traps when that happens inside an IPC dispatch (see
    /// `ExtensionPrivateStoreTests`).
    @MainActor private static var retainedProfiles: [Profile] = []

    @MainActor override func tearDown() async throws {
        ExtensionManager.shared.uninstallSelfConfirmationAnswerOverride = nil
        for webView in openWebViews {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        openWebViews.removeAll()
        for profile in createdProfiles {
            profile.unloadAllExtensions()
            TabStore.shared.forceRemoveProfile(id: profile.id)
            AppDatabase.shared.deleteProfile(id: profile.id.uuidString)
            Self.retainedProfiles.append(profile)
        }
        createdProfiles.removeAll()
        for id in registeredExtensionIDs {
            ExtensionManager.shared.extensions.removeAll { $0.id == id }
            AppDatabase.shared.deleteExtension(id: id)
        }
        registeredExtensionIDs.removeAll()
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixtures

    /// The worker: the polyfill (the context is loaded straight into the
    /// profile, so no install has prepended it), then a listener that makes
    /// one management call in the promise or the callback form and reports how
    /// it settled. `message.arg` is the argument; `message.noArgument` calls
    /// the method with none.
    @MainActor private static let workerJS = ExtensionAPIPolyfill.polyfillJS + """

    const unhandled = [];
    self.addEventListener('unhandledrejection', (event) => {
        unhandled.push(String(event.reason && event.reason.message ? event.reason.message : event.reason));
    });
    function managementCall(message, cb) {
        const m = chrome.management;
        const method = message.method === 'uninstallSelf' ? m.uninstallSelf : m.getPermissionWarningsByManifest;
        const args = message.noArgument ? [] : [message.arg];
        if (cb) { args.push(cb); }
        return method.apply(m, args);
    }
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        if (!message) { return false; }
        if (message.type === 'ping') { sendResponse({ type: 'pong' }); return true; }
        if (message.type === 'promise') {
            let promise;
            try {
                promise = managementCall(message, null);
            } catch (e) {
                sendResponse({ settled: 'threw', message: String(e && e.message ? e.message : e) });
                return true;
            }
            Promise.resolve(promise).then(
                (value) => sendResponse({ settled: 'resolved', value: value === undefined ? null : value }),
                (e) => sendResponse({ settled: 'rejected', message: String(e && e.message ? e.message : e) }));
            return true;
        }
        if (message.type === 'callback') {
            const outcome = {};
            const returned = managementCall(message, function(...args) {
                outcome.argc = args.length;
                outcome.arg0 = args.length ? JSON.stringify(args[0]) : null;
                const lastError = chrome.runtime.lastError;
                outcome.lastErrorInCallback = lastError ? String(lastError.message) : null;
                setTimeout(() => { outcome.unhandled = unhandled.slice(); sendResponse(outcome); }, 150);
            });
            outcome.returnedType = typeof returned;
            return true;
        }
        return false;
    });
    """

    /// An MV3 extension with a module worker and one page, without the
    /// `management` permission, registered in `ExtensionManager` the way an
    /// installed extension is.
    @MainActor private func makeExtension(_ label: String) async throws -> WebExtension {
        let id = "management-self-\(label)-\(UUID().uuidString.prefix(8))"
        let ext = try await makeTestExtension(
            id: id,
            manifestJSON: """
            {
                "manifest_version": 3,
                "name": "Management Self Test",
                "version": "1.0.0",
                "permissions": ["storage"],
                "background": { "service_worker": "background.js", "type": "module" }
            }
            """,
            files: [
                "background.js": Self.workerJS,
                "test.html": "<html><body>management self page</body></html>",
            ])
        tempDirs.append(ext.basePath)
        ExtensionManager.shared.extensions.append(ext)
        registeredExtensionIDs.append(id)
        return ext
    }

    @MainActor private func makeProfile(_ name: String) -> Profile {
        let profile = TabStore.shared.addProfile(name: name)
        createdProfiles.append(profile)
        _ = profile.extensionController
        return profile
    }

    /// The extension loaded into `profile`, an extension page of it, and its
    /// worker awake.
    @MainActor private func loadPage(_ ext: WebExtension, in profile: Profile) async throws -> WKWebView {
        let context = try loadTestContext(ext, in: profile)
        let config = try XCTUnwrap(context.webViewConfiguration)
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        openWebViews.append(page)
        try await loadAndWait(page, URLRequest(url: context.baseURL.appendingPathComponent("test.html")))
        context.loadBackgroundContent { error in
            if let error { print("management self: loadBackgroundContent failed: \(error)") }
        }
        try await waitUntil("the background worker of \(profile.name) to wake", timeout: 30) {
            let ping = try await askWorker(from: page, message: ["type": "ping"], timeout: 5)
            return (ping["reply"] as? [String: Any])?["type"] as? String == "pong"
        }
        return page
    }

    /// One call made by the worker. `arg` nil calls the method with no argument.
    @MainActor private func worker(_ form: String, _ method: String, arg: Any?, via page: WKWebView,
                                   file: StaticString = #filePath, line: UInt = #line) async throws -> [String: Any] {
        var message: [String: Any] = ["type": form, "method": method]
        if let arg { message["arg"] = arg } else { message["noArgument"] = true }
        let answer = try await askWorker(from: page, message: message)
        XCTAssertNil(answer["lastError"] as? String, "the page could not reach the worker", file: file, line: line)
        return try XCTUnwrap(answer["reply"] as? [String: Any], "the worker must answer: \(answer)",
                             file: file, line: line)
    }

    /// JS source for a manifest string argument.
    private static func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    @MainActor private func assertRejected(_ outcome: [String: Any], reading expected: String, _ what: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome["settled"] as? String, "rejected", "\(what): \(outcome)", file: file, line: line)
        XCTAssertEqual(outcome["message"] as? String, expected, "\(what): \(outcome)", file: file, line: line)
    }

    @MainActor private func assertCallbackFailed(_ outcome: [String: Any], reading expected: String, _ what: String,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        if let timedOut = outcome["timedOut"] as? Bool {
            XCTAssertFalse(timedOut, "\(what): the callback must run on failure", file: file, line: line)
        }
        XCTAssertEqual(outcome["argc"] as? Int, 0, "\(what): a failed call hands the callback nothing: \(outcome)",
                       file: file, line: line)
        XCTAssertEqual(outcome["lastErrorInCallback"] as? String, expected, "\(what): \(outcome)",
                       file: file, line: line)
        XCTAssertEqual(outcome["unhandled"] as? [String], [], "\(what): no stray rejection", file: file, line: line)
    }

    /// Promise and callback form, from the page and from the worker, of
    /// `method(arg)`; `argJS` is the same argument as page JS source.
    @MainActor private func allFourForms(_ method: String, arg: Any, argJS: String,
                                         in page: WKWebView) async throws -> [(String, String, [String: Any])] {
        [
            ("page", "promise", try await pageEval(promiseOutcomeJS("chrome.management.\(method)(\(argJS))"), in: page)),
            ("page", "callback", try await pageEval(callbackOutcomeJS(call: "return chrome.management.\(method)(\(argJS), cb);"), in: page)),
            ("worker", "promise", try await worker("promise", method, arg: arg, via: page)),
            ("worker", "callback", try await worker("callback", method, arg: arg, via: page)),
        ]
    }

    // MARK: - The parsers, without WebKit

    /// The warnings are the install prompt's own lines: a manifest with no
    /// permissions warns of nothing, and an unknown permission reads as itself.
    @MainActor func testPermissionWarningsAreTheInstallPromptsLines() throws {
        func warnings(_ manifest: String) throws -> [String] {
            try ExtensionPolyfillHandler.permissionWarnings(from: ["manifestStr": manifest]).get()
        }
        XCTAssertEqual(try warnings(#"{"manifest_version": 3, "name": "N", "version": "1"}"#), [])
        XCTAssertEqual(try warnings(#"{"manifest_version": 2, "name": "N", "version": "1", "permissions": ["cookies", "madeUp", "https://a.example/*"]}"#),
                       [ExtensionPermissionDescriptions.describe("cookies"), "madeUp", "https://a.example/*"])
        XCTAssertEqual(ExtensionPermissionDescriptions.warnings(permissions: ["tabs"], hostPermissions: ["<all_urls>"]),
                       ["Read your browsing activity", "All websites"])
    }

    /// Absent and null options, and an absent or null flag, mean no dialog.
    @MainActor func testUninstallSelfOptionsParser() {
        func parse(_ params: [String: Any]) -> Bool? {
            try? ExtensionPolyfillHandler.uninstallSelfShowsConfirmDialog(from: params).get()
        }
        XCTAssertEqual(parse([:]), false)
        XCTAssertEqual(parse(["options": NSNull()]), false)
        XCTAssertEqual(parse(["options": [String: Any]()]), false)
        XCTAssertEqual(parse(["options": ["showConfirmDialog": NSNull()]]), false)
        XCTAssertEqual(parse(["options": ["showConfirmDialog": true]]), true)
        XCTAssertEqual(parse(["options": ["showConfirmDialog": false]]), false)
        XCTAssertNil(parse(["options": ["showConfirmDialog": 1]]), "a number is not a boolean")
        XCTAssertNil(parse(["options": "yes"]))
    }

    // MARK: - getPermissionWarningsByManifest

    private static let warningManifest = """
    {"manifest_version": 3, "name": "Probe", "version": "2.0",
     "permissions": ["tabs", "storage"], "optional_permissions": ["history"],
     "host_permissions": ["<all_urls>", "https://example.com/*"]}
    """

    /// The install prompt's lines for the required permissions and the site
    /// access — not the optional ones — in the manifest's order.
    private static let expectedWarnings = ["Read your browsing activity", "Store data locally",
                                           "All websites", "https://example.com/*"]

    /// POSITIVE: a valid manifest answers with Detour's install-prompt lines,
    /// from both transports in both forms, without the `management` permission.
    @MainActor func testPermissionWarningsFromBothTransportsInBothForms() async throws {
        let ext = try await makeExtension("warnings")
        let page = try await loadPage(ext, in: makeProfile("Management Warnings"))

        for (transport, form, outcome) in try await allFourForms(
            "getPermissionWarningsByManifest", arg: Self.warningManifest,
            argJS: Self.jsString(Self.warningManifest), in: page) {
            let what = "\(transport) \(form): \(outcome)"
            if form == "promise" {
                XCTAssertEqual(outcome["settled"] as? String, "resolved", what)
                XCTAssertEqual(outcome["value"] as? [String], Self.expectedWarnings, what)
            } else {
                XCTAssertEqual(outcome["argc"] as? Int, 1, what)
                XCTAssertNil(outcome["lastErrorInCallback"] as? String, what)
                let json = try XCTUnwrap(outcome["arg0"] as? String, what)
                XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String], Self.expectedWarnings, what)
            }
        }
    }

    /// NEGATIVE: malformed JSON is refused with Chromium's
    /// `kManifestParseError` from both transports in both forms; JSON that is
    /// not an object reads the same, a manifest that cannot describe an
    /// extension reads `kExtensionCreateError`, and a non-string argument is
    /// refused.
    @MainActor func testBadManifestsAreRefusedFromBothTransportsInBothForms() async throws {
        let ext = try await makeExtension("bad-manifest")
        let page = try await loadPage(ext, in: makeProfile("Management Bad Manifest"))
        let method = "getPermissionWarningsByManifest"

        for (transport, form, outcome) in try await allFourForms(
            method, arg: "{not json", argJS: Self.jsString("{not json"), in: page) {
            if form == "promise" {
                assertRejected(outcome, reading: "Failed to parse manifest.", "\(transport) \(form)")
            } else {
                assertCallbackFailed(outcome, reading: "Failed to parse manifest.", "\(transport) \(form)")
            }
        }

        let cases: [(arg: Any, js: String, expected: String)] = [
            ("[1, 2]", Self.jsString("[1, 2]"), "Failed to parse manifest."),
            ("{\"permissions\": [\"tabs\"]}", Self.jsString("{\"permissions\": [\"tabs\"]}"),
             "Failed to create extension from manifest."),
            (42, "42", "management.getPermissionWarningsByManifest: manifestStr must be a string"),
        ]
        for c in cases {
            assertRejected(try await pageEval(promiseOutcomeJS("chrome.management.\(method)(\(c.js))"), in: page),
                           reading: c.expected, "page \(c.js)")
            assertRejected(try await worker("promise", method, arg: c.arg, via: page),
                           reading: c.expected, "worker \(c.js)")
        }
        assertRejected(try await pageEval(promiseOutcomeJS("chrome.management.\(method)()"), in: page),
                       reading: "management.getPermissionWarningsByManifest: manifestStr must be a string",
                       "page, no argument")
    }

    // MARK: - uninstallSelf

    /// The extension is gone: unregistered, and its context unloaded from
    /// every profile.
    @MainActor private func waitUntilUninstalled(_ ext: WebExtension, from profiles: [Profile]) async throws {
        try await waitUntil("\(ext.id) to be uninstalled") {
            ExtensionManager.shared.extension(withID: ext.id) == nil
                && profiles.allSatisfy { $0.extensionContext(for: ext.id) == nil }
        }
    }

    /// POSITIVE, page transport: `uninstallSelf(callback)` — no options, the
    /// callback in the first slot — shows no dialog and uninstalls the
    /// extension through Settings' path — from every profile, since Detour
    /// installs an extension once for all of them. Another extension in the
    /// same profile is untouched.
    @MainActor func testUninstallSelfWithoutADialogFromThePage() async throws {
        let ext = try await makeExtension("page")
        let other = try await makeExtension("bystander")
        let a = makeProfile("Management Uninstall A")
        let b = makeProfile("Management Uninstall B")
        let page = try await loadPage(ext, in: a)
        _ = try loadTestContext(ext, in: b)
        _ = try loadTestContext(other, in: a)
        var asked = 0
        ExtensionManager.shared.uninstallSelfConfirmationAnswerOverride = { _ in asked += 1; return false }

        // The reply may never arrive (the call unloads this page's context),
        // so the page does not wait for it.
        // The callback-first form, so the polyfill's argument shift is on the
        // path (a function taken for the options cannot be posted).
        _ = try await page.callAsyncJavaScript("chrome.management.uninstallSelf(function() {}); return 'called';",
                                               arguments: [:], contentWorld: .page)
        try await waitUntilUninstalled(ext, from: [a, b])

        XCTAssertEqual(asked, 0, "no dialog without showConfirmDialog")
        XCTAssertNotNil(ExtensionManager.shared.extension(withID: other.id), "another extension stays installed")
        XCTAssertNotNil(a.extensionContext(for: other.id), "another extension's context stays loaded")
    }

    /// POSITIVE, worker transport: `uninstallSelf({ showConfirmDialog: false })`
    /// in the callback form uninstalls without asking.
    @MainActor func testUninstallSelfWithoutADialogFromTheWorker() async throws {
        let ext = try await makeExtension("worker")
        let a = makeProfile("Management Uninstall Worker")
        let page = try await loadPage(ext, in: a)
        var asked = 0
        ExtensionManager.shared.uninstallSelfConfirmationAnswerOverride = { _ in asked += 1; return false }

        _ = try await page.callAsyncJavaScript(
            "chrome.runtime.sendMessage({ type: 'callback', method: 'uninstallSelf', arg: { showConfirmDialog: false } }); return 'sent';",
            arguments: [:], contentWorld: .page)
        try await waitUntilUninstalled(ext, from: [a])
        XCTAssertEqual(asked, 0, "no dialog with showConfirmDialog false")
    }

    /// NEGATIVE: with `showConfirmDialog` and the dialog cancelled, every form
    /// from both transports is refused with Chromium's
    /// `kUninstallCanceledError` and the extension stays installed.
    @MainActor func testCancelledDialogRefusesFromBothTransportsInBothForms() async throws {
        let ext = try await makeExtension("cancel")
        let a = makeProfile("Management Uninstall Cancel")
        let page = try await loadPage(ext, in: a)
        var asked: [String] = []
        ExtensionManager.shared.uninstallSelfConfirmationAnswerOverride = { id in asked.append(id); return false }

        let expected = "Extension \(ext.id) uninstall canceled by user."
        for (transport, form, outcome) in try await allFourForms(
            "uninstallSelf", arg: ["showConfirmDialog": true], argJS: "{ showConfirmDialog: true }", in: page) {
            if form == "promise" {
                assertRejected(outcome, reading: expected, "\(transport) \(form)")
            } else {
                assertCallbackFailed(outcome, reading: expected, "\(transport) \(form)")
            }
        }
        XCTAssertEqual(asked, Array(repeating: ext.id, count: 4), "one dialog per call, for the calling extension")
        XCTAssertNotNil(ExtensionManager.shared.extension(withID: ext.id), "a cancelled uninstall keeps the extension")
        XCTAssertNotNil(a.extensionContext(for: ext.id))
    }

    /// POSITIVE: with the dialog confirmed the extension is uninstalled, after
    /// exactly one question about it.
    @MainActor func testConfirmedDialogUninstalls() async throws {
        let ext = try await makeExtension("confirm")
        let a = makeProfile("Management Uninstall Confirm")
        let page = try await loadPage(ext, in: a)
        var asked: [String] = []
        ExtensionManager.shared.uninstallSelfConfirmationAnswerOverride = { id in asked.append(id); return true }

        _ = try await page.callAsyncJavaScript(
            "chrome.runtime.sendMessage({ type: 'promise', method: 'uninstallSelf', arg: { showConfirmDialog: true } }); return 'sent';",
            arguments: [:], contentWorld: .page)
        try await waitUntilUninstalled(ext, from: [a])
        XCTAssertEqual(asked, [ext.id])
    }

    /// NEGATIVE: two calls asking for the dialog back to back — as WebKit
    /// delivers a batch of messages, the second before the first's dialog task
    /// has run — ask once; the second is refused at once, and a cancel keeps
    /// the extension.
    @MainActor func testASecondDialogWhileOneIsPendingIsRefused() async throws {
        let ext = try await makeExtension("pending")
        var asked = 0
        ExtensionManager.shared.uninstallSelfConfirmationAnswerOverride = { _ in asked += 1; return false }

        var replies: [String?] = []
        ExtensionManager.shared.uninstallSelf(extensionID: ext.id, showConfirmDialog: true) { replies.append($0) }
        ExtensionManager.shared.uninstallSelf(extensionID: ext.id, showConfirmDialog: true) { replies.append($0) }
        XCTAssertEqual(replies.count, 1, "the second call is refused before the first's dialog runs")
        try await waitUntil("both calls to settle") { replies.count == 2 }

        let cancelled = "Extension \(ext.id) uninstall canceled by user."
        XCTAssertEqual(replies, [cancelled, cancelled])
        XCTAssertEqual(asked, 1, "one dialog for the two calls")
        XCTAssertNotNil(ExtensionManager.shared.extension(withID: ext.id))
    }

    /// NEGATIVE: options that are not an object, or a `showConfirmDialog`
    /// that is not a boolean, are refused before anything is asked or done.
    @MainActor func testBadOptionsAreRefusedFromBothTransports() async throws {
        let ext = try await makeExtension("bad-options")
        let page = try await loadPage(ext, in: makeProfile("Management Bad Options"))
        ExtensionManager.shared.uninstallSelfConfirmationAnswerOverride = { _ in
            XCTFail("bad options must not reach the dialog")
            return false
        }

        let notObject = "management.uninstallSelf: options must be an object"
        let notBoolean = "management.uninstallSelf: options.showConfirmDialog must be a boolean"
        assertRejected(try await pageEval(promiseOutcomeJS("chrome.management.uninstallSelf('yes')"), in: page),
                       reading: notObject, "page, string options")
        assertCallbackFailed(try await pageEval(callbackOutcomeJS(
            call: "return chrome.management.uninstallSelf({ showConfirmDialog: 'yes' }, cb);"), in: page),
                             reading: notBoolean, "page callback, string flag")
        assertRejected(try await worker("promise", "uninstallSelf", arg: 7, via: page),
                       reading: notObject, "worker, number options")
        assertCallbackFailed(try await worker("callback", "uninstallSelf", arg: ["showConfirmDialog": 1], via: page),
                             reading: notBoolean, "worker callback, number flag")
        XCTAssertNotNil(ExtensionManager.shared.extension(withID: ext.id))
    }
}
