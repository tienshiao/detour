---
id: TASK-295
title: >-
  Spaces: keyboard shortcuts that jump straight to a space by its position
  (first through ninth)
status: To Do
assignee: []
created_date: '2026-11-08T07:38:00Z'
labels:
  - spaces
  - menus
dependencies: []
references:
  - TASK-292.2
priority: medium
ordinal: 356000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Today the only keyboard route between spaces is Spaces › Next Space (⌥⌘→) and Previous Space (⌥⌘←), which step one at a time and don't wrap. With four or five spaces, getting from the first to the last takes several presses or a reach for the trackpad. Arc users expect a direct jump: Arc's help center gives Control-1, Control-2… on macOS (seen in the Wayback Machine capture of "Spaces: Distinct Browsing Areas", Jul 2026). The website's Spaces guide currently lists this as "Not in Detour" in its Coming from Arc box and answers "Is there a shortcut to jump to a specific Space?" with "Not by number".

Context for the choice of keys (the user's call): the only digit key equivalent in the app today is ⌘0 (View › Actual Size). ⌃1–⌃9 match Arc, but macOS can bind them to Mission Control's "Switch to Desktop N" when that shortcut is turned on in System Settings, in which case the system takes the keys first. ⌘1–⌘9 select tabs in Chrome and favorites/bookmarks in Safari, so they may be wanted for tabs or Favorites later. Spaces are ordered as in Settings › Spaces; Private windows have no other spaces to jump to.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The key binding is chosen with the user before implementation (⌃1–⌃9, ⌘1–⌘9 or another set), with the Mission Control conflict considered
- [ ] #2 Each of the first nine spaces, in Settings › Spaces order, has a shortcut that switches the key window to it, listed in the Spaces menu next to the space's name
- [ ] #3 A shortcut for a position with no space does nothing (no beep, no error), and the shortcuts are disabled in Private windows
- [ ] #4 Reordering, adding or deleting spaces updates which space each shortcut opens without a relaunch
- [ ] #5 Tests cover the position-to-space mapping, including fewer than nine spaces and more than nine
- [ ] #6 Checked at runtime with /verify: the shortcuts switch spaces in the key window only
- [ ] #7 The website's Spaces guide (src/content/features/spaces.md: shortcuts table, FAQ and Coming from Arc box) is updated when this ships
<!-- AC:END -->
