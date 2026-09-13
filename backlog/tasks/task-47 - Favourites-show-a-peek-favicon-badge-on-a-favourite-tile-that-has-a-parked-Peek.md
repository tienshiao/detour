---
id: TASK-47
title: >-
  Favourites: show a peek favicon badge on a favourite tile that has a parked
  Peek
status: To Do
assignee: []
created_date: '2026-09-13 06:15'
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
- [ ] #1 A favourite tile whose backing tab has a live or parked Peek shows the peek favicon as a smaller badge in the tile's top-right corner over a rounded backing; the main favicon stays centred and unchanged
- [ ] #2 A favourite tile with no Peek renders exactly as today (no badge, no reserved space)
- [ ] #3 The badge appears when a Peek is opened on the selected favourite, updates when the peek navigates to a page with a different favicon, and disappears when the Peek is closed, without reselecting the favourite
- [ ] #4 After relaunch a favourite with a persisted Peek shows the badge once the peek favicon download completes
- [ ] #5 The badge is not drawn for pinned or normal tab rows (their existing TabCellView badge is unchanged)
- [ ] #6 Unit tests cover the tile's badge visibility/state given a favourite with and without a peek favicon, and the sidebar refresh path for a favourite host
<!-- AC:END -->
