---
id: TASK-402
title: >-
  Tests:
  PageOpenedWindowTests.testTheOpenerSeesItsWindowClosedHoweverItWasClosed timed
  out once in a full run
status: To Do
assignee: []
created_date: '2026-11-16T22:01:00Z'
labels:
  - tests
  - flaky
dependencies: []
priority: low
type: chore
ordinal: 483000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Full run on main 3223cd7d, 2026-11-16 (4931 tests, after the second two-lane batch): timed out after 10 s waiting for the opener to see the tab the user closed as closed (window.second.closed stayed false after wc.closeTab), PageOpenedWindowTests.swift:357. It passed alone right after (PageOpenedWindowTests 11/0). First time seen. Things to check: whether closing a tab (kept for undo) closes its page right away or only when the web view is released, and whether that release waits on the web content process under full-run load.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is found, or the wait is made independent of load with the reason in the test
- [ ] #2 A full run passes it
<!-- AC:END -->
