---
id: TASK-343
title: 'Shortcuts: Reset and saved bindings are checked for shifted-key conflicts too'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-15T07:30:00Z'
updated_date: '2026-11-15T23:56:00Z'
labels:
  - keyboard
  - settings
dependencies: []
references:
  - TASK-335
  - TASK-327
  - Detour/Commands/ShortcutBindings.swift
  - Detour/Browser/QuickDetour/HotKeyShortcut.swift
priority: low
type: bug
ordinal: 419000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-335. Recording a shortcut now refuses a shifted keystroke that would also fire another item through its character (⇧⌘= is ⌘+ on a US layout), using the current keyboard layout. Two paths still compare by character only: a row's Reset (resetting Zoom In to ⌘+ while another command holds ⇧⌘= is not refused) and the binding resolver, so bindings saved before TASK-335, or that conflict after a keyboard layout change, are never re-checked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Reset refuses, with the holder named, when the default it restores would collide with another binding through a shifted character
- [x] #2 When the shortcuts are loaded (launch, layout change) a pair of bindings that fire on the same keystroke is detected and shown in Settings > Shortcuts, without silently dropping either
- [x] #3 Tests cover the reset case and a saved conflicting pair, on the US and one other installed layout
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. One mapping, TASK-335's: KeyboardLayout.keyCodes(typing:) (the keys that type a character with no modifier) and KeyEquivalent.shiftedKeyEquivalents(on: layout), which builds a HotKeyShortcut per such key and asks HotKeyShortcut.shiftedKeyEquivalent (the recorders' rule), so a saved key equivalent (a character, no key code) gets the same answer as a recorded keystroke. KeyEquivalent.firesOnSameKeystroke(as:shiftedEquivalents:).
2. Reset (ShortcutsSettingsViewController.reset): after the exact holder, refuse when the default would share a keystroke with another command's binding, in either direction, naming the holder and both shortcuts.
3. Saved pairs: ShortcutResolution.sameKeystrokeConflicts (pure, over effective keys; both keep their shortcuts, AppKit fires the exact one, TASK-335's measurement) and ShortcutBindingStore.sameKeystrokeConflicts(shiftedEquivalents:). Detected at launch and on a keyboard layout change (kTISNotifySelectedKeyboardInputSourceChanged, distributed): logged by AppDelegate; the Shortcuts pane reloads on the change and marks both rows.
4. Display (Chosen by Claude, provisional): the row's orange note, as 'Used by macOS' (TASK-295): 'Same key as <other>', a tooltip saying which runs and to record another; macOS's note first when both.
5. Tests (ShortcutConflictTests / ShortcutsSettingsPaneTests): the mapping on US and French; reset refused for ⌘+ while ⇧⌘= is held (US) and the French case on its own keys, and the reverse direction; a saved conflicting pair detected with both kept and both rows marked, on US and French; no false positive (⌘=, ⌥⇧⌘=, letters, layout without the pair).
6. Runtime: a data-dir defaults suite with Reload Page = ⇧⌘= saved: launch log line, both rows marked in Settings > Shortcuts (AX), Zoom In's reset refused (AX press) when it was changed; layout-change plumbing by posting the distributed notification (the user's input source is not switched).
7. Wiki keyboard-shortcuts (limits from TASK-335 updated), review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: one mapping, TASK-335's. KeyboardLayout.keyCodes(typing:) finds the keys that type a saved shortcut's character with no modifier (a saved shortcut names a character, not a key); KeyEquivalent.shiftedKeyEquivalents(on:) asks HotKeyShortcut.shiftedKeyEquivalent (the recorders' rule) for each, so a saved key equivalent and a recorded keystroke get one answer; firesOnSameKeystroke(as:shiftedEquivalents:). Reset (ShortcutsSettingsViewController.reset): after the exact holder, refused when the built-in shortcut and another command's binding are one keystroke in either direction (ShortcutBindingStore.command(sharingKeystrokeWith:)): '⌘+ and ⇧⌘= are one keystroke on this keyboard, and ⇧⌘= is now Reload Page's shortcut. Change that one first.' Saved pairs: ShortcutResolution.sameKeystrokeConflicts (pure, over the effective keys; nothing dropped: AppKit fires the Shift-held exact one, TASK-335's measurement) and ShortcutBindingStore.sameKeystrokeConflicts/reportSameKeystrokeConflicts; AppDelegate logs pairs at launch and on every input source change (distributed kTISNotifySelectedKeyboardInputSourceChanged = KeyboardLayout.selectionDidChangeNotification, category 'shortcuts'); the pane reloads on it and marks both rows.
Chosen by Claude (not yet confirmed by the user): the display is the row's orange note, like 'Used by macOS' (TASK-295): 'Same key as <other>', tooltip '⌘+ and Reload Page's ⇧⌘= are one keystroke on this keyboard, which runs Reload Page. Record another shortcut for one of them.'; both rows of a pair marked; macOS's note wins when a row has both. Alternatives: a line under the list naming the pairs, or an alert when Settings opens.
Found at runtime and fixed (pre-existing, TASK-327's warning line): while a refusal showed, the Shortcuts list collapsed to nothing (the warning line was only held above the pane's bottom and nothing gave the list a height; the existing exact-holder reset refusal does it too, reproduced in a unit test before the fix). The line now sits on the pane's bottom and the list takes the rest.
Tests: ShortcutConflictTests +7 (the mapping on US and French: keypad-only '+', ⇧⌘à = ⌘0 on French only, ⇧⌘/ none on French, ⌥⇧⌘=, letters, no layout; a saved ⇧⌘= pair with Zoom In found on US and French with both kept; ⇧⌘à vs Actual Size on French only; both rows marked, the note and tooltip, macOS's note first; the marks following a layout change; Zoom In's reset refused on US and French and Actual Size's on French only; the holder in either direction), ShortcutsSettingsPaneTests +1 (the list keeps its height under a refusal; failed before the fix: list 2 pt). Run: ShortcutsSettingsPaneTests, ShortcutConflictTests, ShortcutBindingStoreTests, ShortcutMenuTests, SpaceJumpTests, HotKeyShortcutTests, QuickDetourHotKeyTests, MenuKeyEquivalentMatcherTests, MainMenuCharacterizationTests, SettingsSwitchRowTests, SettingsPaneColumnsTests, SettingsPaneHeightTests: 233 tests, 0 failures (after the review's fixes and the layout fix).
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-343, its defaults suite seeded with CommandShortcuts page.reload = ⇧⌘=; current layout of this Mac): launch logged 'Shortcuts page.reload (⇧⌘=) and page.zoom-in (⌘+) are one keystroke on this keyboard layout; both kept, marked in Settings > Shortcuts'; Settings > Shortcuts (Accessibility reader, search 'zoom in' / 'reload page', screenshot): Zoom In's row 'Same key as Reload Page', Reload Page's 'Same key as Zoom In', both keys kept (⌘+, ⇧⌘=). A posted input source change notification logged the pair again (pre-review build). Relaunched with Zoom In also saved on ⌥⌘=: its reset button pressed through Accessibility was refused with the message above and Zoom In kept ⌥⌘=; on the final build (15:54, after the review and the layout fix) the warning shows under the list and the list keeps its rows (screenshot). Not verified: an actual input source switch (the user's input source was not changed; the notification was posted instead, which also reached other apps listening to it, harmlessly); a non-US layout at runtime (tests only).
Review (code-review medium --fix): 7 findings, 4 fixed (the test posted the real distributed notification system-wide: the pane now takes layoutChangeCenter and the test posts on its own center; the layout is read only for Shift-held shortcuts; the holder lookup computes the key's shifted equivalents once; a duplicate assertion and a doc). Left: saved bindings and Reset are compared with the registry's bindable commands only, not the Quick Detour item's hotkey or AppKit's own items, which the recorder's menu-based check covers (a follow-up candidate); a command in two pairs shows one partner (documented).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Reset and saved shortcuts now get TASK-335's shifted-key check, through the same mapping: a saved key equivalent's character is looked up to its keys on the current layout and the recorders' rule asked for each. A row's Reset is refused, naming both shortcuts and the holder, when the default it restores is one keystroke with another command's binding (⌘+ vs ⇧⌘=). Two saved shortcuts on one keystroke keep both (nothing dropped), are logged at launch and on every input source change, and both rows in Settings > Shortcuts say 'Same key as <other>' (provisional display), with the pane reloading on a layout change. Tests on US and French (+8, 233 tests in the shortcut and Settings suites pass); checked at runtime (launch log, both rows marked, the reset refused). Also fixed, found at runtime: the Shortcuts list collapsed while any refusal line showed. Left for a follow-up: Reset and saved pairs are compared with the registry's commands only, not the Quick Detour hotkey's item or AppKit's own items.
<!-- SECTION:FINAL_SUMMARY:END -->
