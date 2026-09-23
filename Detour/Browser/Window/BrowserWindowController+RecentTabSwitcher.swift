import AppKit
import WebKit

// MARK: - Control+Tab recent-tab switcher (TASK-108)

extension BrowserWindowController {

    /// Width, in pixels, of a switcher preview. Cards are at most 200 pt
    /// wide, so this stays sharp on a Retina display while keeping a preview
    /// under 1 MB.
    static let switcherPreviewPixelWidth: CGFloat = 480

    func setupRecentTabSwitcher(for window: NSWindow) {
        let switcher = RecentTabSwitcher(window: window)
        switcher.entries = { [weak self] in self?.recentTabSwitcherEntries() ?? [] }
        switcher.willBegin = { [weak self] in self?.captureVisibleSwitcherPreviews() }
        switcher.didChoose = { [weak self] entry in
            guard let self, entry.focusTabID != self.selectedTabID else { return }
            self.selectTab(id: entry.focusTabID)
            self.tabSidebar.scrollSelectedRowToVisible()
        }
        recentTabSwitcher = switcher
    }

    /// The active space's live tabs — pinned, favourite and normal, a split as
    /// one entry — in switcher order. Dormant pinned entries and favourites
    /// have no tab, so they are never offered; Peeks are not tabs.
    func recentTabSwitcherEntries() -> [RecentTabSwitcher.Entry] {
        guard let space = activeSpace else { return [] }
        let live = space.pinnedEntries.compactMap(\.tab)
            + (space.profile?.favorites.compactMap(\.tab) ?? [])
            + space.tabs

        var seen = Set<UUID>()
        var items: [[BrowserTab]] = []
        for tab in live where !seen.contains(tab.id) {
            let members = splitMembers(of: tab)
            members.forEach { seen.insert($0.id) }
            items.append(members)
        }

        let itemsByFirstID = Dictionary(items.map { ($0[0].id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = items.map { members in
            RecentTabCandidate(tabIDs: members.map(\.id),
                               lastLeftAt: members.compactMap(\.switcherPreviewAt).max())
        }
        return recentTabOrder(candidates, selectedTabID: selectedTabID).compactMap { candidate in
            guard let members = itemsByFirstID[candidate.tabIDs[0]] else { return nil }
            return RecentTabSwitcher.Entry(tabs: members, focusTabID: switcherFocusTab(of: members).id,
                                           isCurrent: members.contains { $0.id == selectedTabID })
        }
    }

    /// The pane a chosen split focuses: the current one, else this window's
    /// remembered pane (as a sidebar click would), else the one left last.
    private func switcherFocusTab(of members: [BrowserTab]) -> BrowserTab {
        if let selected = members.first(where: { $0.id == selectedTabID }) { return selected }
        if members.count > 1, let space = activeSpace,
           let groupID = store.splitGroup(containing: members[0].id, in: space)?.groupID,
           let remembered = members.first(where: { $0.id == lastFocusedSplitMember[groupID] }) {
            return remembered
        }
        return members.max { ($0.switcherPreviewAt ?? .distantPast) < ($1.switcherPreviewAt ?? .distantPast) } ?? members[0]
    }

    /// The panes on screen now get fresh pictures, so the current card shows
    /// the page as it is (including a tab visited for the first time).
    private func captureVisibleSwitcherPreviews() {
        guard let tab = selectedTab else { return }
        splitMembers(of: tab).forEach(captureSwitcherPreview(of:))
    }

    /// Pictures `tab` if its web view is on screen in this window. Never
    /// hosts or wakes a hidden tab to do so — every show of a page costs GPU
    /// surfaces (TASK-104) — so a failed capture keeps the older picture.
    ///
    /// WebKit renders the snapshot in the web process and answers ~50 ms
    /// later, still correctly after the view has left the window (a
    /// synchronous `cacheDisplay` capture blocked the tab switch for as long);
    /// a newer request for the same tab supersedes a pending one.
    func captureSwitcherPreview(of tab: BrowserTab) {
        guard window?.isVisible == true,
              let webView = tab.webView, webView.isDescendant(of: contentContainerView),
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let config = WKSnapshotConfiguration()
        let scale = window?.backingScaleFactor ?? 2
        // Points; the image comes back at the backing scale.
        config.snapshotWidth = NSNumber(value: Double(Self.switcherPreviewPixelWidth / scale))
        tab.switcherPreviewRequest += 1
        let request = tab.switcherPreviewRequest
        webView.takeSnapshot(with: config) { [weak self, weak tab] image, _ in
            guard let tab, let image, tab.switcherPreviewRequest == request else { return }
            tab.switcherPreview = image
            self?.recentTabSwitcher?.previewDidChange()
        }
    }
}
