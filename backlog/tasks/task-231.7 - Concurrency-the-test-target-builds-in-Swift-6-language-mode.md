---
id: TASK-231.7
title: 'Concurrency: the test target builds in Swift 6 language mode'
status: To Do
assignee: []
created_date: '2026-11-03T00:08:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.6
references:
  - project.yml
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 274000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
DetourTests (183 files) was not measured on 2026-11-02. It needs the same settings as the app target. With main-actor default isolation, test cases become main-actor isolated, which interacts with the tests that wait on WebKit callbacks and fixture servers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The DetourTests warning count under the app target's settings is measured and recorded before any fixes
- [ ] #2 The DetourTests target has no concurrency warnings and sets `SWIFT_VERSION: "6"`
- [ ] #3 The full suite passes, and a repeated run (`-test-iterations` on the WebKit-driven suites) shows no new flakiness
<!-- AC:END -->
