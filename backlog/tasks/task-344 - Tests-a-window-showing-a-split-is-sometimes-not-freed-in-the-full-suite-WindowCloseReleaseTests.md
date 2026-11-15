---
id: TASK-344
title: >-
  Tests: a window showing a split is sometimes not freed in the full suite
  (WindowCloseReleaseTests)
status: To Do
assignee: []
created_date: '2026-11-15T07:30:00Z'
labels:
  - tests
  - windows
dependencies: []
references:
  - DetourTests/WindowCloseReleaseTests.swift
  - wiki/platform/webkit-test-host-traps.md
priority: low
type: bug
ordinal: 422000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-11-14 in a full DetourTests run on main (7d4d616): WindowCloseReleaseTests.testAWindowShowingASplitIsFreed failed with "split: the closed window's controller is still alive; retain…", together with PageOpenedWindowTests.testTheOpenerSeesItsWindowClosedHoweverItWasClosed (a 10 s opener timeout). Both suites passed alone (31/31), and the next full run did not repeat it. If something keeps a closed split window's controller alive only after other suites, it may be test interference, or a real retain that only appears under that state, which would leak windows in the app.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The retain path behind the failure is found (or the failure shown to be test order only, with the interfering suite named) and recorded
- [ ] #2 If it is a real retain, it is fixed and the test reproduces it; if it is test interference, the tests are isolated so the full suite is stable
<!-- AC:END -->
