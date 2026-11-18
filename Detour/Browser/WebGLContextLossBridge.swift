import Foundation
import WebKit

/// What a page reported about its WebGL contexts (TASK-410).
enum WebGLContextLossKind: String, Equatable {
    /// `webglcontextlost`: a context the page had was lost.
    case lost
    /// `webglcontextcreationerror`: the page asked for a context and got none.
    case creationError
}

/// Tells `GPUProcessRecycler` the moment a page loses a WebGL context, or fails
/// to get one (TASK-410).
///
/// Once WebKit's GPU process reaches the kernel's 16,384 IOSurfaces, every
/// allocation fails and pages' WebGL contexts die ("WebGL: context lost", and
/// YouTube's attestation with it, TASK-104). The recycler counts surfaces only
/// every two minutes, so this turns the breakage itself into a reason to count
/// now. The report is not trusted on its own: pages lose contexts for harmless
/// reasons too (`WEBGL_lose_context`, WebKit evicting a page's oldest context,
/// a GPU reset after sleep, a recycle), so the recycler decides from the count.
///
/// The listeners live in a private `WKContentWorld`, in every frame, so page
/// script sees neither them nor the handler. They listen in the capture phase
/// on `window`: neither event bubbles, but both pass through capture on their
/// way to a canvas in the document. A canvas outside the document (or an
/// `OffscreenCanvas`) is not seen; the regular two-minute check still covers
/// those pages. Each frame reports each kind at most once per 5 s, and only
/// events WebKit raised: a page can still lose its own contexts on purpose
/// (`WEBGL_lose_context`), but it cannot fake a failed creation.
final class WebGLContextLossBridge: NSObject, WKScriptMessageHandler {
    static let shared = WebGLContextLossBridge()
    static let handlerName = "detourWebGLLoss"
    static let contentWorld = WKContentWorld.world(name: "DetourWebGLLoss")

    static let userScriptSource = """
        (() => {
          const handler = window.webkit?.messageHandlers?.\(handlerName);
          if (!handler) return;
          const minGap = 5000;
          const last = {};
          const listen = (type, kind) => window.addEventListener(type, (event) => {
            if (!event.isTrusted) return;
            const now = Date.now();
            if (now - (last[kind] ?? -Infinity) < minGap) return;
            last[kind] = now;
            handler.postMessage(kind);
          }, true);
          listen('webglcontextlost', '\(WebGLContextLossKind.lost.rawValue)');
          listen('webglcontextcreationerror', '\(WebGLContextLossKind.creationError.rawValue)');
        })();
        """

    /// Where reports go. The recycler in the app; tests swap in a recorder.
    var deliver: (WebGLContextLossKind, BrowserTab, _ isMainFrame: Bool) -> Void = { kind, tab, isMainFrame in
        GPUProcessRecycler.shared.contextLossReported(kind, tab: tab, isMainFrame: isMainFrame)
    }

    /// The tab each web view belongs to. Weak on both sides.
    private static let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    /// Records `tab` as the owner of `webView`'s reports. Called wherever a tab
    /// takes a web view, alongside `FaviconLinkBridge.register`.
    static func register(_ webView: WKWebView, for tab: BrowserTab) {
        tabs.setObject(tab, forKey: webView)
    }

    /// Adds the handler and the script to a tab's configuration. Idempotent,
    /// like `FaviconLinkBridge.install`: configurations reach
    /// `BrowserTab.makeWebView` more than once.
    static func install(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == userScriptSource }) else { return }
        controller.add(shared, contentWorld: contentWorld, name: handlerName)
        controller.addUserScript(WKUserScript(source: userScriptSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: contentWorld))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.world == Self.contentWorld, let webView = message.webView,
              let tab = Self.tabs.object(forKey: webView),
              let raw = message.body as? String, let kind = WebGLContextLossKind(rawValue: raw) else { return }
        deliver(kind, tab, message.frameInfo.isMainFrame)
    }
}
