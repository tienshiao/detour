---
id: TASK-378
title: >-
  Tab opener: a pinned tab or favourite that goes to sleep loses its own opener
  link
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
labels:
  - tabs
  - opener
dependencies: []
references:
  - wiki/tabs/tab-opener.md
priority: low
type: bug
ordinal: 459000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-358's agent. Waking a sleeping pinned tab or favourite builds a new tab at its home page, so the backing tab's own parentID (restored since TASK-358) is lost on wake.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The link survives sleep and wake, or the decision not to keep it is recorded on the tab-opener page
- [ ] #2 A test covers it
<!-- AC:END -->
