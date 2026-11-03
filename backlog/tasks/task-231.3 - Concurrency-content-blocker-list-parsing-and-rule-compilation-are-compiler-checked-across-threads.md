---
id: TASK-231.3
title: >-
  Concurrency: content-blocker list parsing and rule compilation are
  compiler-checked across threads
status: To Do
assignee: []
created_date: '2026-11-03T00:07:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.2
references:
  - Detour/Browser/ContentBlocker/ContentBlockerManager.swift
  - Detour/Browser/ContentBlocker/ContentRuleStore.swift
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 270000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ContentBlockerManager parses lists on its own queue and ContentRuleStore compiles on a work queue. TASK-200 moved rule serialisation and the bad-rule search off the main thread, and ContentRuleStoreThreadingTests covers part of it. At the 2026-11-02 measurement: ContentBlockerManager 13 warnings, plus ContentRuleStore.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 No concurrency warnings remain in Browser/ContentBlocker/
- [ ] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [ ] #3 Compiled rule lists and whitelist behaviour are unchanged: the ContentBlocker* suites and ContentRuleStoreThreadingTests pass
- [ ] #4 The affected test suites pass under Thread Sanitizer (`xcodebuild ... -enableThreadSanitizer YES`), or the task records why a suite cannot run under it
<!-- AC:END -->
