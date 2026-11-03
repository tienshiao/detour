---
id: TASK-235
title: >-
  Tests: SettingsPaneColumnsTests depends on the shared DetourTests data
  directory being empty of link routes
status: To Do
assignee: []
created_date: '2026-11-03T03:00:00Z'
labels:
  - tests
dependencies: []
references:
  - DetourTests/SettingsPaneColumnsTests.swift
  - Detour/Browser/Settings/LinksSettingsViewController.swift
priority: low
type: bug
ordinal: 279000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen during TASK-231.1: testTheLinksPaneDoesNotNeedMoreThanTheListMinimum failed (natural height 1287 > 400) because ~/Library/Application Support/DetourTests/browser.db held 9 link routes left by an earlier harness or test run, and the test reads the shared LinkRouteStore expecting an empty list. It passed with the rows deleted. Any test that builds a settings pane over the shared store has the same weakness.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The Links pane tests build the pane over a store they own (in-memory or a fresh database), so rows in the shared test data directory do not change their result
- [ ] #2 A test that seeds the shared store with routes before building the pane still passes
- [ ] #3 Other settings pane tests that read shared stores are checked for the same dependency and fixed or listed in the task
<!-- AC:END -->
