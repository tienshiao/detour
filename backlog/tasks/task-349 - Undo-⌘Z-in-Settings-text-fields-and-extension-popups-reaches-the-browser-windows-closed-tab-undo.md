---
id: TASK-349
title: >-
  Undo: ⌘Z in Settings text fields and extension popups reaches the browser
  window's closed-tab undo
status: To Do
assignee: []
created_date: '2026-11-16T04:51:00Z'
labels:
  - keyboard
  - undo
dependencies: []
references:
  - TASK-345
  - TASK-346
  - wiki/platform/page-key-equivalents-and-undo.md
priority: low
type: bug
ordinal: 428000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Known since TASK-345, raised again in TASK-346's review. Browser windows, Quick Detour/quarantine windows and (since TASK-346) the launcher answer Undo/Redo themselves; the Settings window's text fields and an extension's action popup do not, so Edit > Undo / ⌘Z there can fall through to the main browser window's browserUndo: and reopen a closed tab. Check each at runtime first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each place is checked at runtime: Settings fields (search engines, site search sheet, Link Routes, Profiles), an extension action popup's fields
- [ ] #2 In every one, Undo/Redo undo the field's typing or do nothing, and never run TabStore's undo; menu titles follow
- [ ] #3 Tests cover Settings and the popup with a closed tab on TabStore's list
<!-- AC:END -->
