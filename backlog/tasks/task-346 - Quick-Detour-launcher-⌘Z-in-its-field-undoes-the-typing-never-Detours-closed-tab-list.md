---
id: TASK-346
title: >-
  Quick Detour launcher: ⌘Z in its field undoes the typing, never Detour's
  closed-tab list
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T21:26:00Z'
updated_date: '2026-11-16T00:09:00Z'
labels:
  - keyboard
  - undo
  - quick-detour
dependencies: []
references:
  - TASK-345
  - Detour/Browser/QuickDetour/QuickDetourLauncher.swift
  - wiki/platform/page-key-equivalents-and-undo.md
priority: low
type: bug
ordinal: 425000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-345's code review, not fixed there (it predates the change and lives in another file). The Quick Detour launcher panel (the palette panel the Quick Detour hotkey opens) does not answer Edit > Undo/Redo, so ⌘Z typed in its field falls through to the main browser window's browserUndo: and can reopen a closed tab there instead of undoing the typing. Since TASK-345, browser windows and Quick Detour/quarantine windows answer Undo/Redo themselves; the launcher should too: its field's own undo, and never TabStore's list.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 ⌘Z / ⇧⌘Z and Edit > Undo/Redo in the launcher's field undo and redo the field's typing (or do nothing when there is none), and never run TabStore's undo
- [x] #2 Menu titles and enabled state follow the field's own undo while the launcher is key
- [x] #3 A test covers the launcher with a closed tab on TabStore's list; checked at runtime
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. QuickDetourPalettePanel answers browserUndo:/browserRedo: itself (it is in its field's responder chain, ahead of NSApp's fall-through to the main window): the first responder's undo manager (the field editor's, which is the panel's), undo/redo when it can, nothing otherwise; never TabStore's. validateMenuItem titles Undo/Redo from that manager ('Undo Typing') and enables them only when it can; other actions to super. The in-window palette (browser windows) is unchanged: TabStore's undo there (TASK-345 AC #3).
2. Check that the field registers its typing (allowsUndo on the field editor, which manager) in the test before relying on it.
3. Tests (QuickDetourLauncherTests): with a close on TabStore's list, the launcher shown: Undo/Redo resolve to the panel (CommandDispatch.responderTarget), disabled and titled 'Undo' with nothing typed and browserUndo leaves TabStore's list alone; typed text: 'Undo Typing' enabled, browserUndo empties the field, 'Redo Typing' brings it back, TabStore's close still on the list.
4. Runtime: Detour frontmost, the launcher from File > New Quick Detour Window (⌥⌘N; the global hotkey is not registered in Debug and the user's production Detour holds it), a closed tab on the list, real keys posted (docs/harness/task327/axdrive.swift): type, ⌘Z empties the field, ⇧⌘Z restores it, ⌘Z with nothing typed does nothing; the closed tab stays closed; Edit > Undo's title while the launcher is key.
5. Wiki (page-key-equivalents-and-undo, quick-detour), review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: QuickDetourPalettePanel answers browserUndo:/browserRedo: itself, with its first responder's undo manager (the field editor's, which is the panel's own NSWindow.undoManager; the field editor's allowsUndo is on, asserted in the test), and validateMenuItem titles Undo/Redo from it ('Undo Typing') and enables them only when it can. Before, the panel (no controller, no delegate answering them, never main) let the nil-target actions go on to the main window, a browser window, whose browserUndo: ran TabStore's undo. The in-window palette is unchanged (a browser window's: the browser's undo, TASK-345 AC #3).
Tests: QuickDetourLauncherTests +1 (a close on TabStore's list; Undo/Redo resolve to the panel; nothing typed: disabled, 'Undo', no-op; typed 'qd': 'Undo Typing' empties the field, 'Redo Typing' brings it back; TabStore's close untouched). Failed against a panel that does not answer the actions (TabStore's undo ran, titles 'Undo'). Run: QuickDetourLauncherTests, PageUndoRoutingTests, MainMenuCharacterizationTests, BrowserCommandRegistryTests, QuickDetourWindowTests, QuickDetourHotKeyTests, QuickDetourEntryPointsTests: 117 tests, 0 failures, none skipped.
Runtime (/verify, Debug 16:01, DETOUR_DATA_DIR=DetourVerify-346, docs/harness/task346/drive.py: real keys posted to the pid with axdrive, the launcher's field and the Edit menu read with docs/harness/task346/axlauncher.swift; Detour frontmost; a tab closed with a real Cmd+W on the list; the launcher opened with Opt+Cmd+N): nothing typed: Edit > Undo/Redo disabled, Cmd+Z changed nothing; typed 'qd': Edit > Undo 'Undo Typing' enabled; Cmd+Z emptied the field, Shift+Cmd+Z restored 'qd'; the closed tab stayed closed throughout; back in the browser window Cmd+Z reopened it. 11/11 (an Escape check in the first script was wrong: the palette's first Escape clears the text, by design). Not verified: the launcher shown by the global hotkey over another app (not registered in Debug; the user's own Detour holds Opt+Cmd+N).
Review (code-review medium --fix): no fix needed in the diff. Recorded limits: an inline completion or other programmatic rewrite of the field empties its undo list (Cmd+Z then does nothing, never the browser's); the test skips when the panel is not key (the file's pattern). Out of scope, for the lead: the launcher answers only Undo/Redo, so other browser-window commands (Cmd+W, Cmd+R, Cmd+T) pressed in it still fall through to the main browser window behind it; Settings' and extension popups' text fields still reach the browser window's browserUndo: (known since TASK-345); the panel's title/enable rules duplicate the registry's Undo/Redo closures instead of being a CommandContext.

Correction: the two review limits above are not measured at runtime: the completion clearing the field's undo comes from the reviewer's throwaway probe test (not kept), and Cmd+W/Cmd+R/Cmd+T falling through from the launcher is a reading of the responder chain, not run. The committed docs/harness/task346/drive.py is the script that ran, minus a wrong Escape check and with its paths made relative to the repository; it was not re-run in that form.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Quick Detour launcher panel now answers Edit > Undo/Redo (⌘Z, ⇧⌘Z) itself with its field's own undo, titled 'Undo Typing' and disabled with nothing typed, so they no longer fall through to the main browser window and reopen a closed tab there. Test (QuickDetourLauncherTests, failing before the fix) and 117 tests in the undo, menu and Quick Detour suites pass; checked at runtime with real keys and the Edit menu read through Accessibility. Limits: a completion or other rewrite of the field clears its undo (⌘Z then does nothing); the global-hotkey-over-another-app case not measured. Found, out of scope: other browser-window shortcuts (⌘W, ⌘R, ⌘T) pressed in the launcher still reach the browser window behind it.
<!-- SECTION:FINAL_SUMMARY:END -->
