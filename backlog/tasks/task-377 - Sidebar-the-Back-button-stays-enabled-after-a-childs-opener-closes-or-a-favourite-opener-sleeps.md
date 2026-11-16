---
id: TASK-377
title: >-
  Sidebar: the Back button stays enabled after a child's opener closes or a
  favourite opener sleeps
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
labels:
  - sidebar
  - tabs
  - opener
dependencies: []
references:
  - wiki/tabs/tab-opener.md
priority: low
type: bug
ordinal: 458000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-358's agent. The sidebar Back button's enabled state is recomputed only when the selected tab's canGoBack changes; when the selected child's opener closes (or, since TASK-358, a favourite opener goes to sleep) it stays enabled and pressing it does nothing. Pre-existing for normal openers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Back's enabled state follows whether parentTab(for:) resolves, refreshed when an opener closes, sleeps or moves
- [ ] #2 A test covers it
<!-- AC:END -->
