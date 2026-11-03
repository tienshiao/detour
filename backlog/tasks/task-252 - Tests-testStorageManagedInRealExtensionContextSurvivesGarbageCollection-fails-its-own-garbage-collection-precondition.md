---
id: TASK-252
title: >-
  Tests: testStorageManagedInRealExtensionContextSurvivesGarbageCollection fails
  its own garbage-collection precondition
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T16:52:00Z'
updated_date: '2026-11-03T23:19:00Z'
labels:
  - tests
  - extensions
dependencies: []
references:
  - DetourTests/ExtensionPolyfillIntegrationTests.swift
priority: low
type: chore
ordinal: 296000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen in TASK-234 and TASK-239: ExtensionPolyfillIntegrationTests.testStorageManagedInRealExtensionContextSurvivesGarbageCollection fails with "no collection observed in 10 rounds" about 1 run in 2-3, alone or in the suite. The failure is the test's precondition that a JavaScript garbage collection happened, not the storage behaviour under test.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The test forces or reliably observes a collection, or skips with a clear message when none can be observed, instead of failing
- [x] #2 It passes 10 of 10 runs (-test-iterations 10)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Root cause: in-page allocation churn did not reliably trigger an observable JS collection (the control WeakRef stayed alive 10 rounds about 1 run in 3). Fix: a forceCollection(in:) helper in ExtensionPolyfillIntegrationTests calls WebKit's private WKProcessPool _garbageCollectJavaScriptObjectsForTesting (pool via KVC on the web view configuration, guarded by respondsToSelector) and polls a control WeakRef made in an earlier script across macrotasks, up to 10 attempts; it throws XCTSkip if the hook is gone or nothing is observed. Applied to both GC guards (storage.managed and action.getUserSettings, which shared the churn). The storage test also now checks the onChanged listener survives the collection.

Tests: both GC tests -test-iterations 10 under caffeinate, twice (before and after review fixes): 20/20 passed each time, 0 skipped. Full ExtensionPolyfillIntegrationTests: 26 tests, 0 failures, 0 skipped.
Review (/code-review --fix): fixed KVC-on-unknown-key crash (responds(to:) guard) and moved the duplicated skip into the helper. Not fixed: a cleared young control does not by itself prove a full collection (an eden GC would clear it too; observed clearing on the first attempt in ~30 ms in every run, which churn never achieved); no churn fallback when the hook is missing (intended); stray __detourGCControl global (cosmetic). /verify skipped: test-only.
<!-- SECTION:NOTES:END -->
