---
id: TASK-331
title: >-
  Navigation: ⌘[ and ⌘] with the page focused go through Detour's Back and
  Forward, so ⌘[ closes a child tab to its opener
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T23:44:00Z'
updated_date: '2026-11-15T00:07:00Z'
labels:
  - navigation
  - keyboard
dependencies: []
references:
  - TASK-325
  - TASK-320
  - Detour/Browser/Window/BrowserWebView.swift
  - wiki/tabs/back-swipe-to-opener.md
priority: medium
type: bug
ordinal: 405000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 during TASK-325 and again in TASK-320. Navigate > Back (⌘[) on a tab opened from another tab, with no back history, closes the child and selects its opener (navigateBackOrCloseChildTab), and so do the sidebar Back button, the back swipe (TASK-325) and the palette's Back (TASK-320). With the page focused, ⌘[ does nothing on such a tab: the item appears disabled, likely because WKWebView's own goBack:/goForward: actions sit ahead of the window controller in the responder chain and validate against WebKit's back list. Observed on the TASK-325 branch, not yet confirmed on a build without it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The cause is confirmed (with the page focused, on a build from before TASK-325 and on main) and recorded
- [x] #2 ⌘[ with the page focused on a child tab with no back history closes it and selects its opener, as the Back button does; ⌘] goes forward as before
- [x] #3 With focus in a page text field, the palette, the find bar or the sidebar, ⌘[ / ⌘] behave the same as the menu item, and WebKit's own back/forward still runs on tabs that have history
- [x] #4 A test covers which responder handles goBack:/goForward: with the web view first responder; checked at runtime with /verify
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Confirm the cause (AC #1): with the page's web view first responder, Navigate > Back resolves to WKWebView's own goBack: (WKIBActions, validated by WKWebView's validateUserInterfaceItem against WebKit's back list), ahead of BrowserWindowController in the responder chain. Check at runtime on a 410d1a1 build (before TASK-325) and on main: child tab with no back item, web view first responder, real Cmd+[ posted to the process; read the menu item's resolution and enablement.
2. Fix in BrowserWebView: override goBack(_:)/goForward(_:) and validateUserInterfaceItem(_:) for those two actions so that in a browser window they go to the window controller (navigateBackOrCloseChildTab semantics, focused pane, Peek first) and are validated by its rule; a Quick Detour window keeps WebKit's. Covers any key the user binds (TASK-327) and a menu click, not just Cmd+[.
3. Comments: BrowserCommands.back (comment only) and CommandDispatch.perform's controller: note.
4. Tests (new BackForwardResponderTests): with the web view first responder the chain still resolves goBack:/goForward: to the web view, the Back item is enabled on a child with no history and closes it to its opener; a split's other pane focused acts on that pane; with history (loopback server) Back/Forward walk WebKit's history; text fields/palette/find bar/sidebar resolve to the controller.
5. /verify: real Cmd+[ / Cmd+] posted to the app process (CGEventPostToPid) with the web view first responder, in a page text field, and from the sidebar.
6. Wiki: back-swipe-to-opener edge case, browser-commands gotcha, log line.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Cause confirmed (AC #1), 2026-11-14, Debug builds, DETOUR_DATA_DIR=DetourVerify-331-main / -pre, DETOUR_MCP=1, fixture page with a target=_blank link, window key (set_window_frame activate=true), real Cmd+[ posted to the process (CGEventPostToPid, docs/harness/task327/axdrive.swift):
- main (6d33753) and 410d1a1 (before TASK-325), same result: on the child tab (no back item) with the page focused (document.hasFocus() true), Cmd+[ reached the page (its keydown listener saw cmd+[) and then did nothing; run_menu_item path Navigate > Back answered menu_item_disabled (Forward too). On the same tab, after Cmd+L moved focus to the palette, Cmd+[ closed the child and selected its opener.
- Why: WKWebView declares goBack:/goForward: (WKIBActions) and validates them by validateUserInterfaceItem against WebKit's back list; with the web view first responder the nil-targeted menu item resolves to it, ahead of BrowserWindowController. New BackForwardResponderTests on unfixed main: the target is the web view and both items are disabled (4 of 6 tests failed as expected; the sidebar-focused and with-history tests passed).
- The endpoint's native click on a sidebar row left the page focused (document.hasFocus() stayed true). That click hands mouseDown to the view directly and skips the window's click-to-focus step, so it says nothing about a real click; the sidebar-focused case is covered by the unit test only.

Fix: BrowserWebView overrides goBack(_:)/goForward(_:) and validateUserInterfaceItem(_:) for those two actions; in a browser window they go to BrowserWindowController.goBack/goForward (navigateBackOrCloseChildTab, the focused pane, an open Peek first) and are enabled by its validateMenuItem (the registry's rule). A Quick Detour window, or a web view in no browser window, keeps WebKit's. Works for any key bound to Back/Forward (TASK-327) and a menu click, not only Cmd+[. ShortcutBindings and the reserved keys are untouched: no key is taken outside the menus. BrowserCommands.swift: the comment on page.back only (no code). CommandDispatch: comment only; perform(..., controller:) stays.

Tests: new BackForwardResponderTests (6): with the page first responder both items still resolve to the web view and are enabled by the controller's rule; Back closes a child with no history to its opener; Forward with nothing ahead leaves the tab; Back acts on the split pane that has the keys; with history (loopback server) Back and Forward walk WebKit's list and the tab stays; with the sidebar table first responder the controller answers. On unfixed main 4 of them failed (the cause), all 6 pass with the fix. Also run: BrowserCommandRegistryTests 22, MainMenuCharacterizationTests 9, NavigationSwipeTests 37, PaletteCommandRowsTests 13, PaletteCommandWindowTests 9: 96 tests, 0 failures.

Runtime (/verify), Debug build 15:57 with the fix, DETOUR_DATA_DIR=DetourVerify-331, DETOUR_MCP=1, window key (set_window_frame activate=true), real key events posted to the process (CGEventPostToPid via docs/harness/task327/axdrive.swift), page focus checked with document.hasFocus():
- child tab, page body focused: Cmd+[ closed it and selected the opener; same with the page's <input> focused and with a contenteditable focused.
- page calls preventDefault on Cmd+[: the page's keydown ran and the child stayed open (the page still gets the key first; nothing taken before it).
- palette (Cmd+L) and find bar (Cmd+F) focused: Cmd+[ closed the child to its opener.
- child with history (navigated to /second.html): Cmd+[ went back to child.html (tab stayed), Cmd+] forward to second.html, Cmd+[ back, and Cmd+[ on the first page closed it to the opener.
- run_menu_item Navigate > Back / Forward with the page focused: completed (was menu_item_disabled before).
Not checked at runtime: sidebar focus (the endpoint's native click did not move focus off the page, see above; covered by the unit test), a Quick Detour window (code path unchanged: super), a split pane (unit test).
Review (code-review medium --fix): no correctness bugs; added a comment that the hand-off stays last (Back can close the view's tab). Noted: Forward with the page focused is now enabled with nothing ahead, as from the sidebar (the controller's rule).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Cmd+[ / Cmd+] (and any key bound to Back/Forward, or a menu click) with the page focused now go through Detour's Back and Forward, so Back on a tab opened from another one with no history closes it and selects its opener, as the sidebar button, swipe and palette do.

Cause (confirmed on main and on 410d1a1, before TASK-325): WKWebView's own goBack:/goForward: actions, validated against WebKit's back list, sit ahead of the window controller in the responder chain while the page has the keys, so the item was disabled. BrowserWebView now overrides both actions and their validation in a browser window and hands them to the controller; a Quick Detour keeps WebKit's. The page still sees the key first (preventDefault wins).

Tests: BackForwardResponderTests (6, new) plus registry, menu characterization, swipe and palette suites, 96 tests, 0 failures. Runtime: real posted key events in a Debug build (page body, input, contenteditable, preventDefault, palette, find bar, history back/forward, menu path). Wiki: browser-commands, back-swipe-to-opener, command-palette, log.
<!-- SECTION:FINAL_SUMMARY:END -->
