---
id: TASK-253
title: >-
  Extensions: Detour never requests notification permission, so extension
  notifications may never be shown
status: To Do
assignee: []
created_date: '2026-11-03T17:09:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: medium
type: bug
ordinal: 297000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noted during TASK-238 and TASK-240: nothing in Detour calls UNUserNotificationCenter.requestAuthorization. Whether an extension's notifications.create shows a banner therefore depends on whether the bundle id happened to be authorized on that Mac (it was on the dev machine for one agent, not for another). On a fresh install the API reports success and nothing appears. When to ask (at first notifications.create, at extension install, from Settings) and what to answer the extension when the user declines are product decisions for this task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The point at which Detour asks for notification permission is decided and recorded, and implemented
- [ ] #2 When permission is denied, notifications.create behaves as recorded (Chrome-like answer or error), and getAll does not list notifications that were never shown
- [ ] #3 Tests cover the granted and denied paths with a fake center; a runtime check on a fresh bundle id shows the prompt and a banner
<!-- AC:END -->
