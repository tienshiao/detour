import Foundation
import WebKit
import AVFoundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "background-host")

/// Hosts a hidden WKWebView for an extension's offscreen document.
/// Similar to `BackgroundHost` but created on demand via `chrome.offscreen.createDocument()`.
class OffscreenDocumentHost: NSObject, WKNavigationDelegate {
    let extensionID: String
    private(set) var webView: WKWebView?
    private let ext: WebExtension
    private(set) var isLoaded = false
    private var loadCompletionHandlers: [() -> Void] = []
    private var audioPlayer: AVAudioPlayer?

    init(extension ext: WebExtension) {
        self.extensionID = ext.id
        self.ext = ext
        super.init()
    }

    /// Load the offscreen document from the extension's basePath.
    /// The completion handler fires after the page finishes loading,
    /// ensuring onMessage listeners are registered before callers send messages.
    func load(url: String, completion: (() -> Void)? = nil) {
        let config = ext.makePageConfiguration()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        self.webView = wv

        if let completion { loadCompletionHandlers.append(completion) }

        // Load via the chrome-extension:// scheme handler so module scripts
        // and absolute-path resource references resolve correctly.
        let pageURL = ExtensionPageSchemeHandler.url(for: ext.id, path: url)
        wv.load(URLRequest(url: pageURL))
    }

    // MARK: - Native Audio Playback

    /// Play audio from base64-encoded data using AVAudioPlayer.
    /// Called by the message bridge when it intercepts a playAudio message,
    /// bypassing WebKit's AudioContext (which requires user gesture in hidden WKWebViews).
    func playAudioNatively(base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.play()
        } catch {
            log.error("AVAudioPlayer error for \(self.extensionID, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Stop any currently playing audio.
    func stopAudioNatively() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Lifecycle

    /// Stop and release the WKWebView.
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        webView?.stopLoading()
        webView = nil
        isLoaded = false
        loadCompletionHandlers.removeAll()
    }

    /// Evaluate JavaScript in the offscreen document.
    func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js, completionHandler: completionHandler)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        let handlers = loadCompletionHandlers
        loadCompletionHandlers.removeAll()
        handlers.forEach { $0() }
    }
}
