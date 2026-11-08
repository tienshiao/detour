import AppKit

// TASK-292.10: the Help menu. The last menu, registered as `NSApp.helpMenu`
// so macOS adds its menu search field. Each item opens a page of the
// website or of the GitHub project in a new tab of the frontmost normal
// browser window's active space, or in a new window when there is none —
// never in a Quick Detour, quarantine or Private window.

/// The Help menu's pages, in one place.
enum HelpLinks: CaseIterable {
    case detourHelp
    case keyboardShortcuts
    case switchingFromArc
    case releaseNotes
    case reportAnIssue

    /// The GitHub project (scripts/publish-release.sh publishes its releases
    /// there; the website links to it).
    static let gitHubProject = "https://github.com/tienshiao/detour"

    var title: String {
        switch self {
        case .detourHelp: return "Detour Help"
        case .keyboardShortcuts: return "Keyboard Shortcuts"
        case .switchingFromArc: return "Switching from Arc"
        case .releaseNotes: return "Release Notes"
        case .reportAnIssue: return "Report an Issue"
        }
    }

    var url: URL {
        switch self {
        case .detourHelp: return URL(string: "https://detourbrowser.com/features/")!
        case .keyboardShortcuts: return URL(string: "https://detourbrowser.com/shortcuts/")!
        case .switchingFromArc: return URL(string: "https://detourbrowser.com/arc/")!
        case .releaseNotes: return URL(string: "\(Self.gitHubProject)/releases")!
        case .reportAnIssue: return URL(string: "\(Self.gitHubProject)/issues/new")!
        }
    }
}

/// Where a Help page opens.
enum HelpLinkPlacement<ID: Hashable>: Equatable {
    /// A new tab, selected, in this normal window's active space.
    case newTab(in: ID)
    /// A new normal window.
    case newWindow
}

extension HelpLinks {
    /// Where a Help page opens, given the browser windows the most recently
    /// active first: the first normal window that shows a space, else a new
    /// window. Private windows are passed over; Quick Detour and quarantine
    /// windows are not browser windows and are never among `windows`.
    static func placement<ID: Hashable>(windows: [LinkPlacementWindow<ID>]) -> HelpLinkPlacement<ID> {
        windows.first { !$0.isPrivate && $0.activeSpaceID != nil }.map { .newTab(in: $0.id) } ?? .newWindow
    }
}

extension AppDelegate {
    /// The Help menu's item for the main menu.
    func makeHelpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        for (index, link) in HelpLinks.allCases.enumerated() {
            if link == .releaseNotes { menu.addItem(.separator()) }
            let linkItem = menu.addItem(withTitle: link.title, action: #selector(openHelpLink(_:)), keyEquivalent: "")
            linkItem.target = self
            linkItem.tag = index
        }
        item.submenu = menu
        return item
    }

    @objc func openHelpLink(_ sender: NSMenuItem) {
        guard HelpLinks.allCases.indices.contains(sender.tag) else { return }
        openHelpPage(HelpLinks.allCases[sender.tag].url)
    }

    /// Opens `url` where `HelpLinks.placement` says, the window in front.
    /// The browser windows on screen, front to back (a minimized one is
    /// not among them).
    func openHelpPage(_ url: URL) {
        let windows = NSApp.browserWindowControllersFrontToBack
        let placement = HelpLinks.placement(windows: windows.map {
            LinkPlacementWindow(id: ObjectIdentifier($0), activeSpaceID: $0.activeSpaceID, isPrivate: $0.isIncognito)
        })
        switch placement {
        case .newTab(let id):
            guard let wc = windows.first(where: { ObjectIdentifier($0) == id }), let space = wc.activeSpace else {
                return createNewWindowWithURL(url)
            }
            // Selected right away: no "opened in background" toast on a
            // collapsed sidebar.
            let tab = wc.withoutBackgroundTabToast { TabStore.shared.addTab(in: space, url: url, parentID: nil) }
            wc.selectTab(id: tab.id)
            wc.window?.makeKeyAndOrderFront(nil)
        case .newWindow:
            createNewWindowWithURL(url)
        }
    }
}
