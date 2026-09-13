---
id: TASK-65
title: >-
  Tests: testContentScriptFrameHellosReachTheWorker is not repetition-safe under
  -test-iterations
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 20:03'
updated_date: '2026-09-13 22:05'
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
- [x] #1 The failing assertions and the carried state are identified from a reproduced -test-iterations failure and recorded in the notes
- [x] #2 ExtensionPolyfillIntegrationTests passes 10 consecutive iterations of the whole class
- [x] #3 No retry or sleep is added; the fix resets or isolates state
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Reproduce: xcodebuild -test-iterations 10 on ExtensionPolyfillIntegrationTests, capture which assertions fail on iteration 2+.
2. Expected carried state: the worker's globalThis.__frameHellos accumulates across iterations (one context per class), so hellos from the previous probe tab satisfy count>=3 immediately and break the single-tab-id and frame-id assertions.
3. Fix: worker answers a clearFrameHellos message; the test clears after waking the worker and before loading the page, and scopes hellos to its own probe tab. No retries or sleeps added.
4. Confirm 10 consecutive iterations of the whole class green.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Reproduced with xcodebuild -test-iterations 10: iteration 1 passes, iterations 2-10 fail 9 assertions each (lines 883, 885, 891, 894, 897, 907, 908, 911, 913). Carried state: globalThis.__frameHellos on the class-shared service worker only grows (6, 9, 12... hellos, 2, 3, 4... tab ids), so the poll returns immediately with the previous iteration's hellos, probedTabID resolves to the stale (unregistered) tab and getAllFrames/getFrame/sendMessage fail with 'Tab not found'. Nothing else is carried (probeWebNavFrames has no cache; fresh web view per call). Fix: worker handles clearFrameHellos; the test clears after the wake ping, and filters hellos to its own loopback origin (the port is unique per run; the probe tab's chrome id is not knowable from Swift). 10 iterations of the whole class: 220 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Root cause: the class-shared service worker's __frameHellos array only ever grows, so every -test-iterations repetition after the first read the previous probe's hellos (stale tab id, 'Tab not found' on getAllFrames/getFrame/sendMessage). Fix: the worker answers clearFrameHellos, the test clears after waking the worker and scopes hellos to its own loopback origin. No retries or sleeps. 10 iterations of the whole class: 220 tests, 0 failures.
<!-- SECTION:FINAL_SUMMARY:END -->
