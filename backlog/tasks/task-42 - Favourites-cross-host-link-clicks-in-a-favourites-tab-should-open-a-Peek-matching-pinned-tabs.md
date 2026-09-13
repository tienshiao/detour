---
id: TASK-42
title: >-
  Favourites: cross-host link clicks in a favourite's tab should open a Peek,
  matching pinned tabs
status: To Do
assignee: []
created_date: '2026-09-13 04:58'
updated_date: '2026-09-13 05:00'
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
- [ ] #1 A link click in a favourite's tab whose target host differs from the favourite's URL host opens a Peek overlay instead of navigating the favourite's web view
- [ ] #2 A link click in a favourite's tab to the same host navigates in place, exactly as for pinned tabs
- [ ] #3 The intercept does not fire when a Peek is already open, when the navigation comes from the peek web view, or when navigationType is not .linkActivated (matches pinned behaviour)
- [ ] #4 Cmd+click and Shift+click keep their existing precedence over the cross-host intercept for favourite tabs, as they do for pinned tabs
- [ ] #5 The Peek opened from a favourite is restored when switching away from and back to the favourite's tab, and is torn down when the favourite's tab closes or goes dormant, the same as a pinned tab's Peek
- [ ] #6 The pinned and favourite paths share one anchor-host resolution helper, with unit tests covering pinned, favourite, and plain-tab (no anchor) cases
- [ ] #7 A Peek opened from a favourite's tab survives relaunch: peek URL, interaction state, and peek favicon are persisted for favourite backing tabs and restored on launch, matching pinned tabs (schema migration and docs/data-model.md updated if favourites need new columns)
- [ ] #8 Persistence tests cover the favourite peek round trip (save, relaunch-style reload, restore), alongside the existing PeekStateTests
<!-- AC:END -->
