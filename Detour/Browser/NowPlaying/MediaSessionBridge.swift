import Foundation
import WebKit

/// Tells a tab what the now-playing bar needs from its page and carries the
/// bar's Previous, Next, Play and Pause back to the page's own Media Session
/// handlers (TASK-192). WebKit keeps Media Session to itself: its handlers
/// answer the system's Now Playing commands and test-only SPI, and nothing
/// reports a page's handlers or metadata to the app.
///
/// Two scripts, both from document start:
///
/// - **Page world, main frame.** Wraps `MediaSession.prototype.setActionHandler`
///   and the `metadata` setters so it knows which handlers the page set, and
///   announces every change with a DOM event on the document. It runs a stored
///   handler when the isolated world dispatches the invoke event. This half
///   is visible to (and replaceable by) the page — which only lets a page
///   misreport its own session.
/// - **Isolated world (`contentWorld`), every frame.** Reads the session's
///   metadata through its own wrappers, watches `webkitpresentationmodechanged`
///   for picture in picture, and posts to the handler. Page script can neither
///   see nor call the handler.
///
/// Everything a page reports is display text or a button to enable:
/// `MediaBridgeMessage` validates it, and a stored handler only ever runs in
/// that page. CSP does not apply to user scripts.
final class MediaSessionBridge: NSObject, WKScriptMessageHandler {
    static let shared = MediaSessionBridge()
    static let handlerName = "detourMedia"
    static let contentWorld = WKContentWorld.world(name: "DetourMedia")

    /// The DOM events the two worlds talk through. The page can see and send
    /// them; see the type comment for why that is harmless.
    static let changedEvent = "detour-media-session-changed"
    static let invokeEvent = "detour-media-session-invoke"
    /// The isolated world's function native calls to run a page handler.
    static let invokeFunction = "detourMediaSessionInvoke"

    static let pageScriptSource = """
        (() => {
          const proto = window.MediaSession && MediaSession.prototype;
          if (!proto || typeof proto.setActionHandler !== 'function') return;
          const doc = document;
          const dispatch = EventTarget.prototype.dispatchEvent;
          const listen = EventTarget.prototype.addEventListener;
          const Custom = CustomEvent;
          const handlers = new Map();
          const changed = () => {
            try { dispatch.call(doc, new Custom('\(changedEvent)', { detail: Array.from(handlers.keys()).join(',') })); } catch (e) {}
          };
          const original = proto.setActionHandler;
          // A method, so the wrapper keeps the name `setActionHandler`. The
          // original runs first: an action WebKit refuses throws before it is recorded.
          proto.setActionHandler = {
            setActionHandler(action, handler) {
              original.call(this, action, handler);
              if (typeof handler === 'function') handlers.set(String(action), handler);
              else handlers.delete(String(action));
              changed();
            },
          }.setActionHandler;
          const wrapSetter = (target, key) => {
            const descriptor = target && Object.getOwnPropertyDescriptor(target, key);
            if (!descriptor || !descriptor.set || !descriptor.configurable) return;
            Object.defineProperty(target, key, {
              configurable: true, enumerable: descriptor.enumerable, get: descriptor.get,
              set(value) { descriptor.set.call(this, value); changed(); },
            });
          };
          wrapSetter(proto, 'metadata');
          const metadataProto = window.MediaMetadata && MediaMetadata.prototype;
          for (const key of ['title', 'artist', 'album', 'artwork']) wrapSetter(metadataProto, key);
          listen.call(doc, '\(invokeEvent)', (event) => {
            const action = String(event.detail);
            const handler = handlers.get(action);
            if (typeof handler === 'function') handler.call(navigator.mediaSession, { action });
          });
        })();
        """

    static let isolatedScriptSource = """
        (() => {
          const post = (message) => {
            try { window.webkit.messageHandlers.\(handlerName).postMessage(message); } catch (e) {}
          };
          const frame = Math.random().toString(36).slice(2, 12) + Date.now().toString(36);
          const inPictureInPicture = new Set();
          let reportedPictureInPicture = false;
          const reportPictureInPicture = () => {
            const active = inPictureInPicture.size > 0;
            if (active === reportedPictureInPicture) return;
            reportedPictureInPicture = active;
            post({ kind: 'pip', frame, active });
          };
          document.addEventListener('webkitpresentationmodechanged', (event) => {
            const video = event.target;
            if (video.webkitPresentationMode === 'picture-in-picture') inPictureInPicture.add(video);
            else inPictureInPicture.delete(video);
            reportPictureInPicture();
          }, true);
          window.addEventListener('pagehide', () => { inPictureInPicture.clear(); reportPictureInPicture(); });
          if (window !== window.top) return;

          let actions = [];
          let lastSession = '';
          const reportSession = () => {
            const session = navigator.mediaSession;
            const metadata = session && session.metadata;
            const message = {
              kind: 'session', actions,
              title: metadata ? metadata.title : null,
              artist: metadata ? metadata.artist : null,
              album: metadata ? metadata.album : null,
              artwork: metadata ? Array.from(metadata.artwork || [], (image) => ({ src: image.src, sizes: image.sizes || '' })) : [],
            };
            const key = JSON.stringify(message);
            if (key === lastSession) return;
            lastSession = key;
            post(message);
          };
          document.addEventListener('\(changedEvent)', (event) => {
            actions = String(event.detail || '').split(',').filter(Boolean);
            reportSession();
          });
          window.addEventListener('pageshow', (event) => {
            if (!event.persisted) return;
            lastSession = '';
            post({ kind: 'document' });
            reportSession();
          });
          window.\(invokeFunction) = (action) => {
            document.dispatchEvent(new CustomEvent('\(invokeEvent)', { detail: String(action) }));
          };
          post({ kind: 'document' });
        })();
        """

    /// The tab each web view belongs to. Weak on both sides.
    private static let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    /// Records `tab` as the owner of `webView`'s reports. Called wherever a tab
    /// takes a web view, alongside `FaviconLinkBridge.register`.
    static func register(_ webView: WKWebView, for tab: BrowserTab) {
        tabs.setObject(tab, forKey: webView)
    }

    /// Adds the handler and both scripts to a tab's configuration. Idempotent,
    /// like `FaviconLinkBridge.install`: configurations reach
    /// `BrowserTab.makeWebView` more than once.
    static func install(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == isolatedScriptSource }) else { return }
        controller.add(shared, contentWorld: contentWorld, name: handlerName)
        controller.addUserScript(WKUserScript(source: pageScriptSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: isolatedScriptSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: contentWorld))
    }

    /// Runs the page's own handler for `action` in its main frame. Does nothing
    /// when the page has none (the page-world half checks).
    static func invoke(_ action: MediaSessionAction, in webView: WKWebView) {
        webView.callAsyncJavaScript("if (typeof \(invokeFunction) === 'function') \(invokeFunction)(action);",
                                    arguments: ["action": action.rawValue], in: nil, in: contentWorld)
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.world == Self.contentWorld, let webView = message.webView,
              let tab = Self.tabs.object(forKey: webView),
              let report = MediaBridgeMessage(body: message.body, isMainFrame: message.frameInfo.isMainFrame) else { return }
        tab.mediaBridgeDidReport(report)
    }
}
