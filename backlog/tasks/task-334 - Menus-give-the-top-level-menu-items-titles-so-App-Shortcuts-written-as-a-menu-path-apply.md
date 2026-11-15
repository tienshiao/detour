---
id: TASK-334
title: >-
  Menus: give the top-level menu items titles so App Shortcuts written as a menu
  path apply
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T23:45:00Z'
updated_date: '2026-11-15T00:28:00Z'
labels:
  - menus
  - keyboard
dependencies: []
references:
  - TASK-327
  - Detour/App/AppDelegate.swift
  - wiki/features/keyboard-shortcuts.md
priority: low
type: bug
ordinal: 408000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-327. macOS App Shortcuts (System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts) can name a menu item by title ("Close Tab") or by path ("File->Close Tab", used when a title is ambiguous). AppKit matches the path against the titles of the parent menu items, and Detour's menu bar items are untitled NSMenuItem() with titled submenus, so path-form entries never apply to Detour.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each top-level menu bar item has the same title as its submenu, and a path-form App Shortcut ("File->Close Tab") applies to the item, measured at runtime
- [x] #2 The menu bar looks the same, and MainMenuCharacterizationTests and the Shortcuts pane's "Set in System Settings" detection still pass
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Baseline: build main, launch (DETOUR_DATA_DIR=DetourVerify-334, DETOUR_MCP=1) with -NSUserKeyEquivalents path-form entries as a launch argument; record that they do not apply (run_menu_item key=, the Shortcuts row, AX bar titles).
2. Title every menu-bar item as its submenu (AppDelegate.setupMainMenu + HelpMenu.makeHelpMenuItem) through one helper; the application menu and its item take the app's name (CFBundleName).
3. Update comments that describe the 'NSMenuItem' placeholder (HotKeyShortcutValidation.menuItemPath, AutomationMenus.displayTitle).
4. Tests: MainMenuCharacterizationTests pins each bar item's title equal to its submenu's / the bar's; golden unchanged; Shortcuts pane tests + ShortcutMenuTests + HotKeyShortcutTests pass.
5. After: same launch; path-form entries apply (run_menu_item key, 'Set in System Settings' row), bar titles unchanged via AX.
6. Wiki keyboard-shortcuts (App Shortcuts section), log, code review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured before (main at 93e17a8, Debug, DETOUR_DATA_DIR=DetourVerify-334, DETOUR_MCP=1, launched with -NSUserKeyEquivalents '{ "\033File\033Close Tab" = "@~w"; "\033Detour\033Settings…" = "@~,"; "\033View\033Zoom In" = "@~="; "Show All History" = "@~y"; }' as a launch argument, never defaults write): through Accessibility (docs/harness/task295/axmenu.swift) Close Tab ⌘W, Settings… ⌘, and Zoom In ⌘+ kept their own keys; only the plain-title Show All History took ⌥⌘Y. Settings > Shortcuts: only Show All History was 'Set in System Settings'.
After (this change, build 16:25): all four took ⌥⌘ (Close Tab ⌥⌘W, Settings… ⌥⌘, , Zoom In ⌥⌘=, Show All History ⌥⌘Y); run_menu_item key=cmd+opt+w ran File > Close Tab and key=cmd+w found no item; Settings > Shortcuts showed 'Set in System Settings' with macOS's shortcut on Settings…, Close Tab, Zoom In and Show All History (screenshot checked). The bar's titles read through Accessibility (docs/harness/task334/axbar.swift: Apple, Detour, File, Edit, View, Navigate, Spaces, Extensions, Develop, Window, Help) were identical before and after. Not checked: a pixel comparison of the bar (Detour was not made frontmost, to keep the user's focus).
The app menu and its item are titled by CFBundleName (AppDelegate.appName), so its path is 'Detour->Settings…' as the bar shows it.
Tried and dropped: a unit test that puts a path-form entry in the argument domain from the test host and retitles the item; AppKit reads NSUserKeyEquivalents once, so it did not apply. MainMenuCharacterizationTests.testEveryBarItemIsTitledAsItsMenu pins the titles instead; the runtime check covers application.
Tests: MainMenuCharacterizationTests (11, +1), HelpMenuTests, BuildInfoTests, ShortcutsSettingsPaneTests, ShortcutMenuTests, ShortcutConflictTests, HotKeyShortcutTests, BrowserCommandRegistryTests, MenuKeyEquivalentMatcherTests: 128 tests, 0 failures.
Code review (medium --fix): no correctness bugs; fixed the wiki wording (an entry must be in place at launch: System Settings' own or a launch argument). Left: the app's name is literal 'Detour' in the registry's menu title while the bar uses CFBundleName (same value in every configuration today); the fallbacks for untitled bar items in menuItemPath/displayTitle stay for test fixtures built with NSMenuItem().
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Every menu-bar item is now titled as its menu (AppDelegate.menuBarItem(for:), used by setupMainMenu and the Help menu; the application menu and its item by the app's name), so macOS App Shortcuts written as a menu path ('File->Close Tab', 'Detour->Settings…') apply to Detour. Measured in the real app with path-form entries passed as a launch argument: none applied before, all did after, Settings > Shortcuts showed them as 'Set in System Settings', and the bar's titles read through Accessibility were unchanged. MainMenuCharacterizationTests pins the bar titles; its golden is unchanged. Wiki: keyboard-shortcuts (App Shortcuts), app-shell.
<!-- SECTION:FINAL_SUMMARY:END -->
