---
id: TASK-228.12
title: >-
  Automation: endpoint clicks select rows in the other table views (Archived
  Tabs list, Settings lists)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T04:51:00Z'
updated_date: '2026-11-16T06:56:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-228.9
  - Detour/Automation/AutomationInput.swift
  - Detour/Browser/Sidebar/SidebarComponents.swift
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: low
type: bug
ordinal: 430000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-228.9. NSTableView's mouseDown gives up on a press in a window that is not key unless it becomes a drag (_shouldAbortMouseDownAfterDragAttempt:), so an endpoint press, which never makes a window key in the background, does not select a row. TASK-228.9 fixed the sidebar's DraggableTableView (needsPanelToBecomeKey false while AutomationInput hands it the press); other tables such as the Archived Tabs page and Settings' lists (Shortcuts, Link Routes, Profiles, Spaces, Extensions) likely have the same problem. Check each first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each table view in the app is listed with whether an endpoint left click selects its row, in the background and with Detour active
- [x] #2 Every one that does not is fixed the TASK-228.9 way (shared, not copied per class) or the reason it is left is recorded
- [x] #3 A test covers one non-sidebar table; checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Probe (test host, background): for every NSTableView the endpoint can click (Archived Tabs list, command palette, Settings: Spaces, Profiles, Extensions, Search, Shortcuts, Link Routes; Downloads popover only if addressable), call the click tool on a row and record the route (direct or through the window), the hit view and whether the row's effect happened. Before-fix results = AC #1 evidence.
2. One shared mechanism: a base table class carrying the needsPanelToBecomeKey override (answers false only while AutomationInput hands it a press), moved out of DraggableTableView; FocusGatedTableView, DraggableTableView, LinkRouteTableView and the plain NSTableView() sites use it. If a table's press goes through the window, cover that route too (flag around both branches or keep table presses direct), whichever selects with the window not key and no release queued.
3. Guard test: every table in the Settings panes, the archive list and the palette is the shared class. Behaviour test: a Settings list row (Spaces) selects by an endpoint click in a test run, window not key, app not active, no release queued, flag nil after.
4. Runtime check through scripts/detour-mcp in the background and with Detour active: archive row restores, a Settings list selects (test run).
5. Wiki (automation-endpoint-input, appkit-gotchas), log, review, commit on lane-b.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Tables the endpoint can click (AC #1), probed in the test host before the fix (host inactive, window not key = Detour in the background), endpoint click at a row's label area:
- Sidebar tab list (DraggableTableView): fixed in TASK-228.9; still selects (regression run, background).
- Archived Tabs list (ArchiveTableView): direct route, hit the table; nothing selected, nothing restored -> broken. Fixed.
- Command palette (plain NSTableView): the press lands on the row's NSTextField label and goes THROUGH THE WINDOW (label takes a first click); it reaches the table up the responder chain and meets the same _shouldAbortMouseDownAfterDragAttempt: check; no action ran -> broken. Fixed; needed the press flag on the window route too (confirmed: with the flag only on the direct route the palette test fails).
- Settings > Spaces, Profiles, Site Search (plain NSTableView): direct route (a plain NSTableView also delays window ordering), hit the table, selection unchanged -> broken. Fixed.
- Settings > Extensions (plain NSTableView, 0 rows in the test host): same class and setup as Spaces/Profiles, so the same; made AutomationTableView. Not clicked (no extension installed).
- Settings > Shortcuts (selectionHighlightStyle none, shouldSelectRow false) and Link Routes (LinkRouteTableView, shouldSelectRow false, 0 rows in the test host): no row is selectable by design; a click on a label does nothing for a person either. Left as is behaviour-wise, but made AutomationTableView so every Detour table shares the class.
- Downloads popover list: not reachable (popovers are not addressable windows, AutomationWindows), left as plain NSTableView.
With Detour active (runtime): bringForward makes the window key before the press, so the check never fires; archive, palette and Settings Site Search rows all acted (see runtime below).

Fix (one shared mechanism): AutomationTableView (in AutomationInput.swift) carries the needsPanelToBecomeKey override that DraggableTableView had (false only while AutomationInput.isHandingPress(to: self)). FocusGatedTableView (-> ArchiveTableView), DraggableTableView, LinkRouteTableView subclass it; Settings' Spaces/Profiles/Extensions/Search/Shortcuts lists and the palette's table are made from it. AutomationInput.click now sets viewTakingPress on both routes (direct and through the window), so a press on a row's label routed through the window reaches a table that cooperates. A person's press keeps AppKit's answer.

Tests: new AutomationInputTests.testAnArchivedTabsRowAndACommandPaletteRowTakeAClick (archive row restores the entry, palette row switches to its tab and closes the palette; window not key, app inactive, flag nil, no release queued; asserts sidebar/archive/palette tables are AutomationTableView) and AutomationWindowKindsTests.testARowOfASettingsListSelectsForATestRunsClick (Spaces row selects in a test run; every Settings pane's table is AutomationTableView). Both failed before the fix (probe), both pass. Suites: AutomationAgentPointerTests 14/0, AutomationInputTests 17/0, AutomationStagingTests 17/0, AutomationToolsTests 22/0, AutomationWindowKindsTests 11/0, CommandPaletteFocusTests 4/0, InitialWindowFocusTests 7/0, PaletteCommandRowsTests 13/0, PaletteCommandWindowTests 9/0, PaletteSelectionTests 14/0, SidebarPageFocusTests 27/0, SiteSearchPaletteTests 25/0 (180/0 together, host inactive, nothing skipped).

Runtime (Debug build from .derived, DETOUR_MCP=1, DETOUR_DATA_DIR=DetourVerify-22812, scripts/detour-mcp). Background (app_active false, window not key throughout): Archived Tabs row (view ArchiveTableView) restored the closed tab twice; palette row (view NSTextField) switched to its tab; sidebar row selected its tab (regression); Settings > Search row (Amazon) selected (inactive highlight), Settings window not key. Detour active (set_window_frame activate=true, window key): Archived Tabs row restored; palette row switched to its tab; Settings > Search row (GitHub) selected. Screenshots checked. Not checked at runtime: Spaces/Profiles lists (one space and one profile in the fresh data dir; the test covers Spaces), Extensions list (no extension), a person's real (HID) click or drag in any of these tables (person's path unchanged by construction).

Code review (/code-review medium --fix, forked): 5 findings. Fixed: the Downloads popover's table is now an AutomationTableView too (it is out of the endpoint's reach, popovers are not addressable, but every Detour table now shares the class; no test of its own); the deliversThroughWindow comment no longer says the flag belongs to the direct route only. Kept: the flag on the window route (intended; AppKit's routing asks the HIT view's needsPanelToBecomeKey, and a control inside a row is not the table; in the background the window never becomes key by an endpoint click anyway (TASK-228.10), and with Detour active bringForward made it key before the press; at runtime the Settings window stayed key after an active row click). Rejected: 'task file hand-edited' (all edits went through the backlog CLI); the duplicated row-to-point helper in two test files (minor). After the fixes: AutomationInputTests 17/0 (one earlier run had testARightClickOnASidebarRowsLabelOrIconOpensTheRowsMenu fail at list_menu, no_open_menu; a right click is untouched by this change, and the rerun passed 17/0: the known flake TASK-228.9 noted), AutomationWindowKindsTests 11/0, DownloadFlightStartTests and DownloadManagerTests passed (0 failures).

