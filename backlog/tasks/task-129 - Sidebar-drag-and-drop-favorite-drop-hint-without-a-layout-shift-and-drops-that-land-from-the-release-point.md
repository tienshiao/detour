---
id: TASK-129
title: >-
  Sidebar drag and drop: favorite drop hint without a layout shift, and drops
  that land from the release point
status: Done
assignee:
  - '@claude'
created_date: '2026-10-02 03:05'
updated_date: '2026-10-02 03:21'
labels: []
dependencies: []
priority: medium
ordinal: 129000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two animation complaints about sidebar drag and drop. (1) On a page with no favorites, starting a tab drag grows the favorites bar to show 'Drop to add favorite', which shifts the whole tab list down on every drag. The hint is wanted (discovery), the shift is not. (2) After a drop the dragged row animates from its ORIGIN to the drop spot; it should feel direct — the proxy that was tracking the mouse travels from the release point to the drop spot.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Starting a tab drag on a page without favorites shows the 'Drop to add favorite' hint without moving the space header or the tab list
- [x] #2 The hint still accepts a tab or pinned-entry drop and adds the favorite; it is not shown for drags that cannot become favorites (folders, splits)
- [x] #3 A row dropped in the tab list or pinned section (reorder, pin, unpin, folder move) arrives from the release point; the real row is not seen travelling from its origin
- [x] #4 Favorite drops (tab to bar, reorder within the bar, favorite to list) start from the release point instead of the source position
- [x] #5 Split create/break drops keep their current in-row reveal animation
- [x] #6 Unit tests cover which drop commands land as a whole row
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Hint: FavoriteDropHintView overlays the space header (fixed height, no constraint changes) and cross-fades with it while an eligible drag is live on a page without favorites; it is its own drop target and forwards to FavoritesBarView. Remove the height-growing drop zone from the bar.
2. Row drops: at acceptDrop take the drag image over as an overlay proxy at the release frame; when the resulting state is applied (sync or deferred), hide the destination row, fly the proxy to it, then reveal. Own proxy rather than NSDraggingInfo.animatesToDestination, so it works for the deferred drop transactions and does not keep the drag session alive during table batch updates.
3. Favorites: tile add / reorder and favorite-to-list insertion start from the drop point.
4. SidebarDropCommand.landsAsWholeRow decides which commands get the landing (split create/break keep the in-row reveal); unit test it.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented (uncommitted, on main's working tree). Hint: FavoriteDropHintView overlays the space header; harness run showed scroll view frame identical before/after the hint appears (0,32 220x944), favorites bar height stays 0. Landing: own overlay proxy instead of NSDraggingInfo.animatesToDestination, so deferred drop transactions work too; table batch update is paced to the proxy's 0.2 s flight (NSAnimationContext duration around begin/endUpdates) — without that the row's own slide ran ~0.4 s and was revealed mid-travel. Harness traces (stub NSDraggingInfo, presentation-layer frames every 25 ms): sync reorder and deferred pin both keep the row at alpha 0 until the proxy reaches the row's final frame, then proxy fades. Bug caught by the harness: the no-state-change cancel was queued before the deferred state application, cancelling every transaction drop's landing — now queued after.
NOT verified: a real mouse drag (stub drags skip enumerateDraggingItems, so the proxy's start frame used the pointer-centred fallback, not the session's draggingFrame), and the feel. Favorite reorder-in-bar start position is untested at runtime. Harness saved as .claude/task129-harness.patch (untracked). Tests: SidebarDragDropTests/SidebarLayoutTests/SplitTabTests pass; full suite not run.

Code review (/code-review --fix): one low finding fixed — performTabDrop left pendingAnimationOrigin set after a refused drop, so the next unrelated tile would fly in from the old release point; now cleared after the delegate call (the store notifies synchronously). Also hides the hint on every page at drag end, not only the active one. Harness rerun after both changes: same traces.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The 'Drop to add favorite' hint now overlays the space header (FavoriteDropHintView) instead of growing the favorites bar, so starting a drag no longer shifts the tab list; it is shown only for drags that can become a favorite. Row drops land from the release point: acceptDrop takes the drag image over as an overlay proxy, applyState flies it to the dropped row (0.2 s, table batch update paced to match) while the real row stays hidden. Favorite tile add/reorder and favorite-to-list drops start from the drop point. Split create/break drops keep their in-row reveal (SidebarDropCommand.landsAsWholeRow, unit-tested). Verified with an in-app harness (stub drag info, presentation-layer traces) and the sidebar unit tests; a real mouse drag and the feel of the timing were not exercised.
<!-- SECTION:FINAL_SUMMARY:END -->
