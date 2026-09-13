import Foundation

/// The tab a window reports to extensions as *active*: the page the user is
/// actually looking at, which is the presented Peek when one is up (TASK-51).
///
/// `selectedTabID` is deliberately untouched by this rule — it still names the
/// focused pane of a split, i.e. the peek's host. Only the extension-visible
/// "active tab" (`tabs.query({active: true})`, toolbar popups, `activeTab`
/// grants) follows the overlay, so a fill or a popup targets the peek page
/// instead of the host hidden behind it.
///
/// A peek with no web view is not it: a parked peek (its host slept and
/// released the web view) is not reported open to the contexts either, so
/// WebKit has nothing to map an activation to.
func extensionActiveTab(selected: BrowserTab?, peekPresented: Bool) -> BrowserTab? {
    guard peekPresented, let peek = selected?.peekTab, peek.webView != nil else { return selected }
    return peek
}

/// The single funnel for a window's activation announcements (TASK-51).
///
/// Every path that can change the extension-visible active tab — selecting a
/// tab, focusing the other pane of a split, presenting/restoring a peek,
/// closing one, deselecting everything — calls `announce`, and the tracker
/// decides whether the contexts hear anything. Deduping by identity is what
/// makes that safe: the paths overlap (a tab switch presents a restored peek,
/// an expand selects a tab), and WebKit gets one `didActivateTab` per real
/// change with the tab it was looking at before.
///
/// The reference is weak: a tab that went away between announcements must not
/// be kept alive here, and a dead `previousActiveTab` is simply nil.
///
/// The previous tab is only reported when it is still registered open *with the
/// same profile*: a space switch across profiles (`setActiveSpace` →
/// `selectTab`) would otherwise hand the target contexts a tab belonging to
/// another profile's contexts, and `expandPeekToNewTab` reports the peek closed
/// before the handover `selectTab` fires. WebKit's
/// `didActivateTab(_:previousActiveTab:)` runs `getOrCreateTab` on the previous
/// tab, so an unknown or closed one would be resurrected there as a phantom
/// tab. The memo itself is unaffected — deduping still works off the last tab
/// announced, registered or not.
final class ExtensionActiveTabTracker {

    private weak var lastAnnounced: BrowserTab?

    /// Announce `tab` as the window's active tab unless it already is.
    ///
    /// A nil `tab` (nothing selected) only clears the memo: "no active tab" has
    /// no notification in WebKit, so the next real activation is announced with
    /// no previous tab rather than a stale one. A nil `profile` (a window with
    /// no space yet) likewise announces nothing and remembers nothing.
    func announce(_ tab: BrowserTab?, in profile: Profile?) {
        guard let tab else {
            lastAnnounced = nil
            return
        }
        guard tab !== lastAnnounced, let profile else { return }
        let previous = lastAnnounced.flatMap { $0.extensionRegisteredProfile === profile ? $0 : nil }
        lastAnnounced = tab
        ExtensionTabLifecycle.didActivate(tab, previousActiveTab: previous, in: profile)
    }
}
