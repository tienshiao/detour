---
id: TASK-47
title: >-
  Favourites: show a peek favicon badge on a favourite tile that has a parked
  Peek
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 06:15'
updated_date: '2026-09-13 06:52'
labels:
  - favourites
  - peek
  - ui
dependencies: []
priority: medium
ordinal: 47000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Pinned rows and normal tab rows show a small secondary favicon (TabCellView.peekFaviconImageView, fed by BrowserTab.displayPeekFavicon) when the tab has a Peek open or parked (peekURL persisted, restored on relaunch since TASK-42). Favourite tiles (FavoriteTileView in Sidebar/FavoritesBarView.swift) render only Favorite.displayFavicon, so a favourite with a parked Peek looks ordinary and clicking it drops the user into a full-screen overlay from a prior session with no warning. Desired: the tile keeps its centred main favicon and gains a smaller peek favicon badged in the top-right corner, on a small rounded backing so it reads over any favicon (reference screenshot: main favicon centred, secondary favicon in a rounded chip at the top-right corner of the tile). The badge must stay in sync live: BrowserWindowController.observePeekTab's $favicon sink calls reloadSelectedTabSidebarCell(), which only resolves pinned entries and space.tabs and so no-ops for favourite hosts; closePeekOverlay's reloadSelectedTabSidebarCell() has the same gap; restoreSession's downloadPeekFavicon() completion and Favorite.onFaviconDownloaded need a path that refreshes the tile. Use BrowserTab.displayPeekFavicon (live peek favicon, else the downloaded one) as the source, the same as TabCellView. Follow-up from the TASK-42 code review.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A favourite tile whose backing tab has a live or parked Peek shows the peek favicon as a smaller badge in the tile's top-right corner over a rounded backing; the main favicon stays centred and unchanged
- [x] #2 A favourite tile with no Peek renders exactly as today (no badge, no reserved space)
- [x] #3 The badge appears when a Peek is opened on the selected favourite, updates when the peek navigates to a page with a different favicon, and disappears when the Peek is closed, without reselecting the favourite
- [x] #4 After relaunch a favourite with a persisted Peek shows the badge once the peek favicon download completes
- [x] #5 The badge is not drawn for pinned or normal tab rows (their existing TabCellView badge is unchanged)
- [x] #6 Unit tests cover the tile's badge visibility/state given a favourite with and without a peek favicon, and the sidebar refresh path for a favourite host
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. FavoriteTileView (Sidebar/FavoritesBarView.swift): add a peek badge = small rounded chip view (~14x14, corner radius 4, windowBackgroundColor fill, hairline labelColor@0.15 border) holding a ~10x10 NSImageView, pinned to the tile's top-right with a 2pt inset, hidden by default. Add refreshPeekBadge() reading favorite.tab?.displayPeekFavicon, and an internal showsPeekBadge for tests. Subscribe (Combine, weak) to favorite.tab?.$peekFavicon so the relaunch favicon download refreshes the badge; re-subscribe when the tile is reused and fav.tab changed.
2. FavoritesBarView: refreshTile(forTabID:) -> tile.refreshPeekBadge(); call refreshPeekBadge() on reused tiles in update(favorites:) and on new tiles after init. SpacePageView + TabSidebarViewController forward refreshFavoriteTile(forTabID:).
3. BrowserWindowController.reloadSelectedTabSidebarCell(): add a third branch for favourite hosts (activeSpace.profile.favorites) -> tabSidebar.refreshFavoriteTile(forTabID:). Covers observePeekTab's favicon sink and closePeekOverlay. Also call it after showPeekOverlay presents a new peek so the badge appears immediately once the peek favicon lands (the sink handles that).
4. Tests: FavoriteTileBadgeTests (headless, like TabCellSplitCollapseTests): no tab -> hidden; live tab with peekFavicon -> shown with that image; live tab whose peekTab has a favicon -> shown; clearPeekState + refresh -> hidden; setting tab.peekFavicon publishes -> badge updates; FavoritesBarView.refreshTile(forTabID:) routes to the right tile.
5. xcodegen generate, build, full DetourTests.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented the peek favicon badge on favourite tiles.

