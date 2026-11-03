---
id: TASK-260
title: >-
  Extensions: chrome.permissions.request, contains and remove do not work for
  history and management
status: To Do
assignee: []
created_date: '2026-11-03T20:54:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: feature
ordinal: 304000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250. WebKit's web process refuses permissions.request/contains/remove for permission names it does not implement ("'history' is not a valid permission") before Detour sees the call, so an extension can only get optional history or management through the Settings switch. A Detour wrapper around chrome.permissions could handle those names (prompt, store the decision, answer contains). Also: the refusal text "permission not declared" is misleading for an optional permission that is declared but not granted, and the API Explorer declares these permissions as required only, so it cannot exercise the optional path.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 permissions.request for optional history or management shows Detour's permission prompt and grants on approval; contains and remove answer and act correctly
- [ ] #2 A call refused because an optional permission is not granted says so, distinct from a permission not declared at all
- [ ] #3 The API Explorer can exercise an optional grant; real-context tests cover request, contains and remove
<!-- AC:END -->
