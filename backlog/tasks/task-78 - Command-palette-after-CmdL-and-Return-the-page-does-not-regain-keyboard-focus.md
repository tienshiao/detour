---
id: TASK-78
title: >-
  Command palette: after Cmd+L and Return the page does not regain keyboard
  focus
status: To Do
assignee: []
created_date: '2026-09-14 08:03'
labels:
  - window
  - command-palette
  - bug
dependencies: []
priority: medium
ordinal: 78000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-76 review (2026-09-14): BrowserWindowController.dismissCommandPalette only restores first responder in the peek case, so after opening the palette with Cmd+L and committing with Return, the window (or the palette's field) keeps first responder and the page's web view receives no key events at all until the user clicks into it — page shortcuts, typing into an autofocused field, and scrolling with the keyboard all do nothing. Fix: on dismissal, return first responder to the pane's web view (the selected tab's, or the peek web view when a peek is showing) in every dismissal path — commit, Esc, click-outside — mirroring how the peek case already does it; check the new-tab path (Cmd+T commits a navigation in a new tab whose web view is created during the dismissal) and the split case (focus the focused pane, selectedTabID). Files: Detour/Browser/Window/BrowserWindowController.swift (dismissCommandPalette, showCommandPalette), Detour/Browser/CommandPalette/CommandPaletteView.swift.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After Cmd+L, typing a URL and pressing Return, the loaded page receives keyboard input without a click (verified in the signed build: space scrolls the page, or a page shortcut works)
- [ ] #2 The same holds for Cmd+T into a new tab, for Esc-dismissal (focus returns to the page that was showing), and for a split, where the focused pane regains first responder
- [ ] #3 A unit test on BrowserWindowController covers dismissCommandPalette restoring first responder to the pane web view in the commit and Esc paths
<!-- AC:END -->
