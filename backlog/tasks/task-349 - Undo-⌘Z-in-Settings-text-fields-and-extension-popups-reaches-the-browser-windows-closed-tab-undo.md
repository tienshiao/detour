---
id: TASK-349
title: >-
  Undo: ⌘Z in Settings text fields and extension popups reaches the browser
  window's closed-tab undo
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T04:51:00Z'
updated_date: '2026-11-16T09:56:00Z'
labels:
  - keyboard
  - undo
dependencies: []
references:
  - TASK-345
  - TASK-346
  - wiki/platform/page-key-equivalents-and-undo.md
priority: low
type: bug
ordinal: 428000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Known since TASK-345, raised again in TASK-346's review. Browser windows, Quick Detour/quarantine windows and (since TASK-346) the launcher answer Undo/Redo themselves; the Settings window's text fields and an extension's action popup do not, so Edit > Undo / ⌘Z there can fall through to the main browser window's browserUndo: and reopen a closed tab. Check each at runtime first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Each place is checked at runtime: Settings fields (search engines, site search sheet, Link Routes, Profiles), an extension action popup's fields
- [x] #2 In every one, Undo/Redo undo the field's typing or do nothing, and never run TabStore's undo; menu titles follow
- [x] #3 Tests cover Settings and the popup with a closed tab on TabStore's list
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Check each place at runtime first (docs/harness/task349/drive.py: real keys posted to the pid, fields and the Edit menu read through Accessibility, a tab closed with a real Cmd+W on the browser's list): Settings > Profiles name field, the Add Site Search sheet, a new Link Route's pattern field, an extension's action popup (API Explorer).
2. One shared rule, FieldUndo (Commands/FieldUndo.swift): the first responder's undo manager in the window (the field editor's, or the popup web view's), undo/redo when it can, titles from it, disabled with nothing; never TabStore's. The launcher (TASK-346) uses it too.
3. Answer browserUndo:/browserRedo: where each place's responder chain reaches first: SettingsWindowController (Settings is main while key), SiteSearchForm (a sheet: AppKit disables an action aimed at the window a sheet is attached to), the popup's PopupContentView (the popover window is never main and its own next responder is the window it is shown from).
4. Tests (SettingsAndPopupUndoTests) with a close on TabStore's list: a Settings field, the site search sheet (real NSAlert + SiteSearchForm), a popup typed into through the page; each failing without its responder.
5. Runtime again with the fix; wiki (browser-undo, page-key-equivalents-and-undo), review, commit.

6. (Lead, after review) Close the popup hole and protect future windows centrally: BrowserWindowController.browserUndo/validate run FieldUndo for the key window whenever it is not a browser window (nonBrowserKeyWindow); a field-less popover's Cmd+Z then does nothing. Add Profile sheet answers itself (review finding).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Runtime check BEFORE the fix (docs/harness/task349/drive.py + axundo.swift; Debug, DETOUR_DATA_DIR=DetourVerify-349, real keys posted to the pid with axdrive, Detour frontmost, a tab closed with a real Cmd+W on the list, fields and the Edit menu read through Accessibility):
- Extension popup (API Explorer, its URL input): bug confirmed. Cmd+Z with nothing typed reopened the closed tab in the browser window behind the popup, Shift+Cmd+Z closed it again, the typing was never undone. The popover window is key, never main, and its own next responder is the window it is shown from, then that window's controller (seen in the test host: _NSPopoverWindow -> browser NSWindow -> BrowserWindowController).
- Settings (Profiles name field, a new Link Route's pattern, the Add Site Search sheet): the premise does not hold. Settings is main while key (the sheet is key with Settings main), so nothing fell through; but nothing answered either: Edit > Undo was disabled, kept a stale 'Undo Close Tab' title, and the typing could not be undone (fixed anyway, per the brief: field undo and titles).
- 'Search engines': no text field exists; the engine is a pop-up button in the Profiles pane.

Implementation: Detour/Commands/FieldUndo.swift, one rule (the key window's first responder's undo manager: field editor or popup web view; titles from it; disabled with nothing; never TabStore's), used by the launcher (refactored, TASK-346 behaviour unchanged), SettingsWindowController, SiteSearchForm and AddProfileViewController (sheets: AppKit disables an action aimed at a window with a sheet attached; measured 'Undo Typing' but disabled when only Settings' controller answered), PopupContentView (popup). Central fallback in BrowserWindowController (nonBrowserKeyWindow): when the action reaches a browser window while a non-browser window is key, it runs that window's FieldUndo instead of TabStore's; covers a popup whose window itself is first responder, field-less popovers and future sheets/panels. Stale comments claiming Settings falls through corrected (undoTarget, a PageUndoRoutingTests message).
Chosen by Claude (not yet confirmed by the user): Cmd+Z / Edit > Undo while a popover without fields is key over a browser window (Downloads, site settings, emoji picker) now does nothing (disabled, 'Undo'); before it reopened a closed tab. Alternative: keep the browser's undo for field-less popovers (drop the fallback for windows whose FieldUndo manager has nothing). Side effect: the endpoint's run_menu_item Undo/Redo on a browser window while Detour is active with Settings (or a popover) key now acts on that key window.

Tests: SettingsAndPopupUndoTests (6): Settings field, site search sheet (real NSAlert + SiteSearchForm), Add Profile sheet (added by the review), popup typed into through the page, popup with its window as first responder, field-less popover (both with a stand-in key window). Each fails without its code (16 failures for the first three, 13 for the last three incl. the Add Profile one). Suites run after the final code: PageUndoRoutingTests, MainMenuCharacterizationTests, BrowserCommandRegistryTests, ExtensionPopoverSizingTests, SettingsWindowFitTests, SiteSearchPaletteTests, SettingsSwitchRowTests, SettingsAndPopupUndoTests, QuickDetourLauncherTests: 116 tests, 0 failures, none skipped.
Runtime AFTER (same script, final build 23:15): Profiles name, a space's name, Add Site Search sheet, Add Profile sheet, Link Route pattern, extension popup: nothing typed -> Undo/Redo disabled, Cmd+Z did nothing; typed -> 'Undo Typing' enabled, Cmd+Z removed the typing, Shift+Cmd+Z restored it; the closed tab stayed closed throughout; back in the browser window Cmd+Z reopened it. 46/46. Not measured at runtime: a popup opened from the sidebar button (endpoint-opened only), a popup whose window is its own first responder, a field-less popover (both test-only).
Review (code-review medium --fix): fixed the missed Add Profile sheet (+ test); finding 'popup protected only while the web view is first responder' and 'central fallback' addressed by nonBrowserKeyWindow on the lead's request; field-less popover behaviour decided as above.

Lead's review (2026-11-15, code-review medium on the committed change): the central fallback handed Undo/Redo to any non-browser key window even for a command addressed to a browser window (automation run_menu_item), reaching Settings' Automation section or a Private Quick Detour past the endpoint's gates. Fixed: nonBrowserKeyWindow defers only when the key window's own chain resolves the undo action to this controller (the popover case), or to nothing in a window that is not main; validateMenuItem computes it only for Undo/Redo. New test testAnAddressedUndoWhileSettingsIsKeyIsTheBrowserWindowsOwn; SettingsAndPopupUndoTests + PageUndoRoutingTests + QuickDetourLauncherTests 32/0 after the fix. Not re-run at runtime after this narrowing (the popover cases are covered by the existing tests). Left as follow-ups: a popup shown from a Quick Detour window has no equivalent fallback; prompt()/alert sheets with text fields cannot undo their typing.

2026-11-16: the user confirmed: Cmd+Z / Edit > Undo while a popover without text fields (Downloads, site settings, emoji picker) is key over a browser window does nothing (Undo disabled), never the browser's undo; also the shared FieldUndo rule, and fixing Settings even though its fall-through did not reproduce.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Edit > Undo/Redo (Cmd+Z, Shift+Cmd+Z) in an extension's popup no longer reaches the browser window behind it and reopens a closed tab. Settings' fields, the Add Site Search and Add Profile sheets, and the popup now undo and redo their own typing, titled 'Undo Typing', and are disabled when there is nothing to undo. One rule (FieldUndo) is shared with the Quick Detour launcher. Behind those, a browser window that still receives the actions while a non-browser window is key runs that window's undo, never TabStore's. That covers a popup whose window itself is first responder, popovers without fields (Cmd+Z there now does nothing, chosen by Claude, to confirm) and future sheets. The Settings fall-through in the task's premise did not reproduce: Settings is main while key. It left Undo disabled with a stale 'Undo Close Tab' title and no field undo, which is fixed. Tests: 6 new (each fails without its code); 116 tests in the undo, menu, Settings, popup and launcher suites pass. Runtime: 46/46 checks with real keys. Not measured at runtime: a popup from the sidebar button, a popup without a first responder, a field-less popover (tests only).
<!-- SECTION:FINAL_SUMMARY:END -->
