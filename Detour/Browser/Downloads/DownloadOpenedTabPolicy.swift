import Foundation

/// What happens to a tab opened for a link whose response turned out to be a
/// download (TASK-205): a Cmd+click or `target=_blank` link, a link a route
/// sent to another space or window, a typed URL in a new tab. WebKit hands
/// the response to the download and the tab is left empty, with nothing
/// committed and the URL as its title; a routed link has also switched a
/// window's space or brought another window forward, for nothing.
enum DownloadOpenedTabPolicy {

    /// The tab a navigation became a download in.
    struct Tab: Equatable {
        /// A tab of the space's normal list: not a pinned entry's or a
        /// favourite's backing tab, which stand for something the user kept.
        let isNormalTab: Bool
        /// The tab's web view has a page in its back-forward list: it showed
        /// something (or was restored with a session to show), so the download
        /// left it on that page rather than empty.
        let hasCommittedPage: Bool
    }

    /// Whether the tab closes once its download has started.
    static func closesTab(_ tab: Tab) -> Bool {
        tab.isNormalTab && !tab.hasCommittedPage
    }

    /// What a routed link changed to show its tab, recorded on the tab when
    /// it is placed.
    struct RoutedOpen<Window: Hashable>: Equatable {
        /// The window the link was clicked in.
        let sourceWindow: Window?
        /// The window the tab was placed in.
        let placedWindow: Window
        /// The placed window was opened for this tab.
        let placedWindowWasCreated: Bool
        /// The placed window is a Private window, so the download is in its
        /// own list and closing it would cancel the download (TASK-156).
        let placedWindowIsPrivate: Bool
        /// The space the placed window showed before it switched to the
        /// tab's, or nil when it did not switch.
        let placedWindowPreviousSpaceID: UUID?
        /// The space the tab was placed in.
        let routedSpaceID: UUID
    }

    /// The windows when the download starts.
    struct Windows<Window: Hashable>: Equatable {
        /// Every browser window still open.
        let open: Set<Window>
        /// The key window if it is a browser window, else Detour's front
        /// browser window (another app or a non-browser window is key).
        let key: Window?
        /// The space each open window shows.
        let activeSpaceID: [Window: UUID]
    }

    enum Step<Window: Hashable>: Equatable {
        case closeWindow(Window)
        case switchSpace(Window, to: UUID)
        case bringToFront(Window)
    }

    /// How to put the windows back after the routed tab closed, in order:
    /// the window opened for it closes, or the window switched for it goes
    /// back to its space, and then the window the link was clicked in comes
    /// to the front again.
    ///
    /// Only while the placed window is still key and still showing the routed
    /// space: a download is decided within moments of the click, and a user
    /// who has gone to another window or space by then is not pulled back.
    ///
    /// A Private window opened for the tab is left as it is, in front: the
    /// download is listed only there, and closing the window would cancel it.
    static func restoration<Window>(of open: RoutedOpen<Window>, windows: Windows<Window>) -> [Step<Window>] {
        let placed = open.placedWindow
        guard windows.open.contains(placed), windows.key == placed,
              windows.activeSpaceID[placed] == open.routedSpaceID else { return [] }
        if open.placedWindowWasCreated && open.placedWindowIsPrivate { return [] }
        var steps: [Step<Window>] = []
        if open.placedWindowWasCreated {
            steps.append(.closeWindow(placed))
        } else if let previous = open.placedWindowPreviousSpaceID {
            steps.append(.switchSpace(placed, to: previous))
        }
        if let source = open.sourceWindow, source != placed, windows.open.contains(source) {
            steps.append(.bringToFront(source))
        }
        return steps
    }
}
