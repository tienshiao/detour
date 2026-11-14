---
id: TASK-334
title: >-
  Menus: give the top-level menu items titles so App Shortcuts written as a menu
  path apply
status: To Do
assignee: []
created_date: '2026-11-14T23:45:00Z'
labels:
  - menus
  - keyboard
dependencies: []
references:
  - TASK-327
  - Detour/App/AppDelegate.swift
  - wiki/features/keyboard-shortcuts.md
priority: low
type: bug
ordinal: 408000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-327. macOS App Shortcuts (System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts) can name a menu item by title ("Close Tab") or by path ("File->Close Tab", used when a title is ambiguous). AppKit matches the path against the titles of the parent menu items, and Detour's menu bar items are untitled NSMenuItem() with titled submenus, so path-form entries never apply to Detour.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each top-level menu bar item has the same title as its submenu, and a path-form App Shortcut ("File->Close Tab") applies to the item, measured at runtime
- [ ] #2 The menu bar looks the same, and MainMenuCharacterizationTests and the Shortcuts pane's "Set in System Settings" detection still pass
<!-- AC:END -->
