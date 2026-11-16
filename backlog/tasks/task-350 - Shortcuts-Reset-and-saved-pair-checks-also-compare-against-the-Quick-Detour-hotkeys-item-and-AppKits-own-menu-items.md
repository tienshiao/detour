---
id: TASK-350
title: >-
  Shortcuts: Reset and saved-pair checks also compare against the Quick Detour
  hotkey's item and AppKit's own menu items
status: To Do
assignee: []
created_date: '2026-11-16T04:51:00Z'
labels:
  - keyboard
  - settings
dependencies: []
references:
  - TASK-343
  - TASK-335
  - Detour/Commands/ShortcutBindings.swift
  - wiki/features/keyboard-shortcuts.md
priority: low
type: bug
ordinal: 429000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-343's review. Recording a shortcut refuses one that collides with the Quick Detour hotkey's menu item or an AppKit-provided item, but the TASK-343 checks (a row's Reset, and saved pairs on one keystroke shown in Settings > Shortcuts) compare only with the registry's bindable commands.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reset is refused, holder named, when the default it restores fires on the same keystroke as the Quick Detour hotkey's item or an AppKit menu item
- [ ] #2 Saved bindings that share a keystroke with those are marked in Settings > Shortcuts like other pairs
- [ ] #3 Tests cover both, on the US and one other layout
<!-- AC:END -->
