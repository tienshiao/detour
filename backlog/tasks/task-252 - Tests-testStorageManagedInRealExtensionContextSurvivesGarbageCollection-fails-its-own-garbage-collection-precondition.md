---
id: TASK-252
title: >-
  Tests: testStorageManagedInRealExtensionContextSurvivesGarbageCollection fails
  its own garbage-collection precondition
status: To Do
assignee: []
created_date: '2026-11-03T16:52:00Z'
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
- [ ] #1 The test forces or reliably observes a collection, or skips with a clear message when none can be observed, instead of failing
- [ ] #2 It passes 10 of 10 runs (-test-iterations 10)
<!-- AC:END -->
