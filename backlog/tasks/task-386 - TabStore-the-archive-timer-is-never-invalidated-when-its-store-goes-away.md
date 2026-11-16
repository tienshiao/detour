---
id: TASK-386
title: 'TabStore: the archive timer is never invalidated when its store goes away'
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:41:00Z'
labels:
  - tabstore
  - tests
dependencies: []
references:
  - Detour/Browser/TabStore.swift
priority: low
type: chore
ordinal: 467000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-363, its code review); read from code. `TabStore.startArchiveTimer()` schedules a repeating 300 s main-run-loop timer (`archiveTimer`, `[weak self]`, running `sleepStaleTabs()` and `archiveStaleTabs()`); nothing ever invalidates it, and the isolated `deinit` TASK-363 added (which removes the deferred Private undo observers) does not either. Today only `AppDelegate` starts it, on `TabStore.shared`, which lives as long as the app, so nothing leaks yet; a test store that started the timer and was released would leave it firing a no-op every 300 s for the rest of the test process. Same kind of leftover as TASK-363's observers.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A TabStore that is released invalidates its archive timer
- [ ] #2 A test shows a released store that started the timer leaves no valid timer behind
<!-- AC:END -->
