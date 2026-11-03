---
id: TASK-231.6
title: 'Concurrency: the app target builds in Swift 6 language mode'
status: To Do
assignee: []
created_date: '2026-11-03T00:08:00Z'
labels:
  - concurrency
dependencies:
  - TASK-231.5
references:
  - project.yml
  - CLAUDE.md
parent_task_id: TASK-231
priority: medium
type: chore
ordinal: 273000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Once the subsystem subtasks are done, the rest of the app target's warnings (Profile, sidebar, window controllers and others, mostly main-actor isolation that is already true at runtime) go to zero and the target switches to Swift 6 mode, where the checks are errors and new code cannot add races.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The Detour target has no concurrency warnings and sets `SWIFT_VERSION: "6"`
- [ ] #2 `@unchecked Sendable`, `nonisolated(unsafe)` and `MainActor.assumeIsolated` remain only where the compiler cannot check the code, each with a comment saying what makes it safe
- [ ] #3 The full DetourTests suite passes
- [ ] #4 At runtime (/verify): multiple windows with tab ownership hand-off, split tabs, the command palette, an extension popup and the History page work
- [ ] #5 CLAUDE.md (which says Swift 5.10) and a wiki page describe the isolation model new code follows
<!-- AC:END -->
