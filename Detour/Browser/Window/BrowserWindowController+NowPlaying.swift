import AppKit
import Combine

/// A window's now-playing bar state (TASK-192). A class so the window
/// controller's extension can keep it in one stored property.
final class NowPlayingWindowState {
    /// The tab the bar shows; nil while hidden.
    var shownTabID: UUID?
    var updateScheduled = false
    /// Fires when a quiet tab's grace runs out (`NowPlayingRule.nextExpiry`).
    var expiryTimer: Timer?
    /// The shown tab's title and favicon, which the bar draws.
    var shownTabSubscriptions = Set<AnyCancellable>()
    var artworkURL: URL?
    var artwork: NSImage?
}

/// The now-playing bar, window side (TASK-192). Each window looks at every tab
/// it could switch to, in any space, and asks `NowPlayingRule` which one the
/// bar shows. It looks again whenever a tab reports a change
/// (`BrowserTab.nowPlayingDidChangeNotification`), when its own selection
/// changes, and when a quiet tab's grace runs out.
extension BrowserWindowController {

    @objc func nowPlayingDidChange(_ notification: Notification) {
        scheduleNowPlayingUpdate()
    }

    /// Coalesces the burst of changes one event makes (a tab switch, a close)
    /// into one evaluation on the next turn of the run loop.
    func scheduleNowPlayingUpdate() {
        guard !nowPlaying.updateScheduled else { return }
        nowPlaying.updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.nowPlaying.updateScheduled = false
            self.updateNowPlayingBar()
        }
    }

    /// Every tab this window can switch to, and whether it is Private: a
    /// normal window's normal spaces (their tabs, pinned tabs, and their
    /// profiles' favourites); a Private window's own space only.
    func nowPlayingTabs() -> [(tab: BrowserTab, isPrivate: Bool)] {
        let spaces = isIncognito ? (activeSpace.map { [$0] } ?? []) : store.spaces.filter { !$0.isIncognito }
        var seen = Set<UUID>()
        var result: [(tab: BrowserTab, isPrivate: Bool)] = []
        for space in spaces {
            for tab in space.tabs + space.pinnedTabs + (space.profile?.favoriteTabs ?? [])
            where seen.insert(tab.id).inserted {
                result.append((tab, space.isIncognito))
            }
        }
        return result
    }

    func updateNowPlayingBar() {
        nowPlaying.expiryTimer?.invalidate()
        nowPlaying.expiryTimer = nil

        let tabs = nowPlayingTabs()
        let candidates = tabs.map { $0.tab.nowPlayingCandidate(isPrivate: $0.isPrivate) }
        let visibleTabs = selectedTab.map(splitMembers(of:)) ?? []
        // Another window's bar may have suspended a tab this window shows.
        for tab in visibleTabs { tab.liftMediaSuspensionFromBar() }
        let visible = Set(visibleTabs.map(\.id))
        let now = Date()
        let shownID = NowPlayingRule.tabToShow(candidates, visibleTabIDs: visible,
                                               windowIsPrivate: isIncognito, now: now)
        if let expiry = NowPlayingRule.nextExpiry(candidates, now: now) {
            let timer = Timer(fire: expiry.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
                self?.scheduleNowPlayingUpdate()
            }
            RunLoop.main.add(timer, forMode: .common)
            nowPlaying.expiryTimer = timer
        }

        let shown = shownID.flatMap { id in tabs.first { $0.tab.id == id }?.tab }
        if shown?.id != nowPlaying.shownTabID {
            nowPlaying.shownTabID = shown?.id
            nowPlaying.shownTabSubscriptions.removeAll()
            if let shown {
                // The bar draws these; they are not now-playing changes.
                shown.$title.dropFirst().removeDuplicates()
                    .sink { [weak self] _ in self?.scheduleNowPlayingUpdate() }
                    .store(in: &nowPlaying.shownTabSubscriptions)
                shown.$favicon.dropFirst()
                    .sink { [weak self] _ in self?.scheduleNowPlayingUpdate() }
                    .store(in: &nowPlaying.shownTabSubscriptions)
            }
        }
        tabSidebar.setNowPlaying(shown.map(nowPlayingModel(for:)))
    }

    private func nowPlayingModel(for tab: BrowserTab) -> NowPlayingBarModel {
        let session = tab.mediaSession
        loadNowPlayingArtwork(session?.artworkURL, for: tab)
        return NowPlayingBarModel(tabID: tab.id, favicon: tab.favicon,
                                  title: session?.title ?? tab.title,
                                  artist: session?.artist,
                                  artwork: nowPlaying.artwork,
                                  isPlaying: tab.isPlayingAudio,
                                  isMuted: tab.isMuted,
                                  canGoPrevious: tab.canPerformMediaSessionAction(.previoustrack),
                                  canGoNext: tab.canPerformMediaSessionAction(.nexttrack),
                                  canMute: PageMediaControl.canMutePage)
    }

    /// The page's artwork (an http or https URL, `MediaSessionReport.artworkURL`),
    /// fetched outside the page by `MediaArtworkLoader`: no cookies, no disk
    /// cache, capped, one fetch per tab.
    private func loadNowPlayingArtwork(_ url: URL?, for tab: BrowserTab) {
        guard url != nowPlaying.artworkURL else { return }
        nowPlaying.artworkURL = url
        nowPlaying.artwork = nil
        guard let url else { return }
        // A window only ever shows a tab of its own kind (`NowPlayingRule`).
        MediaArtworkLoader.shared.load(url, tabID: tab.id, isPrivate: isIncognito) { [weak self] image in
            guard let self, self.nowPlaying.artworkURL == url, let image else { return }
            self.nowPlaying.artwork = image
            self.scheduleNowPlayingUpdate()
        }
    }

    // MARK: Controls

    func tabSidebar(_ sidebar: TabSidebarViewController, didRequestNowPlaying action: NowPlayingBarAction, tabID: UUID) {
        guard let tab = nowPlayingTabs().first(where: { $0.tab.id == tabID })?.tab else { return }
        switch action {
        case .selectTab: revealNowPlayingTab(tab)
        case .previous: tab.performMediaSessionAction(.previoustrack)
        case .next: tab.performMediaSessionAction(.nexttrack)
        case .playPause: tab.togglePlayPauseFromBar()
        case .toggleMute: tab.toggleMute()
        case .dismiss: tab.dismissFromNowPlaying()
        }
    }

    /// Selects the playing tab, switching to its space when it is not in the
    /// active one. A favourite shows in every space of its profile, so the
    /// active space is tried first.
    func revealNowPlayingTab(_ tab: BrowserTab) {
        if activeSpace?.displayableTab(id: tab.id) != nil {
            selectTab(id: tab.id)
            return
        }
        guard !isIncognito,
              let space = store.spaces.first(where: { !$0.isIncognito && $0.displayableTab(id: tab.id) != nil }) else { return }
        setActiveSpace(id: space.id, selectTab: false)
        selectTab(id: tab.id)
    }
}
