import Foundation

extension TabRecord {
    /// The single mapping from a live `BrowserTab` to its persisted row — the
    /// one place every persisted column is read off the tab (TASK-49).
    ///
    /// `TabStore.saveNow` writes three kinds of row through it, differing only
    /// in what is passed here: normal tabs (`sortOrder` = position in
    /// `space.tabs`, plus the split fields), pinned backing tabs
    /// (`sortOrder` -1) and favourite backing tabs (`sortOrder` -2). `profile`
    /// is the one the row's page is resolved against — the space's, or the
    /// favourite's own — and `extensionID` is derived from it here so that no
    /// site hand-copies the derivation either. Before
    /// TASK-49 those were three hand-copied positional literals, and the
    /// favourite one had already drifted once (its peek columns were written as
    /// nil until TASK-42).
    ///
    /// Decision (TASK-49): favourite backing tabs now persist `lastDeselectedAt`
    /// and `parentID` like every other row, rather than hard-coding them to nil.
    /// Restore does not read either column for a backing tab — they drive
    /// `sleepStaleTabs` and child-tab ordering, both of which only apply to tabs
    /// in `space.tabs` — so nothing changes on load; the special case, and the
    /// drift it invited, go away.
    ///
    /// `splitGroupID`/`splitFraction` stay parameters instead of being read off
    /// the tab because a *pinned* split lives on the pinned entries, never on
    /// the backing tab (see the split-tabs design doc §12): only the normal-tab
    /// site has a group to persist here.
    init(tab: BrowserTab, spaceID: UUID, sortOrder: Int, profile: Profile?,
         splitGroupID: UUID? = nil, splitFraction: Double? = nil) {
        self.init(
            id: tab.id.uuidString,
            spaceID: spaceID.uuidString,
            url: tab.url?.absoluteString,
            title: tab.title,
            faviconURL: tab.faviconURL?.absoluteString,
            interactionState: tab.currentInteractionStateData(),
            sortOrder: sortOrder,
            lastDeselectedAt: tab.lastDeselectedAt?.timeIntervalSince1970,
            parentID: tab.parentID?.uuidString,
            peekURL: tab.peekURL?.absoluteString,
            peekInteractionState: tab.peekInteractionState,
            peekFaviconURL: tab.peekFaviconURL?.absoluteString,
            splitGroupID: splitGroupID?.uuidString,
            splitFraction: splitFraction,
            extensionID: profile?.extensionID(forPageURL: tab.url)
        )
    }
}
