---
id: TASK-370
title: >-
  Content blocking: exercise the over-cap chunking on a real list
  (urlhaus-filter is at 73% of the cap and growing)
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - content-blocking
  - tests
dependencies: []
references:
  - wiki/features/content-blocking-chunks.md
priority: low
type: task
ordinal: 451000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-359's measurement (2026-11-15): urlhaus-filter 109,083 rules, 72.7% of WebKit's 150,000-rule cap, up from 102,775 twenty days earlier. TASK-145's chunking has only run on synthetic lists.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test (or gated measurement) compiles a real list padded past the cap through the chunk path and checks every chunk attaches
- [ ] #2 The chunks page records the result
<!-- AC:END -->
