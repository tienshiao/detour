---
id: TASK-209
title: 'Command palette: scope suggestions to the palette''s profile'
status: To Do
assignee: []
created_date: '2026-10-26 07:08'
updated_date: '2026-10-26 07:11'
labels:
  - command-palette
  - profiles
dependencies: []
priority: medium
ordinal: 245000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-26: the command palette should be scoped to the profile; history and other suggestions from other profiles must not appear as options.

Today (wiki/features/suggestion-pipeline.md):
- Open tabs: a normal window's palette offers the tabs of every non-incognito space (PaletteTabScope.offeredSpaceIDs), including spaces of other profiles. 'Switch to Tab' can therefore jump into another profile.
- History (top hit, history rows, inline completion, recent pages in the empty-field list and the TASK-184 filler rows) is scoped to the active space (TASK-94 decision), so it is narrower than the profile.
- Search suggestions use the active space's profile engine.

Change: every row the palette shows comes from the palette's profile only: open tabs from that profile's spaces (never another profile's, never across the Private boundary), history from that profile, filler rows likewise. Decide and record whether history widens from the space to the whole profile (matching the History page and the Quick Detour scope, which the profile's History page already includes) or stays space-scoped within the profile; this revisits TASK-94. Check every entry point: Cmd+T, Cmd+L, the empty-state 'Where to next?' palette, the Quick Detour launcher and its in-place palette.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 No palette row (open tab, history, top hit, inline completion, empty-field or filler row) comes from another profile, in every palette entry point
- [ ] #2 History scope within the profile (space or whole profile) is decided with the user and recorded, replacing the TASK-94 note if it changes
- [ ] #3 PaletteTabScope and the history lookups are driven by tests first (PaletteTabScopeTests, suggestion-provider tests), including two profiles with overlapping URLs
- [ ] #4 Checked at runtime with two profiles
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (user, 2026-10-26): history in the palette widens from the active space to the whole profile, like the History page (including the profile's Quick Detour visits). This replaces the TASK-94 space-scoped decision; update wiki/features/suggestion-pipeline.md and the history own-title matching page accordingly (row titles then come from the profile's own visits, never another profile's).
<!-- SECTION:NOTES:END -->
