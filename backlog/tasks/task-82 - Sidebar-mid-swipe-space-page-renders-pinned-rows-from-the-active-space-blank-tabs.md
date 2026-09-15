---
id: TASK-82
title: >-
  Sidebar: mid-swipe space page renders pinned rows from the active space (blank
  tabs)
status: Done
assignee: []
created_date: '2026-09-15 17:35'
updated_date: '2026-09-15 18:21'
labels:
  - bug
  - sidebar
dependencies: []
priority: medium
ordinal: 82000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Swiping from a space with fewer pinned items (e.g. Work: 0 pinned) to one with more (Home: 2 pinned) shows the incoming page's pinned rows as blank cells (default favicon, empty title). tableView(_:viewFor:row:) sizes the pinned section per page via pinnedItemCountForTableView but reads the cell content from flattenedPinnedItems, which belongs to the active space only; out-of-range rows fall back to an unconfigured TabCellView, in-range rows show the wrong space's entries.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Non-active space pages render their own space's pinned entries, folders and pinned splits mid-swipe
- [x] #2 Pinned item count and pinned cell content for a page come from the same per-page source
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause (two parts): (1) viewFor read pinned cells from the active space's flattenedPinnedItems for every page; (2) non-active pages were never reloaded after first load — a new window briefly has page 0 active with an empty model, so Home's table cached 3 rows with spacer/separator heights and was never reloaded after assignDefaultSpace switched to Work (blank rows, wrong spacing). Folder tint came from the active space's safeTintColor.
Fix: non-active pages render from a per-page InactivePageContent snapshot (pinned items, tab items, tint) captured at reload; pages reload on rebuild, when a page stops being active, and when a swipe/space-button animation starts; while the strip is moving, BrowserWindowController's TabStore callbacks for other spaces call tabSidebar.inactiveSpaceContentDidChange() (coalesced reload). Folder cells and row views use the page's own tint.
Verified with a temporary env-gated harness (reverted) sending synthetic trackpad scroll phases through the real swipe handler in a new window on Work: before fix Home page mid-swipe = 3 rows (2 blank Tab('') cells, one at 12pt); after = 8 rows at correct heights, pink folder tint; a tab added to Home mid-swipe appears immediately. Sidebar/space/split test classes pass.

Code review (--fix): inactive-page snapshot now flattens with space.selectedTabID instead of nil, so an outgoing page whose selected tab sits in a collapsed pinned folder keeps its exposed row aligned with the table's retained selection. Builds.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Non-active sidebar pages render from a per-page snapshot of their own space (pinned items, tab items, tint), reloaded on build, on losing active status, at swipe/click-animation start, and on other-space TabStore changes while the strip moves. Verified via harness before/after and sidebar/space/split test classes.
<!-- SECTION:FINAL_SUMMARY:END -->
