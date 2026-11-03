---
id: TASK-240
title: 'Extensions: notifications.clear and notifications.update diverge from Chrome'
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T16:33:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 284000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-234. clear always answers true, while Chrome answers whether a notification with that ID existed. update replaces the whole options object, while Chrome merges the given fields into the existing notification (an update that changes only the message keeps the title and icon). Extensions that branch on clear's result or update one field at a time behave differently in Detour.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 clear answers true only when a notification with that ID existed for that extension (including one whose create is still in flight), false otherwise
- [ ] #2 update merges the given options into the existing notification; fields not given are kept
- [ ] #3 Tests at the manager level and in a real extension context, for both the promise and the callback forms
- [ ] #4 The notification's subtitle is not set to its iconUrl (pre-existing: content.subtitle carries the icon URL), and iconUrl / contextMessage map to what Chrome shows, or the gap is recorded
<!-- AC:END -->
