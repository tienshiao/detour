---
id: TASK-292.10
title: >-
  Help menu: open the Detour guide, keyboard shortcuts, Switching from Arc,
  release notes and issue reporting
status: Done
assignee:
  - '@claude'
created_date: '2026-11-08T06:59:00Z'
updated_date: '2026-11-08T10:53:00Z'
labels:
  - menus
dependencies:
  - TASK-292.2
  - TASK-292.3
  - TASK-292.9
references:
  - Detour/App/AppDelegate.swift
parent_task_id: TASK-292
priority: medium
ordinal: 351000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The app has no Help menu (the menu bar ends at Window in AppDelegate). With guide pages on the website (TASK-292) the Help menu is where users look for them, and registering it as the app's help menu also gives them macOS's built-in menu search field for free.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A Help menu is the last menu and is the app's registered help menu, so the macOS menu search field appears in it
- [x] #2 Items: Detour Help (the guide index), Keyboard Shortcuts, Switching from Arc, Release Notes, Report an Issue (GitHub issues)
- [x] #3 Each opens in a new tab of the frontmost normal browser window's active space, or a new window when there is none; never in a Quick Detour or Quarantine window
- [x] #4 The URLs are defined in one place and a test checks they are https URLs on detourbrowser.com (or github.com for issues and releases)
- [x] #5 Checked at runtime with /verify: each item opens the right page in the right window
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. HelpLinks enum (Detour/App/HelpMenu.swift): the five pages in one place. Website: /features/, /shortcuts/, /arc/ on https://detourbrowser.com. GitHub project tienshiao/detour (scripts/publish-release.sh REPO, git remote, the website's links): /releases and /issues/new.
2. Help menu built by AppDelegate.makeHelpMenuItem() (an extension in HelpMenu.swift), added last in setupMainMenu and registered as NSApp.helpMenu (macOS adds the search field). Separator before Release Notes.
3. Window choice, pure: HelpLinks.placement(windows:) over LinkPlacementWindow: the first normal (non-Private) browser window showing a space, front to back (existing NSApp.browserWindowControllersFrontToBack), else a new window (createNewWindowWithURL). Quick Detour and quarantine windows are not browser windows, so never chosen.
4. Tests: HelpMenuTests (URLs https on detourbrowser.com/github.com, exact URLs, placement cases, the menu registered and last, a page opening as a selected tab in the front window).
5. Runtime: each item with a normal window key, with a Quick Detour key, a quarantine key, only a Private window; the search field via Shift-Cmd-/.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, user decision: TASK-292.9 is done in the same batch so the Keyboard Shortcuts item has a page. Website page changes for unreleased features are committed on a website branch and held for the next release, not deployed.

Implemented (Nov 8 2026, @claude):
- Detour/App/HelpMenu.swift: HelpLinks (the five pages in one place), the pure HelpLinks.placement(windows:), and an AppDelegate extension (makeHelpMenuItem, openHelpLink, openHelpPage). AppDelegate.setupMainMenu adds the Help menu after Window and sets NSApp.helpMenu (4 lines).
- URLs: Detour Help https://detourbrowser.com/features/ ; Keyboard Shortcuts https://detourbrowser.com/shortcuts/ ; Switching from Arc https://detourbrowser.com/arc/ ; Release Notes https://github.com/tienshiao/detour/releases ; Report an Issue https://github.com/tienshiao/detour/issues/new. The GitHub project comes from the repo, not a guess: scripts/publish-release.sh (REPO="tienshiao/detour", which publishes the releases and DMGs the website's download links point at), the git remote (tienshiao/detour) and the website's own links to https://github.com/tienshiao/detour. /features/ and /shortcuts/ are being built by TASK-292.9.
- Menu: Detour Help, Keyboard Shortcuts, Switching from Arc, separator, Release Notes, Report an Issue. No key equivalents (Shift-Cmd-/ is macOS's help search).
- Window choice: the first normal (non-Private) browser window showing a space in NSApp.browserWindowControllersFrontToBack (the existing helper: key, main, then on-screen order; Quick Detour and quarantine windows are not BrowserWindowControllers so are never chosen; a minimized window is not in it) gets a new selected tab in its active space and comes forward; with none, createNewWindowWithURL (a new normal window on the default space, as assignDefaultSpace picks). No existing 'frontmost normal browser window' helper skipped Private windows, so the choice is a small pure function over the existing LinkPlacementWindow snapshot type.
- Tests: new HelpMenuTests (8): every URL https on detourbrowser.com or github.com, the exact URLs, placement (front normal window, a Private one in front passed over, only Private or none -> new window, a window with no space passed over), the menu is the registered help menu and last with the five items, a page opens as the selected tab in the front window. Also run: MenuKeyEquivalentMatcherTests (15), HotKeyShortcutTests (27). Final clean-tree run listed below.
- Runtime (/verify, DETOUR_DATA_DIR=DetourB8-29210-1 and -2, temporary DEBUG harness performing the real Help menu items): NSApp.helpMenu is the last menu, items as above. With the normal window in front, each of the five items opened a new selected tab in its active space with the right URL (tabs 1..5: features/, shortcuts/, arc/, github releases, github issues/new). With a Quick Detour key (activated by a real HID click; key=QuickDetourWindowController): Detour Help opened in the normal window, which became key; the Quick Detour kept its own page. With a quarantine window in front: Switching from Arc went to the normal window. With only a Private window (normal window closed; Private key after a real click): Keyboard Shortcuts and Release Notes each opened a new NORMAL window with the page; the Private window got no tab. Not verified: the macOS Help search field on screen (Shift-Cmd-/ was posted with Detour active, but the captures of this multi-display setup did not include the menu bar); it rests on NSApp.helpMenu being set, which the test checks. Pages were not loaded over the network (URLs checked). Defaults keys and data dirs removed; WebKit store directories under ~/Library/WebKit/com.detourbrowser.mac/ left.

Final clean-tree run (harness removed): AddressBarIconOrderTests 5, HelpMenuTests 8, MenuKeyEquivalentMatcherTests 15, OpenInQuickDetourMenuTests 11, QuickDetourDockMenuTests 7: 46 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Detour now has a Help menu, last in the menu bar and registered as NSApp.helpMenu: Detour Help (detourbrowser.com/features/), Keyboard Shortcuts (/shortcuts/), Switching from Arc (/arc/), Release Notes and Report an Issue (github.com/tienshiao/detour releases and issues/new, from scripts/publish-release.sh). URLs live in HelpLinks; each opens as a selected tab in the frontmost normal browser window's active space, or a new normal window — never a Quick Detour, quarantine or Private window (pure HelpLinks.placement). 8 tests; runtime-checked every item with a normal window, a Quick Detour key, a quarantine in front and only a Private window. The macOS search field itself was not seen on screen (registration is tested).
<!-- SECTION:FINAL_SUMMARY:END -->
