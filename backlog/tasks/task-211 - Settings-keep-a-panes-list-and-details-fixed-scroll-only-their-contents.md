---
id: TASK-211
title: 'Settings: keep a pane''s list and details fixed; scroll only their contents'
status: To Do
assignee: []
created_date: '2026-10-27 02:17'
labels:
  - settings
  - ui
  - bug
dependencies: []
priority: medium
ordinal: 247000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Feedback (user, 2026-10-26, screenshot of the Profiles pane): scrolling the profile's details also scrolls the profile list on the left out of view. Since TASK-189, SettingsPaneViewController puts each pane's whole body in one NSScrollView, so a list pane's master list and detail area move together.

Change: in the list panes (Profiles, Spaces, Extensions, Links — the ones with SettingsMetrics.listPaneMinimumHeight), the list and the detail area are anchored to the top and bottom of the pane below the description. The list's rows scroll inside the list, and the detail contents scroll inside the detail area, independently. Panes without a master list (General, Content Blocking) keep scrolling as a whole.

Keep the TASK-189/TASK-192 sizing rules: the window still fits smaller displays (SettingsPaneHeight, minimum heights), nothing widens the window, and a long list scrolled to its end stays at its end.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 In Profiles, Spaces, Extensions and Links, scrolling the details leaves the list in place, and scrolling the list leaves the details in place
- [ ] #2 The list and the details fill the pane's height below the description, top and bottom, at every window height the pane allows
- [ ] #3 General and Content Blocking still scroll as one body
- [ ] #4 The window still fits a small display, as TASK-192 requires, and a long list scrolled to its end stays at its end
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Queued (user, 2026-10-26): ahead of TASK-194, after TASK-210 (order: 210, this task, 194, 201, 202, 209).
<!-- SECTION:NOTES:END -->
