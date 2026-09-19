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
    static func allows(_ url: URL?, targetsMainFrame: Bool, navigationType: WKNavigationType,
                       armedPage: InternalPage?) -> Bool {
        guard InternalPage.isInternal(url) else { return true }
        guard targetsMainFrame, let url, let page = InternalPage(url: url) else { return false }
        if page == armedPage { return true }
        // Back/forward and reload only ever revisit an entry an armed load put
        // in this tab's list (script cannot push a cross-origin entry), and a
        // session restore arrives as `.backForward`. A web page can send the tab
        // *back* to the internal page this way; it gains nothing by it — the
        // document is cross-origin to it and runs no page-world script.
        return navigationType == .backForward || navigationType == .reload
    }
}
