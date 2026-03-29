import Foundation
import WebKit
import AVFoundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "offscreen-host")

/// Hosts a hidden WKWebView for an extension's offscreen document.
/// Created on demand via `chrome.offscreen.createDocument()` and destroyed
/// via `chrome.offscreen.closeDocument()`.
class OffscreenDocumentHost: NSObject, WKNavigationDelegate {
    let extensionID: String
    private(set) var webView: WKWebView?
    private let basePath: URL
    private(set) var isLoaded = false
    private var loadCompletionHandlers: [() -> Void] = []
    private var audioPlayer: AVAudioPlayer?

    init(extensionID: String, basePath: URL) {
        self.extensionID = extensionID
        self.basePath = basePath
        super.init()
    }

    /// Load the offscreen document.
    /// - Parameters:
    ///   - url: Relative path within the extension (e.g. "offscreen.html")
    ///   - configuration: Optional WKWebViewConfiguration to use (e.g. from the extension context)
    ///   - completion: Called after the page finishes loading
    func load(url: String, configuration: WKWebViewConfiguration? = nil, completion: (() -> Void)? = nil) {
        let config = configuration ?? WKWebViewConfiguration()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        self.webView = wv

        if let completion { loadCompletionHandlers.append(completion) }

        // Load the offscreen page from the extension's base directory
        let pageURL = basePath.appendingPathComponent(url)
        wv.loadFileURL(pageURL, allowingReadAccessTo: basePath)
    }

    // MARK: - Native Audio Playback

    /// Play audio from base64-encoded data using AVAudioPlayer.
    /// WebKit's AudioContext doesn't work in hidden WKWebViews without user gesture,
    /// so we play audio via AVAudioPlayer instead.
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
