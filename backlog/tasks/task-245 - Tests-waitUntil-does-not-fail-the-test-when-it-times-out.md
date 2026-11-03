---
id: TASK-245
title: 'Tests: waitUntil does not fail the test when it times out'
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
labels:
  - tests
dependencies: []
references:
  - DetourTests/ExtensionTestSupport.swift
priority: low
type: chore
ordinal: 289000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noted during TASK-236. The shared waitUntil helper in DetourTests/ExtensionTestSupport.swift (used in ~57 test files) does not throw or stop the test on timeout, so a failed wait lets the test continue on stale state and the real failure shows up later as a confusing assertion, or not at all.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A waitUntil timeout fails the test at the wait, naming what was awaited, and does not continue the test body
- [ ] #2 Every caller compiles and the full suite passes; callers that relied on a timeout not failing are found and fixed or recorded
<!-- AC:END -->
