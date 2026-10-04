---
id: TASK-134
title: >-
  Extensions: runtime.onInstalled 'install' is lost when the worker fails to
  load the first time
status: To Do
assignee: []
created_date: '2026-10-04 01:54'
labels:
  - bug
  - extensions
dependencies: []
priority: medium
ordinal: 157000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-10-03 during TASK-132.4 with the Claude extension (before its load failure was fixed on the epic branch).

Detour delivers runtime.onInstalled itself. The polyfill's runtimeOnInstalledJS schedules a claim with setTimeout(claim, 0) (ExtensionAPIPolyfill.swift, scheduleClaim); the handler's 'runtime.claimInstalledEvent' case (ExtensionPolyfillHandler.swift) calls AppDatabase.claimRuntimeInstalledEvent(extensionID:profileID:isPrivateProfile:currentVersion:) (Detour/Storage/Database.swift), which reads the owed event and saves the ledger row in one transaction. Its doc comment states the design: the ledger advances before the worker dispatches, so a worker that dies in between loses the event rather than risking it twice.

The hole: the polyfill module is imported before the extension's own modules, so its timer is queued first and still fires when the extension's module evaluation then throws. Observed on the unmodified Claude extension (log .claude/scratch/task132.4/02-baseline-log.txt in the main checkout, untracked): 17:44:02.734 uncaught exception in the extension's module; 17:44:02.736 'runtime.onInstalled: delivering install (previous none, now 1.0.98)'; 17:44:02.737 'The background content failed to load'. The three recovery reloads that followed logged no further delivery. So 'install' was consumed by a worker that had registered no listener, and an extension whose first load fails never receives 'install' once a later version (or a fixed environment) loads. The ledger row was not read in that failing run; it was read as 1.0.98 in a later successful one.

The same shape applies to 'update': a new version whose worker fails at load consumes the 'update' event.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A test reproduces it: an extension whose worker throws at module evaluation on its first load, then loads successfully, receives onInstalled with reason install on the successful load
- [ ] #2 An event is recorded as delivered only when a listener was actually there to receive it (or the equivalent rule chosen), and that rule is written in the claim's doc comment and docs/extensions.md
- [ ] #3 The existing guarantee holds: an event is never delivered twice, including across the automatic context reloads after a background load failure and across a relaunch
- [ ] #4 The same holds for reason update
- [ ] #5 The existing onInstalled tests (RuntimeInstalledEvent, the polyfill and profile-wiring suites) pass
<!-- AC:END -->
