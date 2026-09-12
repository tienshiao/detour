import XCTest
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

/// Poll `condition` until it holds, failing the test if `timeout` elapses first.
/// `what` names the thing being waited for, so the failure says what never
/// happened.
@MainActor
func waitUntil(_ what: String, timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.1,
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while try await !condition() {
        if Date() >= deadline {
            XCTFail("timed out after \(timeout) s waiting for \(what)", file: file, line: line)
            return
        }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
}

/// One round trip to an extension's background service worker: sends `message`
/// with `chrome.runtime.sendMessage` from a loaded extension page and returns the
/// parsed envelope, with both halves of the answer in it:
///  - `reply`: what the worker responded (`NSNull` when it answered nothing —
///    which is also what WebKit produces when it could not reach the worker at
///    all — and the string `"timeout"` when the callback never fired);
///  - `lastError`: `chrome.runtime.lastError.message`, the only place a delivery
///    failure is reported, so a caller can tell "the worker said nothing" from
///    "the message never got there".
@MainActor
func askWorker(from webView: WKWebView, message: [String: Any],
               timeout: TimeInterval = 10) async throws -> [String: Any] {
    let raw = try await webView.callAsyncJavaScript("""
        const reply = await new Promise((resolve) => {
            let settled = false;
            chrome.runtime.sendMessage(message, (r) => {
                settled = true;
                resolve({ reply: r === undefined ? null : r,
                          lastError: chrome.runtime.lastError ? chrome.runtime.lastError.message : null });
            });
            setTimeout(() => { if (!settled) resolve({ reply: 'timeout', lastError: null }); }, timeoutMS);
        });
        return JSON.stringify(reply);
    """, arguments: ["message": message, "timeoutMS": Int(timeout * 1000)], contentWorld: .page)
    let jsonString = try XCTUnwrap(raw as? String, "expected a JSON string from the page")
    let data = try XCTUnwrap(jsonString.data(using: .utf8))
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
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
