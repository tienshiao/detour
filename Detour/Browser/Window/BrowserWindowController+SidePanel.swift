import AppKit
import WebKit

// TASK-132.8: which extension side panel this window shows, and showing it.
//
// The decision is `ExtensionSidePanelController.reconcile()`'s, made for every
// window at once; this is the window's half — what it is displaying, and
// putting a panel's view beside the tab content (`SidePanelLayoutView`).

extension BrowserWindowController {

    /// The tabs whose live web views this window is showing, most relevant
    /// first: the presented peek, the selected tab (in a split, the focused
    /// pane), then the other pane. Empty when the window shows a snapshot —
    /// another window owns the web view — or nothing, so a tab's panel only
    /// ever shows in the window that owns the tab's web view.
    var sidePanelDisplayedTabs: [BrowserTab] {
        guard !hasClosed, ownsWebView, let tab = selectedTab else { return [] }
        var tabs: [BrowserTab] = []
        if peekOverlayView != nil, let peek = tab.peekTab { tabs.append(peek) }
        tabs.append(tab)
        tabs.append(contentsOf: splitMembers(of: tab).filter { $0 !== tab })
        return tabs
    }

    /// The panel beside this window's tab content, if any.
    var displayedSidePanel: ExtensionSidePanel? {
        (contentAreaView.panelView as? ExtensionSidePanelView)?.panel
    }

    /// Whether the layout still holds a panel's view — true for a moment after
    /// a panel closed, when its view is gone from the window but the tab
    /// content has not been given the width back yet.
    var isHoldingSidePanelView: Bool {
        contentAreaView.panelView != nil
    }

    /// Puts `panel` beside the tab content, or takes the panel away for nil.
    /// The panel's web view is only moved, never reloaded. Called by
    /// `ExtensionSidePanelController.reconcile()`.
    func showSidePanel(_ panel: ExtensionSidePanel?) {
        let leaving = contentAreaView.panelView
        let wanted = panel?.view
        if leaving === wanted, wanted == nil || wanted?.superview === contentAreaView { return }
        // The keys must not stay with a panel that is leaving the window.
        let leavingHadFocus = leaving.map { view in
            (window?.firstResponder as? NSView)?.isDescendant(of: view) ?? false
        } ?? false
        contentAreaView.setPanel(wanted)
        if leavingHadFocus, leaving !== wanted {
            restoreWebContentFocus()
        }
    }

    /// Settles the side panels after this window changed what it displays.
    func settleSidePanels() {
        ExtensionSidePanelController.reconcile()
    }
}
