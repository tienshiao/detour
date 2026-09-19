import Foundation
import WebKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "InternalPageBridge")

/// The native side of internal pages: `webkit.messageHandlers.detourInternal`.
///
/// The handler and each page's script live in a private `WKContentWorld`. Page
/// scripts — a web page's, or anything that found its way into an internal
/// document — and extension content scripts run in other worlds and cannot see
/// the handler at all. That is exposure control, not the guarantee: a user
/// content controller can be shared between web views (a `window.open` child
/// gets its opener's), so every message is re-verified against its sender, and
/// the API carries no scope identifiers — what a page may read is derived here
/// from the tab that sent the message, never from what the message says.
final class InternalPageBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = InternalPageBridge()
    static let handlerName = "detourInternal"
    static let contentWorld = WKContentWorld.world(name: "DetourInternalPage")

    /// Adds the bridge and the page scripts to a tab's configuration. Idempotent:
    /// registering a handler name twice in one world raises, and configurations
    /// reach `BrowserTab.makeWebView` more than once (an extension's shared
    /// configuration on every wake).
    static func install(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        let scripts = InternalPage.allCases.map(userScriptSource(for:))
        guard !controller.userScripts.contains(where: { scripts.contains($0.source) }) else { return }
        controller.addScriptMessageHandler(shared, contentWorld: contentWorld, name: handlerName)
        for source in scripts {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: contentWorld))
        }
    }

    /// The page's script, inert everywhere but on its own page. `location` is
    /// read through this world's own bindings, which page script cannot patch.
    static func userScriptSource(for page: InternalPage) -> String {
        """
        (() => {
          if (location.protocol !== '\(InternalPage.scheme):' || location.host !== '\(page.rawValue)') return;
          const native = (method, params) =>
            window.webkit.messageHandlers.\(handlerName).postMessage({ method, params: params || {} });
        \(page.scriptSource)
        })();
        """
    }

    /// The page a message may act as: sent by a main frame whose security
    /// origin, frame URL and web view URL all name the same internal page.
    static func authorizedPage(isMainFrame: Bool, originProtocol: String, originHost: String,
                               frameURL: URL?, webViewURL: URL?) -> InternalPage? {
        guard isMainFrame,
              originProtocol.caseInsensitiveCompare(InternalPage.scheme) == .orderedSame,
              let page = InternalPage(rawValue: originHost.lowercased()),
              let frameURL, InternalPage(url: frameURL) == page,
              let webViewURL, InternalPage(url: webViewURL) == page else { return nil }
        return page
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        let frame = message.frameInfo
        guard message.world == Self.contentWorld,
              let webView = message.webView,
              let page = Self.authorizedPage(isMainFrame: frame.isMainFrame,
                                             originProtocol: frame.securityOrigin.protocol,
                                             originHost: frame.securityOrigin.host,
                                             frameURL: frame.request.url,
                                             webViewURL: webView.url),
              let tab = TabStore.shared.tab(hosting: webView) else {
            log.error("Rejected a message from \(message.frameInfo.securityOrigin.protocol, privacy: .public)://\(message.frameInfo.securityOrigin.host, privacy: .public)")
            replyHandler(nil, "forbidden")
            return
        }
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            replyHandler(nil, "malformed")
            return
        }
        let params = body["params"] as? [String: Any] ?? [:]
        switch page {
        case .history:
            HistoryPageBridge.handle(method: method, params: params, from: tab, reply: replyHandler)
        }
    }
}

extension TabStore {
    /// The tab whose web view this is, wherever it lives: a space's tabs, its
    /// pinned entries, the profile's favourites, or a peek over any of them.
    func tab(hosting webView: WKWebView) -> BrowserTab? {
        for space in spaces {
            var candidates = space.tabs
            candidates.append(contentsOf: space.pinnedEntries.compactMap { $0.tab })
            candidates.append(contentsOf: space.profile?.favorites.compactMap { $0.tab } ?? [])
            candidates.append(contentsOf: candidates.compactMap { $0.peekTab })
            if let tab = candidates.first(where: { $0.webView === webView }) { return tab }
        }
        return nil
    }
}
