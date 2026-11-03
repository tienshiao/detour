---
id: TASK-243
title: 'Native messaging: quitting Detour may leave live port hosts running'
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T17:25:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - Detour/App/AppDelegate.swift
priority: low
type: bug
ordinal: 287000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-233 runtime verification: after the app was sent SIGTERM, a silent connectNative host process (holding the keep-alive) kept running. Whether a normal quit (Cmd+Q, applicationWillTerminate) ends live port hosts, or only a SIGTERM leaks them, is unknown. Orphaned hosts (e.g. 1Password's) would keep running after Detour is gone.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 What a normal quit and a SIGTERM each do to live native hosts is measured and recorded
- [ ] #2 After a normal quit no native host process started by Detour is left running
- [ ] #3 The task records a signed-build check with 1Password after the change, if behaviour changed
- [ ] #4 A host that ignores SIGTERM, or one torn down less than its 2 s SIGKILL grace before quit (TASK-241), does not outlive Detour
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
From TASK-241 review: the SIGKILL escalation timer dies with the app, so a TERM-ignoring host can outlive Detour; quit should terminate hosts with a short bounded wait before SIGKILL. Optionally cancel the SIGKILL timer from the termination handler so the Process and pipes are freed as soon as a host exits.
<!-- SECTION:NOTES:END -->
