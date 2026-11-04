import AppKit
import os

private let log = Logger(subsystem: "com.detourbrowser.mac", category: "downloads")

/// Closes a tab whose first navigation became a download, and puts back what a
/// routed link changed to show it (TASK-205; the rules are
/// `DownloadOpenedTabPolicy`). Called on the main thread by both navigation
/// delegates a tab's web view can have: its window's, and its own before a
/// window claims it.
enum DownloadOpenedTab {

    static func navigationBecameDownload(in tab: BrowserTab?) {
        guard let tab, let space = closingSpace(of: tab) else { return }
        let routedOpen = tab.routedOpen
        // A turn later: the delegate callback returns before the web view that
        // made it is torn down. The download goes on without it, held by
        // `DownloadManager`.
        DispatchQueue.main.async {
            guard closingSpace(of: tab) === space, let index = space.tabs.firstIndex(where: { $0 === tab }) else { return }
            log.info("Closing the tab a download was opened in: it never showed a page")
            MainActor.assumeIsolated {
                // A window showing the tab moves its selection the way a close
                // does (the opener, a split partner), not the removal
                // observer's plain neighbour.
                for wc in NSApp.browserWindowControllersFrontToBack
                where wc.activeSpaceID == space.id && wc.selectedTabID == tab.id {
                    wc.settlingSelectionForClose { wc.settleSelectionLeaving(tabAt: index, in: space) }
                }
            }
            TabStore.shared.closeTab(id: tab.id, in: space, undoable: false)
            if let routedOpen = routedOpen?.liveOpen {
                MainActor.assumeIsolated {
                    (NSApp.delegate as? AppDelegate)?.restoreWindows(after: routedOpen)
                }
            }
        }
    }

    /// The space `tab` closes from, or nil when it stays. A tab restored or
    /// put to sleep stands for a page even when its web view, woken without a
    /// saved session, has nothing in its back-forward list yet.
    private static func closingSpace(of tab: BrowserTab) -> Space? {
        let space = tab.spaceID.flatMap { TabStore.shared.space(withID: $0) }
        let closes = DownloadOpenedTabPolicy.closesTab(.init(
            isNormalTab: space?.tabs.contains { $0 === tab } == true,
            hasCommittedPage: tab.standsForSavedPage || tab.webView?.backForwardList.currentItem != nil))
        return closes ? space : nil
    }
}

/// What a routed link changed to show its tab (TASK-205), kept on the tab.
/// The windows are held weakly next to the record so that one which has gone
/// by the time the download starts is not mistaken for a window allocated at
/// its address since.
final class RoutedOpenRecord {
    let open: DownloadOpenedTabPolicy.RoutedOpen<ObjectIdentifier>
    weak var sourceWindow: BrowserWindowController?
    weak var placedWindow: BrowserWindowController?

    init(open: DownloadOpenedTabPolicy.RoutedOpen<ObjectIdentifier>,
         sourceWindow: BrowserWindowController?, placedWindow: BrowserWindowController) {
        self.open = open
        self.sourceWindow = sourceWindow
        self.placedWindow = placedWindow
    }

    /// The record with the windows still alive, or nil when the placed window
    /// is gone (there is nothing to put back).
    var liveOpen: DownloadOpenedTabPolicy.RoutedOpen<ObjectIdentifier>? {
        guard let placedWindow, ObjectIdentifier(placedWindow) == open.placedWindow else { return nil }
        return .init(sourceWindow: sourceWindow.map(ObjectIdentifier.init), placedWindow: open.placedWindow,
                     placedWindowWasCreated: open.placedWindowWasCreated,
                     placedWindowIsPrivate: open.placedWindowIsPrivate,
                     placedWindowPreviousSpaceID: open.placedWindowPreviousSpaceID,
                     routedSpaceID: open.routedSpaceID)
    }
}
