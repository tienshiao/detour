---
id: TASK-333
title: 'Pages: ⇧⌘Z (Redo) in a page is never matched by BrowserWebView''s interception'
status: To Do
assignee: []
created_date: '2026-11-14T23:45:00Z'
labels:
  - keyboard
  - undo
dependencies: []
references:
  - TASK-327
  - Detour/Browser/Window/BrowserWebView.swift
priority: low
type: bug
ordinal: 407000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-327. BrowserWebView intercepts ⌘Z and ⇧⌘Z so undo and redo reach the page (or Detour's own undo) correctly. The ⇧⌘Z branch compares charactersIgnoringModifiers with "z", but with Shift held the event reports "Z", so the branch never runs and ⇧⌘Z takes the menu path instead. TASK-327 removed ⇧⌘Z from the shortcut reservations for that reason. Find out what the branch was meant to do (git history, the task that added it) before changing it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The intended behaviour of the ⇧⌘Z branch is found and recorded, and ⇧⌘Z in a page does that (in text fields, contenteditable and outside them)
- [ ] #2 TASK-327's shortcut reservations match the fixed behaviour (⇧⌘Z reserved again if it is taken before the menus)
- [ ] #3 A test covers the key matching with and without Shift; checked at runtime with /verify
<!-- AC:END -->
