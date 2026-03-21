import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "background-host")

/// Hosts a hidden WKWebView for an extension's background service worker.
/// The webView loads a synthetic HTML page that includes the chrome API polyfills
/// and the extension's background script.
class BackgroundHost: NSObject, WKNavigationDelegate {
    let extensionID: String
    private(set) var webView: WKWebView?
    private let ext: WebExtension
    private(set) var isLoaded = false
    private var loadCompletionHandlers: [() -> Void] = []
    private static let syntheticBackgroundPath = "_generated_background.html"

    init(extension ext: WebExtension) {
        self.extensionID = ext.id
        self.ext = ext
        super.init()
    }

    /// Start the background host by creating a hidden WKWebView and loading the background script.
    /// The optional completion handler fires after the page finishes loading, ensuring the
    /// chrome API polyfills and background script are ready to receive messages.
    func start(isFirstRun: Bool = true, completion: (() -> Void)? = nil) {
        guard let serviceWorker = ext.manifest.background?.serviceWorker else { return }
        log.info("Starting background host for \(self.extensionID, privacy: .public)")

        let config = ext.makePageConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        self.webView = wv

        if let completion { loadCompletionHandlers.append(completion) }

        // Fire runtime.onInstalled and runtime.onStartup after the background script runs,
        // using setTimeout(0) so all synchronous listener registrations complete first.
        // Only fire onInstalled with reason 'install' on first install; subsequent starts
        // fire onStartup only (Chrome doesn't fire onInstalled on every browser restart).
        var parts: [String] = []
        if isFirstRun {
            parts.append("if (window.__extensionDispatchOnInstalled) { window.__extensionDispatchOnInstalled({ reason: 'install' }); }")
        }
        parts.append("if (window.__extensionDispatchOnStartup) { window.__extensionDispatchOnStartup(); }")
        let dispatchJS = parts.joined(separator: "\n")
        let onInstalledJS = "setTimeout(function() { \(dispatchJS) }, 0);"

        let isModule = ext.manifest.background?.isModule == true

        if isModule {
            // For ES module backgrounds, use <script type="module" src="..."> so that
            // dynamic import() and top-level await work correctly. The src URL goes through
            // the chrome-extension:// scheme handler, which serves the file from disk.
            // We load via a real chrome-extension:// URL (not loadHTMLString) so WebKit
            // gives the page the correct origin, allowing module script imports.
            let scriptURL = ExtensionPageSchemeHandler.url(for: ext.id, path: serviceWorker).absoluteString
            let html = """
            <!DOCTYPE html>
            <html>
            <head><title>Background - \(ext.manifest.name)</title></head>
            <body>
            <script type="module" src="\(scriptURL)"></script>
            <script>\(onInstalledJS)</script>
            </body>
            </html>
            """

            // Register the synthetic page and load via the scheme handler
            ExtensionPageSchemeHandler.shared.registerSyntheticPage(
                extensionID: ext.id,
                path: Self.syntheticBackgroundPath,
                html: html
            )
            let pageURL = ExtensionPageSchemeHandler.url(for: ext.id, path: Self.syntheticBackgroundPath)
            wv.load(URLRequest(url: pageURL))
        } else {
            // For non-module backgrounds, inline the script content directly.
            let scriptURL = ext.basePath.appendingPathComponent(serviceWorker)
            let scriptContent = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""

            let html = """
            <!DOCTYPE html>
            <html>
            <head><title>Background - \(ext.manifest.name)</title></head>
            <body>
            <script>\(scriptContent)</script>
            <script>\(onInstalledJS)</script>
            </body>
            </html>
            """

            let baseURL = ExtensionPageSchemeHandler.url(for: ext.id, path: "/")
            wv.loadHTMLString(html, baseURL: baseURL)
        }
    }

    /// Stop the background host and release the WKWebView.
    func stop() {
        log.info("Stopping background host for \(self.extensionID, privacy: .public)")
        ExtensionPageSchemeHandler.shared.removeSyntheticPage(
            extensionID: ext.id,
            path: Self.syntheticBackgroundPath
        )
        webView?.stopLoading()
        webView = nil
        isLoaded = false
        loadCompletionHandlers.removeAll()
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        let handlers = loadCompletionHandlers
        loadCompletionHandlers.removeAll()
        handlers.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("didFail for \(self.extensionID, privacy: .public): \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("didFailProvisionalNavigation for \(self.extensionID, privacy: .public): \(error.localizedDescription)")
    }

    /// Evaluate JavaScript in the background webView.
    func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js, completionHandler: completionHandler)
    }

    /// Dispatch an event to the background script by name with a JSON-serializable data dict.
    func dispatchEvent(_ functionName: String, data: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        let js = "if (window.\(functionName)) { window.\(functionName)(\(jsonString)); }"
        evaluateJavaScript(js)
    }
}
