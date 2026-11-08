---
id: TASK-300
title: 'Link context menu: Open Link in Quick Detour'
status: To Do
assignee: []
created_date: '2026-11-08T08:40:00Z'
labels:
  - quick-detour
  - menus
dependencies: []
priority: medium
ordinal: 361000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc's link context menu can open a link in Little Arc (the user, Nov 8 2026); Detour's Quick Detour is its counterpart but has no menu entry. Today a link reaches Quick Detour only by ⌥⌘-click, which depends on the Settings › Quick Detour checkbox "Open links and sidebar tabs in Quick Detour with ⌥⌘-click" (on by default) and is not discoverable, or through a Link Route.

The browser window's link menu is built in BrowserWebView (willOpenMenu, Detour/Browser/Window/BrowserWebView.swift ~85-105): it replaces WebKit's link items with Open Link in New Tab, Open Link in New Window and, outside a Peek, Open Link in Split View. A Quick Detour window keeps WebKit's own link items, where opening a link already opens another Quick Detour (TASK-193.1). Sidebar tabs open a copy in Quick Detour with ⌥⌘-click (TabSidebarViewController ~83), also with no menu item.

Things to decide while building it: which profile the Quick Detour uses (the window's, as ⌥⌘-click does), what a Private window does (a Private Quick Detour, as today), whether the item shows inside a Peek, whether it follows the ⌥⌘-click setting or is always offered, and whether the sidebar tab menu gets a matching "Open in Quick Detour".
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Right-clicking a link in a browser window offers Open Link in Quick Detour next to the other Open Link items, and choosing it opens the link in a Quick Detour window exactly as ⌥⌘-click does (same profile; Private in a Private window)
- [ ] #2 The item's behavior in a Peek and its relation to the ⌥⌘-click setting are decided with the user and implemented
- [ ] #3 Whether the sidebar tab menu gets an Open in Quick Detour item is decided with the user (and implemented if yes)
- [ ] #4 Checked at runtime with /verify in a normal and a Private window
- [ ] #5 The website's Quick Detour guide page (when it exists, TASK-292.8) mentions the menu item
<!-- AC:END -->
