import Foundation
import WebKit

/// Hosts a hidden WKWebView for an extension's background service worker.
/// The webView loads a synthetic HTML page that includes the chrome API polyfills
/// and the extension's background script.
class BackgroundHost {
    let extensionID: String
    private(set) var webView: WKWebView?
    private let ext: WebExtension

    init(extension ext: WebExtension) {
        self.extensionID = ext.id
        self.ext = ext
    }

    /// Start the background host by creating a hidden WKWebView and loading the background script.
    func start() {
        guard let serviceWorker = ext.manifest.background?.serviceWorker else { return }

        let config = ext.makePageConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isInspectable = true
        self.webView = wv

        // Read the background script and inline it, since loadHTMLString with a
        // file baseURL may not grant the web process access to load relative scripts.
        let scriptURL = ext.basePath.appendingPathComponent(serviceWorker)
        let scriptContent = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""

        // Fire runtime.onInstalled immediately after the background script runs,
        // using setTimeout(0) so all synchronous listener registrations complete first.
        let onInstalledJS = """
        setTimeout(function() {
            if (window.__extensionDispatchOnInstalled) {
                window.__extensionDispatchOnInstalled({ reason: 'install' });
            }
        }, 0);
        """

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

    /// Stop the background host and release the WKWebView.
    func stop() {
        webView?.stopLoading()
        webView = nil
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
