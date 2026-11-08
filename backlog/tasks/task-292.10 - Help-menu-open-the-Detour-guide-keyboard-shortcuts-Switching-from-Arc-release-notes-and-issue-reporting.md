---
id: TASK-292.10
title: >-
  Help menu: open the Detour guide, keyboard shortcuts, Switching from Arc,
  release notes and issue reporting
status: To Do
assignee: []
created_date: '2026-11-08T06:59:00Z'
labels:
  - menus
dependencies:
  - TASK-292.2
  - TASK-292.3
  - TASK-292.9
references:
  - Detour/App/AppDelegate.swift
parent_task_id: TASK-292
priority: medium
ordinal: 351000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The app has no Help menu (the menu bar ends at Window in AppDelegate). With guide pages on the website (TASK-292) the Help menu is where users look for them, and registering it as the app's help menu also gives them macOS's built-in menu search field for free.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A Help menu is the last menu and is the app's registered help menu, so the macOS menu search field appears in it
- [ ] #2 Items: Detour Help (the guide index), Keyboard Shortcuts, Switching from Arc, Release Notes, Report an Issue (GitHub issues)
- [ ] #3 Each opens in a new tab of the frontmost normal browser window's active space, or a new window when there is none; never in a Quick Detour or Quarantine window
- [ ] #4 The URLs are defined in one place and a test checks they are https URLs on detourbrowser.com (or github.com for issues and releases)
- [ ] #5 Checked at runtime with /verify: each item opens the right page in the right window
<!-- AC:END -->
