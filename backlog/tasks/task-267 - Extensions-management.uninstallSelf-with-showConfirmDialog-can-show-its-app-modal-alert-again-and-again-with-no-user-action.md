---
id: TASK-267
title: >-
  Extensions: management.uninstallSelf with showConfirmDialog can show its
  app-modal alert again and again with no user action
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - security
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: medium
type: bug
ordinal: 314000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionManager.uninstallSelf` (TASK-257) shows an app-modal NSAlert with no user-gesture check (the polyfill has no gesture signal). The only guard is `pendingUninstallSelfConfirmations`, which stops two alerts stacking but not a new one right after Cancel. A worker on a timer or a loop can therefore keep the user in a cycle of modal alerts, and the alert names the extension with its own manifest-controlled display name, at a moment the extension chooses.

The `history` / `management` `permissions.request` prompt (TASK-260) also appears without a gesture, but a denial is saved and later requests are refused without asking, so it cannot loop the same way.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After the user cancels an uninstallSelf confirmation, further uninstallSelf calls with showConfirmDialog from that extension are refused without an alert for a period (or the session), with Chromium's cancel error
- [ ] #2 uninstallSelf without showConfirmDialog is unaffected
- [ ] #3 Tests cover cancel followed by an immediate second request, using uninstallSelfConfirmationAnswerOverride
- [ ] #4 The polyfill-layer wiki records the rule
<!-- AC:END -->
