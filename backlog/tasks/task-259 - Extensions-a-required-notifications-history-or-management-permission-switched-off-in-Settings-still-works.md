---
id: TASK-259
title: >-
  Extensions: a required notifications, history or management permission
  switched off in Settings still works
status: To Do
assignee: []
created_date: '2026-11-03T20:54:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: medium
type: bug
ordinal: 303000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250 (pre-existing). The polyfill-gated APIs treat a permission in the manifest's required permissions list as always active (permissionIsActive), so when the user turns that permission off in Settings the API keeps working. The Settings switch should mean what it shows.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Whether Settings lets the user switch off required permissions is recorded; if it does, a switched-off required notifications, history or management permission refuses calls until switched on again
- [ ] #2 Positive and negative real-context tests from both transports
<!-- AC:END -->
