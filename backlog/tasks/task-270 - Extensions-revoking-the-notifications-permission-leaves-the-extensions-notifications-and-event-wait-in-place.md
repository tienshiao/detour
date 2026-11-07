---
id: TASK-270
title: >-
  Extensions: revoking the notifications permission leaves the extension's
  notifications and event wait in place
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - notifications
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 317000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

Neither the Settings switch nor the extension's own `permissions.remove` of an optional `notifications` touches `ExtensionNotificationManager`. The banners stay in Notification Center, the parked `awaitEvent` stays parked, and `deliver` (ExtensionNotificationManager.swift ~697-713) answers a park admitted before the revocation without checking the permission again, so a click on an old banner still fires onClicked. Meanwhile `notifications.clear` is refused (TASK-239 gate), so the extension cannot take its own banners down.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 When notifications stops being active for an extension in a profile (Settings switch off, permissions.remove of the optional permission), its notifications in that profile are removed and no further onClicked/onClosed is delivered
- [ ] #2 The parked wait is answered with the permission refusal, so the polyfill re-arms after a later grant (TASK-250 behaviour)
- [ ] #3 Tests cover both revocation paths
<!-- AC:END -->
