---
id: TASK-276
title: >-
  Docs: fix the permission-scope and notification-ordering descriptions the
  review found wrong
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T03:38:00Z'
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
- [x] #1 The doc comments describe permission decisions as per extension, applied to every profile
- [x] #2 The polyfill-layer wiki row describes the actual mechanism
- [x] #3 applySavedDecisions and Profile.loadExtensionContext state the invariant savedGrantsRevoked relies on, and the permissions wiki page records it
- [x] #4 wiki-lint passes and wiki/log.md has a line
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Re-check each item against the current code (13 commits since filing): 1. reword the polyfill handler's permission comments (notificationsPermitted, revokeNotificationsIfNotPermitted, permissionIsActive) so decisions are the extension's, applied to every profile's context. 2. rewrite the polyfill-layer wiki row for create/clear/create from ExtensionNotificationManager.show/addFinished/clear. 3. state the savedGrantsRevoked invariant on applySavedDecisions, at the restore in Profile.loadExtensionContext, pointed to from savedGrantsRevoked, and in the permissions wiki. 4. wiki-lint, log line, Debug build (comments only).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Re-checked against HEAD 65bc716. notificationsPermitted still said 'granted in this profile'; permissionIsActive no longer did, but got a paragraph saying a saved decision is the extension's and reaches every profile's context, with the one gap found while checking: an answer to WebKit's own permissions.request prompt is saved (handlePermissionPrompt) but WebKit applies it to the asking context only, so other profiles get it at their next load. revokeNotificationsIfNotPermitted (TASK-270) reworded the same way; it writes no permission, so it is outside the invariant (said in its comment and the wiki). Notification row: clear removes the entry and identifier, the second create gets a new identifier, the first add finds no entry and removes only its own identifier; a first create still in the authorization wait never adds. Generations matter only for create/create without a clear (identifier kept), now said in the same row. Invariant written on applySavedDecisions (with why its clear-then-restore and its .unknown-for-no-row writes keep it), at the restore in Profile.loadExtensionContext, a pointer in savedGrantsRevoked's doc, and a new bullet in wiki/extensions/permissions.md. Verification: comments-only diff (checked: no non-comment Swift lines changed); Debug build into .derived succeeded (sandbox off; the one Swift warning is pre-existing, ExtensionPolyfillHandler '??' on a non-optional). No tests or app launch, per the docs-only rule. wiki-lint --fix: 0 errors (1 pre-existing staleness warning on claude-extension-epic.md).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Docs and comments only. The polyfill handler's permission comments now say decisions are per extension and applied to every profile's context (Private included), noting that a WebKit permissions.request answer reaches other profiles only at their next load. The polyfill-layer wiki row for create/clear/create describes the real mechanism (new identifier after the clear; the first add removes only its own), with generations credited to create/create. The invariant savedGrantsRevoked relies on is stated on applySavedDecisions, at the restore in Profile.loadExtensionContext, referenced from savedGrantsRevoked, and recorded in wiki/extensions/permissions.md. Debug build passes; wiki-lint 0 errors.
<!-- SECTION:FINAL_SUMMARY:END -->
