---
id: TASK-339
title: >-
  Extensions settings: every permission has a readable name (no raw 'privacy' or
  'favicon')
status: To Do
assignee: []
created_date: '2026-11-15T05:14:00Z'
labels:
  - extensions
  - settings
dependencies: []
references:
  - TASK-338
  - Detour/Browser/Settings/ExtensionsSettingsViewController.swift
  - wiki/extensions/permissions.md
priority: low
type: bug
ordinal: 414000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-338's captures: the Extensions pane lists API Explorer's permissions with readable names ("Store data locally", "Read your browsing activity"), except two that show the raw manifest name, "privacy" and "favicon". The permission-to-text table has no entry for them, and any other unmapped permission would show the same way.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 "privacy" and "favicon" show readable names in the Extensions pane, worded like the others
- [ ] #2 Every permission Detour knows about (the manifest permissions the polyfill and WebKit support) has an entry, checked by a test that walks the known list
- [ ] #3 An unknown permission still shows something readable (its name, made legible) rather than nothing; tests cover it
<!-- AC:END -->
