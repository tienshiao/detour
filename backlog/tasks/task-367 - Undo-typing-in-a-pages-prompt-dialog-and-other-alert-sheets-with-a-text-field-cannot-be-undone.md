---
id: TASK-367
title: >-
  Undo: typing in a page's prompt() dialog (and other alert sheets with a text
  field) cannot be undone
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - undo
  - webkit
dependencies: []
references:
  - wiki/platform/page-key-equivalents-and-undo.md
priority: low
type: bug
ordinal: 448000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-349's review. AppKit disables actions aimed at a window with a sheet attached, so Cmd+Z in an NSAlert accessory field (a page's prompt() in a browser or Quick Detour window) reaches nothing. TASK-349 solved the same problem for Settings' sheets with per-sheet responders.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Cmd+Z / Shift+Cmd+Z in a prompt() field undo and redo its typing, never TabStore's list
- [x] #2 A test covers it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Runtime first, on the build without the fix: a page's prompt() in a browser window and in a Quick Detour window (fixture page on loopback calling prompt() after load), real keys: type in the field, Cmd+Z / Shift+Cmd+Z, Edit > Undo's state.
2. A small view that answers browserUndo:/browserRedo: and validates them with FieldUndo for its window (FieldUndoView, in FieldUndo.swift), used as the alert's accessory container: the prompt() field in BrowserWindowController and QuickDetourWindowController, and the HTTP sign-in sheet's username/password container (same gap, 'other alert sheets with a text field'). The sheet's own chain then answers, ahead of the parent window AppKit disables while the sheet is attached.
3. Tests (failing first): a page's prompt() through the real UI delegate in a browser window and in a Quick Detour window (setTimeout(() => prompt(...))): the sheet's field typed into; Undo/Redo resolve inside the sheet, 'Undo Typing' undoes, 'Redo Typing' redoes; TabStore's list untouched; the sheet ended with a return code in teardown.
4. Runtime again with the fix.
5. Wiki (page-key-equivalents-and-undo, browser-undo table), review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Runtime before the fix (Debug with TASK-366, DETOUR_DATA_DIR=DetourVerify-348, docs/harness/task367/drive.py: prompt.html served on 127.0.0.1:8765 calls prompt() after load; real keys posted with axdrive; a tab closed with a real Cmd+W on the browser's list): in a browser window and in a Quick Detour window (opened from the launcher with real keys) the sheet's field had the keys when it opened; after typing 'qd' Edit > Undo read 'Undo', disabled, and Cmd+Z left 'qd' in the field; no tab reopened. Premise confirmed.

Implementation: FieldUndoView (FieldUndo.swift), an NSView that answers browserUndo:/browserRedo: and validates them with FieldUndo for its window, is the alert's accessory container: the prompt() field in BrowserWindowController+WKUIDelegate and QuickDetourWindowController+WebKit (FieldUndoView.wrapping(field)), and the HTTP sign-in sheet's username/password container (HTTPAuthenticationPrompt, shared by both window kinds). It sits in the fields' responder chain, ahead of the sheet window, so the sheet answers itself, as SiteSearchForm does; the parent window, which AppKit disables while the sheet is attached, is never asked.
Scope: the sign-in sheet is included because the task's title names 'other alert sheets with a text field' and it had the same gap (same one-line change). No other alert sheet in Detour has a text field (searched for accessoryView: the Site Search sheet already answers, TASK-349).
Tests (SettingsAndPopupUndoTests +3): testUndoInAPagesPromptInABrowserWindowIsItsFieldsTyping and testUndoInAPagesPromptInAQuickDetourIsItsFieldsTyping (a real prompt() through the window's UI delegate: the sheet's field typed into; Undo/Redo resolve inside the sheet, disabled 'Undo' with nothing typed, 'Undo Typing' undoes, 'Redo Typing' redoes; TabStore's list untouched; OK hands the page 'qd') failed before the change (nothing in the sheet answered Undo); testUndoInTheSignInSheetIsItsFieldsTyping (HTTPAuthenticationPrompt.handle with a hand-built Basic challenge on a plain window; Cancel rejects) written with the fix, not run against the old code. Run: SettingsAndPopupUndoTests, PageUndoRoutingTests, QuickDetourWindowTests, QuickDetourOpenInWindowTests, WebKitDelegateReachabilityTests, MainMenuCharacterizationTests: 69 tests, 0 failures.
Runtime with the fix (Debug 08:27, a fresh DETOUR_DATA_DIR=DetourVerify-348, docs/harness/task367/drive.py): 18/18: in a browser window and in a Quick Detour window (opened from the launcher with real keys) the prompt's field had the keys when the sheet opened; Edit > Undo disabled with nothing typed and Cmd+Z did nothing; after typing 'qd' 'Undo Typing' enabled, Cmd+Z emptied the field, Shift+Cmd+Z restored it; a tab closed with a real Cmd+W stayed closed throughout. OK then gave the page 'qd' (its title 'Answered: qd'); a screen capture showed the prompt sheet laid out as before. (A first run on the old data dir started without a closed tab: the restored fixture tab prompted at launch, so the setup Cmd+W was disabled; rerun on a fresh dir.) Not verified at runtime: the sign-in sheet (test only).

Review (code-review medium --fix): no correctness findings. Fixed: the prompt and sign-in tests share one in-sheet check (checkSheetFieldUndo; the sign-in copy now also asserts Redo resolves to the same target); FieldUndo's overview names FieldUndoView; the wiki's TASK-366 and TASK-367 paragraphs moved after TASK-349's 'Measured with the fix, the same script' paragraph, which they had split from its subject. The reviewer probed with a standalone AppKit run: the wrapped field still has the keys when the sheet opens, and in the sign-in sheet Undo after moving to the password field has only the password's typing. Not changed: FieldUndoView, PopupContentView and SiteSearchForm each carry the same three members (unifying touches classes outside this task); the harness focuses the field through Accessibility if needed (it never needed to: it had the keys when the sheet opened, both runs). Altitude, for the lead: each alert sheet with a text field opts in at its call site; an app-level fallback for a sheet key window would cover any future one.

After the review's edits: SettingsAndPopupUndoTests + QuickDetourLauncherTests: 28 tests, 0 failures.

User decisions 2026-11-16: kept as built (no choice in these notes was marked Chosen by Claude): FieldUndoView as the accessory of the prompt() sheet in both window kinds and of the HTTP sign-in sheet, each opting in at its call site. The review's altitude notes (an app-level fallback for sheet key windows; FieldUndoView, PopupContentView and SiteSearchForm repeating the same three members) are filed with TASK-366's as TASK-391.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Typing in a page's prompt() sheet (browser and Quick Detour windows) and in the HTTP sign-in sheet can now be undone: the alert's accessory is a FieldUndoView, which answers Edit > Undo/Redo inside the sheet with the fields' own typing (FieldUndo), never TabStore's list; before, AppKit disabled the actions aimed at the window behind the sheet and nothing answered (measured with real keys in both windows). Tests: SettingsAndPopupUndoTests +3 (real prompt() in both window kinds, failing before the change; the sign-in sheet); 69 tests in the related suites pass. Runtime: docs/harness/task367/drive.py 18/18 with real keys. Limits: the sign-in sheet is checked by test only; any future alert sheet with a field has to use FieldUndoView.
<!-- SECTION:FINAL_SUMMARY:END -->
