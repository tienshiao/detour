---
id: TASK-353
title: Code comments contradicted by later tasks, and RuntimeInstalledEvent's NSLock
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T05:37:00Z'
updated_date: '2026-11-16T05:53:00Z'
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
- [ ] #5 SettingsMetrics.designMaximumContentHeight's comment gives the current reason for 720 pt (the user's decision 2026-11-15: Profiles, ~1008 pt on the grouped form, opens at the cap and scrolls), not 'so Profiles opens whole'
- [ ] #6 BrowserCommands.fixedShortcuts no longer marks Cut/Copy/Paste/Select All PROVISIONAL (the user's decision 2026-11-15: they stay fixed)
- [ ] #7 HistoryDatabase.swift's comment above the title-maintenance triggers names the actual delete APIs and lists importVisits among the visit writers
<!-- AC:END -->
