---
id: TASK-348
title: >-
  Quick Detour launcher: browser-window shortcuts typed in its field (⌘W, ⌘R,
  ⌘T) act on the browser window behind it
status: To Do
assignee: []
created_date: '2026-11-16T04:51:00Z'
labels:
  - keyboard
  - quick-detour
dependencies: []
references:
  - TASK-346
  - Detour/Browser/QuickDetour/QuickDetourLauncher.swift
  - wiki/platform/page-key-equivalents-and-undo.md
priority: medium
type: bug
ordinal: 427000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-346's code review, from reading the code; not run yet. The launcher panel (QuickDetourPalettePanel) has no controller that answers the browser window's menu actions and never becomes main, so a menu key equivalent typed in its field falls through to the browser window behind it, the same cause TASK-346 fixed for Undo/Redo. ⌘W would then close a tab in that window while the person is typing in the launcher.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Confirmed at runtime which browser-window commands reach the window behind the launcher while the launcher is key
- [ ] #2 None of them acts on a browser window while the launcher is key: each is either answered by the launcher (⌘W closes the launcher, for example) or disabled
- [ ] #3 A test covers ⌘W with a tab open behind the launcher; checked at runtime
<!-- AC:END -->
