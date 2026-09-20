---
id: TASK-98
title: >-
  Tests: FavoriteFaviconTests fails intermittently (2 of 4 tests) on a clean
  tree
status: To Do
assignee: []
created_date: '2026-09-20 18:47'
labels:
  - bug
  - tests
dependencies: []
references:
  - DetourTests/FavoriteFaviconTests.swift
priority: low
ordinal: 98000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Observed twice on the baseline tree during TASK-96 (2026-09-19/20), independent of the change under test: a full-suite run fails 2 of the 4 FavoriteFaviconTests; a re-run passes. Which two tests fail was not recorded. Suspect: process-global FaviconLoader.shared state. setUp/tearDown already swap the fetch seam and call resetForTesting(), so the likely leaks are (a) another suite's in-flight favicon download or completion landing during these tests (or these tests' seam being live while another suite's tabs/favourites request icons), (b) resetForTesting() not clearing everything (in-flight requests, waiters, cache), or (c) completions delivered asynchronously after the expectation window. First step is to capture a failing run's assertion output and find whether it is order-dependent (run the suite after the suites that create tabs/favourites with favicon URLs).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The failure is reproduced or explained from a captured failing run (which tests, which assertions)
- [ ] #2 FavoriteFaviconTests no longer depends on process-global FaviconLoader state leaking across suites (isolated loader instance or a complete reset), and passes 20 consecutive full-suite-order runs
<!-- AC:END -->
