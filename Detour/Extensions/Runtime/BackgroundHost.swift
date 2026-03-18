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

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        // Add chrome API polyfills in the .page world (background runs in .page)
        let apiBundle = ChromeAPIBundle.generateBundle(for: ext, isContentScript: false)
        let apiScript = WKUserScript(
            source: apiBundle,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(apiScript)

        // Register message bridge in .page world for background
        ExtensionMessageBridge.shared.register(on: config.userContentController)

        let wv = WKWebView(frame: .zero, configuration: config)
        self.webView = wv

        // Read the background script and inline it, since loadHTMLString with a
        // file baseURL may not grant the web process access to load relative scripts.
        let scriptURL = ext.basePath.appendingPathComponent(serviceWorker)
        let scriptContent = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""

        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Background - \(ext.manifest.name)</title></head>
        <body>
        <script>\(scriptContent)</script>
        </body>
        </html>
        """

        wv.loadHTMLString(html, baseURL: ext.basePath)
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
}
