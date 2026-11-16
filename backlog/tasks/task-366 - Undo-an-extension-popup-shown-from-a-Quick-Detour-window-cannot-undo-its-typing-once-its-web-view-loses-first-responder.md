---
id: TASK-366
title: >-
  Undo: an extension popup shown from a Quick Detour window cannot undo its
  typing once its web view loses first responder
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T16:23:00Z'
labels:
  - undo
  - extensions
  - quick-detour
dependencies: []
references:
  - wiki/platform/page-key-equivalents-and-undo.md
  - wiki/architecture/browser-undo.md
priority: low
type: bug
ordinal: 447000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-349's review. Browser windows got a central fallback (nonBrowserKeyWindow) so a popup whose window is its own first responder still answers Undo with its field's typing; QuickDetourWindowController has no equivalent, so there Cmd+Z is disabled and the popup's typing cannot be undone.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A popup shown from a Quick Detour window answers Undo/Redo with its own typing whatever has first responder in it
- [x] #2 A test like SettingsAndPopupUndoTests' popup cases covers it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Move TASK-349's fallback rule out of BrowserWindowController into FieldUndo (keyWindowHandingUndo(to:in:), with the keyWindowSource test hook moved there too): the key window, when it is not this window, not a browser or Quick Detour window, and its own chain hands Undo to this controller or to nothing while it is not main.
2. QuickDetourWindowController's browserUndo:/browserRedo: and validateMenuItem use it first, as BrowserWindowController's do: a popup shown from a Quick Detour window whose popover window is its own first responder (the chain skips PopupContentView and reaches the Quick Detour controller through the popover window's next responder) runs the popup's own undo; a command addressed to the Quick Detour while Settings is key stays its own.
3. Tests (SettingsAndPopupUndoTests): a popup from a Quick Detour window, typed into, popover window first responder: the chain reaches the QD controller (premise), Undo enabled 'Undo Typing', undoes the popup's typing, Redo redoes, TabStore's list untouched (fails first: disabled 'Undo'); Settings key with typing: an Undo addressed to the QD controller leaves Settings' typing alone. Existing browser-window fallback tests unchanged.
4. Runtime: the API Explorer popup opened from a Quick Detour window with the endpoint, typed into, real Cmd+Z / Shift+Cmd+Z (the web view's first-responder loss cannot be produced with real input; covered by the test).
5. Wiki (page-key-equivalents-and-undo, browser-undo table), review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: the TASK-349 fallback rule moved from BrowserWindowController.nonBrowserKeyWindow into FieldUndo.keyWindowHandingUndo(to:in:) (with its keyWindowSource test hook, and FieldUndo.validateForKeyWindow for Undo/Redo validation), unchanged in substance: the key window, when it is not the controller's window nor a browser or Quick Detour window, and its own chain hands Undo to this controller, or to nothing while it is not main. BrowserWindowController.nonBrowserKeyWindow now asks it. QuickDetourWindowController's browserUndo:/browserRedo: and validateMenuItem ask it first, then their page's own undo as before.
Tests (SettingsAndPopupUndoTests +2; showPopup split into loadPopupExtension + presentPopup(from:)): testUndoInAPopupFromAQuickDetourWithoutAFirstResponderIsStillThePopups (a popup shown from a real Quick Detour window, typed 'qd', the popover window made its own first responder: its chain reaches the Quick Detour's controller (premise asserted), Undo enabled 'Undo Typing' and undoes the popup's typing, Redo redoes, TabStore's list untouched; with the Quick Detour key again, Undo is its own: disabled) failed before the QD change (disabled 'Undo', typing kept); testAnAddressedUndoWhileSettingsIsKeyIsTheQuickDetoursOwn (Settings key with typing: an Undo addressed to the Quick Detour is disabled and leaves Settings' typing alone). Run: SettingsAndPopupUndoTests, PageUndoRoutingTests, QuickDetourWindowTests, QuickDetourLauncherTests, MainMenuCharacterizationTests, BrowserCommandRegistryTests: 85 tests, 0 failures.
Runtime (Debug 08:19, DETOUR_DATA_DIR=DetourVerify-348, docs/harness/task366/drive.py: API Explorer installed and pinned in the isolated DB, a tab closed with a real Cmd+W, a Quick Detour opened from the launcher with real keys, the popup opened with an Accessibility press on the Quick Detour's title-bar button, seen in a screen capture with typing in its Create Tab input): 10/10: Edit > Undo/Redo disabled with nothing typed and Cmd+Z did nothing; typed 'qd': 'Undo Typing' enabled, Cmd+Z removed it, Shift+Cmd+Z put it back; the closed tab stayed closed; back in the browser window Cmd+Z reopened it. Not verified at runtime: the popover window losing first responder to itself (the case this task fixes; no real input produces it, covered by the test).

Review (code-review medium --fix): no correctness findings, nothing changed. Kept as is: the browser/Quick Detour type checks in keyWindowHandingUndo (redundant with the responder-target check, kept as a guard); BrowserWindowController.nonBrowserKeyWindow as a named wrapper (the TASK-349 tests and wiki use it); the test's fixed 100 ms wait and .invalid Quick Detour page (the suite's existing pattern). Altitude, for the lead: the fallback lives in each presenting controller (browser, now Quick Detour); a responder installed by ExtensionPopoverController between the popover window and the presenting window, answering Undo/Redo with FieldUndo, would cover any future presenter at once.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
An extension popup shown from a Quick Detour or quarantine window now answers Undo/Redo with its own typing even when its popover window is its own first responder: QuickDetourWindowController asks the same fallback as browser windows, whose rule moved into FieldUndo.keyWindowHandingUndo(to:in:) with TASK-349's hardened condition (only a key window whose chain hands Undo to this controller, or to nothing in a non-main window). Tests: SettingsAndPopupUndoTests +2 (the popup case failed before the change; an addressed undo with Settings key leaves its typing alone); 85 tests in the undo, menu and Quick Detour suites pass. Runtime: real Cmd+Z / Shift+Cmd+Z in API Explorer's popup opened from a Quick Detour's title bar, 10/10; the first-responder-loss case itself is test-only.
<!-- SECTION:FINAL_SUMMARY:END -->
