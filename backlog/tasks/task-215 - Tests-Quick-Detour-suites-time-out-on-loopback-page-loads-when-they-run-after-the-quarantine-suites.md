---
id: TASK-215
title: >-
  Tests: Quick Detour suites time out on loopback page loads when they run after
  the quarantine suites
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
labels:
  - bug
  - tests
dependencies: []
references:
  - wiki/playbooks/build-and-test.md
priority: low
ordinal: 251000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen in TASK-194 and TASK-209: in a long combined DetourTests run, after about ten suites (and reliably when the Quarantine suites run first), later Quick Detour suites time out waiting for loopback fixture pages (34 timeouts in TASK-209's 580-test run; 12 on HEAD before TASK-209 with the same suite order). Each suite passes on its own. Something the earlier suites leave behind (windows, web views, data stores, WebContent processes, the fixture server) starves later loads. Related in shape to TASK-166.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause is found and recorded in the task and wiki/playbooks/build-and-test.md
- [ ] #2 A combined run of the Quarantine and Quick Detour suites in that order passes with no load timeouts
<!-- AC:END -->
