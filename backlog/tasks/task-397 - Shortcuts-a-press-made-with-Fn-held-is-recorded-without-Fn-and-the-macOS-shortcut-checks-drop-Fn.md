---
id: TASK-397
title: >-
  Shortcuts: a press made with Fn held is recorded without Fn, and the
  macOS-shortcut checks drop Fn
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:43:00Z'
labels:
  - keyboard
  - shortcuts
dependencies: []
references:
  - Detour/Browser/QuickDetour/HotKeyShortcut.swift
  - Detour/Browser/Settings/ShortcutsSettingsViewController.swift
priority: low
type: bug
ordinal: 478000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-375, reported as not changed); read from code. TASK-375 made Settings > Shortcuts compare Fn on a key with a character (`KeyEquivalent.holdsFn`; arrows and F-keys, whose every press carries Fn, compared without it), so macOS's own Fn items (fn-D, fn-E) are never named for a binding. Three places still drop Fn:

- The recorders (Settings > Shortcuts and Quick Detour) build the shortcut with `HotKeyShortcut(event:)`, which keeps only its significant modifiers, so a press made with Fn held is recorded as the same key without Fn. An app cannot give its own item Fn (measured in TASK-375: AppKit drops it), so the recorded binding then fires on the press without Fn, not the one the user made.
- The "Used by macOS" mark (`ShortcutRowState.isTakenByMacOS`) and the recorders' macOS-shortcut refusal compare with the symbolic hotkeys read through `HotKeyShortcut.modifiers(fromCarbon:)`, which maps the Carbon bits for Command, Option, Control and Shift only ("other bits (Fn, Caps Lock) are ignored"), so a macOS shortcut that needs Fn is compared without it.

Wiki: wiki/features/keyboard-shortcuts.md, wiki/platform/appkit-gotchas.md (the Fn row).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A press with Fn held on a key with a character is refused by both recorders with a reason (or recorded as what will fire), never silently recorded as the key without Fn
- [ ] #2 The Used by macOS mark and the macOS-shortcut refusal compare a macOS shortcut that needs Fn with Fn, as the menu-item checks do since TASK-375
- [ ] #3 Tests cover both, with an injected key and macOS shortcut list
<!-- AC:END -->
