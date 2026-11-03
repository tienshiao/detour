---
id: TASK-238
title: >-
  Extensions: one profile's notifications are visible to and clearable by the
  same extension in another profile
status: To Do
assignee: []
created_date: '2026-11-03T07:58:00Z'
labels:
  - extensions
  - privacy
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: medium
type: bug
ordinal: 282000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-234 (pre-existing). ExtensionNotificationManager keys notifications by extension ID and notification ID only, and every profile shares one manager. The same extension installed in two profiles (including the Private profile) therefore sees, through notifications.getAll, the IDs and contents of notifications created in the other profile, and can clear or update them. Private-profile isolation is a product promise; a normal-profile extension must not learn what the Private copy did, and vice versa. Clicks on a notification must also be routed back to the profile that created it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 getAll, clear and update in one profile never see or affect a notification created by the same extension in another profile, including Private
- [ ] #2 A click or close on a notification is delivered only to the extension context of the profile that created it
- [ ] #3 Real-extension-context tests cover two persistent profiles and a persistent plus the Private profile, from both transports
<!-- AC:END -->
