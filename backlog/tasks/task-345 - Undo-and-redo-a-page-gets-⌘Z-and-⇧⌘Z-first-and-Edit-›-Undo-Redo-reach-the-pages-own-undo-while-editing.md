---
id: TASK-345
title: >-
  Undo and redo: a page gets ⌘Z and ⇧⌘Z first, and Edit › Undo/Redo reach the
  page's own undo while editing
status: To Do
assignee: []
created_date: '2026-11-15T07:37:00Z'
labels:
  - keyboard
  - undo
dependencies: []
references:
  - TASK-333
  - Detour/Browser/Window/BrowserWebView.swift
  - wiki/tabs/tab-lifecycle.md
priority: medium
type: feature
ordinal: 423000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decided 2026-11-14 by the user after TASK-333. Today BrowserWebView takes ⌘Z and ⇧⌘Z before the page whenever Detour's own undo list (closed tabs, moved tabs) has something to undo or redo and no editable element is focused, so canvas web apps (Figma, Google Sheets) lose their own undo and redo. And in a focused page field, ⌘Z goes to the page and then to Edit > Undo, whose browserUndo:/browserRedo: act on Detour's list: with a closed tab on the list, ⌘Z in a text box reopens the tab instead of undoing the typing; with nothing on the list it does nothing, although WebKit holds the field's edit (execCommand('undo') undoes it). TASK-333 measured both (wiki/tabs/tab-lifecycle.md). The user chose: the page first, Detour's undo only when the page does not handle the key; and Edit > Undo/Redo reach the page's own undo while editing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With no editable element focused, ⌘Z / ⇧⌘Z reach the page first; Detour's undo or redo runs only when the page does not handle the key (no preventDefault), and runs once
- [ ] #2 With an editable element focused (input, textarea, contenteditable), Edit > Undo / Redo and ⌘Z / ⇧⌘Z undo and redo the page's edit, never Detour's list, and the menu titles say so (or stay generic)
- [ ] #3 With focus outside the page (sidebar, palette), Detour's undo and redo work as today
- [ ] #4 TASK-327's shortcut reservations match the new routing
- [ ] #5 Tests cover the routing decision; checked at runtime with a canvas-style fixture that handles ⌘Z itself, a plain input and contenteditable
<!-- AC:END -->
