---
id: TASK-131
title: 'Sidebar: a focused tab list loses keyboard focus when the space list changes'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-10-02 07:35'
updated_date: '2026-10-02 08:35'
labels:
  - sidebar
  - bug
dependencies: []
priority: low
ordinal: 131000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-130 code review and reproduced in-app on 2026-10-02 (probe: .claude/task131-harness.patch, DETOUR_KEYLOOP_MODE=rebuild). TabSidebarViewController.rebuildPages() tears down every space page and builds new ones whenever the list of space IDs changes (a space added, deleted or reordered — from Settings, another window, or undo/redo of Add Space). If the active space's tab list had keyboard focus (a click on a row puts it there), the list is removed from the window and AppKit leaves the window itself as first responder: nothing is focused, and arrow keys do nothing until the user clicks again. Probe: list focused -> addSpace -> first responder is the window, Down arrow has no effect; same after deleteSpace. With the web page focused the rebuild leaves it focused (no problem there), and the archive page is not rebuilt.

Expected: recreating the pages is an implementation detail and must not move the keyboard. The rebuilt list of the active space takes the focus its predecessor had.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With the active space's tab list focused, adding or deleting another space leaves the (rebuilt) active list as first responder
- [x] #2 A rebuild while the web page or the archive page holds focus leaves that focus where it is
- [x] #3 A rebuild while nothing in the sidebar is focused does not focus the list
- [x] #4 Unit tests cover the three cases
- [x] #5 The rebuilt list keeps the selected row of the list it replaces (the highlight, and where the arrow keys start from), without re-selecting the tab
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. In rebuildPages(), before tearing the pages down, record whether the first responder is inside the active space's page (and the archive page is not showing).
2. After the new pages are laid out and updateActivePage() has enabled the active page, make its list first responder if the old one had focus.
3. Tests in SidebarPageFocusTests: list focused + addSpace / deleteSpace; page focused + addSpace; archive search focused + addSpace; nothing focused + addSpace.
4. Verify in-app with the rebuild probe before (done: focus drops to the window) and after.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Scope added while verifying (2026-10-02): with only the focus carried over, the in-app probe's Down arrow opened the New Tab palette — the rebuilt list comes back with no row selected, so the arrow keys start from the top and land on the New Tab row. The selection loss is part of the same rebuild, so rebuildPages() now carries the selected row across as well.

Implemented (uncommitted, 2026-10-02) in TabSidebarViewController.rebuildPages(): before the teardown it records the old list's selected row and whether focus is inside the active space's page (activeSpacePageHoldsKeyboardFocus); after updateActivePage() it re-selects that row under suppressingSelectionCallbacks and, if the old list had focus and the archive page is not showing, makes the new list first responder. The row index carries over because the active list is backed by the controller's own model, which a rebuild does not change.
Verified. In-app probe (DETOUR_KEYLOOP_MODE=rebuild), before: list focused, addSpace or deleteSpace -> first responder is the window, selectedRow -1 (also with the web page focused, so the selected tab's highlight was lost on every rebuild), Down arrow does nothing. After: the rebuilt list is first responder, selectedRow unchanged (3), Down arrow moves to the next tab (row 4) and no palette opens; with the web page focused it stays focused and the row stays selected. Tests: 6 new in SidebarPageFocusTests (list focused + add / delete, selected row kept, web page focused, archive list focused, nothing focused); 3 of them fail with the fix stashed. 212 tests across the window and sidebar suites pass; the full suite was not run.
NOT exercised: real key presses, adding or deleting a space from Settings or another window, undo/redo of Add Space, a rebuild that removes the active space (the window then switches space, which hands focus to the page as in TASK-130), a tab rename in progress during a rebuild (the edit is lost, as before; the list gets the focus).

Code review (Oct 2) found one real bug in the first version and fixed it: when the active space itself was removed, rebuildPages() carried the row and the focus onto the fallback page (page 0), so another space's list took the keyboard and setActiveSpace's selectTab then saw focus as held and never gave it to the web page. The carry-over now happens only while the active page shows the same space before and after the rebuild (activePageSpaceID). Two tests added: deleting the active space (fails without the guard) and moving the active space with TabStore.moveSpace. This supersedes the earlier note that the removed-active-space case was not exercised. activeSpacePageHoldsKeyboardFocus now goes through currentPage. SidebarPageFocusTests is 16 tests; 214 tests across the window and sidebar suites pass on the final source.
Left open by the review: (a) the rebuild still resets the active list's scroll position, so a carried selected row can end up off screen (not confirmed in-app); (b) a tab or folder rename in progress is ended by the teardown and may commit a half-typed name; (c) design: rebuildPages() recreates every page on any space-list change, and reusing the page of each surviving space would keep focus, selection, scroll and an open rename without carry-over code.

Pre-commit in-app check on the review-corrected code (rebuild and left-behind probes): unchanged from the earlier passing run — the rebuilt list keeps focus and its selected row, Down arrow moves to the next tab, the web page keeps focus when it had it. Deleting the active space was not run in the app; it is covered by the unit test only.
<!-- SECTION:NOTES:END -->
