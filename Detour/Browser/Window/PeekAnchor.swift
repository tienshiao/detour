import Foundation

/// The "anchor" a tab is held to for the cross-host Peek rule: a pinned
/// entry's home URL or a favourite's URL. Ordinary tabs have none.
///
/// Pure lookup + predicate so the navigation-policy branch in
/// `BrowserWindowController+Navigation` stays a single readable condition and
/// the rule itself is unit-testable (`PeekAnchorTests`).
enum PeekAnchor {

    /// The anchor URL of the pinned entry or favourite whose LIVE backing tab
    /// has `tabID`; nil for an ordinary tab or a dormant tile (no backing tab,
    /// so nothing can be navigating).
    ///
    /// Pinned entries are checked first: a tab can only be in one section, and
    /// the pinned home URL is the authoritative anchor when it is.
    static func anchorURL(forTabID tabID: UUID,
                          pinnedEntries: [PinnedEntry],
                          favorites: [Favorite]) -> URL? {
        if let entry = pinnedEntries.first(where: { $0.tab?.id == tabID }) {
            return entry.pinnedURL
        }
        if let favorite = favorites.first(where: { $0.tab?.id == tabID }) {
            return favorite.url
        }
        return nil
    }

    /// The tab a peek-worthy link activation should be anchored to, given the
    /// tab the caller resolved from the web view that fired it rather than from
    /// the selection (TASK-48).
    ///
    /// A pinned split hosts two panes; a link activated in the *unfocused* one
    /// fires from a web view that is not `selectedTab.webView`, so anchoring on
    /// the selection let it fall through and navigate the pinned pane off its
    /// home host. Middle clicks and scripted `anchor.click()` reach the policy
    /// decision without AppKit having moved first responder, so this cannot
    /// rely on the click having focused the pane already — the caller focuses
    /// it before showing the peek, because `showPeekOverlay` anchors on
    /// `selectedTab`.
    ///
    /// Accepted only when `clicked` is the selected tab or a pane of its split:
    /// anything else is a background navigation that must not steal the
    /// window's overlay, and a peek's web view resolves to the peek tab, which
    /// is neither — so peeks keep navigating in place.
    ///
    /// `splitMembers` is an autoclosure because resolving them scans the
    /// store's tab/pinned lists, and the common single-pane case (the clicked
    /// tab *is* the selected tab) never needs them.
    static func interceptTab(clicked: BrowserTab?, selectedTab: BrowserTab?,
                             splitMembers: @autoclosure () -> [BrowserTab]) -> BrowserTab? {
        guard let clicked else { return nil }
        let hosted = clicked === selectedTab || splitMembers().contains { $0 === clicked }
        return hosted ? clicked : nil
    }

    /// True only when both the anchor and the target have a host and the hosts
    /// differ. A hostless URL on either side (`about:blank`, `data:`) means the
    /// navigation stays in place.
    static func shouldPeekCrossHostNavigation(anchorURL: URL, to target: URL) -> Bool {
        guard let anchorHost = anchorURL.host, let targetHost = target.host else { return false }
        return targetHost != anchorHost
    }

    /// Whether a link activation on an anchored tab opens a Peek.
    ///
    /// `opensNewWindow` is a `target="_blank"` (or named-target) link: WebKit
    /// asks the navigation delegate about it with a nil `targetFrame` before it
    /// would call `createWebViewWith`, so cancelling here is what keeps it out
    /// of a new tab. Such a link peeks whenever the target has a host, same
    /// host included — navigating in place is not what the page asked for, and
    /// a new tab defeats the pinned-app model (TASK-85). An in-place link only
    /// peeks when it leaves the anchor's host.
    static func shouldPeek(anchorURL: URL, to target: URL, opensNewWindow: Bool) -> Bool {
        if opensNewWindow { return target.host != nil }
        return shouldPeekCrossHostNavigation(anchorURL: anchorURL, to: target)
    }

    /// Whether a script `window.open` from an anchored tab opens a Peek. Such
    /// opens never reach the navigation delegate — only `createWebViewWith` —
    /// so they need their own rule (Google Calendar opens a Zoom link this way,
    /// TASK-85). A tab-style open peeks like a `_blank` link; a popup-style one
    /// (`wantsPopup`: size/position or `popup` features, as OAuth and payment
    /// windows ask for) keeps its own tab, as does a hostless target
    /// (`window.open("")` a page then writes into).
    static func shouldPeekScriptedWindow(to target: URL, wantsPopup: Bool) -> Bool {
        !wantsPopup && target.host != nil
    }
}
