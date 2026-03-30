import Foundation
import WebKit
import AVFoundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "offscreen-host")

/// Hosts a hidden WKWebView for an extension's offscreen document.
/// Created on demand via `chrome.offscreen.createDocument()` and destroyed
/// via `chrome.offscreen.closeDocument()`.
class OffscreenDocumentHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler, AVAudioPlayerDelegate {
    let extensionID: String
    private(set) var webView: WKWebView?
    private let basePath: URL
    private var loadCompletionHandlers: [() -> Void] = []
    private var audioPlayer: AVAudioPlayer?

    private static let audioBridgeHandler = "detourAudioBridge"

    /// JavaScript shim injected at document start that replaces AudioContext
    /// with a bridge to native AVAudioPlayer. WebKit's AudioContext doesn't
    /// work in hidden WKWebViews without a user gesture.
    private static let audioContextShimJS = """
    (function() {
        const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.detourAudioBridge;
        if (!bridge) {
            console.warn('[Detour AudioBridge] message handler not available');
            return;
        }
        console.log('[Detour AudioBridge] Installing AudioContext shim');

        // Global ref so native can call onended when AVAudioPlayer finishes
        window.__detourActiveSourceNode = null;

        window.AudioContext = class AudioContext {
            constructor() {
                this.state = 'running';
                this.destination = {};
                console.log('[Detour AudioBridge] AudioContext created');
            }

            createBufferSource() {
                console.log('[Detour AudioBridge] createBufferSource()');
                const node = {
                    buffer: null,
                    _onended: null,
                    connect() {},
                    disconnect() {},
                    start() {
                        const buf = this.buffer;
                        if (!buf || !buf._base64) {
                            console.warn('[Detour AudioBridge] start() called but no base64 audio data');
                            return;
                        }
                        console.log('[Detour AudioBridge] start() → sending', buf._base64.length, 'chars to native');
                        window.__detourActiveSourceNode = this;
                        bridge.postMessage({ action: 'play', audioSrc: buf._base64 });
                    },
                    stop() {
                        console.log('[Detour AudioBridge] stop()');
                        window.__detourActiveSourceNode = null;
                        bridge.postMessage({ action: 'stop' });
                    },
                    set onended(fn) { this._onended = fn; },
                    get onended() { return this._onended; }
                };
                return node;
            }

            async decodeAudioData(arrayBuffer) {
                console.log('[Detour AudioBridge] decodeAudioData()', arrayBuffer.byteLength, 'bytes');
                const bytes = new Uint8Array(arrayBuffer);
                const chunks = [];
                for (let i = 0; i < bytes.length; i += 8192) {
                    chunks.push(String.fromCharCode.apply(null, bytes.subarray(i, i + 8192)));
                }
                const base64 = btoa(chunks.join(''));
                console.log('[Detour AudioBridge] encoded to base64:', base64.length, 'chars');
                return { _base64: base64, duration: 0 };
            }

            async close() {
                console.log('[Detour AudioBridge] close()');
                this.state = 'closed';
            }
        };

        window.webkitAudioContext = window.AudioContext;
    })();
    """

    init(extensionID: String, basePath: URL) {
        self.extensionID = extensionID
        self.basePath = basePath
        super.init()
    }

    /// Load the offscreen document.
    /// - Parameters:
    ///   - url: Relative path within the extension (e.g. "offscreen.html")
    ///   - configuration: Optional WKWebViewConfiguration to use (e.g. from the extension context)
    ///   - baseURL: The extension's webkit-extension:// base URL (from WKWebExtensionContext.baseURL)
    ///   - completion: Called after the page finishes loading
    func load(url: String, configuration: WKWebViewConfiguration? = nil, baseURL: URL? = nil, completion: (() -> Void)? = nil) {
        let config = configuration ?? WKWebViewConfiguration()

        // Register native audio bridge handler. The AudioContext shim itself is injected
        // via evaluateJavaScript in didFinish rather than as a WKUserScript, because the
        // extension context's userContentController is shared with the service worker.
        config.userContentController.removeScriptMessageHandler(forName: Self.audioBridgeHandler)
        config.userContentController.add(self, name: Self.audioBridgeHandler)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isInspectable = true
        wv.navigationDelegate = self
        self.webView = wv

        if let completion { loadCompletionHandlers.append(completion) }

        if let baseURL {
            // Load via the extension's webkit-extension:// URL scheme so chrome.* APIs work
            let extensionPageURL = baseURL.appendingPathComponent(url)
            log.info("Loading offscreen document: \(extensionPageURL.absoluteString, privacy: .public) for \(self.extensionID, privacy: .public)")
            wv.load(URLRequest(url: extensionPageURL))
        } else {
            // Fallback: load as file URL
            let pageURL = basePath.appendingPathComponent(url)
            log.info("Loading offscreen document (file): \(pageURL.path, privacy: .public) for \(self.extensionID, privacy: .public)")
            wv.loadFileURL(pageURL, allowingReadAccessTo: basePath)
        }
    }

