---
id: TASK-274
title: >-
  Native messaging: a wrapper-script host that does not exec leaves its real
  host running after quit
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - wiki/extensions/native-messaging.md
priority: low
type: bug
ordinal: 321000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

Termination signals only the direct child (`NativeMessagingHost.swift` ~344-347, ~430-441); there is no process group or descendant handling. A host installed as a `#!/bin/sh` wrapper that starts python or node without `exec` dies on SIGTERM/SIGKILL, and the real host is reparented to launchd and keeps running if it does not watch stdin. TASK-243 and wiki/extensions/native-messaging.md say no host outlives quit; that holds only for hosts that exec.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Quitting Detour, and SIGTERM to Detour, end a wrapper host's descendants as well as the wrapper (or the limit is decided and recorded in the wiki with the reason)
- [ ] #2 Signalling never reaches a process outside the host's own tree
- [ ] #3 A test uses a fake wrapper host that spawns a non-exec child
<!-- AC:END -->
