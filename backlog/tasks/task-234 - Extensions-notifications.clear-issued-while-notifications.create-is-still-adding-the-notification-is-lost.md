---
id: TASK-234
title: >-
  Extensions: notifications.clear issued while notifications.create is still
  adding the notification is lost
status: To Do
assignee: []
created_date: '2026-11-03T03:00:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 278000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-231.4 (pre-existing). ExtensionNotificationManager.create records the notification in its maps only once UNUserNotificationCenter.add returns. An extension that calls notifications.create('x') and then notifications.clear('x') without awaiting: clear runs removeDeliveredNotifications before the notification exists and finds nothing in the maps; when add returns, the entry is recorded and the banner shows, so getAll lists a notification the extension cleared. Since TASK-231.4 the bookkeeping is on the main actor, so the fix is about ordering, not threads.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A clear (and an update) issued while the create is still in flight takes effect: the notification is not shown, or is removed once added, and getAll does not list it
- [ ] #2 Tests cover create-then-clear and create-then-update without awaiting, in a real extension context and at the manager level
<!-- AC:END -->
