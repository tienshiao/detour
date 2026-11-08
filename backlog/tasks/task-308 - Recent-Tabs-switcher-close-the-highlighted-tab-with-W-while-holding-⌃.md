---
id: TASK-308
title: 'Recent Tabs switcher: close the highlighted tab with W while holding ⌃'
status: To Do
assignee: []
created_date: '2026-11-08T10:00:00Z'
labels:
  - tabs
  - recent-tabs
dependencies: []
references:
  - TASK-292.6
priority: low
ordinal: 369000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc let you close tabs from its Control-Tab switcher by continuing to hold Control and tapping W (Arc for macOS 2023 release notes: "You can now close tabs from the recent tab switcher (CTRL + TAB) by continuing to hold CTRL and tapping W"). Detour's switcher (RecentTabSwitcher.swift: a local key monitor; ⌃Tab / ⌃⇧Tab move, ←/→ move, Return or keypad Enter commits, Escape cancels, releasing ⌃ commits) has no way to close a tab, so the website's Recent Tabs page (TASK-292.6) lists it under "Not in Detour". Requested by the user, Nov 8 2026.

Things to settle while building it: a split card (one card for two tabs) closes both or asks; pinned tabs and favorites (close = make dormant, as ⌘W does); the highlight moves to the next card and the switcher stays open while ⌃ is held; the last card closing ends the switcher; closing goes through the same path as ⌘W, so ⇧⌘T / Undo bring it back.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With the switcher open and ⌃ held, pressing W closes the highlighted card's tab through the same path as ⌘W (Undo and Reopen Closed Tab bring it back), the card disappears and the highlight moves to the next card
- [ ] #2 Split cards, pinned tabs and favorites follow a rule agreed with the user
- [ ] #3 Closing the last card closes the switcher; releasing ⌃ afterwards selects the highlighted tab as usual
- [ ] #4 Tests cover the switcher's close handling (RecentTabOrder / switcher model) for normal, split and pinned cards
- [ ] #5 Checked at runtime with /verify
- [ ] #6 The website's Recent Tabs page moves it from Not in Detour to the how-to steps
<!-- AC:END -->
