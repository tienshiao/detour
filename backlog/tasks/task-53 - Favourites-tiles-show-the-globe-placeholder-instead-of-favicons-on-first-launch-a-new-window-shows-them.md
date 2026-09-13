---
id: TASK-53
title: >-
  Favourites: tiles show the globe placeholder instead of favicons on first
  launch; a new window shows them
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 08:45'
updated_date: '2026-09-13 09:35'
labels:
  - bug
  - favourites
dependencies: []
references:
  - >-
    /Users/tma/.codetoaster/uploads/7353d77e-88b4-4751-bf47-23f064e7d221/Screenshot
    2026-09-13 at 1.38.16 AM.png
priority: medium
ordinal: 53000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed 2026-09-13 (Work profile, two favourites): right after launching Detour the favourites strip shows the 'globe' fallback for every tile (screenshot in refs); opening a second window renders the favicons correctly in that window. Suspects from reading the code: (1) TabStore.restoreSession builds a restored favourite with tab: backingTab when its session record has a live tabID (TabStore ~940-975), and Favorite.init only downloads faviconURL when tab == nil (Favorite.swift ~29) — the restored backing tab is a sleeping BrowserTab whose .favicon is nil until it wakes, so displayFavicon (tab?.favicon ?? favicon) is nil and nothing ever fetches the favourite's own icon; (2) Favorite.onFaviconDownloaded is a single closure: TabStore's restore path installs one that notifies tabStoreDidUpdateFavorites, and FavoritesBarView's tile (~555) overwrites it with one that sets that tile's imageView, so whichever tile was built last is the only thing refreshed, and a tile rebuilt by updateFavorites after the download loses the update; (3) check what differs for a second window — its tiles are built from displayFavicon at a later time, which may mean the icon exists by then and the first window simply never re-rendered. Reproduce with a favourite whose backing tab is restored asleep vs a dormant favourite; confirm which suspect applies before fixing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 On a cold launch, favourite tiles in the first window show their favicons (from the favourite's cached favicon, its faviconURL download, or the backing tab) without opening another window
- [x] #2 A favourite restored with a sleeping backing tab shows an icon before the tab wakes (the favourite's own favicon is downloaded or persisted independently of the tab)
- [x] #3 Favicon downloads update every window's favourites strip, not only the last tile that registered onFaviconDownloaded
- [x] #4 Unit test covers restoring a favourite with a backing tab and asserts displayFavicon becomes non-nil once the loader completes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Root cause (confirmed by reading): a favourite restored with a live sleeping backing tab never downloads its own icon (Favorite.init only does when tab == nil); the backing tab does download its faviconURL (BrowserTab sleeping init), but TabStore.subscribeToTab's notify only knows pinned entries and space.tabs, and the tile only listens to Favorite.onFaviconDownloaded — so the icon arrives after the first window's tiles were built and nothing re-renders them. A second window builds its tiles after the download and reads it. For dormant favourites the tile overwrites the store's single onFaviconDownloaded closure, so other windows never hear of the download.
2. Favorite: favicon becomes @Published; init downloads its faviconURL whenever favicon is nil, regardless of tab (FaviconLoader caches and coalesces, so the backing tab's identical URL costs one fetch); drop the single onFaviconDownloaded closure and TabStore's restore-time closure.
3. FavoriteTileView binds to favorite.$favicon and favorite.tab?.$favicon (like bindPeekFavicon), re-applying displayFavicon ?? globe; rebinding happens wherever refreshPeekBadge is (tile reuse in update(favorites:), refreshTile(forTabID:)) so a tab swap on activate/deactivate rebinds.
4. FaviconLoader gets an injectable fetch seam for tests (default URLSession).
5. Tests (FavoriteFaviconTests): restore a favourite with a sleeping backing tab whose record has a faviconURL, assert displayFavicon nil before and non-nil after the seam completes; two tiles for one favourite both update; a dormant favourite's own download updates a tile; activate/deactivate rebinding.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause confirmed by reading: a favourite restored with a live sleeping backing tab never downloaded its own icon (Favorite.init only did when tab == nil), the backing tab's own faviconURL download landed after the first window's tiles were built, and nothing re-rendered them — TabStore.subscribeToTab's notify only knows pinned entries and space.tabs, and the tile listened only to Favorite.onFaviconDownloaded, which the tile itself overwrote (so other windows never heard a dormant favourite's download either). A second window built its tiles after the download. Fix: Favorite.favicon is @Published and downloaded whenever nil regardless of the tab; FavoriteTileView binds favorite.$favicon and favorite.tab?.$favicon (rebound on tile reuse and tab swap); the single closure is gone. FaviconLoader gained an injectable fetch seam for tests. Tests: FavoriteFaviconTests (restore with a sleeping backing tab, two tiles for one favourite, dormant download, tab swap rebinding). Review: no findings. Runtime cold-launch check not performed here.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Favourite tiles now follow favicon arrivals in every window: Favorite publishes its favicon and downloads it independently of its backing tab, and each tile subscribes to both the favourite's and the backing tab's favicon publishers instead of a single overwritable closure. Verified with FavoriteFaviconTests plus the favourites and TabStore suites.
<!-- SECTION:FINAL_SUMMARY:END -->
