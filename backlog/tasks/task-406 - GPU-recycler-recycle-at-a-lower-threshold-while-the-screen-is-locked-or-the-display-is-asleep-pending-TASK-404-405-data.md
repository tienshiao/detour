---
id: TASK-406
title: >-
  GPU recycler: recycle at a lower threshold while the screen is locked or the
  display is asleep (pending TASK-404/405 data)
status: To Do
assignee: []
created_date: '2026-11-17T19:47:00Z'
labels:
  - gpu
  - webkit
dependencies:
  - TASK-404
priority: medium
type: feature
ordinal: 487000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On 2026-11-17 the display was off 03:05-08:01 and the GPU process was recycled only at 16,697 surfaces at 11:10 during active use (TASK-403). While the screen is locked or the display asleep nobody sees a recycle, so a much lower threshold (for example 6,000) would make the busy-user rules a rare fallback. Not started yet: the user decides the threshold once TASK-404/405 show how much closing and sleeping tabs actually frees.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The threshold and gate are confirmed by the user
- [ ] #2 GPUProcessRecyclePolicyTests cover the locked/asleep gate, including media and the rate limit still blocking
<!-- AC:END -->
