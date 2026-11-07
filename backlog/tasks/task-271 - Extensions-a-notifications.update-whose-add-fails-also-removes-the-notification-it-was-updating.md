---
id: TASK-271
title: >-
  Extensions: a notifications.update whose add fails also removes the
  notification it was updating
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 318000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

On a failed `add`, `ExtensionNotificationManager.addFinished` (~480-486) calls `removeEntry` and `removeNotifications` for the shared identifier. For an update that means the update answers `wasUpdated: false` but the notification the earlier create showed is gone too. Chrome leaves the original in place. `add` rarely fails, hence low priority.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A failed update answers wasUpdated false and leaves the original notification shown and listed by getAll
- [ ] #2 A failed create still leaves no entry behind
- [ ] #3 Tests cover both with the fake center failing add
<!-- AC:END -->
