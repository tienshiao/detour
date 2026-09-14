---
id: TASK-72
title: >-
  Extensions: keep disabled extensions' origins inside ITP's interaction window
  too
status: To Do
assignee: []
created_date: '2026-09-14 05:39'
labels:
  - extensions
  - webkit
dependencies: []
priority: medium
ordinal: 72000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-70's ExtensionOriginInteractionKeeper logs a user interaction only for *loaded* extension contexts (at load and daily). WebKit carries an extension's IndexedDB and localStorage onto each new origin from its persisted LastSeenBaseURL, so an extension left disabled (or its profile unused) for longer than the interaction window — 7 or 30 operating days — has its last origin's script-written storage purged by tracking prevention in the meantime, and the rename at its next load finds nothing to move. Closing the hole means persisting the last base URL of every installed extension per profile (Detour's own record, since WKWebExtensionContext.baseURL is only known while loaded) and having the keeper re-log those origins alongside the loaded ones. Filed from the TASK-69/70/71 review on 2026-09-13.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Disabling an extension for longer than the ITP window and re-enabling it keeps its IndexedDB/localStorage (test drives an ITP pass against the persisted last origin the way ExtensionOriginTrackingPreventionTests does)
- [ ] #2 The keeper re-logs persisted last-seen origins of installed-but-unloaded extensions at launch and daily, skipping incognito profiles
- [ ] #3 docs/1password-integration-plan.md TASK-70 section notes the closed hole
<!-- AC:END -->
