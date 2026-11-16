---
id: TASK-348
title: >-
  Quick Detour launcher: browser-window shortcuts typed in its field (⌘W, ⌘R,
  ⌘T) act on the browser window behind it
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T04:51:00Z'
updated_date: '2026-11-16T16:11:00Z'
labels:
  - keyboard
  - quick-detour
dependencies: []
references:
  - TASK-346
  - Detour/Browser/QuickDetour/QuickDetourLauncher.swift
  - wiki/platform/page-key-equivalents-and-undo.md
priority: medium
type: bug
ordinal: 427000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-346's code review, from reading the code; not run yet. The launcher panel (QuickDetourPalettePanel) has no controller that answers the browser window's menu actions and never becomes main, so a menu key equivalent typed in its field falls through to the browser window behind it, the same cause TASK-346 fixed for Undo/Redo. ⌘W would then close a tab in that window while the person is typing in the launcher.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Confirmed at runtime which browser-window commands reach the window behind the launcher while the launcher is key
- [x] #2 None of them acts on a browser window while the launcher is key: each is either answered by the launcher (⌘W closes the launcher, for example) or disabled
- [x] #3 A test covers ⌘W with a tab open behind the launcher; checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Runtime first, on the unfixed build (AC #1): Detour in front with two tabs, the launcher opened with Opt+Cmd+N, real keys posted (axdrive) for the browser-window shortcuts with an observable effect (Cmd+W, Shift+Cmd+T, Cmd+D, Cmd+T, Cmd+L, Cmd+Y, Cmd+S); record which reach the browser window behind. Stop and report if none do.
2. QuickDetourPalettePanel answers every window-controller command of the registry (BrowserCommands.all with responder .windowController) itself, as plain @objc methods: Close Tab (Cmd+W) closes the launcher (through the launcher that owns the panel, nothing opens); Undo/Redo stay the field's (TASK-346); every other one is a no-op and validates false. Items that are no window-controller command (App delegate: Cmd+N, Opt+Cmd+N, Cmd+,; AppKit: Cut/Copy/Paste, Minimize) still go to super / the app delegate as now.
3. Tests (QuickDetourLauncherTests): registry-driven: every .windowController action resolves along the panel's chain to the panel, and validates false except Close Tab (enabled) and Undo/Redo (the field's); a browser window with a tab behind the launcher: Close Tab through the panel closes the launcher and leaves the browser window's tabs alone; the panel's chain fails first without the fix. Not dependent on the panel being key.
4. Runtime again with the fix, same script: no command reaches the browser window; Cmd+W closes the launcher.
5. Wiki (quick-detour-launcher, page-key-equivalents-and-undo limits paragraph), review, Backlog, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Runtime before the fix (Debug from a8af7b5c, DETOUR_DATA_DIR=DetourVerify-348, docs/harness/task348/drive.py without --fixed: real keys posted to the pid with axdrive, Detour in front, the launcher opened with Opt+Cmd+N over a browser window with two tabs and a closed tab on its list): with the launcher key and still up, Cmd+W closed a tab in the browser window behind it (2 -> 1), Shift+Cmd+T reopened one (1 -> 2), Cmd+D pinned the selected tab, Cmd+Y opened History there; Cmd+T and Cmd+L opened the browser window's own palette behind the launcher (seen in a screen capture of the browser window: 'Where do you want to go?', and 'detour://history/' for Cmd+L). Cmd+R and Opt+Cmd+Down showed no visible change (about:blank pages; one tab). So every browser-window command with an observable effect reached the main window behind the launcher.

