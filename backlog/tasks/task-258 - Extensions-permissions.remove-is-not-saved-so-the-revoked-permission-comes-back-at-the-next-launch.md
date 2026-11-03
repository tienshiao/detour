---
id: TASK-258
title: >-
  Extensions: permissions.remove is not saved, so the revoked permission comes
  back at the next launch
status: To Do
assignee: []
created_date: '2026-11-03T20:53:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Browser/Profile.swift
priority: medium
type: bug
ordinal: 302000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250, confirmed in the running app: when an extension calls chrome.permissions.remove for an optional permission, WebKit revokes it in the context, but Detour's stored decision row stays granted. At the next launch the decision restore (TASK-19/25) grants it again, and Settings still shows the switch ON. Affects every optional permission and host permission WebKit handles, not only the polyfill-gated ones.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An extension's permissions.remove of an optional permission or origin updates the stored decision, so the permission stays revoked after a relaunch and Settings shows it off
- [ ] #2 A later permissions.request grant is stored again
- [ ] #3 Tests cover remove then relaunch (context reload) for an API permission and a host permission
<!-- AC:END -->
