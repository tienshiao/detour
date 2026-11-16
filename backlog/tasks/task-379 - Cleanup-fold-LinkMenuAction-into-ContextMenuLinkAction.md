---
id: TASK-379
title: 'Cleanup: fold LinkMenuAction into ContextMenuLinkAction'
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
labels:
  - cleanup
  - links
dependencies: []
references:
  - wiki/features/link-routing-in-page.md
priority: low
type: chore
ordinal: 460000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-356's review. TASK-356 added LinkMenuAction (which Open Link item was chosen) next to the existing ContextMenuLinkAction; folding them touches about 37 call sites.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One enum names the link menu's actions; behaviour and tests unchanged
<!-- AC:END -->
