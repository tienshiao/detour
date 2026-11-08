import XCTest
import Network
import Synchronization
import WebKit
@testable import Detour

// Shared helpers for the extension-polyfill test suites: waiting on a real
// navigation instead of sleeping a fixed interval, and posting a raw polyfill
// envelope through `webkit.messageHandlers` from a loaded page.

/// Drives one navigation to completion. Installs itself as the web view's
/// navigation delegate for the duration and restores the previous delegate
/// afterwards, so a caller's own delegate survives the wait.
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {

    struct TimedOut: Error, CustomStringConvertible {
        let timeout: TimeInterval
        var description: String { "navigation did not finish within \(timeout)s" }
    }

    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?

    /// Run `start` on `webView` and return when the navigation it kicks off
    /// finishes; throws if the navigation fails or the timeout elapses.
    func navigate(
        _ webView: WKWebView, timeout: TimeInterval, start: (WKWebView) -> Void
    ) async throws {
        let previousDelegate = webView.navigationDelegate
        webView.navigationDelegate = self
        defer {
            webView.navigationDelegate = previousDelegate
            timeoutTask?.cancel()
            timeoutTask = nil
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.continuation = continuation
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.settle(.failure(TimedOut(timeout: timeout)))
            }
            start(webView)
        }
    }

    /// Resume the waiting caller at most once: WebKit can report a failure and
    /// the timeout can fire for the same navigation.
    private func settle(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        settle(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        settle(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        settle(.failure(error))
    }
}

/// Load `request` and return once the page has finished loading.
@MainActor
func loadAndWait(_ webView: WKWebView, _ request: URLRequest, timeout: TimeInterval = 10) async throws {
    try await NavigationWaiter().navigate(webView, timeout: timeout) { $0.load(request) }
}

/// Load an HTML string and return once the page has finished loading.
@MainActor
func loadHTMLStringAndWait(
    _ webView: WKWebView, html: String, baseURL: URL?, timeout: TimeInterval = 10
) async throws {
    try await NavigationWaiter().navigate(webView, timeout: timeout) {
        $0.loadHTMLString(html, baseURL: baseURL)
    }
}

/// What `waitUntil` throws when its condition never held: the test body stops
/// at the wait instead of going on with stale state.
struct WaitTimedOut: Error, CustomStringConvertible {
    let what: String
    let timeout: TimeInterval
    var description: String { "timed out after \(timeout) s waiting for \(what)" }
}

/// Poll `condition` until it holds. If `timeout` elapses first, the test fails
/// at the call site and the wait throws `WaitTimedOut`, so the rest of the test
/// body does not run. `what` names the thing being waited for, so the failure
/// says what never happened.
///
/// The failure is recorded with `XCTFail` as well as thrown: the recorded one
/// points at the waiting line, and it still fails the test when a caller's
/// `do`/`catch` or `try?` swallows the error. A test that *expects* a condition
/// may never hold polls with `pollUntil(timeout:pollInterval:_:)` instead.
@MainActor
func waitUntil(_ what: String, timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.1,
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () async throws -> Bool) async throws {
    if try await pollUntil(timeout: timeout, pollInterval: pollInterval, condition) { return }
    let timedOut = WaitTimedOut(what: what, timeout: timeout)
    XCTFail(timedOut.description, file: file, line: line)
    throw timedOut
}

/// Poll `condition` until it holds or `timeout` elapses, and say which: `true`
/// once it held, `false` on timeout. Never fails the test; it is for a wait whose
/// timeout is an expected outcome. Use `waitUntil` for anything the test needs.
@MainActor
func pollUntil(timeout: TimeInterval, pollInterval: TimeInterval = 0.1,
               _ condition: () async throws -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while try await !condition() {
        if Date() >= deadline { return false }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    return true
}

/// How a test page reaches the background worker.
enum WorkerTransport {
    /// Call `chrome.runtime.sendMessage` from the page itself — only works on an
    /// extension-origin page, which is the only kind that has `chrome` in the
    /// page world.
    case direct
    /// Post `{ __detourTest: 'ask', id, message }` on `window` and wait for the
    /// matching `{ __detourTest: 'answer' }` — for an https page whose only
    /// `chrome` lives in the content-script world, which a test cannot evaluate
    /// JS in. The fixture's content.js must carry the relay listener.
    case contentScriptRelay
}

/// One round trip to an extension's background service worker: sends `message`
/// either straight from the page (`.direct`) or through the content script's
/// relay (`.contentScriptRelay`) and returns the parsed envelope, with both
/// halves of the answer in it:
///  - `reply`: what the worker responded (`NSNull` when it answered nothing —
///    which is also what WebKit produces when it could not reach the worker at
///    all — and the string `"timeout"` when the callback never fired);
///  - `lastError`: `chrome.runtime.lastError.message`, the only place a delivery
///    failure is reported, so a caller can tell "the worker said nothing" from
///    "the message never got there".
@MainActor
func askWorker(from webView: WKWebView, message: [String: Any],
               via transport: WorkerTransport = .direct,
               timeout: TimeInterval = 10) async throws -> [String: Any] {
    let js: String
    switch transport {
    case .direct:
        js = """
            const reply = await new Promise((resolve) => {
                const timer = setTimeout(() => resolve({ reply: 'timeout', lastError: null }), timeoutMS);
                chrome.runtime.sendMessage(message, (r) => {
                    clearTimeout(timer);
                    resolve({ reply: r === undefined ? null : r,
                              lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
                });
            });
            return JSON.stringify(reply);
        """
    case .contentScriptRelay:
        js = """
            const id = String(Math.random());
            const answer = await new Promise((resolve) => {
                const onAnswer = (event) => {
                    const data = event.data;
                    if (!data || data.__detourTest !== 'answer' || data.id !== id) { return; }
                    clearTimeout(timer);
                    window.removeEventListener('message', onAnswer);
                    resolve({ reply: data.reply, lastError: data.lastError });
                };
                const timer = setTimeout(() => {
                    window.removeEventListener('message', onAnswer);
                    resolve({ reply: 'timeout', lastError: null });
                }, timeoutMS);
                window.addEventListener('message', onAnswer);
                window.postMessage({ __detourTest: 'ask', id: id, message: message }, '*');
            });
            return JSON.stringify(answer);
        """
    }
    let raw = try await webView.callAsyncJavaScript(
        js, arguments: ["message": message, "timeoutMS": Int(timeout * 1000)], contentWorld: .page)
    let jsonString = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
    let data = try XCTUnwrap(jsonString.data(using: .utf8))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Did the worker answer nothing? A message that never got there and a worker
/// that responded `undefined` both arrive as null, and `"timeout"` means the
/// callback never fired at all.
func workerReplyIsEmpty(_ envelope: [String: Any]) -> Bool {
    guard let reply = envelope["reply"] else { return true }
    if reply is NSNull { return true }
    if let text = reply as? String, text == "timeout" { return true }
    return false
}

/// Post a raw polyfill envelope straight through `webkit.messageHandlers` from
/// the page, bypassing the polyfill JS (which stamps its own `extensionID`), so
/// a test can claim any id. Returns the bridge's reply or its rejection text.
@MainActor
func postRawPolyfillEnvelope(
    from webView: WKWebView,
    type: String,
    claimedID: String,
    params: [String: Any] = ["detectionIntervalInSeconds": 60]
) async throws -> (result: Any?, error: String?) {
    let js = """
        try {
            const r = await webkit.messageHandlers.detourPolyfill.postMessage({
                type: type, extensionID: claimedID, params: params
            });
            return JSON.stringify({ result: r === undefined ? null : r });
        } catch (e) {
            return JSON.stringify({ error: String(e && e.message ? e.message : e) });
        }
    """
    let raw = try await webView.callAsyncJavaScript(
        js, arguments: ["type": type, "claimedID": claimedID, "params": params],
        contentWorld: .page
    )
    let jsonString = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
    let data = try XCTUnwrap(jsonString.data(using: .utf8))
    let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (dict["result"], dict["error"] as? String)
}

// MARK: - Fake native messaging host

/// Run a command line tool and capture its stdout.
@discardableResult
func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// SIGKILLs `pid` after `seconds` unless cancelled (TASK-265). A regression
/// that blocks the main actor in a write to a host that never reads then
/// fails (the kill unblocks the write, and the test finds the host gone and
/// the time spent) instead of hanging the run.
func killing(_ pid: pid_t, after seconds: TimeInterval) -> DispatchWorkItem {
    let item = DispatchWorkItem { _ = Darwin.kill(pid, SIGKILL) }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    return item
}

/// A stand-in native messaging host: a shell script that `exec`s
/// `sleep <token>` and reads nothing, so a test gets a real host process that
/// stays connected and silent (`Behavior` has variants that write fixed bytes
/// first, or echo). `token` is unique per fixture, so a stray process
/// from another run — or another agent's — can never be counted, or killed, by
/// this one.
///
/// Creating one points `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` (honored in Debug
/// builds only) at its directory; `tearDown()` restores that variable, kills
/// every process the fixture spawned and removes the directory. Call it from the
/// test's own tearDown: nothing this spawns may outlive the test.
final class FakeNativeMessagingHost {

    /// What the host process does once it is spawned.
    enum Behavior {
        /// Reads nothing and writes nothing: `exec sleep <token>`.
        case silent
        /// Writes these bytes to stdout, closes it, then sleeps as `.silent`
        /// does, so the reader sees EOF while the process is still alive
        /// (its exit cannot race the read loop's report).
        case writesThenClosesStdout(Data)
        /// `exec cat`: every byte written to it comes back on stdout. It
        /// exits when its stdin closes, so it carries no sleep token and
        /// `processCount()` does not see it.
        case echoes
        /// As `echoes`, but visible to `processCount()`: `cat` is given an empty
        /// file named `sleep <token>` to read after stdin, so the token is on
        /// its command line (TASK-242).
        case echoesCounted
        /// Waits for the first byte of input (the request), writes these
        /// bytes to stdout and exits with `status` straight away: a one-shot
        /// `sendNativeMessage` host. The process is gone by the time the
        /// read loop gets to the reply, so it carries no sleep token.
        case answersThenExits(Data, status: Int32)
        /// As `answersThenExits`, but the exiting host leaves a background
        /// `sleep <token>` holding its stdout open: the read loop sees the
        /// host exit and no EOF. `processCount()` sees the sleep.
        case answersThenExitsLeavingStdoutOpen(Data)
        /// Waits for the first byte of input, writes these bytes and then
        /// `exec`s `sleep <token>` with stdout still open: a host that stays
        /// alive and silent after answering.
        case answersThenStaysAlive(Data)
        /// As `.silent`, but SIGTERM is ignored (`trap '' TERM`, which the
        /// `exec`'d sleep inherits): only SIGKILL ends it (TASK-241).
        case silentIgnoringSIGTERM
        /// Closes its stdin, then sleeps as `.silent` does: a write to it
        /// fails with EPIPE while the process is still alive (TASK-265).
        case closesStdin
        /// A wrapper script that runs its real host without `exec`
        /// (TASK-274): the script's shell is the host process and waits on a
        /// `sleep <token>` child, which reads nothing, so it never sees its
        /// stdin close. `processIDs()` sees the child, `wrapperIDs()` the
        /// shell.
        case wrapsSilentChild
        /// As `wrapsSilentChild`, but the child ignores SIGTERM (`trap ''
        /// TERM` in a shell that then `exec`s the sleep); the wrapper does not.
        case wrapsChildIgnoringSIGTERM
    }

    /// The host name an extension passes to `connectNative` / `sendNativeMessage`.
    let name: String
    /// The `sleep` argument that identifies this fixture's processes.
    let sleepToken: String

    private let dir: URL
    /// The host script, the manifest's `path`: what a test's sweep of its
    /// own hosts names (`terminateSpawnedHostsForTesting`).
    var scriptPath: String { dir.appendingPathComponent("fake-host.sh").path }
    private let previousHostsDir: String?

    /// `editingManifest` changes the manifest before it is written, for a
    /// test of a manifest Detour must refuse (TASK-266); it gets the script's
    /// absolute path to build a relative one from.
    init(name: String = "com.detour.fake_host_test", allowing extensionIDs: [String],
         behavior: Behavior = .silent,
         editingManifest: ((inout [String: Any], _ scriptPath: String) -> Void)? = nil) throws {
        self.name = name
        self.sleepToken = String(Int.random(in: 300_000...899_999))
        self.previousHostsDir = ProcessInfo.processInfo.environment["DETOUR_NATIVE_MESSAGING_HOSTS_DIR"]
        self.dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("detour-test-fake-host-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let script = dir.appendingPathComponent("fake-host.sh")
        let body: String
        switch behavior {
        case .silent:
            body = "exec sleep \(sleepToken)\n"
        case .writesThenClosesStdout(let output):
            let outputFile = dir.appendingPathComponent("stdout.bin")
            try output.write(to: outputFile)
            body = "/bin/cat '\(outputFile.path)'\nexec 1>&-\nexec sleep \(sleepToken)\n"
        case .echoes:
            body = "exec /bin/cat\n"
        case .echoesCounted:
            let tokenFile = dir.appendingPathComponent("sleep \(sleepToken)")
            try Data().write(to: tokenFile)
            body = "exec /bin/cat - '\(tokenFile.path)'\n"
        case .answersThenExits(let output, let status):
            let outputFile = dir.appendingPathComponent("stdout.bin")
            try output.write(to: outputFile)
            body = "/usr/bin/head -c 1 >/dev/null\n/bin/cat '\(outputFile.path)'\nexit \(status)\n"
        case .answersThenExitsLeavingStdoutOpen(let output):
            let outputFile = dir.appendingPathComponent("stdout.bin")
            try output.write(to: outputFile)
            body = "/usr/bin/head -c 1 >/dev/null\n/bin/cat '\(outputFile.path)'\n/bin/sleep \(sleepToken) &\nexit 0\n"
        case .answersThenStaysAlive(let output):
            let outputFile = dir.appendingPathComponent("stdout.bin")
            try output.write(to: outputFile)
            body = "/usr/bin/head -c 1 >/dev/null\n/bin/cat '\(outputFile.path)'\nexec sleep \(sleepToken)\n"
        case .silentIgnoringSIGTERM:
            body = "trap '' TERM\nexec sleep \(sleepToken)\n"
        case .closesStdin:
            body = "exec 0<&-\nexec sleep \(sleepToken)\n"
        // `exit $?` after the child keeps the shell from running its last
        // command in place.
        case .wrapsSilentChild:
            body = "/bin/sleep \(sleepToken)\nexit $?\n"
        case .wrapsChildIgnoringSIGTERM:
            body = "/bin/sh -c \"trap '' TERM; exec /bin/sleep \(sleepToken)\"\nexit $?\n"
        }
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var manifest: [String: Any] = [
            "name": name,
            "description": "Detour test fake native messaging host",
            "path": script.path,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" },
        ]
        editingManifest?(&manifest, script.path)
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: dir.appendingPathComponent("\(name).json"))
        setenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR", dir.path, 1)
    }

    /// `absolutePath` as a path relative to the process's working
    /// directory that leads to the same file: `../` up to the root, then the
    /// path. A manifest with it must be refused even though it resolves to
    /// an executable (TASK-266).
    static func relativeFromWorkingDirectory(_ absolutePath: String) -> String {
        let depth = FileManager.default.currentDirectoryPath
            .split(separator: "/", omittingEmptySubsequences: true).count
        return String(repeating: "../", count: depth) + absolutePath.drop { $0 == "/" }
    }

    /// How many of this fixture's host processes are alive right now.
    func processCount() -> Int {
        processIDs().count
    }

    /// The pids of this fixture's live host processes. A test that replaces a
    /// background context needs the identities, not just the count: the old and
    /// the new context spawn the same number of hosts, so "the old ones exited"
    /// can only be said about specific processes (TASK-67).
    func processIDs() -> [Int32] {
        pids(matching: "sleep \(sleepToken)")
    }

    /// The pids of this fixture's live host scripts that are still running
    /// as shells: a wrapper behavior's host process (TASK-274). The script's
    /// path is in this fixture's own directory, so nothing else matches.
    func wrapperIDs() -> [Int32] {
        pids(matching: scriptPath)
    }

    private func pids(matching pattern: String) -> [Int32] {
        runTool("/usr/bin/pgrep", ["-f", pattern])
            .output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    func tearDown() {
        if let previousHostsDir {
            setenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR", previousHostsDir, 1)
        } else {
            unsetenv("DETOUR_NATIVE_MESSAGING_HOSTS_DIR")
        }
        // The token finds every sleep, a wrapper's child included even once
        // it has been left to launchd; the script path finds a wrapper shell.
        runTool("/usr/bin/pkill", ["-KILL", "-f", "sleep \(sleepToken)"])
        runTool("/usr/bin/pkill", ["-KILL", "-f", scriptPath])
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - Minimal tab/window conformances

/// A window WebKit will accept for a bare WKWebView. `BrowserWindowController`
/// is the app's conformance, but it needs a real NSWindow and a TabStore space;
/// a test only needs `chrome.tabs` to see one window with one tab.
@MainActor
final class ProbeExtensionWindow: NSObject, WKWebExtensionWindow {
    var openTabs: [any WKWebExtensionTab] = []

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { openTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { openTabs.first }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func frame(for context: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 800, height: 600) }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { CGRect(x: 0, y: 0, width: 1440, height: 900) }
}

/// A tab backed by a plain WKWebView, so a page loaded outside TabStore can
/// still be given a `chrome.tabs` id.
@MainActor
final class ProbeExtensionTab: NSObject, WKWebExtensionTab {
    private let wv: WKWebView
    private weak var containingWindow: ProbeExtensionWindow?

    init(webView: WKWebView, window: ProbeExtensionWindow) {
        self.wv = webView
        self.containingWindow = window
        super.init()
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { wv }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { containingWindow }
    func url(for context: WKWebExtensionContext) -> URL? { wv.url }
    func title(for context: WKWebExtensionContext) -> String? { wv.title }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !wv.isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { false }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}

/// Register `webView` with `context` as the one tab of a fresh window. This
/// mirrors the app's own open/focus/activate sequence
/// (`ExtensionManager.notifyExistingTabs`) — the focus step is what gives the
/// context a `focusedWindow`, without which `tabs.query({currentWindow: true})`
/// and `windows.getCurrent` see nothing. It does not forward
/// `didChangeTabProperties` after the load: url and title are read live off the
/// web view, so the only thing missing is `tabs.onUpdated` events.
///
/// Content-script messages only reach the background worker, and
/// `chrome.tabs.query` only sees anything, once the web view is a registered tab
/// — so this must happen *before* the page loads. The returned pair has to be
/// kept alive for as long as the tab should exist and handed to
/// `unregisterProbeTab` when the test is done with it.
@MainActor
func registerProbeTab(for webView: WKWebView, in context: WKWebExtensionContext)
    -> (window: ProbeExtensionWindow, tab: ProbeExtensionTab) {
    let window = ProbeExtensionWindow()
    let tab = ProbeExtensionTab(webView: webView, window: window)
    window.openTabs = [tab]
    context.didOpenWindow(window)
    context.didFocusWindow(window)
    context.didOpenTab(tab)
    context.didActivateTab(tab, previousActiveTab: nil)
    return (window, tab)
}

/// Undo `registerProbeTab`, so a tab does not outlive the test that opened it.
@MainActor
func unregisterProbeTab(_ probe: (window: ProbeExtensionWindow, tab: ProbeExtensionTab),
                        in context: WKWebExtensionContext) {
    context.didCloseTab(probe.tab, windowIsClosing: true)
    context.didCloseWindow(probe.window)
}

// MARK: - Extension fixtures

/// The `options.html` the minimal fixture manifest points at.
let optionsPageTestFiles: [String: String] = ["options.html": "<html><body>options</body></html>"]

/// The minimal MV3 manifest the extension-page suites build on: an options page
/// and no background content.
func optionsPageManifestJSON(name: String) -> String {
    """
    {
        "manifest_version": 3,
        "name": "\(name)",
        "version": "1.0.0",
        "options_ui": { "page": "options.html" }
    }
    """
}

/// Write an unpacked extension into `directory` — by default a fresh temp
/// directory named after `id` — and return it with its `WKWebExtension` loaded.
/// The caller owns that directory (`ext.basePath`) and is responsible for
/// removing it in tearDown; it is deliberately not registered anywhere, so a
/// suite decides for itself what "installed" means for it.
@MainActor
func makeTestExtension(id: String, manifestJSON: String, files: [String: String] = [:],
                       in directory: URL? = nil) async throws -> WebExtension {
    let dir = directory ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("detour-test-\(id)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try manifestJSON.write(to: dir.appendingPathComponent("manifest.json"),
                           atomically: true, encoding: .utf8)
    for (file, contents) in files {
        try contents.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    let wkExt = try await WKWebExtension(resourceBaseURL: dir)
    let manifest = try ExtensionManifest.parse(at: dir.appendingPathComponent("manifest.json"))
    let ext = WebExtension(id: id, manifest: manifest, basePath: dir)
    ext.wkExtension = wkExt
    return ext
}

/// `makeTestExtension` for the minimal options-page fixture. The id is
/// `idPrefix` plus a random suffix, so two fixtures never collide.
@MainActor
func makeOptionsPageTestExtension(idPrefix: String, name: String) async throws -> WebExtension {
    try await makeTestExtension(id: "\(idPrefix)-\(UUID().uuidString.prefix(8))",
                                manifestJSON: optionsPageManifestJSON(name: name),
                                files: optionsPageTestFiles)
}

/// The manifest.json `ext` was built from, as it is on disk — what a suite that
/// wants a real manifest blob in the DB row saves.
func testExtensionManifestData(_ ext: WebExtension) throws -> Data {
    try Data(contentsOf: ext.basePath.appendingPathComponent("manifest.json"))
}

/// Save `ext` as an installed, globally enabled extension. `manifestJSON`
/// defaults to an empty object, for the suites that never read the blob back.
@MainActor
func installTestExtension(_ ext: WebExtension, in db: AppDatabase,
                          manifestJSON: Data = Data("{}".utf8)) {
    db.saveExtension(ExtensionRecord(
        id: ext.id, name: ext.manifest.name, version: ext.manifest.version,
        manifestJSON: manifestJSON, basePath: ext.basePath.path,
        isEnabled: true, installedAt: Date().timeIntervalSince1970
    ))
}

/// Write the ON `profileExtension` row each profile that has `ext` on carries:
/// what an install from that profile, or migration v24 for a profile that
/// existed before TASK-312, leaves behind. No row is off in every profile, so a
/// suite that loads through the real rule (`loadExtensionsIntoProfile`, the
/// toggles, an install's reload) needs it. Rows only — nothing is loaded — and
/// the manager's enabled-set cache is dropped so the next read sees them.
@MainActor
func turnOnTestExtension(_ ext: WebExtension, in profiles: Profile..., db: AppDatabase = .shared) {
    for profile in profiles {
        db.setProfileExtensionEnabled(extensionID: ext.id, profileID: profile.id.uuidString, enabled: true)
    }
    ExtensionManager.shared.invalidateEnabledExtensionsCache()
}

/// `array[index]` as a test failure rather than a crash when it is out of range
/// (a test host crash takes every later test in the run with it).
func testElement<T>(_ array: [T], _ index: Int, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(array.indices.contains(index) ? array[index] : nil,
                  "index \(index) out of range: \(array.count) element(s)", file: file, line: line)
}

/// Load `ext`'s context into `profile` and return it. The caller is responsible
/// for unloading it in tearDown.
@MainActor
func loadTestContext(_ ext: WebExtension, in profile: Profile) throws -> WKWebExtensionContext {
    _ = profile.loadExtensionContext(ext)
    return try XCTUnwrap(profile.extensionContext(for: ext.id), "the context should load")
}

/// A tab as a restore or an undo builds one: never woken, so it has no web view
/// and nothing has loaded its URL yet.
@MainActor
func sleepingTab(_ url: URL, title: String = "Page", in space: Space) -> BrowserTab {
    BrowserTab(id: UUID(), title: title, url: url, faviconURL: nil,
               cachedInteractionState: nil, spaceID: space.id)
}

/// An extension page URL, resolved against a context's base URL. An escaped
/// query and a fragment must both survive a rehost untouched, so tests build
/// them here rather than by string concatenation.
func extensionPageURL(_ path: String, on base: URL) throws -> URL {
    try XCTUnwrap(URL(string: path, relativeTo: base)?.absoluteURL)
}

// MARK: - Bridge reply

/// A bridge reply handed from a reply handler to the test awaiting it.
/// `@unchecked`: the value is a JSON-like object graph handed over once, on
/// the main actor, and never shared afterwards.
struct BridgeReply: @unchecked Sendable {
    let result: Any?
    let error: String?
}

// MARK: - One-shot flag

/// One-shot flag guarding a continuation that several callbacks can reach.
/// Nonisolated: the callbacks run on the servers' own dispatch queues.
nonisolated final class LockedFlag: Sendable {
    private let used = Mutex(false)

    func claim() -> Bool {
        used.withLock { used in
            if used { return false }
            used = true
            return true
        }
    }
}

// MARK: - Loopback WebSocket echo server

/// A WebSocket echo server on 127.0.0.1, built on Network.framework's own
/// `NWProtocolWebSocket` (it performs the server-side handshake). Every text and
/// binary frame is echoed back unchanged and a close from the peer is answered
/// with a close, so a relayed socket can be driven end to end against a real
/// server (TASK-8, `WebSocketRelaySessionTests`).
/// Nonisolated: it runs on its own dispatch queue, its state behind a Mutex.
nonisolated final class LoopbackWebSocketServer: Sendable {

    private struct State {
        var openConnections: [ObjectIdentifier: NWConnection] = [:]
        var accepted = 0
        var ended = 0
        var closeFrames = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "detour-test-loopback-ws")
    private let state = Mutex(State())

    struct StartTimedOut: Error, CustomStringConvertible {
        var description: String { "loopback WebSocket server did not become ready" }
    }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: params, on: .any)
    }

    /// Connections the server has accepted so far.
    var acceptedConnections: Int {
        state.withLock { $0.accepted }
    }

    /// Connections that have since ended (peer close, cancel, or failure) — this
    /// is how a test sees that the relay really tore its socket down.
    var endedConnections: Int {
        state.withLock { $0.ended }
    }

    /// Close frames received from clients.
    var closeFramesReceived: Int {
        state.withLock { $0.closeFrames }
    }

    /// Start listening and return the port that was assigned.
    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                continuation.resume(throwing: StartTimedOut())
            }
        }
    }

    /// Close every open connection with a normal-closure handshake, so a test can
    /// drive a server-initiated close.
    func closeAllConnections() {
        let connections = state.withLock { Array($0.openConnections.values) }
        for connection in connections {
            sendClose(on: connection)
        }
    }

    func stop() {
        closeAllConnections()
        listener.cancel()
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        state.withLock { state in
            state.accepted += 1
            state.openConnections[ObjectIdentifier(connection)] = connection
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.forget(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func forget(_ connection: NWConnection) {
        state.withLock { state in
            if state.openConnections.removeValue(forKey: ObjectIdentifier(connection)) != nil {
                state.ended += 1
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                self.forget(connection)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .close:
                self.state.withLock { $0.closeFrames += 1 }
                self.sendClose(on: connection)
                return
            case .text:
                self.send(data ?? Data(), opcode: .text, on: connection)
            case .binary:
                self.send(data ?? Data(), opcode: .binary, on: connection)
            default:
                break
            }
            self.receive(on: connection)
        }
    }

    private func send(_ payload: Data, opcode: NWProtocolWebSocket.Opcode, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "echo", metadata: [metadata])
        connection.send(content: payload, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

    private func sendClose(on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in
                            connection.cancel()
                        })
    }
}

// MARK: - Loopback WebSocket handshake capture

/// A loopback server that records the headers of the WebSocket handshake sent
/// to it and then drops the connection, so a test can assert what actually went
/// out on the wire — `NWProtocolWebSocket` (and `URLSessionWebSocketTask`)
/// perform the handshake internally and expose none of it, which is how the
/// relay's `Cookie` header (TASK-8) is verified rather than merely inspected on
/// the `URLRequest`.
///
/// It deliberately never completes the upgrade: `URLSessionWebSocketTask`
/// refuses a hand-rolled `101` over a plain TCP `NWConnection` even when the
/// response is byte-identical to the one `NWProtocolWebSocket`'s own server
/// sends, so the socket that opens is `LoopbackWebSocketServer`'s job and this
/// one's is only to show what was asked for. The client sees the connection
/// fail, which the relay reports as an error and a 1006 close.
/// Nonisolated: it runs on its own dispatch queue, its state behind a Mutex.
nonisolated final class LoopbackHandshakeCaptureServer: Sendable {

    private struct State {
        var requests: [[String: String]] = []
        var connections: [NWConnection] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "detour-test-ws-handshake")
    private let state = Mutex(State())

    struct StartTimedOut: Error, CustomStringConvertible {
        var description: String { "loopback handshake server did not become ready" }
    }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    /// The headers of each handshake seen, in order, with lowercased names.
    var requests: [[String: String]] {
        state.withLock { $0.requests }
    }

    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                continuation.resume(throwing: StartTimedOut())
            }
        }
    }

    func stop() {
        let open = state.withLock { state in
            defer { state.connections.removeAll() }
            return state.connections
        }
        for connection in open { connection.cancel() }
        listener.cancel()
    }

    // MARK: Handshake

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil, !isComplete else {
                connection.cancel()
                return
            }
            guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                self.readRequest(on: connection, buffer: buffer)
                return
            }
            self.capture(text, on: connection)
        }
    }

    private func capture(_ request: String, on connection: NWConnection) {
        var headers: [String: String] = [:]
        for line in request.components(separatedBy: "\r\n").dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        state.withLock { $0.requests.append(headers) }
        connection.cancel()
    }
}

