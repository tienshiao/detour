---
id: TASK-269
title: >-
  Extensions: notifications.create with an empty id keeps it instead of
  generating one
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: bug
ordinal: 316000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

Chrome generates an id when `notificationId` is "not set or empty". Detour's handler (ExtensionPolyfillHandler.swift ~772) passes `""` through and `ExtensionNotificationManager.create` (~408) keeps it as a literal id, so every `create('', ...)` replaces the previous notification and `getAll` lists a single `""` entry. TASK-254 fixed the null case only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 create('', options) generates a fresh id, returned to the caller, like create(null, options) and create(options)
- [ ] #2 Two create('', ...) calls produce two notifications
- [ ] #3 Tests cover the empty-string id from both transports
<!-- AC:END -->
