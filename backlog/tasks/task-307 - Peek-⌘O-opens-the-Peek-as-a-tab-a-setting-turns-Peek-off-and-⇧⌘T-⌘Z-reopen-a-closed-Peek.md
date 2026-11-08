---
id: TASK-307
title: >-
  Peek: ⌘O opens the Peek as a tab, a setting turns Peek off, and ⇧⌘T / ⌘Z
  reopen a closed Peek
status: To Do
assignee: []
created_date: '2026-11-08T10:00:00Z'
labels:
  - peek
dependencies: []
references:
  - TASK-292.6
priority: medium
ordinal: 368000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Three Peek behaviors Arc had (Arc's Peek help article; Arc for macOS 2023 release notes: "CMD Z and CMD SHIFT T will now reopen a closed Peek, like they re-open closed tabs") that Detour lacks. The website's Peek guide page (TASK-292.6) lists them under "Not in Detour" today. Requested by the user, Nov 8 2026.

1. A shortcut that opens the Peek as a tab. Arc used ⌘O ("open Peek in a new tab"). Today the only way is the Open in New Tab button next to the Peek. ⌘O is File › Open Quick Detour in Space, enabled only while a Quick Detour is key (AppDelegate ~718, QuickDetourWindowController.openInDefaultSpace); a browser window with a Peek up could take the same key for the same idea ("move this preview into a tab"), via its own menu item or validation.
2. A setting that turns Peek off. Arc had one (Arc › Settings › Links). With Peek off, links from pinned tabs and favorites to other sites (and target=_blank / window.open in them) open as new tabs instead of Peeks; whether Shift-click still peeks, and whether the setting is app-wide or per Profile, are to be decided.
3. Reopening a closed Peek with ⇧⌘T (Reopen Closed Tab) or ⌘Z, like a closed tab. A closed Peek leaves no closed-tab record today (BrowserWindowController.closePeekOverlay/hidePeekUI, BrowserTab.peekTab = nil); reopening means recording it (URL, interaction state, host tab) and restoring it as a Peek on its host if the host is still open, else as a tab.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With a Peek up in a browser window, ⌘O (or the agreed key) opens the Peek's page as a new tab exactly as Open in New Tab does, listed in a menu with the key; Quick Detour's ⌘O is unchanged
- [ ] #2 A Peek setting exists (scope and Shift-click behavior agreed with the user); with Peek off, links that would auto-peek from pinned tabs and favorites open in new tabs
- [ ] #3 Closing a Peek can be undone with ⌘Z and reopened with ⇧⌘T: it comes back as a Peek on its host tab with its page and scroll state, or as a tab when the host is gone; Private windows follow their existing closed-tab rules
- [ ] #4 Tests cover the setting's effect on the auto-peek rule, the closed-Peek record and both reopen paths
- [ ] #5 Checked at runtime with /verify
- [ ] #6 The website's Peek guide page moves these from Not in Detour to how-to steps
<!-- AC:END -->
