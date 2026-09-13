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

    /// True only when both the anchor and the target have a host and the hosts
    /// differ. A hostless URL on either side (`about:blank`, `data:`) means the
    /// navigation stays in place.
    static func shouldPeekCrossHostNavigation(anchorURL: URL, to target: URL) -> Bool {
        guard let anchorHost = anchorURL.host, let targetHost = target.host else { return false }
        return targetHost != anchorHost
    }
}
