---
id: TASK-279
title: >-
  Extensions: the static permission checks default to the wall clock, so a new
  call site can bypass the injected test clock
status: To Do
assignee: []
created_date: '2026-11-07T09:35:00Z'
labels:
  - extensions
  - permissions
  - tests
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: task
ordinal: 326000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Follow-up from the TASK-264..277 review-fix batch (2026-11-06/07). Found while doing TASK-277.

TASK-277 routed `ExtensionPolyfillHandler`'s `now` clock through the permission gates, but the static functions (`permissionRefusal`, `permissionRequestPlan`, `activeAPIPermissions` and friends) still take `now: Date = Date()`. About 21 test call sites rely on the default. A new caller that forgets the argument silently reads the wall clock, and grant or denial expiry in that path is no longer testable.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The static permission functions have no default for their clock argument; every caller passes one
- [ ] #2 Existing tests pass with an explicit clock
<!-- AC:END -->
