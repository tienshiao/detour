import Foundation
import WebKit

/// Reports a page's `<link rel=icon>` to its tab as soon as the parser (or a
/// script) puts one in the document, instead of waiting for the load to end
/// (TASK-112).
///
/// A tab opened in the background loads in a hidden web view, and WebKit can
/// leave hidden pages loading for a long time when several load at once — the
/// `load` event may not come until the tab is first shown. The page's icon link
/// is usually in the DOM long before that, so the tab's `isLoading` edge alone
/// left those rows on the generic globe.
///
/// The script lives in a private `WKContentWorld`, so page script can neither
/// see the handler nor patch the observer. The handler still re-checks the
/// sender: only a main frame whose origin is the tab's current page is heard.
final class FaviconLinkBridge: NSObject, WKScriptMessageHandler {
    static let shared = FaviconLinkBridge()
    static let handlerName = "detourFavicon"
    static let contentWorld = WKContentWorld.world(name: "DetourFavicon")

    /// The icon links Detour recognises, in document order. Shared with
    /// `BrowserTab.fetchFavicon`'s end-of-load lookup so the two never disagree.
    static let iconLinkSelector = "link[rel~='icon'], link[rel='shortcut icon']"

    /// Runs from document start and observes the whole document, so a link the
    /// parser inserts is reported at the next microtask checkpoint — even while
    /// the parser then blocks on a slow script. Only mutations that touch a
    /// `<link>` trigger a lookup; a lookup that finds the href already reported
    /// sends nothing.
    static let userScriptSource = """
        (() => {
          const selector = "\(iconLinkSelector)";
          let reported = null;
          const report = () => {
            const href = document.querySelector(selector)?.href;
            if (!href || href === reported) return;
            reported = href;
            window.webkit.messageHandlers.\(handlerName).postMessage(href);
          };
          const isLink = (node) => node.localName === 'link';
          const touchesLink = (records) => records.some((record) =>
            isLink(record.target) ||
            Array.prototype.some.call(record.addedNodes, isLink) ||
            Array.prototype.some.call(record.removedNodes, isLink));
          new MutationObserver((records) => { if (touchesLink(records)) report(); })
            .observe(document, { childList: true, subtree: true, attributes: true,
                                 attributeFilter: ['href', 'rel'] });
          report();
        })();
        """

    /// The tab each web view belongs to. Weak on both sides: neither outlives
    /// the other because of this table.
    private static let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    /// Records `tab` as the owner of `webView`'s reports. Called wherever a tab
    /// takes a web view, alongside `ExtensionPageHostRegistry.register`.
    static func register(_ webView: WKWebView, for tab: BrowserTab) {
        tabs.setObject(tab, forKey: webView)
    }

    /// Adds the handler and the script to a tab's configuration. Idempotent:
    /// registering a handler name twice in one world raises, and configurations
    /// reach `BrowserTab.makeWebView` more than once (an extension's shared
    /// configuration on every wake).
    static func install(on configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source == userScriptSource }) else { return }
        controller.add(shared, contentWorld: contentWorld, name: handlerName)
        controller.addUserScript(WKUserScript(source: userScriptSource, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: contentWorld))
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.world == Self.contentWorld, message.frameInfo.isMainFrame,
              let webView = message.webView, let tab = Self.tabs.object(forKey: webView),
              let href = message.body as? String, let url = URL(string: href) else { return }
        tab.pageDidReportFaviconLink(url, originHost: message.frameInfo.securityOrigin.host)
    }
}
