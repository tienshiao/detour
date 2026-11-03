---
id: TASK-261
title: >-
  Extensions: management.getSelf and getAll leave out permissions granted at
  runtime
status: To Do
assignee: []
created_date: '2026-11-03T20:54:00Z'
labels:
  - extensions
  - permissions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
priority: low
type: bug
ordinal: 305000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-250. The ExtensionInfo permissions and hostPermissions lists that management.getSelf / getAll return are built from the manifest, so optional permissions granted at runtime are missing, unlike Chrome.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 getSelf and getAll list active permissions, including runtime grants, and drop revoked ones
- [ ] #2 Real-context tests cover a grant and a revoke
<!-- AC:END -->
