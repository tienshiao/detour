---
id: TASK-343
title: 'Shortcuts: Reset and saved bindings are checked for shifted-key conflicts too'
status: To Do
assignee: []
created_date: '2026-11-15T07:30:00Z'
labels:
  - keyboard
  - settings
dependencies: []
references:
  - TASK-335
  - TASK-327
  - Detour/Commands/ShortcutBindings.swift
  - Detour/Browser/QuickDetour/HotKeyShortcut.swift
priority: low
type: bug
ordinal: 419000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-335. Recording a shortcut now refuses a shifted keystroke that would also fire another item through its character (⇧⌘= is ⌘+ on a US layout), using the current keyboard layout. Two paths still compare by character only: a row's Reset (resetting Zoom In to ⌘+ while another command holds ⇧⌘= is not refused) and the binding resolver, so bindings saved before TASK-335, or that conflict after a keyboard layout change, are never re-checked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Reset refuses, with the holder named, when the default it restores would collide with another binding through a shifted character
- [ ] #2 When the shortcuts are loaded (launch, layout change) a pair of bindings that fire on the same keystroke is detected and shown in Settings > Shortcuts, without silently dropping either
- [ ] #3 Tests cover the reset case and a saved conflicting pair, on the US and one other installed layout
<!-- AC:END -->
