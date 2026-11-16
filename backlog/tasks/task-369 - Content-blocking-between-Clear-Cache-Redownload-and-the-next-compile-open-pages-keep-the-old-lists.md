---
id: TASK-369
title: >-
  Content blocking: between Clear Cache & Redownload and the next compile, open
  pages keep the old lists
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
labels:
  - content-blocking
dependencies: []
references:
  - wiki/features/content-blocking-clear-cache.md
priority: low
type: bug
ordinal: 450000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-359's agent, read from the code. Clear Cache & Redownload removes the compiled lists, but nothing updates open pages until the next successful compile, so they keep the old lists attached (both window kinds).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 What open pages use between Clear Cache and the recompile is decided and recorded
- [ ] #2 Pages pick up the recompiled lists when it lands
<!-- AC:END -->
