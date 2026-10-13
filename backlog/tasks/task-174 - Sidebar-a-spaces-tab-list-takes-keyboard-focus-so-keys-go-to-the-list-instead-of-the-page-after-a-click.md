---
id: TASK-174
title: >-
  Sidebar: a space's tab list takes keyboard focus, so keys go to the list
  instead of the page after a click
status: Done
assignee:
  - '@claude'
created_date: '2026-10-11 07:21'
updated_date: '2026-10-13 01:22'
labels:
  - sidebar
  - focus
  - bug
dependencies: []
references:
  - Detour/Browser/Sidebar/SidebarComponents.swift
  - Detour/Browser/Sidebar/TabSidebarViewController.swift
  - wiki/sidebar/keyboard-focus.md
  - DetourTests/SidebarPageFocusTests.swift
priority: medium
ordinal: 197000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Clicking a row in the sidebar's tab list makes the list first responder and selectTab leaves it there ("focus held by a control stays", wiki/sidebar/keyboard-focus.md rule 2). After choosing a tab with the mouse, typing goes to the list — arrow keys walk rows, everything else is dropped — until the user clicks the page.

Decision (user, 2026-10-11): the sidebar's tab lists should not be able to hold keyboard focus. Choosing a tab there leaves the keyboard on the page. This reverses the TASK-128/130/131 choice to let the active list keep focus for arrow-key row walking; Cmd+Option+Up/Down and Control+Tab remain the keyboard ways to change tab.

Out of scope: text fields that need the keyboard keep it while in use — an inline rename, and the Archived Tabs page (search field and its list).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A space's tab list never becomes first responder, on screen or off
- [x] #2 After a click on a tab row the selected tab's page (or its presented Peek) holds keyboard focus, whatever held it before, unless the click itself opened something that takes it (the command palette from New Tab, an inline rename)
- [x] #3 Clicking the list while a row is being renamed ends the rename as it did before (commit)
- [x] #4 Ending an inline rename with Return or Escape gives the keyboard to the page, not to the list or to nothing
- [x] #5 A rebuild of the space pages does not leave the keyboard on nothing
- [x] #6 The Archived Tabs page keeps its keyboard behaviour (search field, Down into the list, Return, Delete)
- [x] #7 Focus tests are updated to the new rule; wiki/sidebar/keyboard-focus.md records the decision and what it replaced
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Tests first (SidebarPageFocusTests, InitialWindowFocusTests): the list refuses focus; a click hands the keyboard to the page; a click ends a rename; Return/Escape in a rename give the keyboard to the page; rebuilt pages do not drop it. The old tests that focused the list are re-based on a rename field, the one thing a space page still holds the keyboard for.
2. DraggableTableView stops inheriting FocusGatedTableView and never accepts first responder; its mouseDown ends a rename in the list, lets AppKit handle the click, then hands the keyboard to the page unless the click moved it somewhere new (palette, newly selected page).
3. TabCellView / FolderCellView: Return and Escape end the edit and release the keyboard through the list.
4. TabSidebarViewController: the space pages leave the focus gate (archive page only); rebuildPages carries the selected row only and hands a lost rename's keyboard to the page.
5. Runtime check with posted clicks and keys; wiki/sidebar/keyboard-focus.md records the decision.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented 2026-10-11 on branch task-173-174-switcher-peek-sidebar-focus (from main). DraggableTableView no longer inherits FocusGatedTableView and refuses first responder (acceptsFirstResponder and becomeFirstResponder). Its mouseDown ends a rename inside the list, lets AppKit handle the click, then calls onReleaseKeyboardFocus; the window (tabSidebarDidReleaseKeyboardFocus) gives the keyboard to the page unless the command palette is open. TabCellView / FolderCellView: Return, Tab, Shift+Tab (commit) and Escape (cancel) end the edit and release the keyboard. rebuildPages carries the selected row only; a rename lost with its row hands the keyboard to the page. SpacePageView.acceptsKeyboardFocus is gone; the archive page's gate is unchanged.

Measured while writing the tests: after Return in a rename AppKit keeps first responder on the label, and after Tab it is the window, so both are handled explicitly. A tab switch during a rename already gave the page the keyboard (the row refresh ends the rename, and selectTab then sees focus as unheld); the old test for it passed only because isDescendant(of:) is true for the list itself.

TDD: tests rewritten first against the unchanged code: SidebarPageFocusTests + InitialWindowFocusTests = 31 run, 19 assertion failures in 11 tests. Final code: SidebarPageFocusTests 27, InitialWindowFocusTests 7, CommandPaletteFocusTests 4 and the TASK-173 suites = 76 run, 0 failed. Full DetourTests on the final code: 2,139 run, 11 skipped, 1 failure in ExtensionPolyfillIntegrationTests (a garbage-collection timing test that passes run alone; see TASK-173). A synthetic mouse-down does not select a table row in a test host that is not the active app, so the tests hand the mouse-down to the list for the list's own part and select rows with selectRowIndexes.

Code review (/code-review --fix) found and fixed: (1) the first version compared first responder before and after the click; every text field edits through the window's one field editor, so find bar -> click New Tab looked like 'nothing moved' and the palette's keyboard went to the page. Now the list always gives the keyboard up after a click and the window refuses while the palette is open (test: testAClickThatOpensThePaletteTakesTheKeyboardFromAnotherField). (2) Tab in a rename left the window as first responder. (3) the test helper's row math went around SidebarLayout/TabListItems. Left as is: a window drag from the list's empty area or the start of a row drag also hands the keyboard to the page (the old list took focus on those too); the rename code is duplicated between the two cells; FocusGatedTableView now has one subclass.

Runtime (harness docs/harness/task173-174-harness.patch, isolated profiles, posted mouse and key events, app launched from a shell and so not active). New code: after a posted click on a row the web view keeps first responder and the page's keydown listener receives the posted key, in all three steps (page focused; find bar focused; nothing focused and the selected row clicked). Old sidebar code, same harness: first responder is DraggableTableView after each click and no page receives the key. NOT verified at runtime: the posted click did not change the list's selection in either build (the app was not active), so 'click another tab's row, then type' was not seen end to end with a real selection change — that needs a click by a person, or the app launched active. Also not run: rename by Return/Tab/Escape in the app (tests only), Full Keyboard Access.

Known gap, recorded in wiki/sidebar/keyboard-focus.md: a row reloaded under its own rename (reloadData(forRowIndexes:) while the pinned tab being renamed changes title or favicon) ends the rename and leaves the keyboard with the window until the next click or tab switch; before, the list picked it up. Two hooks in the cell were tried and did not fire with the cell still attached.

2026-10-12, task sweep: the user confirmed the one thing left to try by hand. In the build they have run since 2026-10-11, after a click on a tab row the keys go to the page.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A space's tab list no longer takes keyboard focus. A click on it leaves the keyboard on the selected tab's page (or gives it to the page from wherever it was, the find bar included); the command palette opened by New Tab keeps it. An inline rename is the only thing in a space page that holds the keyboard, and it gives it to the page when it ends (Return, Tab, Escape, a click elsewhere in the list, rebuilt pages). The Archived Tabs page is unchanged. Arrow-key row walking in the list is gone with it; Cmd+Option+Up/Down and Control+Tab remain. Tests: SidebarPageFocusTests, InitialWindowFocusTests. Runtime: posted clicks and keys, before and after; click a tab and type confirmed by the user in daily use (2026-10-12).
<!-- SECTION:FINAL_SUMMARY:END -->
