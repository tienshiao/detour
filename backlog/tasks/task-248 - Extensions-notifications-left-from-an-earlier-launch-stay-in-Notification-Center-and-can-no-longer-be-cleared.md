---
id: TASK-248
title: >-
  Extensions: notifications left from an earlier launch stay in Notification
  Center and can no longer be cleared
status: To Do
assignee: []
created_date: '2026-11-03T16:33:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 292000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-238. Notification identifiers are opaque per entry since TASK-238 (detour-ext-notification.v3|<UUID>), and the manager keeps entries in memory only. A banner delivered in an earlier launch, in the v3, v2 or legacy <ext>:<id> form, is orphaned after a relaunch: clicks on it are ignored and the extension's clear or create with the same id no longer reaches it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 At launch, Detour removes every delivered and pending extension notification it created in an earlier launch (v3, v2 and legacy identifier forms), and nothing else
- [ ] #2 The ExtensionNotificationCenter seam can list delivered notifications, and a manager-level test covers the cleanup with a fake center
<!-- AC:END -->
