---
id: TASK-97
title: >-
  Command palette: recent history aggregates every visit in the space (25-28 ms
  at 50k visits, main thread)
status: To Do
assignee: []
created_date: '2026-09-20 07:21'
labels: []
dependencies: []
references:
  - Detour/Storage/HistoryDatabase.swift
priority: low
ordinal: 97000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
recentHistory (the palette's list before anything is typed) groups ALL of the space's visits per URL and only then takes the newest few, so its cost grows with total history: 25.2 ms before TASK-94 and 28.3 ms after, on the synthetic 50,000-visit profile in a Debug build, on the main thread. Pre-existing; measured during TASK-94. Normal profiles are far smaller, hence low priority. Direction: walk visits newest-first (index on spaceID + visit time) and stop once enough distinct URLs are collected, keeping the TASK-94 label rule (the space's latest non-empty own title; shared title only when no other space visited the URL).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 recentHistory cost no longer grows with total visit count: measured on the 50k-visit fixture before/after and recorded in the task
- [ ] #2 Results are identical to today's (order, dedupe per URL, labels, limit) - existing recent-history and TASK-94 label tests pass unchanged
- [ ] #3 A test covers a space whose newest visits are many repeats of one URL (the early-stop must still return the full distinct count)
<!-- AC:END -->
