---
id: TASK-34
title: >-
  Favourites: moving an extension-page favourite into the tab list or pinned
  section must give a loadable tab
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 01:41'
labels:
  - extensions
  - tabs
  - bug
dependencies: []
priority: low
ordinal: 34000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-30 work. TabStore.restoreFavoriteAsTab builds the tab for a dormant favourite with space.makeWebViewConfiguration() instead of TabStore.makeTab(loading:) (TASK-24), so a favourite whose URL is a webkit-extension:// page (e.g. an options page) dragged into the tab list becomes a tab that cannot load the scheme. Check restoreFavoriteAsPinned and every other conversion between favourites, pinned entries and tabs (favourite -> pinned, pinned -> favourite, tab -> favourite, drag between sections and across spaces of the same profile) for the same pattern, and for the extension id being carried: a live backing tab moves as-is, a dormant one must be built through makeTab(loading:), and a stored URL on a dead origin must be rehomed with the TASK-28/TASK-30 helpers (rehomedTileURL / classifyCapturedPage), dropping it only if the extension is uninstalled.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Dragging a dormant extension-page favourite into the tab list or the pinned section gives a tab that loads the page on the extension's current origin
- [ ] #2 Every favourite/pinned/tab conversion path is audited; those that can carry an extension page build dormant tabs via makeTab(loading:) and rehome stored URLs; ordinary URLs are unchanged
- [ ] #3 Tests cover favourite -> tab and favourite -> pinned for an extension page (including after a context reload) and one ordinary URL
<!-- AC:END -->
