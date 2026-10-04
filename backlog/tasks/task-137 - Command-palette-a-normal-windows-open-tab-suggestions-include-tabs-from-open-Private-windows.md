---
id: TASK-137
title: >-
  Command palette: a normal window's open-tab suggestions include tabs from open
  Private windows
status: To Do
assignee: []
created_date: '2026-10-04 01:58'
labels: []
dependencies: []
references:
  - wiki/architecture/incognito.md
  - Detour/Browser/CommandPalette/CommandPaletteView.swift
priority: high
ordinal: 160000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
CommandPaletteView.gatherTabInfos (Detour/Browser/CommandPalette/CommandPaletteView.swift) narrows the space list only when the palette's own window is Private: `spaces.filter { !isIncognito || $0.id == activeSpaceID }`. In a normal window isIncognito is false, so the filter passes every space in TabStore.spaces, which includes the spaces of open Private windows. Their tabs (URL, title, favicon) are handed to SuggestionProvider as open-tab candidates and can appear in the suggestion list, as the top hit, and as a switch-to-tab target. Found by reading the code while writing wiki/architecture/incognito.md; not yet observed in the running app.

Expected: a Private window's tabs are never offered in another window's palette; a Private window's palette keeps offering only its own space's tabs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A normal window's palette (empty query and typed query, including the top hit) never lists a tab that belongs to an incognito space
- [ ] #2 A Private window's palette still lists the open tabs of its own space and of no other
- [ ] #3 The space filtering is a testable rule with a unit test that fails before the fix (normal window + open Private window; Private window + normal spaces)
- [ ] #4 wiki/architecture/incognito.md and wiki/features/suggestion-pipeline.md are updated
<!-- AC:END -->
