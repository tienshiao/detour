---
id: TASK-42
title: >-
  Favourites: cross-host link clicks in a favourite's tab should open a Peek,
  matching pinned tabs
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 04:58'
updated_date: '2026-09-13 06:09'
labels:
  - bug
  - favourites
  - peek
dependencies: []
priority: medium
ordinal: 42000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Pinned tabs open a Peek overlay when a link click navigates to a different host than the pinned URL (BrowserWindowController+Navigation.swift decidePolicyFor navigationAction: the intercept looks up the selected tab in activeSpace.pinnedEntries and compares navigationAction.request.url.host against pinnedEntry.pinnedURL.host, only for .linkActivated on the tab's own webView with no Peek already open). Favourites (Favorite.tab, living in profile.favorites, shown in FavoritesBarView) never take that branch because the lookup only consults pinned entries, so a cross-host click in a favourite's tab navigates the favourite's web view away in place. Favourites are the same product concept as pinned tabs (a durable, anchored page) and should follow the same Peek rules: same host comparison against the favourite's anchor URL (Favorite.url), same modifier precedence (Cmd new tab, Shift peek, Option split, then the cross-host intercept), same exclusions (not while a Peek is open, not on the peek web view itself, not for non-link navigations), and the same Peek lifecycle behaviour already implemented for pinned tabs (the overlay follows the host tab across tab switches via restorePeekOverlayIfNeeded, PiP handoff, sleep saves peek state, close clears it, ExtensionManager's peek enumeration in Profile.swift). Also check whether peek persistence (peekURL / peekInteractionState / peekFaviconURL on TabRecord, restored on relaunch) reaches favourite backing tabs the way it reaches pinned backing tabs; if favourites' backing tabs are not persisted through TabRecord, decide and document whether favourite peeks survive relaunch. Extract the shared 'anchor host for this tab' resolution into one helper (pinned entry or favourite) so the two code paths cannot drift, and cover it with unit tests.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A link click in a favourite's tab whose target host differs from the favourite's URL host opens a Peek overlay instead of navigating the favourite's web view
- [x] #2 A link click in a favourite's tab to the same host navigates in place, exactly as for pinned tabs
- [x] #3 The intercept does not fire when a Peek is already open, when the navigation comes from the peek web view, or when navigationType is not .linkActivated (matches pinned behaviour)
- [x] #4 Cmd+click and Shift+click keep their existing precedence over the cross-host intercept for favourite tabs, as they do for pinned tabs
- [x] #5 The Peek opened from a favourite is restored when switching away from and back to the favourite's tab, and is torn down when the favourite's tab closes or goes dormant, the same as a pinned tab's Peek
- [x] #6 The pinned and favourite paths share one anchor-host resolution helper, with unit tests covering pinned, favourite, and plain-tab (no anchor) cases
- [x] #7 A Peek opened from a favourite's tab survives relaunch: peek URL, interaction state, and peek favicon are persisted for favourite backing tabs and restored on launch, matching pinned tabs (schema migration and docs/data-model.md updated if favourites need new columns)
- [x] #8 Persistence tests cover the favourite peek round trip (save, relaunch-style reload, restore), alongside the existing PeekStateTests
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Add a pure helper (new file Detour/Browser/Window/PeekAnchor.swift, enum PeekAnchor): anchorURL(forTabID:pinnedEntries:favorites:) -> URL? returns the pinned entry's pinnedURL or the favourite's url whose LIVE tab has that id, else nil; shouldPeekCrossHostNavigation(anchorURL:to:) -> Bool is true only when both hosts exist and differ.
2. BrowserWindowController+Navigation.decidePolicyFor: replace the activeSpace.pinnedEntries lookup with PeekAnchor over activeSpace.pinnedEntries + activeSpace.profile?.favorites; keep every other condition and the branch order (Cmd, Shift, Option, then the cross-host intercept) unchanged.
3. TabStore.saveNow: favourite backing TabRecords (sortOrder -2) write tab.peekURL / peekInteractionState / peekFaviconURL instead of nil.
4. TabStore.restoreSession favourites loop: copy peekURL / peekInteractionState / peekFaviconURL from the TabRecord onto the backing tab and call downloadPeekFavicon(), mirroring the pinned branch.
5. Tests: PeekAnchorTests (pinned, favourite, dormant favourite, plain tab, same host, different host, missing host); FavoritePeekPersistenceTests round trip through saveNow + a fresh TabStore(appDB:).restoreSession() for a favourite and, for symmetry, a pinned entry.
6. Lifecycle (AC 5) needs no code: hidePeekUI / restorePeekOverlayIfNeeded / closePeekOverlay key off selectedTab, and deactivateFavorite -> tab.teardown() tears the peek down; verify by reading and note in the task. xcodegen generate, build, run DetourTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: new pure helper Detour/Browser/Window/PeekAnchor.swift (anchorURL(forTabID:pinnedEntries:favorites:) — pinned entries first, then favourites, nil for ordinary/dormant tiles; shouldPeekCrossHostNavigation(anchorURL:to:) — true only when both sides have a host and they differ). BrowserWindowController+Navigation now resolves the anchor through it for pinned tabs AND favourites; every other condition (webView === tab.webView, peekOverlayView == nil, .linkActivated, the async showPeekOverlay) and the branch order (Cmd, Shift, Option, download, peek) are unchanged — verified by reading the diff. TabStore.saveNow now writes peekURL/peekInteractionState/peekFaviconURL on the favourite backing-tab record (sortOrder -2) instead of nil, and restoreSession copies them back onto the favourite's backing tab plus downloadPeekFavicon(), mirroring the pinned branch. Tests: new PeekAnchorTests (11) and FavoritePeekPersistenceTests (3, incl. a pinned symmetry case); targeted run of those plus PeekStateTests/TabStoreTests/ExtensionPageFavoriteTests = 57 passed, 0 failures; full suite 918 tests, 0 failures. Lifecycle (step 6) needed no code change: BrowserWindowController.selectedTab already resolves favourite backing tabs (pinned ?? favorites ?? currentTabs), and hidePeekUI/restorePeekOverlayIfNeeded/closePeekOverlay key only off selectedTab/selectedTab?.peekTab with nothing pinned-specific; TabStore.deactivateFavorite calls tab.teardown(), which tears down and nils peekTab. One benign asymmetry left alone: reloadSelectedTabSidebarCell only covers pinned entries and space.tabs, but the peek favicon badge is a TabCellView (sidebar row) affordance and favourite tiles render no peek badge, so there is nothing to refresh for a favourite.

Code review (--fix) applied: TabStore.removeFavorite now tears down a live backing tab (and its peek) and the window deselects it (was: peek page stranded on screen with no dismiss path after 'Remove from Favorites'); _webViewFullscreenMayReturnToInline now also matches pinned/favourite backing tabs as PiP hosts; peek intercept checks .linkActivated first; PeekAnchor.shouldPeekCrossHostNavigation takes a non-optional anchor; restore-side peek columns go through BrowserTab.applyPersistedPeekState(from:) in all three restoreSession branches; regression test testRemovingFavoriteTearsDownItsBackingTab. Deferred (not fixed): favourite tiles render no parked-peek badge (pinned rows do); a cross-host click in the unfocused pane of a pinned split bypasses the intercept because it anchors on selectedTab; saveNow still builds TabRecord in three hand-copied literals.

Validation: full DetourTests suite after the review fixes: 918 executed, 0 failures, 1 pre-existing skip; Detour app target builds.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Favourites now follow the pinned-tab Peek rule: a new pure PeekAnchor helper resolves a tab's anchor URL from the space's pinned entries or the profile's favourites, and the cross-host intercept in BrowserWindowController+Navigation uses it (all other conditions and the Cmd/Shift/Option precedence unchanged). A favourite's peek persists across relaunch: saveNow writes the peek columns for favourite backing tabs and restoreSession applies them via the new BrowserTab.applyPersistedPeekState(from:), shared by all three restore branches. Review fixes folded in: removeFavorite tears down a live backing tab (and the window deselects it), the fullscreen return-to-inline lookup covers pinned and favourite backing tabs, and the intercept checks .linkActivated first. Verified with PeekAnchorTests, FavoritePeekPersistenceTests, and the full suite (918 tests, 0 failures).
<!-- SECTION:FINAL_SUMMARY:END -->
