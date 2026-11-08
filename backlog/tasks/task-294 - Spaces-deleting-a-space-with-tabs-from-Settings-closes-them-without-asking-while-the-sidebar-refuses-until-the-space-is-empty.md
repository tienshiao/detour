---
id: TASK-294
title: >-
  Spaces: deleting a space with tabs from Settings closes them without asking,
  while the sidebar refuses until the space is empty
status: To Do
assignee: []
created_date: '2026-11-08T07:34:00Z'
labels:
  - spaces
dependencies: []
references:
  - TASK-292.2
priority: low
ordinal: 355000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while writing the Spaces guide page (TASK-292.2), from the code at v0.4.0 (unchanged on main). The two ways to delete a space apply different rules to a space that still has tabs:

- Sidebar (right-click a space button or an empty part of the tab list, Delete Space): a space with normal or pinned tabs is refused with "Cannot Delete Space / Close or move all tabs first before deleting this space."; an empty space gets a confirmation (Delete "<name>"? / This space will be removed.). Detour/Browser/Window/BrowserWindowController+TabSidebar.swift:644-690.
- Settings › Spaces, the "−" button: deletes at once with no confirmation, even with tabs; its tabs, pinned entries and folders are closed (closed-tab records kept). Detour/Browser/Settings/SpacesSettingsViewController.swift:350-366.

Both can be undone (Undo Delete Space restores the space with its tabs), but the undo runs from the browser window, and someone clicking "−" in Settings may not know their tabs are gone or that undo exists. Which rule both should follow (refuse until empty, or confirm and close the tabs) is the user's call; the guide page describes today's behavior and needs updating when this changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Deleting a space that has tabs follows the same rule from the sidebar and from Settings › Spaces (chosen with the user before implementation)
- [ ] #2 Settings never removes a space that has tabs without either refusing or asking first
- [ ] #3 Undo Delete Space still restores the space with its tabs from either path
- [ ] #4 TabStore or controller tests cover the rule for an empty space and for a space with normal and pinned tabs
- [ ] #5 The Spaces guide page on the website (src/content/features/spaces.md) matches the new behavior
<!-- AC:END -->
