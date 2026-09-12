import Foundation
import WebKit
import AVFoundation
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "offscreen-host")

/// Hosts a hidden WKWebView for an extension's offscreen document.
/// Created on demand via `chrome.offscreen.createDocument()` and destroyed
/// via `chrome.offscreen.closeDocument()`.
class OffscreenDocumentHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler, AVAudioPlayerDelegate {

    /// Why an offscreen document's load did not succeed. Both cases settle a
    /// pending `chrome.offscreen.createDocument`, which would otherwise hang
    /// forever waiting for a `didFinish` that is never coming.
    enum LoadError: LocalizedError {
        /// `stop()` ran while the document was still loading — an explicit
        /// `closeDocument`, or the context being unloaded/reloaded (TASK-12).
        case closedBeforeLoad
        /// The navigation itself failed: the page is missing (404), or the load
        /// was blocked or otherwise errored out (TASK-18). `path` is the
        /// extension-relative path that was asked for.
        case navigationFailed(path: String?, underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .closedBeforeLoad:
                return "Offscreen document was closed before it finished loading"
            case .navigationFailed(let path, let underlying):
                let page = path ?? "(unknown page)"
                return "Offscreen document \(page) failed to load: \(underlying.localizedDescription)"
            }
        }
    }

    let extensionID: String
    private(set) var webView: WKWebView?
    private let basePath: URL
    /// Completions waiting for the current load to settle. Every path that ends
    /// a load — `didFinish`, a real navigation failure, and `stop()` — drains
    /// them through `settleLoad`, exactly once, so a pending `createDocument`
    /// can neither hang nor be answered twice. More than one can wait: a
    /// `createDocument` that arrives while the first is still loading joins
    /// the same load (`addLoadCompletion`) rather than being told a document
    /// exists before one does.
    private var loadCompletionHandlers: [(Result<Void, any Error>) -> Void] = []
    /// True from `load(url:)` until the load settles. While true, the registered
    /// host is not yet a document: `hasDocument`-style checks must not count it,
    /// and a concurrent create must wait on it instead of reporting success.
    private(set) var isLoading = false
    /// Extension-relative path of the document being loaded, for error text.
    private var requestedPath: String?
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
    ///   - completion: Called exactly once when the load settles: `.success`
    ///     from `didFinish`, `.failure(LoadError.navigationFailed)` when the
    ///     navigation errors out, `.failure(LoadError.closedBeforeLoad)` when
    ///     `stop()` runs first.
    func load(url: String, configuration: WKWebViewConfiguration? = nil, baseURL: URL? = nil,
              completion: ((Result<Void, any Error>) -> Void)? = nil) {
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
        requestedPath = url
        isLoading = true

        if let baseURL {
            // Load via the extension's webkit-extension:// URL scheme so chrome.* APIs work
            let extensionPageURL = baseURL.appendingPathComponent(url)
            log.info("Loading offscreen document: \(extensionPageURL.absoluteString, privacy: .private) for \(self.extensionID, privacy: .public)")
            wv.load(URLRequest(url: extensionPageURL))
        } else {
            // Fallback: load as file URL
            let pageURL = basePath.appendingPathComponent(url)
            log.info("Loading offscreen document (file): \(pageURL.path, privacy: .private) for \(self.extensionID, privacy: .public)")
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

        // A load still in flight never reaches didFinish now; fail its
        // completions so the pending createDocument request settles. The web
        // view is already gone at this point, so a completion that calls back
        // into stop() finds nothing left to do.
        settleLoad(.failure(LoadError.closedBeforeLoad))
    }

    /// Wait on the load already in flight. Only meaningful while `isLoading`;
    /// callers check that first, since a settled load never runs completions
    /// again.
    func addLoadCompletion(_ completion: @escaping (Result<Void, any Error>) -> Void) {
        loadCompletionHandlers.append(completion)
    }

    /// Record that the load is over and run the pending completions. Clearing
    /// first makes this re-entrant: a completion that closes or reloads the
    /// document cannot see the handlers it is itself running. Once settled,
    /// later delegate callbacks (a post-load navigation, a trailing
    /// cancellation from `stopLoading()`) find nothing to do.
    private func settleLoad(_ result: Result<Void, any Error>) {
        guard isLoading else { return }
        isLoading = false
        let handlers = loadCompletionHandlers
        loadCompletionHandlers.removeAll()
        handlers.forEach { $0(result) }
    }

    /// A navigation failure reported by WebKit. Cancellations are not the end
    /// of the load: a page that navigates itself before its first load finishes
    /// fails the first navigation with `NSURLErrorCancelled` and then finishes
    /// the second, so the load stays pending for that `didFinish` (and is still
    /// settled by `stop()` if the document is closed first). Anything else is a
    /// real failure: a missing page, a blocked load, a dropped connection. The
    /// dead web view itself is torn down by whoever owns the host (the polyfill
    /// handler unregisters and stops it), not here.
    private func failLoad(_ error: any Error, phase: StaticString) {
        if error.isIgnoredNavigationError {
            log.info("Offscreen document \(phase, privacy: .public) navigation superseded for \(self.extensionID, privacy: .public); still loading")
            return
        }
        log.error("Offscreen document \(phase, privacy: .public) navigation failed for \(self.extensionID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        settleLoad(.failure(LoadError.navigationFailed(path: requestedPath, underlying: error)))
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

        settleLoad(.success(()))
    }

    // Both failure callbacks go through failLoad: a real failure must settle the
    // pending createDocument rather than leave it waiting for a didFinish that
    // will never arrive (TASK-18).

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failLoad(error, phase: "committed")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failLoad(error, phase: "provisional")
    }
}
