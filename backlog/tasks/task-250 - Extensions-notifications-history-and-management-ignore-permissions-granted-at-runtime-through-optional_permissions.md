---
id: TASK-250
title: >-
  Extensions: notifications, history and management ignore permissions granted
  at runtime through optional_permissions
status: To Do
assignee: []
created_date: '2026-11-03T16:52:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: bug
ordinal: 294000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-239. The polyfill namespace gates and the native hasPermission checks for notifications, history and management read only the manifest's permissions list. An extension that lists one of them under optional_permissions and is granted it at runtime (permissions.request) never gets the API, until it is moved to required permissions. Chrome makes the API available as soon as the grant is made. Revocation should take it away again.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After a runtime grant of an optional notifications, history or management permission, the API works in the extension's contexts (newly created ones at least; existing ones if Chrome does so); after revocation it is refused
- [ ] #2 Positive and negative tests in a real extension context for grant and revoke
<!-- AC:END -->
