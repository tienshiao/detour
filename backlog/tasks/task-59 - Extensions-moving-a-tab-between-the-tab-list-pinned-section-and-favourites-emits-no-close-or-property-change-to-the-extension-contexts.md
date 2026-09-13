---
id: TASK-59
title: >-
  Extensions: moving a tab between the tab list, pinned section and favourites
  emits no close or property change to the extension contexts
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
labels:
  - extensions
  - favorites
  - tabs
dependencies: []
priority: low
ordinal: 59000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-52 review. TabStore.addFavorite(from:) (TabStore.swift ~1027) carries a comment saying the tab was just detached from its section, which reported it closed to the extension contexts, and that the favorites didSet re-opens it. Neither half is true today: detachTab (~1885) and detachPinnedEntry (~1895) only remove the tab from the list and post the sidebar notification (the TASK-52 container hooks report placement only, removal has no hook), and the favorites didSet -> didPlace is deliberately silent for a tab whose extensionRegisteredProfile is already set. So the net effect of dragging a live tab or pinned entry to the favourites bar is: no didClose, no didOpen, no didChangeProperties. The tab stays registered under the same profile, which is the right end state for a same-profile move, but the contexts are never told that its pinned flag, its index, or its window membership changed. The same silent hand-off applies to the reverse moves (restoreFavoriteAsTab, restoreFavoriteAsPinned) and to the tab list <-> pinned moves if they also bypass the lifecycle.

Decide the rule and make the code match it: either (a) treat a section move as a close + re-open (what the comment claims; simplest, and matches how a profile swap is handled), or (b) keep the registration and announce the change with ExtensionTabLifecycle.didChangeProperties (WKWebExtension.TabChangedProperties for pinned and whatever else the window enumeration exposes) at every hand-off. Then fix the addFavorite comment. Check what pinTab / unpinTab already do so the four moves are consistent.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Every live-tab move between the tab list, pinned section and favourites (both directions, all six pairs that exist) reports to the contexts under one documented rule: either close + reopen, or a didChangeProperties with the changed properties
- [ ] #2 After dragging a pinned entry to favourites, tabs.query({pinned: true}) from an extension in that profile no longer returns the tab, and tabs.get still resolves it
- [ ] #3 The comment on addFavorite(from:) describes what actually happens
- [ ] #4 Unit tests with the ExtensionTabLifecycle notifier spy cover each move and assert the exact sequence of lifecycle calls
<!-- AC:END -->
