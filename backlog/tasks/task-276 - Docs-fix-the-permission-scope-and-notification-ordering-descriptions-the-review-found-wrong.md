---
id: TASK-276
title: >-
  Docs: fix the permission-scope and notification-ordering descriptions the
  review found wrong
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - wiki
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - Detour/Browser/Profile.swift
  - wiki/extensions/polyfill-layer.md
  - wiki/extensions/permissions.md
priority: low
type: docs
ordinal: 323000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

- `ExtensionPolyfillHandler.notificationsPermitted` and `permissionIsActive` say "granted in this profile"; saved decisions are per extension and applied to every profile's context, Private included (`ExtensionManager.setPermissionDecision`, `requestOutsideWebKitPermissions`).
- wiki/extensions/polyfill-layer.md ~426, the row for `create('x'), clear('x'), create('x')`, says the first add "finds a newer generation and does nothing"; in the code clear drops the identifier, the second create gets a new one, and the first add finds no entry and removes its own notification. Outcome right, mechanism wrong.
- `ExtensionManager.savedGrantsRevoked` infers "the extension removed its own grant" from context state at delivery, because WebKit's removal notification cannot tell Detour's writes from the extension's. It is correct only while every Detour write leaves a state the rule ignores; a future write that removes a grant from one profile's context alone would delete the saved grant for every profile. The invariant is not stated where those writes are (`applySavedDecisions`, `Profile.loadExtensionContext`).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The doc comments describe permission decisions as per extension, applied to every profile
- [ ] #2 The polyfill-layer wiki row describes the actual mechanism
- [ ] #3 applySavedDecisions and Profile.loadExtensionContext state the invariant savedGrantsRevoked relies on, and the permissions wiki page records it
- [ ] #4 wiki-lint passes and wiki/log.md has a line
<!-- AC:END -->
