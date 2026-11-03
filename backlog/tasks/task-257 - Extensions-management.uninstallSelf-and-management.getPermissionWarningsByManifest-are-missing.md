---
id: TASK-257
title: >-
  Extensions: management.uninstallSelf and
  management.getPermissionWarningsByManifest are missing
status: To Do
assignee: []
created_date: '2026-11-03T20:26:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: low
type: feature
ordinal: 301000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-251. Chrome offers management.getSelf, uninstallSelf and getPermissionWarningsByManifest without the management permission (Chromium extensions/common/api/_api_features.json: dependencies []). Detour implements only getSelf; the other two do not exist with or without the permission. uninstallSelf with showConfirmDialog needs a confirmation UI decision.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 management.uninstallSelf uninstalls the calling extension from its profile (with a confirmation when showConfirmDialog is true), and is available without the management permission
- [ ] #2 management.getPermissionWarningsByManifest returns the warnings Detour would show for a manifest string, or the gap is recorded
- [ ] #3 Real-context tests from both transports, including bad arguments; API Explorer exercises both
<!-- AC:END -->
