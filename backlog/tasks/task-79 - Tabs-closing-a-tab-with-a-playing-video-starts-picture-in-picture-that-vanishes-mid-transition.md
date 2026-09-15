---
id: TASK-79
title: >-
  Tabs: closing a tab with a playing video starts picture-in-picture that
  vanishes mid-transition
status: In Progress
assignee: []
created_date: '2026-09-15 01:07'
labels:
  - bug
  - tabs
dependencies: []
modified_files:
  - Detour/Browser/Window/BrowserWindowController.swift
  - Detour/Browser/Window/BrowserWindowController+TabSidebar.swift
priority: medium
ordinal: 79000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Closing the selected tab while its video plays briefly starts picture-in-picture, which disappears during the transition. The close paths settle selection onto a neighbour BEFORE removing the tab, so selectTab treats the closing tab as a switched-away, still-playing tab and enters PiP. The store's teardown then pauses media and releases the web view, killing the PiP window.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Closing the selected tab (Cmd+W, sidebar close, archive) with a playing video does not start picture-in-picture
- [ ] #2 Closing a selected pinned tab or a selected split group with a playing video does not start picture-in-picture
- [ ] #3 Switching away from a playing tab, or moving it to another space, still starts picture-in-picture
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Added a scoped settlingSelectionForClose helper that sets a flag selectTab checks before both switch-away PiP entries (tab and peek). Wrapped the three close paths that settle selection before closing: closeTab(at:wasSelected:), closePinnedTab(at:), and the close-split-group handler. Move-to-space shares settleSelectionLeaving but keeps the tab alive, so it is deliberately not wrapped. Removal paths that select after the store has torn the tab down (extension tabs.remove, back-closes-child) never entered PiP, because teardown clears isPlayingAudio and the web view. Build succeeds; live PiP behaviour not observed (screen capture is blocked for the shell host).
<!-- SECTION:NOTES:END -->
