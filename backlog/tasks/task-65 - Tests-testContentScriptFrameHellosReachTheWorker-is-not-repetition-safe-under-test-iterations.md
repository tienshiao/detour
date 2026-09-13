---
id: TASK-65
title: >-
  Tests: testContentScriptFrameHellosReachTheWorker is not repetition-safe under
  -test-iterations
status: To Do
assignee: []
created_date: '2026-09-13 20:03'
labels:
  - tests
  - extensions
  - flake
dependencies: []
priority: low
ordinal: 65000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while reproducing TASK-60. On the unmodified tree, ExtensionPolyfillIntegrationTests.testContentScriptFrameHellosReachTheWorker (DetourTests/ExtensionPolyfillIntegrationTests.swift ~792) fails 9 of 10 iterations when the class is run with xcodebuild -test-iterations 10 (9 assertions per failing iteration), while passing on a single run. The suite shares one loaded extension context across the class, so the likely cause is state carried between iterations: hello records or counters in the worker or in storage that are not reset, listeners accumulating in the worker, or a frame registry that already contains the previous iteration frames so the expected counts are off by one iteration. It did not fail during the TASK-60 200-iteration loop of the three getUserSettings tests, so it is specific to this test. Find the carried state, make the test reset it (or use per-iteration frame ids / a fresh web view) so it is repetition-safe, and confirm 10 iterations green. Do not add retries or sleeps.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The failing assertions and the carried state are identified from a reproduced -test-iterations failure and recorded in the notes
- [ ] #2 ExtensionPolyfillIntegrationTests passes 10 consecutive iterations of the whole class
- [ ] #3 No retry or sleep is added; the fix resets or isolates state
<!-- AC:END -->
