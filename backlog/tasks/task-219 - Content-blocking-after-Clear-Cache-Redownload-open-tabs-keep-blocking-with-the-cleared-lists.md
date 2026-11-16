---
id: TASK-219
title: >-
  Content blocking: when a cleared list's redownload fails, pages keep its old
  rules until quit
status: To Do
assignee:
  - '@claude'
created_date: 2026-10-27 22:21
updated_date: '2026-11-16T21:47:00Z'
labels:
  - content-blocking
  - bug
dependencies: []
references:
  - wiki/features/content-blocking.md
  - wiki/features/content-blocking-clear-cache.md
  - Detour/Browser/ContentBlocker/ContentRuleStore.swift
priority: medium
type: bug
ordinal: 255000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-202 (2026-10-27); rescoped 2026-11-16 after the second two-lane batch (TASK-368, TASK-369) and the user's decision on TASK-369.

What is left: since TASK-369, Clear Cache & Redownload keeps each list's last completed chunks in memory (`ContentRuleStore.clearedLists`, filled by `invalidateAll`), and `attachableLists(forList:)` gives them to pages (open ones, through TASK-368's pass, and new ones, through `ContentBlockerManager.ruleLists(for:in:)`) until the list's next compile records and drops them. Read from code: when the redownload does not lead to a compile (`fetchAndCompile`'s fetch error, a response that is not 200 or 304, unreadable text, or a compile that ends `.failed`; offline or a timed-out request ends in the fetch error), nothing drops them, so every page keeps blocking with the old rules until quit, while Settings says the list is cleared ("No active rules"). Someone who clears to get rid of a bad rule keeps it.

The user's decision (2026-11-16, on TASK-369): keep the old rules only while the list's redownload is in flight; drop them when it fails or times out. Pages then have no rules from that list until it compiles.

The original first criterion (open tabs pick up the recompiled lists without a reload) was delivered by TASK-368 and TASK-369. Wiki: wiki/features/content-blocking-clear-cache.md ("Pages between the clear and the recompile").
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 When a cleared list's redownload fails (fetch error, bad response, failed compile) or times out, its old rules are dropped from every open page and no new page gets them
- [ ] #2 While the redownload is in flight, pages keep the old rules as TASK-369 made them; a successful compile still replaces them on every page
- [ ] #3 Tests cover a failed and a timed-out redownload (LivePageContentBlockingTests style); the wiki's clear-cache page records the rule
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-16: rescoped to the user's decision on TASK-369 (old rules only while the redownload is in flight, dropped when it fails or times out); priority raised to medium as asked. The old AC #1 (open tabs use the recompiled lists without a reload) was delivered by TASK-368 (every live page takes a rules change) and TASK-369 (its AC #2); the old AC #2 is the new AC #1.
<!-- SECTION:NOTES:END -->
