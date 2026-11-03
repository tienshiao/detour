---
id: TASK-254
title: >-
  Extensions: notifications.create(null, options) is treated as create(options)
  with empty options
status: To Do
assignee: []
created_date: '2026-11-03T17:09:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: bug
ordinal: 298000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-240. The notificationsJS polyfill (ExtensionAPIPolyfill.swift, around the create argument parsing) takes the options-first path when the first argument is an object, and typeof null is "object", so create(null, options) creates a notification with empty options and a generated id. Chrome treats a null id as absent and uses the options.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 create(null, options) and create(undefined, options) use the given options with a generated id
- [ ] #2 JS-level tests cover null, undefined, a string id and options-only, in promise and callback forms
<!-- AC:END -->
