---
id: TASK-236
title: >-
  Tests: testAnArmedWorkerHoldsOneAnchorAndADisarmStopsReanchoring is flaky
  under Thread Sanitizer
status: To Do
assignee: []
created_date: '2026-11-03T03:00:00Z'
labels:
  - tests
dependencies: []
references:
  - DetourTests/ExtensionPolyfillProfileWiringTests.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 280000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-231.4: ExtensionPolyfillProfileWiringTests.testAnArmedWorkerHoldsOneAnchorAndADisarmStopsReanchoring failed 2 of 5 runs under -enableThreadSanitizer YES, and 1 of 5 on the commit before that task's changes, always with 3 anchors opened where at most openedAtDisarm + 1 (2) is allowed; no ThreadSanitizer report. It passes in normal runs. The test toggles the simulated native host connected/connected/disconnected/disconnected back to back and sleeps 0.5 s; under TSan's slowdown the worker evidently re-anchors once more than the assertion allows. Whether that extra anchor is a real behaviour on a slow machine or only a test timing assumption is open.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The cause of the extra anchor is recorded: a test timing assumption, or a real re-anchor the keep-alive logic should not make
- [ ] #2 The test passes 10 of 10 runs under Thread Sanitizer (-test-iterations 10) and in normal runs, without loosening it beyond what the recorded cause justifies
<!-- AC:END -->
