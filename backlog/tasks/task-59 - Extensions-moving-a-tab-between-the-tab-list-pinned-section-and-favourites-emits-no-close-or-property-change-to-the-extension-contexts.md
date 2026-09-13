---
id: TASK-59
title: >-
  Extensions: moving a tab between the tab list, pinned section and favourites
  emits no close or property change to the extension contexts
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 17:31'
updated_date: '2026-09-13 19:00'
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
- [x] #1 Every live-tab move between the tab list, pinned section and favourites (both directions, all six pairs that exist) reports to the contexts under one documented rule: either close + reopen, or a didChangeProperties with the changed properties
- [x] #2 After dragging a pinned entry to favourites, tabs.query({pinned: true}) from an extension in that profile no longer returns the tab, and tabs.get still resolves it
- [x] #3 The comment on addFavorite(from:) describes what actually happens
- [x] #4 Unit tests with the ExtensionTabLifecycle notifier spy cover each move and assert the exact sequence of lifecycle calls
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Rule (decided): a same-profile move between the tab list, pinned section and favourites keeps the tab registered with the contexts (no close/reopen). What changes for an extension is the pinned flag, so the move announces WKWebExtension.TabChangedProperties.pinned when that flag changes; a move that leaves it unchanged (tab list <-> favourites) announces nothing. Cross-space moves are TASK-38 and are not covered here.
2. Make pinned real: add isPinned(for:) to WKExtensionTabConformance (true when a space pinnedEntries entry backs the tab; add a TabStore helper such as isPinnedTab(_:) that checks every space). Today the conformance omits it, so extensions always see pinned=false.
3. Add ExtensionTabLifecycle.didChangePinned(_ tab:) (no-op for an unregistered tab) that sends didChangeProperties(.pinned). Call it from every hand-off that changes the flag: pinTab, unpinTab, pinSplitGroup/unpinSplitGroup, detachPinnedEntry -> addFavorite (the sidebar drop handler; put the call where the tab lands, i.e. in addFavorite(from:) when the source was pinned, or in the store move helper), restoreFavoriteAsPinned, and the closePinnedTab/unpin undo paths. Audit the other section moves and confirm they leave the flag unchanged.
4. Fix the addFavorite(from:) comment to describe the actual behaviour (the detach does not close; the favorites didSet is silent for a registered tab; the registration is kept on purpose).
5. Tests: extend ExtensionTabLifecycleTests with the RecordingNotifier (record the properties on .change): for each move assert the exact lifecycle sequence (no open/close; exactly one .pinned change when the flag flips, none otherwise), plus a conformance test that isPinned(for:) reflects the section.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Rule: a same-profile move between the tab list, pinned section and favourites keeps the registration; only a pinned flip is announced (didChangePinned -> TabChangedProperties.pinned). isPinned(for:) added to the conformance via TabStore.isPinned(_:). Review: the two-call UI composition (detach then addFavorite) could strand a live registered tab when addFavorite refused a URL-less tab, so the move is now TabStore.moveTabToFavorites which validates before detaching and announces the flip itself; tabStoreDidDetachTab was dropped again (teardown is the close point, a plain remove is right); unpin announces the flip only for tabs the contexts knew as pinned. API Explorer gained a Query Pinned Tabs button and pin marker. AC #2 verified at store/conformance level, not from JS.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Section moves keep the extension registration and announce the pinned flag when it flips; extensions now see a real pinned flag. Verified by ExtensionTabLifecycleTests sequences per move plus the existing favourites/pinned suites.
<!-- SECTION:FINAL_SUMMARY:END -->
