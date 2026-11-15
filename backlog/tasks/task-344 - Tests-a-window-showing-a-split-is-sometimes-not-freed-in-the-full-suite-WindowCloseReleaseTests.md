---
id: TASK-344
title: >-
  Tests: a window showing a split is sometimes not freed in the full suite
  (WindowCloseReleaseTests)
status: To Do
assignee: []
created_date: '2026-11-15T07:30:00Z'
updated_date: '2026-11-15T22:03:00Z'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-15 (lead, TASK-228.11 rebase): reproduced in a 13-suite run that included AutomationStagingTests (180 tests, this one failure; WindowCloseReleaseTests + AutomationAgentPointerTests alone 33/33). The retain tree leads through TabStore.observers to an ArcImportWindowController still alive from AutomationStagingTests (its window held via LaunchServices/NSScrollPocket), so the interfering suite is AutomationStagingTests: it leaves an Arc import window open. Start there.
<!-- SECTION:NOTES:END -->