Follow-up after the review (second commit):
- New AutomationInputTests.testASwitchInATableRowTogglesAndTheRowSelects: an NSSwitch inside an AutomationTableView row (routed through the window with the table's flag set) toggles and sends its action, the window stays not key, no release queued; a click beside it selects the row. Closes the reviewer's question about controls in rows on the window route.
- The Settings test now clicks a row in Spaces, Profiles and Site Search (each selected, window not key, app inactive) and switches panes through the toolbar item (showPane shows the window, which activates the app). It skips when the test host is active; macOS grants the test host's activation only sometimes, so in a run after other Settings tests it can skip (it did once in four runs; standalone it ran: AutomationWindowKindsTests 11/0, nothing skipped).
- Extensions list: never clicked (no extension in the test host or the runtime data dir); its result is inferred from the shared class and its setup being the same as Profiles'.
- Wiki wording corrected: Spaces' list is a drag source; Profiles, Site Search and the archive list are not and still delayed window ordering for the press.
- Runs after these changes: AutomationInputTests 18/0, AutomationWindowKindsTests 11/0 (standalone, no skip) and 11 with the Settings test skipped (with other suites), AutomationAgentPointerTests 14/0, SidebarPageFocusTests 27/0.
- The runtime pass ran before the review's two small fixes (the Downloads popover's table class, a comment) and before this test-only follow-up.
- Seen at runtime, not investigated (out of scope): select_tab on beta followed by Cmd+W closed gamma (the select_tab output was discarded, so whether it selected is unverified).
Chosen by Claude (not yet confirmed by the user): the press flag is set on both routes (direct and through the window); alternative: keep any press whose hit view is inside a table on the direct route. Chosen by Claude (not yet confirmed by the user): every Detour table is made from AutomationTableView, including the Shortcuts and Link Routes lists (no selectable rows) and the Downloads popover (out of reach); alternative: only the tables with selectable rows or click actions.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An automation-endpoint click now acts on a row of every Detour table as a person's click does, in the background and with Detour active: an Archived Tabs row restores its tab, a command palette row switches to its tab or opens its page, and a Settings list row (Spaces, Profiles, Extensions, Site Search) selects. All had TASK-228.9's trap: -[NSTableView mouseDown:] gives up on a press in a window that is not key unless it becomes a drag. Fix: one shared base class, AutomationTableView (in AutomationInput.swift), carries the needsPanelToBecomeKey override that only DraggableTableView had, and every Detour table derives from it or is made from it. AutomationInput.click now sets its press flag on the window route too, because a press on a palette row's label goes through the window and reaches the table up the responder chain. A person's press is unchanged. Shortcuts and Link Routes select no row by design. The Downloads popover is out of the endpoint's reach but uses the class as well. Tests: AutomationInputTests (archive and palette rows) and AutomationWindowKindsTests (a Settings list row, and that every Settings table is an AutomationTableView). Checked at runtime through scripts/detour-mcp in both states. Not checked: Spaces, Profiles and Extensions rows at runtime (the fresh data dir had one space, one profile and no extension; a test covers Spaces), and a person's real click or drag.
<!-- SECTION:FINAL_SUMMARY:END -->
