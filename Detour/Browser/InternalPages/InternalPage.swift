import Foundation
import WebKit

/// A page Detour itself serves into a normal tab (`detour://history/`), the way
/// Safari and Chrome show their history. Being a tab, it gets web view
/// ownership, snapshots, sleep/wake, splits and session restore for free; being
/// privileged, it must be unreachable from web content. Three layers keep it so:
///
///  1. `InternalPageNavigationPolicy` — only Detour can navigate a tab to it.
///  2. `InternalPageSchemeHandler` — only an internal document can load its
///     resources, and the document runs no page-world script (CSP).
///  3. `InternalPageBridge` — the native bridge lives in a private content
///     world and re-verifies every sender.
enum InternalPage: String, CaseIterable {
    case history

    static let scheme = "detour"

    /// The canonical URL, the one tabs persist and the address bar shows.
    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)/")! }

    var title: String {
        switch self {
        case .history: return "History"
        }
    }

    /// The SF Symbol the sidebar shows instead of a favicon. An internal page
    /// has none to fetch, and nothing may go to the network for a `detour://`
    /// URL — `BrowserTab.load(_:arming:)` skips its optimistic `favicon.ico`
    /// download for exactly that reason.
    var symbolName: String {
        switch self {
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// The page a URL belongs to: any URL on the internal scheme whose host
    /// names a page, whatever its path or query (a page's own resources and its
    /// `?q=` state live under its host).
    init?(url: URL) {
        guard Self.isInternal(url), let host = url.host?.lowercased(),
              let page = InternalPage(rawValue: host) else { return nil }
        self = page
    }

    /// Whether a URL is on the internal scheme at all — including hosts that
    /// name no page, which nothing may navigate to either.
    static func isInternal(_ url: URL?) -> Bool {
        url?.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
    }
}

/// Decides whether a navigation to an internal URL may proceed. Pure, so both
/// navigation delegates (`BrowserWindowController` for a claimed web view,
/// `BrowserTab` for one no window has claimed yet) share one tested rule.
///
/// A navigation action does not say who asked for it: an app-initiated
/// `load(_:)` reports the *current document* as its source frame, exactly like
/// a script navigation from that document would. So trust is carried out of
/// band — `BrowserTab.loadInternalPage(_:)` arms the tab for one page, and
/// plain `BrowserTab.load(_:)`, the entry point every untrusted caller shares
/// (an extension's `tabs.create`/`tabs.update`, Cmd+click, a link from another
/// app), never does.
enum InternalPageNavigationPolicy {
    /// - Parameters:
    ///   - targetsMainFrame: `navigationAction.targetFrame?.isMainFrame == true`.
    ///     A nil target frame is a new window, which is refused: nothing opens
    ///     an internal page with a script-reachable opener.
    ///   - armedPage: the page the navigating tab was armed for, if any.
    ///   - sessionEntryURLs: the URLs in the web view's back/forward list.
    enum Decision: Equatable {
        /// Not an internal URL: not this policy's business.
        case notInternal
        case refused
        /// Let through by the tab's arming, which the caller must now spend.
        case allowedByArming
        /// Let through as a revisit of a session entry; any arming is untouched.
        case allowedAsRevisit

        var allows: Bool { self != .refused }
    }

    static func decision(for url: URL?, targetsMainFrame: Bool, navigationType: WKNavigationType,
                         armedPage: InternalPage?, sessionEntryURLs: Set<URL>) -> Decision {
        guard InternalPage.isInternal(url) else { return .notInternal }
        guard targetsMainFrame, let url, let page = InternalPage(url: url) else { return .refused }
        if page == armedPage { return .allowedByArming }
        // Back/forward and reload may revisit an entry an armed load put in this
        // tab's list, and a session restore arrives as `.backForward` with the
        // list already in place. The URL must *be* such an entry: a server
        // redirect keeps the type of the navigation it interrupts, so going
        // back to a web page that answers `302 detour://history/?q=…` would
        // otherwise walk in. Script cannot forge an entry — `pushState` is
        // same-origin, and navigating to one is what this policy refuses. A web
        // page can still send the tab *back* to the internal page; it gains
        // nothing by it — the document is cross-origin to it and runs no
        // page-world script.
        guard navigationType == .backForward || navigationType == .reload else { return .refused }
        return sessionEntryURLs.contains(url) ? .allowedAsRevisit : .refused
    }

    static func sessionEntryURLs(of webView: WKWebView) -> Set<URL> {
        let list = webView.backForwardList
        return Set((list.backList + list.forwardList + [list.currentItem].compactMap { $0 }).map(\.url))
    }
}