Files changed:
- Detour/Browser/Sidebar/FavoritesBarView.swift: FavoriteTileView gains peekBadgeView (14x14 rounded chip, corner radius 4, windowBackgroundColor fill, 0.5pt labelColor@0.15 hairline border) pinned 2pt from the tile's top/trailing edges, holding a 10x10 peekFaviconImageView (scaleProportionallyUpOrDown), added after imageView so it draws over the centred main favicon. Hidden entirely (no reserved space) when favorite.tab?.displayPeekFavicon is nil. New refreshPeekBadge() (idempotent), showsPeekBadge test hook, and bindPeekFavicon() subscribing to tab.$peekFavicon (dropFirst, RunLoop.main, weak self) with boundTab identity tracking so the binding follows a favourite activating/going dormant across tile reuse. setup() calls setupPeekBadge() + refreshPeekBadge(). FavoritesBarView gains refreshTile(forTabID:) and a tile(at:) test accessor, and calls existing.refreshPeekBadge() on reused tiles in update(favorites:); new tiles refresh via their own init.
- Detour/Browser/Sidebar/SpacePageView.swift: refreshFavoriteTile(forTabID:) forwarding to favoritesBar.
- Detour/Browser/Sidebar/TabSidebarViewController.swift: refreshFavoriteTile(forTabID:) forwarding to the active space page.
- Detour/Browser/Window/BrowserWindowController.swift: reloadSelectedTabSidebarCell() gains a third branch for favourite hosts (space.profile?.favorites) -> tabSidebar.refreshFavoriteTile(forTabID:), plus a doc comment.
- DetourTests/FavoriteTileBadgeTests.swift (new, 8 tests): dormant favourite -> no badge; live tab without peek -> no badge; peekFavicon set before tile creation -> badge with that exact image; peekFavicon published after creation (relaunch download) -> badge appears after a run-loop spin; clearPeekState + refresh -> hidden and image cleared; favourite tab swap (dormant -> live) rebinds and observes the new tab; FavoritesBarView.refreshTile(forTabID:) updates only the matching tile; reused tile across two update(favorites:) calls picks up the badge.

Refresh paths verified by reading the code, not just by test: observePeekTab's $favicon sink -> reloadSelectedTabSidebarCell -> refreshFavoriteTile (badge appears/updates on peek open + navigation); closePeekOverlay -> clearPeekState + reloadSelectedTabSidebarCell (badge disappears); TabStore.restoreSession favourite branch -> backingTab.applyPersistedPeekState -> downloadPeekFavicon -> $peekFavicon publish -> the tile's subscription (badge appears post-relaunch once the download lands; if it lands before the tile exists, setup()'s refreshPeekBadge picks it up).

No behaviour change for pinned/normal rows: TabCellView untouched.

Tests: targeted run (FavoriteTileBadgeTests + TabCellSplitCollapseTests + FavoritePeekPersistenceTests) 15 tests, 0 failures. Full DetourTests suite: 926 tests, 0 failures, TEST SUCCEEDED. Detour builds clean.

Deviations from the plan: none of substance. peekFaviconImageView is exposed as a plain internal 'let' (not private(set) var) to match TabCellView's splitFaviconImageView; FavoritesBarView gained an internal tile(at:) accessor for the bar-routing tests as the plan allowed.

Validation after the code-review fixes: full DetourTests 927 executed, 0 failures, 1 pre-existing skip (one earlier full run had a flaky failure in ExtensionPolyfillIntegrationTests.testGapFillingModulesInRealExtensionContext, unrelated to this change; it passed 3/3 in isolation and on the full-suite rerun). Detour app target builds.
<!-- SECTION:NOTES:END -->

## Comments

<!-- COMMENTS:BEGIN -->
created: 2026-09-13 06:42
---
Code review (--fix) of the working tree. Fixed: (1) live peek favicon was never published on the host, so the tile's $peekFavicon subscription only covered the relaunch download and other windows / non-active space pages stayed stale — BrowserWindowController.observePeekTab now mirrors peekTab.favicon (with its URL, under one non-nil guard) onto host.peekFavicon, both at subscribe time (covers a favicon that lands while the peek UI is hidden; dropFirst swallowed it) and in the $favicon sink; (2) reloadSelectedTabSidebarCell's favourites branch is unconditional (refreshTile is a no-op otherwise) and TabSidebarViewController.refreshFavoriteTile refreshes every space page; (3) showPeekOverlay's fresh-peek path tears down an orphaned peek and clears parked state when the URL differs, so a stale parked favicon can't badge/persist for the new peek; (4) peek chip was a plain non-opaque NSView, so clicks on it moved the window (mouseDownCanMoveWindow) — FavoriteTileView.hitTest now resolves to the tile; (5) chip cgColors re-resolve in viewDidChangeEffectiveAppearance (dark-mode switch left a light chip); (6) dropped boundTab identity tracking (unconditional rebind + separate applyPeekBadge), tile(at:) and showsPeekBadge hooks (tileViews is private(set), peekBadgeView internal); (7) testRefreshTileRoutesToTheMatchingFavoriteOnly only passed because the run loop never spun — rewritten around a live peek with a spin, plus a new live-peek precedence test. Kept .receive(on: RunLoop.main) on purpose: @Published emits before storing and displayPeekFavicon re-reads the property. Full DetourTests: 927 tests, 0 failures.
---
<!-- COMMENTS:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Favourite tiles now show a small rounded peek-favicon chip in the top-right corner when the backing tab has a live or parked Peek, hidden entirely otherwise. The tile reads BrowserTab.displayPeekFavicon and subscribes to the tab's published peekFavicon; the window controller mirrors a live peek's favicon onto the host tab (mirrorPeekFavicon) so every window and space page observes it, and reloadSelectedTabSidebarCell falls through to a favourite-tile refresh across all space pages. Review fixes folded in: the chip is decorative for hit-testing (no accidental window drag), chip colours re-resolve on appearance change, and a fresh peek to a different URL tears down an orphaned parked peek so a stale badge cannot persist. Verified with FavoriteTileBadgeTests (headless) and the full suite (927 tests, 0 failures).
<!-- SECTION:FINAL_SUMMARY:END -->
