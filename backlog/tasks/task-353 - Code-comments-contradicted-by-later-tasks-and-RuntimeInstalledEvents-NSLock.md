---
id: TASK-353
title: Code comments contradicted by later tasks, and RuntimeInstalledEvent's NSLock
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:37:00Z'
labels:
  - cleanup
  - concurrency
dependencies: []
references:
  - Detour/Browser/Profile.swift
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
  - Detour/Extensions/Runtime/RuntimeInstalledEvent.swift
priority: low
type: chore
ordinal: 433000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in the wiki content lint (the wiki pages were corrected; the code comments were not). CLAUDE.md requires shared mutable state behind Synchronization.Mutex, never NSLock.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Profile.swift's comment that Private profile extension contexts 'live until quit' says what TASK-298 made true (a Private session end resets them)
- [ ] #2 ExtensionAPIPolyfill.swift's watchPort comment agrees with TASK-142/TASK-263's measurements of WebKit's removePort
- [ ] #3 ProvisionalInstalledEventClaims in RuntimeInstalledEvent.swift uses a Mutex instead of NSLock, with its tests passing
- [ ] #4 docs/harness/task175-176-harness.patch no longer says data: URLs do not load (TASK-159)
<!-- AC:END -->