// MARK: - Callback-form polyfill calls (TASK-23)

/// JS (for `callAsyncJavaScript`) that makes one callback-style extension API
/// call and returns, as a JSON string, everything the callback-or-promise
/// contract is judged on:
///  - `returnedType`: `typeof` what the API call returned (`undefined` when a
///    callback was taken);
///  - `argc` / `arg0`: what the callback was invoked with (`arg0` JSON-encoded);
///  - `lastErrorInCallback`: `chrome.runtime.lastError.message` read inside the
///    callback, or null (absent when `readLastError` is false, so the error
///    goes unchecked);
///  - `lastErrorAfter`: `chrome.runtime.lastError` once the callback has
///    returned and the event loop has turned (`"undefined"`, `"null"`, or JSON);
///  - `ownLastErrorAfter`: whether `lastError` is still an own property of
///    `chrome.runtime` afterwards;
///  - `mode`: `__detourCallbackLastError.lastMode`;
///  - `unhandled`: reasons of every `unhandledrejection` seen meanwhile;
///  - `consoleErrors`: every `console.error` line meanwhile;
///  - `uncaught`: messages of every `error` event meanwhile (exceptions the
///    callback threw);
///  - `timedOut`: the callback never ran.
///
/// `call` is a function body with `cb` in scope that returns the API's return
/// value, e.g. `return chrome.offscreen.createDocument({...}, cb);`. `setup`
/// runs first; `teardown` runs in a `finally` after the outcome is recorded.
func callbackOutcomeJS(call: String, setup: String = "", teardown: String = "",
                       readLastError: Bool = true, throwFromCallback: Bool = false) -> String {
    #"""
    const unhandled = [];
    const uncaught = [];
    const consoleErrors = [];
    const onUnhandled = (event) => {
        unhandled.push(String(event.reason && event.reason.message ? event.reason.message : event.reason));
        event.preventDefault();
    };
    const onError = (event) => { uncaught.push(String(event.message)); event.preventDefault(); };
    const originalConsoleError = console.error;
    globalThis.addEventListener('unhandledrejection', onUnhandled);
    globalThis.addEventListener('error', onError);
    console.error = function(...args) { consoleErrors.push(args.map(String).join(' ')); };
    try {
        \#(setup)
        const outcome = { timedOut: false };
        await new Promise((resolve) => {
            const timer = setTimeout(() => { outcome.timedOut = true; resolve(); }, 8000);
            const cb = function(...args) {
                clearTimeout(timer);
                outcome.argc = args.length;
                outcome.arg0 = args.length ? JSON.stringify(args[0]) : null;
                if (\#(readLastError ? "true" : "false")) {
                    const lastError = chrome.runtime.lastError;
                    outcome.lastErrorInCallback = lastError ? String(lastError.message) : null;
                }
                resolve();
                if (\#(throwFromCallback ? "true" : "false")) throw new Error('thrown from callback');
            };
            const returned = (function() { \#(call) })();
            outcome.returnedType = typeof returned;
        });
        // Let a stray rejection or a rethrown exception be reported.
        await new Promise((resolve) => setTimeout(resolve, 150));
        const after = chrome.runtime.lastError;
        outcome.lastErrorAfter = after === undefined ? 'undefined' : JSON.stringify(after);
        outcome.ownLastErrorAfter = Object.prototype.hasOwnProperty.call(chrome.runtime, 'lastError');
        outcome.mode = globalThis.__detourCallbackLastError ? globalThis.__detourCallbackLastError.lastMode : 'missing';
        outcome.unhandled = unhandled;
        outcome.uncaught = uncaught;
        outcome.consoleErrors = consoleErrors.slice();
        return JSON.stringify(outcome);
    } finally {
        console.error = originalConsoleError;
        globalThis.removeEventListener('unhandledrejection', onUnhandled);
        globalThis.removeEventListener('error', onError);
        \#(teardown)
    }
    """#
}

/// JS returning, as a JSON string, how the promise form of `call` settled:
/// `{ settled: 'resolved' | 'rejected', value, message }`. `call` is an
/// expression evaluating to the promise.
func promiseOutcomeJS(_ call: String) -> String {
    #"""
    try {
        const value = await (\#(call));
        return JSON.stringify({ settled: 'resolved', value: value === undefined ? null : value });
    } catch (e) {
        return JSON.stringify({ settled: 'rejected', message: String(e && e.message ? e.message : e) });
    }
    """#
}

/// Runs `js` (a `callbackOutcomeJS` / `promiseOutcomeJS` body, or any body
/// returning a JSON object string) in `page`'s page world and decodes it.
@MainActor
func pageEval(_ js: String, in page: WKWebView) async throws -> [String: Any] {
    let raw = try await page.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
    let json = try XCTUnwrap(raw as? String, "expected JSON, got \(String(describing: raw))")
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

// MARK: - Loopback HTTP server

/// A one-shot-per-connection HTTP/1.1 server on 127.0.0.1, just enough to serve
/// a handful of HTML routes. Content scripts are only injected into frames whose
/// URL matches a manifest match pattern, and `<all_urls>` covers neither
/// `about:srcdoc` nor `data:` — so a frame probe needs real http documents.
///
/// Every request's path is recorded in `requestedPaths` (a 404 counts too), so
/// a page can also use the server as a beacon target to say "I loaded".
/// Nonisolated: it runs on its own dispatch queue, its state behind a Mutex.
nonisolated final class LoopbackHTTPServer: Sendable {

    private struct State {
        var port: UInt16 = 0
        var requestedPaths: [String] = []
        var requests: [Request] = []
        var held: [String: [NWConnection]] = [:]
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "detour-test-loopback-http")
    private let routes: [String: String]
    private let pending: [String: String]
    private let stalled: [String: String]
    private let truncated: [String: String]
    private let redirects: [String: String]
    private let setCookies: [String: String]
    private let state = Mutex(State())

    /// The request paths seen so far, in arrival order.
    var requestedPaths: [String] {
        state.withLock { $0.requestedPaths }
    }

    /// One request as it arrived: its path and its `Cookie` header, if any.
    struct Request: Equatable, Sendable {
        var path: String
        var cookie: String?
    }

    /// The requests seen so far, in arrival order (TASK-194: which cookies a
    /// page sent).
    var requests: [Request] {
        state.withLock { $0.requests }
    }

    struct StartTimedOut: Error, CustomStringConvertible {
        var description: String { "loopback HTTP server did not become ready" }
    }

    /// - Parameters:
    ///   - pending: routes whose response *head* is sent when the request
    ///     arrives and whose body is withheld until `release(_:)` — a resource
    ///     that has started but not finished. The value is the body sent on
    ///     release. A page loading one of these has committed (so it has a
    ///     back/forward entry and a URL) while `isLoading` stays true, which is
    ///     what a long-running single-page app looks like (TASK-91).
    ///   - stalled: routes that send *nothing* until `release(_:)`, when the
    ///     whole response goes out — a navigation that stays provisional, so the
    ///     web view is still on the previous document and entry.
    ///   - truncated: routes whose head promises more than is ever sent: the
    ///     value goes out as the start of the body, and `release(_:)` closes
    ///     the connection with the rest still owed — a navigation that commits,
    ///     renders what arrived and then *fails* (TASK-178).
    ///   - redirects: routes answered with a `302 Found` to the value, in
    ///     which `{port}` stands for the server's port (TASK-191.4).
    ///   - setCookies: routes whose (200) response carries a `Set-Cookie`
    ///     header with the value (TASK-194).
    init(routes: [String: String], pending: [String: String] = [:],
         stalled: [String: String] = [:], truncated: [String: String] = [:],
         redirects: [String: String] = [:], setCookies: [String: String] = [:]) throws {
        self.routes = routes
        self.setCookies = setCookies
        self.pending = pending
        self.stalled = stalled
        self.truncated = truncated
        self.redirects = redirects
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)
    }

    /// Start listening and return the port that was assigned.
    func start(timeout: TimeInterval = 5) async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [listener, weak self] state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    let port = listener.port?.rawValue ?? 0
                    self?.state.withLock { $0.port = port }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                guard resumed.claim() else { return }
                continuation.resume(throwing: StartTimedOut())
            }
        }
    }

    func stop() {
        let held = state.withLock { state in
            defer { state.held.removeAll() }
            return state.held.values.flatMap { $0 }
        }
        for connection in held { connection.cancel() }
        listener.cancel()
    }

    /// Finishes the withheld responses of a `pending` or `stalled` route: what
    /// is left of the response goes out and the connection closes, which is what
    /// ends the load. A `truncated` route has nothing left to send, so the
    /// close alone ends its load, short of the promised length.
    func release(_ path: String) {
        let connections = state.withLock { $0.held.removeValue(forKey: path) ?? [] }
        var rest = Data()
        if truncated[path] != nil {
            // Nothing: the close is the response ending short.
        } else if let body = pending[path] {
            rest = Data(body.utf8)
        } else if let body = stalled[path] {
            rest = Data((Self.head(contentLength: body.utf8.count) + body).utf8)
        }
        for connection in connections {
            connection.send(content: rest, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, accumulated: Data())
    }

    /// A single `receive` is not guaranteed to deliver the whole request line —
    /// keep reading until the head terminator arrives, and give up (cancelling
    /// the connection) on EOF or error rather than leaving it open.
    private func readHead(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            guard error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            var head = accumulated
            head.append(data)
            guard head.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete || head.count > 64 * 1024 {
                    connection.cancel()
                } else {
                    self.readHead(connection, accumulated: head)
                }
                return
            }
            self.respond(connection, head: head)
        }
    }

    private func respond(_ connection: NWConnection, head: Data) {
        let request = String(decoding: head, as: UTF8.self)
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let cookie = request.components(separatedBy: "\r\n").lazy
            .first { $0.lowercased().hasPrefix("cookie:") }
            .map { String($0.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces) }
        // A held connection is recorded in the same critical section as its
        // path, so a test that sees the path in `requestedPaths` and calls
        // `release(_:)` always finds the connection to release.
        let holds = pending[path] != nil || stalled[path] != nil || truncated[path] != nil
        state.withLock { state in
            state.requestedPaths.append(path)
            state.requests.append(Request(path: path, cookie: cookie))
            if holds { state.held[path, default: []].append(connection) }
        }

        if holds {
            if let start = truncated[path] {
                // More is promised than `release(_:)` will ever deliver.
                let header = Self.head(contentLength: start.utf8.count + 4096)
                connection.send(content: Data((header + start).utf8), completion: .contentProcessed { _ in })
                return
            }
            guard pending[path] != nil else { return } // stalled: not a byte yet
            // Headers only, no Content-Length: the body is terminated by the
            // close in `release(_:)`, so the resource stays in flight until then.
            connection.send(content: Data(Self.head(contentLength: nil).utf8),
                            completion: .contentProcessed { _ in })
            return
        }

        if let location = redirects[path] {
            let port = state.withLock { $0.port }
            let head = "HTTP/1.1 302 Found\r\nLocation: \(location.replacingOccurrences(of: "{port}", with: String(port)))\r\n"
                + "Content-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let body = Data((routes[path] ?? "<html><body>not found</body></html>").utf8)
        let status = routes[path] == nil ? "404 Not Found" : "200 OK"
        var response = Data(Self.head(status: status, contentLength: body.count,
                                      setCookie: routes[path] == nil ? nil : setCookies[path]).utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// The head of an HTML response whose connection closes after it. Without
    /// a `contentLength` the close is what ends the body.
    private static func head(status: String = "200 OK", contentLength: Int?, setCookie: String? = nil) -> String {
        "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + (setCookie.map { "Set-Cookie: \($0)\r\n" } ?? "")
            + (contentLength.map { "Content-Length: \($0)\r\n" } ?? "")
            + "Connection: close\r\n\r\n"
    }
}
