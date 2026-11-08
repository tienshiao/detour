---
id: TASK-300
title: 'Link context menu: Open Link in Quick Detour'
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T08:40:00Z'
updated_date: '2026-11-08T11:18:00Z'
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
- [x] #1 Right-clicking a link in a browser window offers Open Link in Quick Detour next to the other Open Link items, and choosing it opens the link in a Quick Detour window exactly as ⌥⌘-click does (same profile; Private in a Private window)
- [x] #2 The item's behavior in a Peek and its relation to the ⌥⌘-click setting are decided with the user and implemented
- [x] #3 Whether the sidebar tab menu gets an Open in Quick Detour item is decided with the user (and implemented if yes)
- [x] #4 Checked at runtime with /verify in a normal and a Private window
- [ ] #5 The website's Quick Detour guide page (when it exists, TASK-292.8) mentions the menu item
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Link menu (BrowserWebView.willOpenMenu, browser windows only): add 'Open Link in Quick Detour' after Open Link in New Window, before Split View; always offered (not tied to the Opt-Cmd-click setting), in a Peek too. Its action sets contextMenuLinkAction = .openInQuickDetour and performs WebKit's Open Link in New Window item, as the other items do.
2. createWebViewWith: .openInQuickDetour -> openLinkInQuickDetourFromMenu: a web link (http/https, the same rule Opt-Cmd-click uses, now QuickDetour.opensLinkInQuickDetour) goes through openQuickDetour(url, firing:) — the page's profile, Private in a Private window; any other link does what Opt-Cmd-click on it does (falls to Cmd-click: a background tab).
3. Sidebar tab menus (single tab, pinned entry, split row, pinned split row): 'Open in Quick Detour', a copy of the row's address computed by quickDetourCopyURL(forRow:at:) at the right-click point (the split pane under the pointer), sent through the same delegate call as Opt-Cmd-click.
4. Tests: OpenInQuickDetourMenuTests (menu content and order, setting off, Peek, the action, normal and Private profiles, non-web link, sidebar menu incl. split pane and Private).
5. Runtime check in a normal and a Private window; website facts in the notes.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: the item is always offered (independent of the ⌥⌘-click setting, which governs only the gesture), also inside a Peek, and the sidebar tab menu gets a matching 'Open in Quick Detour'.

Implemented (Nov 8 2026, @claude):
- Link menu (BrowserWebView.willOpenMenu, browser windows only): 'Open Link in Quick Detour' after Open Link in New Window and before Open Link in Split View. Always offered, independent of the Opt-Cmd-click setting; also inside a Peek (where Split View is still left out). Like its neighbours it sets contextMenuLinkAction (.openInQuickDetour) and performs WebKit's Open Link in New Window item; createWebViewWith hands the link to openLinkInQuickDetourFromMenu(_:firing:in:), which does what Opt-Cmd-click on the link does: a web link (http/https, QuickDetour.opensLinkInQuickDetour, now also the rule inPageLinkClickBranch uses) -> openQuickDetour(url, firing:) on the page's profile (Private in a Private window; a Peek's is the window's space's profile), never routed; any other link (mailto: etc.) is a Cmd-click, a background tab, as Opt-Cmd-click on it is. A Quick Detour window's own link menu is unchanged (WebKit's items; its Open Link in New Window already opens another Quick Detour).
- Sidebar tab menus: 'Open in Quick Detour' on a tab row and a pinned entry (after Share), and on split and pinned split rows (after Copy URL). It is the Opt-Cmd-click copy: quickDetourCopyURL(forRow:at:) at the right-click point (DraggableTableView.lastMenuPoint, new), so a split row copies the pane under the pointer; same delegate call (tabSidebar(_:didRequestQuickDetourCopyOf:)), so the sidebar's profile and Private in a Private window. Not offered for a row with no address. Favourite tiles' menu (only Remove from Favorites) was not given the item: the decision named the sidebar tab menu.
- Tests: new OpenInQuickDetourMenuTests (11): item order in the link menu, offered with the setting off, offered in a Peek (no split item there), choosing it performs WebKit's item with the Quick Detour action, a web link opens a Quick Detour on the page's profile with no tab, a Private window's is Private, a mailto: link opens a background tab and no Quick Detour, the http/https rule, the sidebar menu's copy (setting off), a split row's pane under the pointer, a Private window's sidebar menu. Run with LinkRoutingEligibilityTests (45), QuickDetourEntryPointsTests (21), QuickDetourSidebarCopyTests (6), SidebarDragDropTests (39): 122 tests, 0 failures.
- Runtime (/verify, DETOUR_DATA_DIR=DetourB8-300-2, temporary DEBUG harness posting real right-clicks with NSApp.postEvent and choosing from the real menus once they tracked), with the Opt-Cmd-click setting OFF: normal window link menu read 'Open Link in New Tab, Open Link in New Window, Open Link in Quick Detour, Open Link in Split View, Download Linked File, Copy Link, ...' and choosing it opened a Quick Detour on Default with https://example.com/linked; in a Peek the menu had the item (no Split View) and it opened the same on Default; the sidebar tab menu (Copy URL, Share, Open in Quick Detour, ...) opened a copy of the tab's address on Default; in a Private window the link menu and the sidebar tab menu each opened a Private Quick Detour (profile Private). Not checked at runtime: a split row's pane choice and a non-web link (unit-tested). Defaults keys and data dirs of DetourB8-300-1/-2 removed; their WebKit store directories under ~/Library/WebKit/com.detourbrowser.mac/ were left.
- Website facts for AC #5 (Quick Detour guide page, TASK-292.8): right-click a link in a browser window (also in a Peek) and choose 'Open Link in Quick Detour' (listed after Open Link in New Window); it opens the link in a new Quick Detour exactly as Option-Command-click does: on the page's profile, a Private Quick Detour from a Private window. It is always in the menu, even when Settings > Quick Detour > 'Open links and sidebar tabs in Quick Detour with ⌥⌘-click' is off (that setting only controls the click). Right-click a tab in the sidebar and choose 'Open in Quick Detour' to open a copy of that tab's page in a Quick Detour (the tab stays where it is; on a split tab, the half you right-clicked).
Website AC pending (held for release).

Website: updated Quick Detour (/features/quick-detour/: Open Link in Quick Detour in the link menu, also in a Peek; Open in Quick Detour in the sidebar tab menu; both offered with the ⌥⌘-click setting off; Arc box Same) on website branch next-release (ef26356), held for the release
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Browser windows' link menu offers Open Link in Quick Detour (after Open Link in New Window), always and inside a Peek too; it does exactly what Opt-Cmd-click does (page's profile, Private in a Private window; non-web links fall to a background tab). The sidebar's tab row menus offer Open in Quick Detour, the Opt-Cmd-click copy (split row: the pane under the pointer). 11 new tests plus related suites (122, 0 failures); runtime-checked in normal and Private windows and in a Peek with the Opt-Cmd-click setting off. Only the website AC (#5) remains, facts in the notes.
<!-- SECTION:FINAL_SUMMARY:END -->
