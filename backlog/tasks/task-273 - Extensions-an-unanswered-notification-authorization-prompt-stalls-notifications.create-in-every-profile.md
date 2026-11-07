---
id: TASK-273
title: >-
  Extensions: an unanswered notification authorization prompt stalls
  notifications.create in every profile
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
ordinal: 320000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionNotificationManager.authorize()` (~331-350, TASK-253) has every create and update in every profile wait on the one in-flight authorization request, with no timeout. If the user leaves the macOS prompt sitting in Notification Center, every `await chrome.notifications.create(...)` hangs indefinitely and the pending entries pile up.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A create or update made while authorization is unanswered gets an answer within a bounded time (created and shown once authorized, or refused/queued with the behaviour recorded)
- [ ] #2 Pending entries waiting on authorization are bounded
- [ ] #3 Tests drive an authorization request that never completes with the fake center
<!-- AC:END -->
