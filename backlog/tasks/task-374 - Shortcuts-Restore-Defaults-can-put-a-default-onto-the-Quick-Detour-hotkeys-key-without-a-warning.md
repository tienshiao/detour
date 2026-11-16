---
id: TASK-374
title: >-
  Shortcuts: Restore Defaults can put a default onto the Quick Detour hotkey's
  key without a warning
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:54:00Z'
updated_date: '2026-11-16T21:45:00Z'
labels:
  - keyboard
  - shortcuts
dependencies: []
references:
  - wiki/features/keyboard-shortcuts.md
priority: low
type: bug
ordinal: 455000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-350's agent. TASK-350 made Reset and saved shortcuts check the Quick Detour hotkey and menu items no command is; Restore Defaults does not run those checks.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Restore Defaults warns about (or marks) a default that collides with the Quick Detour hotkey or an outside holder
- [x] #2 A test covers it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. One validator (ShortcutResolution.resetConflict, pure): a default against other commands' shortcuts (exact, then the same keystroke through a shifted character) and the holders outside the commands (TASK-350); one message builder. A row's Reset calls it with today's effective keys (behaviour unchanged).
2. Restore Defaults (ShortcutResolution.restoreDefaultsConflicts, pure): evaluated against the state the restore leaves, not today's bindings (a swap restores cleanly). Only rows the restore changes (overridden ones). A row whose default clashes with an outside holder keeps its own shortcut; then, to a fixpoint, a row whose default a kept row's shortcut holds (exactly or on its keystroke) is kept too. Others restored; unknown IDs dropped as before (store.resetAll(keeping:)).
3. On a clash: the kept rows are named on the warning line with the reason (the Reset refusal's words), beep. Chosen by Claude; alternative: restore everything and rely on the warning plus the Same key as marks (validator returns the list, so flipping is small).
4. Tests failing first (ShortcutConflictTests, US and French): Quick Detour exact and keystroke, an item outside the commands (French-only), the cascade, a swap that restores cleanly, nothing kept without a clash; store resetAll(keeping:) (ShortcutBindingStoreTests).
5. /verify via Settings > Shortcuts (Accessibility): seeded rebinding + Quick Detour on its default, press Restore Defaults, read the warning and rows.
6. Wiki keyboard-shortcuts (Restore Defaults, remove the limit sentence), log, review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise checked: the pane's reload already ran outsideHolderConflicts over the effective keys, so after Restore Defaults a default on the Quick Detour key got the 'Same key as Quick Detour' mark; what was missing was the check itself (Reset refuses, Restore Defaults restored onto the taken key, where with the hotkey on the default does nothing: the Carbon hotkey takes the key first and AppKit leaves the later of two items on one key with none) and any warning line.
Implementation: one validator, ShortcutResolution.resetConflict (another command's shortcut exactly, then on its keystroke through a shifted character, then a holder outside the commands), used by a row's Reset (today's effective keys; behaviour unchanged; the store's command(holding:) / command(sharingKeystrokeWith:) removed) and by ShortcutResolution.restoreDefaultsConflicts: every overridden command's default checked against the state the restore leaves (the kept commands' own shortcuts and the outside holders), to a fixpoint, so a swap restores cleanly and a command whose default a kept command holds is kept too. ShortcutBindingStore.resetAll(keeping:) drops every other entry, unknown IDs included. The warning line: 'Restore Defaults left Reload Page as it is: ⌘R is the Quick Detour shortcut (Settings > Quick Detour). Change that one first.' / 'Restore Defaults left 2 commands as they are. New Tab: … Reload Page: …', with a beep.
Chosen by Claude (not yet confirmed by the user): on a clash Restore Defaults leaves that command as it is (keeps its shortcut) and names it on the warning line, as a row's Reset refuses; alternative: restore everything and warn (the validator returns the list, so flipping is a few lines in restoreDefaults).
Tests: failing first against the old Restore Defaults (4 new tests, 13 assertions failed; the swap test passes either way). New: ShortcutConflictTests +5 (Quick Detour shortcut, Quick Detour keystroke on US and French, an item outside the commands on French only, a command kept because a kept one holds its default exactly and on the keystroke, a swap restored and an earlier refusal cleared), testTheStoreFindsTheHolderInEitherDirection rewritten as testTheResetCheckFindsTheHolderInEitherDirection; ShortcutBindingStoreTests +1 (resetAll(keeping:)). Run: ShortcutConflictTests, ShortcutBindingStoreTests, ShortcutsSettingsPaneTests, ShortcutMenuTests, SpaceJumpTests, MenuKeyEquivalentMatcherTests, HotKeyShortcutTests, QuickDetourHotKeyTests: 173 tests, 0 failures (after the review). One earlier run had SpaceJumpTests.testAddReorderAndDeleteChangeWhatAShortcutOpensWithNoMenuRebuild fail on its spin wait; it passed alone and in the next full run of the group (timing, not this change).
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-374, endpoint; screen locked, so open_ui settings pane=shortcuts, click and screenshots through the endpoint instead of Accessibility): suite seeded with New Tab cleared, Reload Page ⌘T, Close Tab ⌥⌘W, the Quick Detour hotkey ⌘R and off. Restore Defaults clicked: Close Tab back on ⌘W, New Tab still None, Reload Page kept, the warning line 'Restore Defaults left 2 commands as they are. New Tab: ⌘T is now Reload Page's shortcut. Change that one first. Reload Page: ⌘R is the Quick Detour shortcut (Settings > Quick Detour). Change that one first.', the list kept its height; the stored CommandShortcuts held only tab.new and page.reload. Not verified at runtime: a non-US layout (tests only).
Review (code-review medium --fix): no correctness bug; 1 fixed (resetAll(keeping:) reuses write(); doc comment). Left: a command not overridden whose new default an override took is not named (pre-existing resolver rule: it had none before the restore either); Check for Updates hidden from the pane is checked too (it has no default, so it can never be kept); holders' shifted equivalents re-read per check (a handful of commands); an empty reason list cannot happen from the caller.

User decisions 2026-11-16: confirmed: on a clash, Restore Defaults leaves that command as it is (keeps its shortcut) and names it on the warning line with Reset's reason (rather than restoring everything and warning).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Restore Defaults in Settings > Shortcuts now runs the check of a row's Reset (one validator, ShortcutResolution.resetConflict) on every overridden command, against the state the restore leaves. A command whose default the Quick Detour hotkey or a menu item no command is holds (exactly, or on its keystroke through a shifted character) keeps its own shortcut, and so does a command whose default a kept one holds; the rest are restored, and the warning line names each command left with Reset's reason. Before, the default was put back onto the taken key and only the 'Same key as' mark showed it. Tests on US and French (failing first; 173 tests in the shortcut suites pass); checked at runtime through the endpoint. Provisional (Claude's choice): leave the clashing command as it is rather than restore and warn.
<!-- SECTION:FINAL_SUMMARY:END -->
