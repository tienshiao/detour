---
id: TASK-132.11
title: 'Sidebar: colour stripe on tab rows that belong to a tab group'
status: In Progress
assignee:
  - '@claude'
created_date: 2026-10-03 23:09
updated_date: '2026-11-08T00:23:00Z'
labels: []
dependencies:
  - TASK-132.10
parent_task_id: TASK-132
priority: medium
ordinal: 143000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First visible form of tab groups (product decision: stripe first, header rows later). A member row carries a leading stripe in the group's colour, and the group title is discoverable (tooltip or equivalent). No header row, no collapse, no group drag yet. Must not change row heights or the list's layout, and must go through SidebarLayout / TabListItems rather than inline row maths.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each normal-tab row in a group shows a stripe in the group's colour; a split-group row shows it once for the pair
- [x] #2 Changing the group's colour or title, or a tab joining or leaving, updates the rows without a reload flash
- [x] #3 The group title is reachable from a member row
- [ ] #4 The stripe reads correctly in light and dark, on the selected row, and during hover and drag
- [x] #5 Ungrouped rows look exactly as they do today
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure rule in TabListItems.swift: TabGroupStripe (groupID, colour, title, continuesAbove/Below) and tabGroupStripe(at:in:groups:) / tabGroupStripes(for:groups:). An item carries a stripe only when every tab in it names the same tabGroupID and that id is a group of the space (split row: once for the pair; a pair whose panes disagree, or an id naming no group, gets none: rendering never trusts group data). The stripe runs on into an adjacent item of the same group, so a group reads as one bar with rounded ends. Tests in SplitTabTests.
2. TabGroupColorView (new file in Sidebar/): fills its bounds with the group's colour through updateLayer, so light/dark and increased contrast follow the appearance. Colour decision: the nine macOS system colours (systemGray, systemBlue, ...), one per Chrome name.
3. TabCellView: a 3 pt stripe in the 10 pt gutter left of the row highlight (outside the selection, hover background, progress bar and dev-mode border, so none of them changes it and it changes none of them); full row height where it continues, capped and rounded at a group's ends. No constraint or row height changes; hidden when nil, cleared in prepareForReuse. Accessibility label names the group.
4. TabSidebarViewController: every normal-tab configuration path (viewFor, applyState loop, reloadTab, inactive pages) sets the row's stripe from the pure rule; groups are read from the page's space in TabStore (like profileIDForTableView); pinned paths clear it. New refreshTabGroupStripes() repaints visible rows in place.
5. BrowserWindowController+TabStore: the five tab-group callbacks refresh stripes in place for the active space (no reloadData, AC #2), inactiveSpaceContentDidChange otherwise.
6. AC #3: the tab hover card shows the group (colour dot + title, 'Unnamed group' when the title is empty) for a member row; HoverCardContent gets the group through TabHoverCardHost; tests in TabHoverCardTests.
7. Tests: SplitTabTests, TabHoverCardTests, SidebarLayoutTests. /code-review --fix, /verify with a seeded tabGroup row (light/dark, selected, hover, split row, neighbours) and an env-gated harness for live updates (patch kept in docs/harness). Wiki: tab-groups, tab-cell, row-layout, tab-hover-card; log line.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
User note (2026-10-04, verbatim): "I think the colored accent bars for a group should also? at least? be on the sidebar tab so the user can identify the groups without having to click into them."

Asked whether 'also' meant a second place besides the sidebar row stripe. User's answer (2026-10-04, verbatim): "there should be a single stripe on the sidebar row."

Reading (Claude's): the group's colour is shown in one place, as one stripe on each member's sidebar row, visible without selecting the tab. That is AC #1 as written (a split-group row shows the stripe once for the pair). This task does not add the colour anywhere else, such as the content area. The header rows of TASK-132.19 are a separate, later decision.

Implementation (2026-11-07, @claude, branch task-132.11):
- Rule: tabGroupStripe(at:in:groups:) / tabGroupStripes(for:groups:) in TabListItems.swift (TabGroupStripe: groupID, colour, title, continuesAbove/Below; tabGroupDisplayTitle gives 'Unnamed group' for an empty title). A row has a stripe when every tab of its item names the same tabGroupID and that id is a group of the space; a split row shows it once; a pair whose panes disagree or an id naming no group gets none.
- Look: a 3 pt bar in the 10 pt gutter between the tab list's edge and the row highlight (TabCellView.updateTabGroupStripe, view made on first use, no constraints, no row height change). It runs the full row height into an adjacent row of the same group and is held 7 pt in with rounded ends at the group's first and last rows, so a group reads as one bar and two same-coloured neighbours stay apart. Outside the selection, hover background, progress bar and dev-mode border; the drag image (cell widened 6 pt) leaves it out.
- Colour decision: each Chrome name is the macOS system colour of that name (TabGroupColor.displayColor in Sidebar/TabGroupColorView.swift: systemGray, systemBlue, systemRed, systemYellow, systemGreen, systemPink, systemPurple, systemCyan, systemOrange). Why: light, dark and increased-contrast variants made for the system's own backgrounds, names match one to one; Chrome's hex palette would need our own dark and contrast values. TabGroupColorView resolves the colour in updateLayer against plain aqua/darkAqua (keeping high contrast): measured, the vibrant sidebar's unselected rows resolved systemBlue to #4584F2 and the selected row to #5199FA, a visible seam in the bar; resolved against plain aqua every row gives #5199FA.
- AC #3: the tab hover card of a member row (single or either split half) shows a line above the title: a dot in the group's colour and its title ('Unnamed group' when empty); HoverCardContent.tabGroup via TabHoverCardHost.hoverCardTabGroup(for:). The stripe is also an accessibility element 'Tab group: <title>'. No tooltip: rows have none since the hover card replaced them.
- AC #2: the window answers tabStoreDidCreate/Update/Remove/MoveTabGroup and tabStoreDidChangeTabGroupMembership with TabSidebarViewController.refreshTabGroupStripes() (sets each visible row's stripe on its existing cell) for the active space, inactiveSpaceContentDidChange() otherwise. Structural changes already go through applyState, which reconfigures every visible row. Groups are read live from the page's space (spaceForTableView), like the profile.
- Tests: SplitTabTests +8 (stripes per row and joins, split once, ungrouped none, one-member caps, adjacent groups apart, never trusts group data, follows colour/title changes, display title, cell stripe in the gutter and cleared on reuse); TabHoverCardTests +2 (grouped tab names its group incl. unnamed; only a normal tab's card names one). Run after review: SplitTabTests 71, SidebarLayoutTests 41, SidebarDragDropTests 39, DevModeTests 42, TabCellSplitCollapseTests 3, TabHoverCardTests 52, TabHoverCardControllerTests 9: 257 tests, 0 failures.
- /code-review --fix: no correctness bugs; applied 5 cleanups (pinned rows clear the stripe in updatePinnedMode/updateSplitPinnedMode instead of three call sites; re-round the stripe on viewDidChangeBackingProperties; applyState computes all stripes once; tabGroup(of:in:) returns the group (one lookup); shared spaceForTableView). Skipped: a redundant repaint after tabStoreDidMoveTabGroup (cheap, order-proof), a cell moved within its row without resizing (no known path), and the hover card naming each pane's own group for a corrupted split whose panes disagree (data the store never writes).
- Runtime check (docs/harness/task132.11-harness.patch, isolated DETOUR_DATA_DIR, groups seeded into browser.db with sqlite between two launches, final code): in light and dark, at rest, with the split row selected and with a member row hovered, every member row had its stripe in its group's colour (Research blue over Echo, Charlie|Delta, Bravo as one bar; unnamed purple on Golf alone), all 41 logged stripe frames clear of the row highlight, every row 36 pt, ungrouped rows with no stripe view at all, the stripe colour the same on the selected row as on its neighbours (pixel samples). Hover card: 'Research' / 'Unnamed group' line with the group's dot, none for an ungrouped row. Live through TabStore: recolour+rename, ungroup, create, add, rename unnamed: every visible row kept its cell instance (no reload) and the stripes changed in place; moving Bravo out of the group via moveTab removed its stripe and recapped the bar. Screenshots: .claude/scratch/verify13211/ in the worktree (gitignored).
- Not verified at runtime: a live drag session (needs a real pointer drag; the drag image leaves the gutter out by construction, and rows keep their cells while the gap opens), inactive pages mid-swipe (same viewFor path with the page's own space), and increased-contrast mode.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Tab group members now show a 3 pt stripe in the group's colour in the gutter left of their sidebar row (a split row once for the pair), joined into one bar per group with rounded ends; Chrome's colour names are drawn as macOS system colours; the group's title is on the member row's hover card ('Unnamed group' when empty) and in the stripe's accessibility label. The rule is the pure tabGroupStripe(at:in:groups:) next to tabListItems; group callbacks repaint stripes on the existing cells. Ungrouped rows get no view and no layout change. Tests: +8 SplitTabTests, +2 TabHoverCardTests; 257 tests in the seven affected suites pass. Runtime check covered light/dark, selected split row, hover, ungrouped neighbours and live recolour/rename/ungroup/create/add/move without reloads. Open: AC #4's drag leg was not exercised in a live drag session.
<!-- SECTION:FINAL_SUMMARY:END -->
