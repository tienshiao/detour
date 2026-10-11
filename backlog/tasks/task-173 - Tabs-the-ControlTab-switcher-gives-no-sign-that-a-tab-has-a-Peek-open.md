---
id: TASK-173
title: 'Tabs: the Control+Tab switcher gives no sign that a tab has a Peek open'
status: To Do
assignee: []
created_date: '2026-10-11 07:21'
labels:
  - tabs
  - switcher
  - peek
dependencies: []
references:
  - Detour/Browser/Window/RecentTabSwitcher.swift
  - Detour/Browser/Window/BrowserWindowController+RecentTabSwitcher.swift
  - wiki/tabs/tab-switching.md
  - wiki/tabs/peek.md
priority: low
ordinal: 196000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A tab whose Peek is open returns to the Peek when it is selected, but its card in the Control+Tab switcher shows only the host page behind it (the snapshot is of the host's web view; the Peek is a sibling view). A user who expects to land on the Peek, or on the host, cannot tell which from the overlay.

Expected: the card of a tab that will come back with a Peek shows it — the host's picture dimmed, with the Peek's page in a panel over it, as on screen. Without a picture of the Peek (parked, restored from the session, capture failed) the panel shows the Peek's favicon.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The card of a tab whose Peek will be presented on return (live, hidden or parked) shows a panel over a dimmed preview; a tab without a Peek is unchanged
- [ ] #2 The panel shows the Peek's page as it was when the tab was left, and for the current tab as it is when the switcher opens
- [ ] #3 With no picture of the Peek, the panel shows the Peek's favicon instead of staying blank
- [ ] #4 A split's card shows the Peek of the pane that gets focus when the card is chosen
- [ ] #5 Closing or expanding the Peek removes the panel from the card
- [ ] #6 Tests cover which entries carry a Peek and the capture when the tab is left
<!-- AC:END -->
