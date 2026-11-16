---
id: TASK-228.9
title: >-
  Automation: a left click on a sidebar row selects its tab, as a person's click
  does
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T07:30:00Z'
updated_date: '2026-11-16T04:51:00Z'
labels:
  - automation
  - sidebar
dependencies: []
references:
  - TASK-228.7
  - TASK-228.8
  - Detour/Automation/AutomationInput.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: bug
ordinal: 420000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-228.8. Through the endpoint a left click on a sidebar tab row does not select the tab, on both the old direct route and with TASK-228.8's window routing off; select_tab does. Sidebar rows delay window ordering, so TASK-228.8 keeps them on the direct route. A right click on the same row opens its menu since TASK-228.7.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The endpoint's left click on a sidebar tab row selects that tab in that window, with Detour active and in the background
- [x] #2 Clicks on the row's close button, a folder's disclosure and a pinned entry behave as a person's clicks do
- [x] #3 A test covers selecting by click; checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Find why the direct route selects nothing: probe NSTableView's mouseDown in the test host (swizzled nextEvent/postEvent/selectRowIndexes) and read its disassembly.
2. Fix in the delivery where possible; where the table's own check needs the view, let the list cooperate only during the endpoint's press (no select call).
3. Close button (hover-only): give the endpoint's left click on a native view a pointer arrival (mouseEntered/mouseExited on the views under the point) so it behaves as a person's click.
4. Tests in AutomationInputTests: row, close button, pinned entry, folder row + disclosure, New Tab row; regressions: right-click menu, agent pointer suites.
5. Runtime check through the endpoint in the background and with Detour active; wiki + log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause (probed in the test host with swizzled nextEvent/postEvent/selectRowIndexes, and from the disassembly of -[NSTableView mouseDown:]): the table first asks _shouldAbortMouseDownAfterDragAttempt: (window not key, window can become key, table.needsPanelToBecomeKey). When true it only tries a drag (_performDragFromMouseDown: takes the release off the queue and posts it back) and returns without selecting unless Command is held. The endpoint's press always met it: no window is key while Detour is in the background. Not the click count, timestamps or the current event. With the table answering false, the same direct press selected the row, the table's selection tracking took the release, and the window stayed non-key.
Fix: DraggableTableView.needsPanelToBecomeKey answers false only while AutomationInput.click hands a press straight to it or a view inside it (AutomationInput.viewTakingPress / isHandingPress(to:)); a person's press keeps AppKit's answer, so dragging a row out of a background window is untouched. Why the view has to cooperate: the check is the table's own and reads the window's key state, and the endpoint must leave the key window alone in the background (TASK-228.10), so nothing in the delivery alone gets past it short of swizzling AppKit. No select call: the table's own mouse-down runs (folder toggle, New Tab row -> palette, Opt-Cmd Quick Detour).
Close button: shown only on hover, so the press landed on the row. Chosen by Claude (not yet confirmed by the user): a left click on a native view at a window point first sends mouseEntered to the views under the point (hit view down, tracking areas they own with .mouseEnteredAndExited; .activeInActiveApp ignored; not an area the person's pointer is in while AppKit tracks it), lays out, re-hit-tests and re-gates (retarget), clicks, then mouseExited. Alternative: no hover emulation (agents close tabs through the row menu / Close Tab) or a separate hover tool. Open question for the lead: an agent cannot discover a hover-only control (hit_test and screenshots don't show it); the click description says where the close button is.
A person's first click on a row of a window that is not key: by the disassembly, AppKit does not make the window key at the press when the view delays window ordering (it orders/keys on the release), so it probably only raises the window and does not select. Not checked with a real (HID) click.
Out of scope: every other NSTableView (Archived Tabs list, Settings lists) has the same AppKit check, so endpoint clicks there may not select either. The in-app (source app) screenshot showed a stale sidebar right after pinning a tab at runtime; source=screen was right.
Tests: AutomationInputTests 14/0 (new: testALeftClickOnASidebarRowSelectsItsTab, testALeftClickOnARowsCloseButtonClosesTheTab, testPinnedEntryFolderAndNewTabRowsTakeAClick; row tests wait for the rows to settle, which also hardens the existing right-click test that flaked once with the row still sliding in), AutomationAgentPointerTests 12/0, AutomationToolsTests 22/0, AutomationWindowKindsTests 10/0 (58/0 together).
Runtime (Debug build, DETOUR_MCP=1, isolated data dir, through scripts/detour-mcp): Detour in the background (app_active false throughout, window never key): click on a row's title selected it; a click at the close button's place closed the tab (view HoverButton); a pinned entry's row selected it; a folder's row collapsed it and its disclosure expanded it; the New Tab row opened the palette; with the agent pointer on, the click glided and selected the row. With Detour active (set_window_frame activate=true, window key): pinned row selected, folder row toggled, close button closed the tab. Not checked at runtime: a person's drag of a row out of a background window (needs a real drag; the person's press path is unchanged by construction). The runtime pass ran before the review's small fixes (per-view layout, isTracking, the view-scoped flag); the tests cover those.

User confirmed 2026-11-15: hover on arrival (a left click first hovers the views under the point so hover-only controls like the close button take it). Follow-up filed for other table views.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The endpoint's left click on a sidebar row now selects the tab, in the background and with Detour active. Cause: -[NSTableView mouseDown:] gives up on a press in a window that is not key unless it becomes a drag (_shouldAbortMouseDownAfterDragAttempt:: not key, can become key, needsPanelToBecomeKey). DraggableTableView answers false to needsPanelToBecomeKey only while the endpoint hands it a press, so the table's own mouse-down selects; a person's press is untouched. A left click on a native view at a window point now hovers the views under it first (and leaves them after), so a row's hover-only close button closes the tab (chosen by Claude). Folder disclosure (routed through the window since TASK-228.8), folder rows, pinned entries and the New Tab row behave as a person's clicks. Tests in AutomationInputTests; checked at runtime through scripts/detour-mcp. Open: whether the hover emulation is wanted; agents cannot discover hover-only controls; other NSTableViews may have the same issue.
<!-- SECTION:FINAL_SUMMARY:END -->
