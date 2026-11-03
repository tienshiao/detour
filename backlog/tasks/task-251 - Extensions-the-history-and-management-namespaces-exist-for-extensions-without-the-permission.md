---
id: TASK-251
title: >-
  Extensions: the history and management namespaces exist for extensions without
  the permission
status: To Do
assignee: []
created_date: '2026-11-03T16:52:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: bug
ordinal: 295000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-239. The polyfill installs chrome.history and chrome.management for every extension ("Always install"); only the native handler refuses calls. Feature detection (if (chrome.history)) is therefore wrong for extensions without the permission, unlike Chrome. management.getSelf (and getPermissionWarningsByManifest) need no permission in Chrome and must stay available.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 chrome.history / browser.history are undefined without the history permission
- [ ] #2 Without the management permission only the permission-free management methods are present
- [ ] #3 JS-level and real-context tests cover presence with and absence without each permission
<!-- AC:END -->
