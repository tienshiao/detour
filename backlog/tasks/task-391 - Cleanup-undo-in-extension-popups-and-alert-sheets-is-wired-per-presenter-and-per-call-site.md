---
id: TASK-391
title: >-
  Cleanup: undo in extension popups and alert sheets is wired per presenter and
  per call site
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:42:00Z'
labels:
  - undo
  - cleanup
dependencies: []
references:
  - Detour/Commands/FieldUndo.swift
  - Detour/Extensions/UI/ExtensionPopoverController.swift
priority: low
type: chore
ordinal: 472000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-366 and TASK-367, their code reviews, "altitude" notes for the lead). Three places where undo for windows that are not browser windows is wired per site instead of once:

1. An extension popup whose popover window is its own first responder answers Undo through a fallback in each presenting controller (`BrowserWindowController.nonBrowserKeyWindow`, and since TASK-366 `QuickDetourWindowController`, both asking `FieldUndo.keyWindowHandingUndo(to:in:)`). One responder that `ExtensionPopoverController` inserts between the popover window and its presenter, answering Undo/Redo with `FieldUndo`, would cover every presenter, including future ones.
2. An alert sheet with a text field opts in at its call site by wrapping its accessory in `FieldUndoView` (the `prompt()` sheet in both window kinds, `HTTPAuthenticationPrompt`); a future sheet that forgets has no Undo (AppKit disables actions aimed at a window with a sheet). An app-level fallback for a sheet key window would cover every future one.
3. The same three members (`browserUndo:`, `browserRedo:`, `validateMenuItem` through `FieldUndo`) are written out in `FieldUndoView`, `PopupContentView` and `SiteSearchForm`.

Behaviour today is correct; this is cleanup. Wiki: wiki/platform/page-key-equivalents-and-undo.md, wiki/architecture/browser-undo.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An extension popup answers Undo/Redo with its own typing whatever window presents it, without a fallback in each presenting controller (SettingsAndPopupUndoTests pass unchanged)
- [ ] #2 An alert sheet with a text field gets its field undo without opting in at its call site, or the reason to keep the opt-in is recorded
- [ ] #3 FieldUndoView, PopupContentView and SiteSearchForm share one implementation of the Undo/Redo responder members
<!-- AC:END -->