Implementation: QuickDetourPalettePanel answers every window-controller command of the registry (BrowserCommands.all with responder .windowController, 40 actions) with a plain @objc method, so AppKit's nil-target search stops at the panel instead of going on to the main window. Close Tab (Cmd+W) closes the launcher through the launcher that owns the panel (onCloseCommand; nothing opens); Undo/Redo stay the field's (TASK-346); every other one is a no-op and validates false (a beep for its key). NSWindow's own selectNextTab:/selectPreviousTab: are overridden as no-ops. Items that are no window-controller command still go to super: the app delegate's (Cmd+N, Opt+Cmd+N, Cmd+,) and AppKit's (Cut/Copy/Paste/Select All reach the field editor).
Chosen by Claude (not yet confirmed by the user): Cmd+W closes the launcher (as Escape on an empty field / clicking away do), keeping the item's title 'Close Tab' (browser windows do not retitle it back); alternative: disable it like the rest. Every other browser-window command (Cmd+T, Cmd+L, Shift+Cmd+T, Cmd+D, Cmd+R, Cmd+Y, the Spaces and Navigate items) does nothing in the launcher, disabled; alternative: Cmd+L selecting the field's text, Cmd+T doing nothing silently.
Tests (QuickDetourLauncherTests +2, both failed before the fix: the panel's chain resolved the actions to nothing, NSApp.target(forAction:) to the browser window's controller, and CommandDispatch.perform of Close Tab in the panel returned false with the launcher still up): testEveryBrowserWindowCommandStopsAtTheLauncher (registry-driven: every .windowController action resolves to the panel and validates false except Close Tab; the app delegate's and AppKit's text items unchanged); testCloseTabInTheLauncherClosesItAndLeavesTheBrowserWindowsTab (a Private browser window with a tab, main, behind the launcher; with the panel key and the browser window main, as in this run, NSApp.target(forAction:) stops at the panel; Close Tab closes the launcher, opens nothing, leaves the tab). Run: QuickDetourLauncherTests, MainMenuCharacterizationTests, BrowserCommandRegistryTests, PageUndoRoutingTests, QuickDetourHotKeyTests, QuickDetourEntryPointsTests, SettingsAndPopupUndoTests: 110 tests, 0 failures.
Runtime after the fix (Debug 08:01, same data dir, docs/harness/task348/drive.py --fixed): 18/18: none of Cmd+W, Shift+Cmd+T, Cmd+D, Cmd+T, Cmd+L, Cmd+Y, Cmd+R, Opt+Cmd+Down changed the browser window (tab count, pinned count, selected tab); Cmd+W closed the launcher, the others left it up; a screen capture of the browser window after Cmd+T and after Cmd+L showed no palette in it; back in the browser window Cmd+W still closed a tab. Not verified: the launcher shown by the global hotkey over another app (not registered in Debug; that app keeps the menu bar); menu clicks in the menu bar while the launcher is key (the same validation answers them, not run).

Review (code-review medium --fix): fixed: the panel resets a disabled command's contextual title to the registry's ('Unpin Tab' or 'Open Peek in New Tab' left by a browser window no longer shows, disabled, while the launcher is key; the test seeds a stale title); Close Tab keeps the panel alive while the launcher closes it (withExtendedLifetime). Not changed: the test's NSApp.target(forAction:) check runs only with the panel key and the browser window main (it ran in this run: it failed before the fix); the 'is a window-controller command' filter is written twice (panel and test), kept apart on purpose. Out of scope, for the lead: any other key window that never becomes main and does not answer these commands still lets them fall through to the main browser window, e.g. the automation approval panel (non-activating, key only if needed; with Full Keyboard Access on, Cmd+W/Cmd+D/Shift+Cmd+T there would act on the browser window behind it; read in the review, not run). A general fix would disable every .windowController command in BrowserWindowController.validateMenuItem when a non-main key window hands it there, as nonBrowserKeyWindow does for Undo.

After the review fixes: QuickDetourLauncherTests, BrowserCommandRegistryTests, MainMenuCharacterizationTests: 49 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Quick Detour launcher panel now answers every browser-window command of the registry itself, so none falls through to the browser window behind it. Measured first with real keys: Cmd+W closed a tab there, Shift+Cmd+T reopened one, Cmd+D pinned one, Cmd+Y opened History, Cmd+T and Cmd+L opened its palette. Now Cmd+W closes the launcher (nothing opens) and the rest are disabled (Claude's choices, to confirm); Undo/Redo stay the field's (TASK-346); app and AppKit items unchanged. Tests: QuickDetourLauncherTests +2 (registry-driven, and Cmd+W with a tab behind), failing before the fix; 110 tests in the related suites pass. Runtime: docs/harness/task348/drive.py --fixed 18/18. Out of scope: other never-main key windows (the automation approval panel) can still let these commands through.
<!-- SECTION:FINAL_SUMMARY:END -->