    // MARK: - WKScriptMessageHandler (audio bridge)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.audioBridgeHandler,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String else {
            log.warning("Audio bridge: invalid message from \(self.extensionID, privacy: .public)")
            return
        }

        log.info("Audio bridge action=\(action, privacy: .public) from \(self.extensionID, privacy: .public)")

        switch action {
        case "play":
            if let base64 = body["audioSrc"] as? String {
                log.info("Audio bridge: playing \(base64.count) base64 chars")
                playAudioNatively(base64: base64)
            } else {
                log.warning("Audio bridge: play action missing audioSrc")
            }
        case "stop":
            log.info("Audio bridge: stopping playback")
            stopAudioNatively()
        default:
            log.warning("Audio bridge: unknown action \(action, privacy: .public)")
        }
    }

    // MARK: - Native Audio Playback

    /// Play audio from base64-encoded data using AVAudioPlayer.
    func playAudioNatively(base64: String) {
        guard let data = Data(base64Encoded: base64) else {
            log.error("Audio bridge: failed to decode base64 (\(base64.count) chars) for \(self.extensionID, privacy: .public)")
            return
        }
        log.info("Audio bridge: decoded \(data.count) bytes of audio data")
        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            log.info("Audio bridge: AVAudioPlayer playing, duration=\(self.audioPlayer?.duration ?? 0)s")
        } catch {
            log.error("AVAudioPlayer error for \(self.extensionID, privacy: .public): \(error.localizedDescription)")
        }
    }

    /// Stop any currently playing audio.
    func stopAudioNatively() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        log.info("Audio bridge: playback finished (success=\(flag)) for \(self.extensionID, privacy: .public)")
        audioPlayer = nil
        // Fire the JS sourceNode.onended callback so the extension knows playback completed
        webView?.evaluateJavaScript("""
            (function() {
                const node = window.__detourActiveSourceNode;
                window.__detourActiveSourceNode = null;
                if (node && typeof node._onended === 'function') {
                    node._onended();
                }
            })();
        """, completionHandler: nil)
    }

    // MARK: - Lifecycle

    /// Stop and release the WKWebView.
    func stop() {
        audioPlayer?.stop()
        audioPlayer = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.audioBridgeHandler)
        webView?.stopLoading()
        webView = nil

        loadCompletionHandlers.removeAll()
    }

    /// Evaluate JavaScript in the offscreen document.
    func evaluateJavaScript(_ js: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        webView?.evaluateJavaScript(js, completionHandler: completionHandler)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log.info("Offscreen document didFinish for \(self.extensionID, privacy: .public), URL: \(webView.url?.absoluteString ?? "nil", privacy: .public)")
        // Inject AudioContext shim — must be done via evaluateJavaScript rather than
        // WKUserScript because the extension context's userContentController is shared
        // with the service worker.
        webView.evaluateJavaScript(Self.audioContextShimJS) { result, error in
            if let error {
                log.error("AudioContext shim injection error: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("AudioContext shim injected after load for \(self.extensionID, privacy: .public)")
            }
        }

        let handlers = loadCompletionHandlers
        loadCompletionHandlers.removeAll()
        handlers.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log.error("Offscreen document navigation failed for \(self.extensionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log.error("Offscreen document provisional navigation failed for \(self.extensionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
}
