---
id: TASK-278
title: >-
  Extensions: a permission granted through WebKit's permissions.request prompt
  reaches the extension's other loaded profiles only at their next load
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - Detour/Browser/Profile.swift
  - wiki/extensions/permissions.md
priority: low
type: bug
ordinal: 325000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found while doing TASK-276.

Saved permission decisions belong to the extension and are applied to every profile's context (`applySavedDecisions`). A grant the extension gets through WebKit's own `permissions.request` prompt is saved, but it is applied only to the context that asked. The extension's contexts in other loaded profiles (Private included) keep the old state until they load again, so for that time the same extension sees different permissions in different profiles, unlike every other decision path.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After a WebKit-prompted permissions.request grant is answered, the extension's contexts in every other loaded profile report the permission as granted without a reload
- [ ] #2 A denied prompt changes no other profile
- [ ] #3 Tests cover the grant reaching a second loaded profile, and the denial reaching none
<!-- AC:END -->
