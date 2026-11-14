---
id: TASK-335
title: >-
  Shortcuts: detect conflicts between a shifted key and its character (⇧⌘= and
  Zoom In ⌘+)
status: To Do
assignee: []
created_date: '2026-11-14T23:45:00Z'
labels:
  - keyboard
  - settings
dependencies: []
references:
  - TASK-327
  - TASK-193.2
  - Detour/Browser/QuickDetour/HotKeyShortcut.swift
  - Detour/App/MenuKeyEquivalentMatcher.swift
priority: low
type: bug
ordinal: 409000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-327, a known limit since TASK-193.2. Both shortcut recorders (Settings > Shortcuts and the Quick Detour hotkey) compare a recorded key with menu key equivalents by character and modifiers. Zoom In is ⌘+, which fires on the keystroke ⇧⌘= on a US layout, so recording ⇧⌘= for another command is not refused although both fire on the same keystroke. The same goes for other shifted punctuation (⌘? and ⇧⌘/ and so on), and it depends on the keyboard layout.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Recording a keystroke that would also fire an existing menu item through its shifted character is refused with that item named, in both recorders, on the current keyboard layout
- [ ] #2 The mapping uses the current layout (UCKeyTranslate or equivalent), not a US table, and the layout limits are recorded in the wiki
- [ ] #3 Tests cover ⇧⌘= vs ⌘+, ⇧⌘/ vs ⌘?, and an unshifted key that must not be refused
<!-- AC:END -->
