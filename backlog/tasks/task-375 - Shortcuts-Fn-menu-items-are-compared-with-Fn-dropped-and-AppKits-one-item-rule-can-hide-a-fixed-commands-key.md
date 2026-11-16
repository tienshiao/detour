---
id: TASK-375
title: >-
  Shortcuts: Fn menu items are compared with Fn dropped, and AppKit's one-item
  rule can hide a fixed command's key
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T09:55:00Z'
updated_date: '2026-11-16T18:11:00Z'
labels:
  - keyboard
  - shortcuts
dependencies: []
references:
  - wiki/features/keyboard-shortcuts.md
  - wiki/platform/appkit-gotchas.md
priority: low
type: bug
ordinal: 456000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15/16 during the two-lane batch (TASK-349..358, 228.12/228.13), TASK-350's agent. (1) Items that need Fn (fn-D, fn-E, Window tiling) are compared with Fn dropped, as the recorder does, so a binding on the same key without Fn could be named against them. (2) AppKit keeps a key equivalent on only one menu-bar item (macOS 26; docs/harness/task350); after a duplicate is seeded into defaults, an emptied live item can let the recorder accept a key a fixed command should hold. No current default is affected.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Fn is part of the comparison (or the difference is recorded with its reason)
- [x] #2 The recorder checks fixed commands by their registry key, not the live item
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike (docs/harness/task375/fn-items.swift, dup-released.swift): how AppKit matches items whose mask holds Fn against presses with and without Fn, arrows and F-keys; whether an item AppKit emptied for a duplicate gets its key back.
2. Fn in the comparison: KeyEquivalent.normalized keeps Fn on a key with a character (holdsFn), so isSameShortcut (holders, the recorders' menu check, the Reset/Restore check) tells fn⌃F from ⌃F, while arrows and F-keys stay compared without it; a Fn-held key has no shifted equivalents. The TASK-56 fast-path matcher follows (added by the code review).
3. One held-key rule, HotKeyShortcutValidation.heldKeyEquivalent(of:): a fixed command's item holds its registry key unless an App Shortcut applies; used by keystrokeHolders and both recorders' menu check (Settings > Shortcuts and Quick Detour).
4. Tests failing first, US and French where the layout enters: Fn pure / holders / recorder with an injected key / the real bar's fn-D and fn-E; both recorders refusing ⌘C for an emptied Copy item; the seeded duplicate's own row; an arrow press with Fn and the numeric-pad bit still matching in the fast path.
5. /verify through the endpoint (screen locked): New Window seeded on ⌘C, re-recording ⌘C on its row refused for Edit > Copy.
6. Wiki (keyboard-shortcuts, quick-detour-hotkey, appkit-gotchas Menus), log, review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Measured first (docs/harness/task375, macOS 26, 2026-11-16). fn-items.swift: an app cannot give its own item Fn (AppKit logs 'only supported for system-provided menu items' and drops it); AppKit's own Start Dictation fn-D and Emoji & Symbols fn-E fire only with Fn (fn+E opened the palette, E alone nothing); an item without Fn does not fire on a press holding Fn on a key with a character (fn⌘E did not fire ⌘E, fn⌃G not ⌃G); arrow and F-keys carry Fn on every press, so there it decides nothing. No Window tiling item appeared in the spike or in the test host's bar (whose Fn items are fn-D and fn-E only, neither with ⌘ or ⌃, which no binding could equal). dup-released.swift: an item AppKit emptied for a duplicate key gets it back once the other item lets go (Copy read '' while New Window held ⌘C and 'c' once New Window moved to ⌘K; seen again at runtime through run_menu_item key=cmd+c); the one-item rule showed with Copy on AppKit's copy: and no target, not between two items on an app's own action and target. So part (2) is narrower than filed: once the seeded duplicate moves, the live menu is right again; the live menu misleads while the duplicate holds, on the duplicate's own row (its item is left out of the check and Copy's is empty), where re-recording ⌘C was accepted.
Implementation: (1) KeyEquivalent.holdsFn / isFunctionKey; normalized keeps Fn on a key with a character, so isSameShortcut (holders, the recorders' menu check, the Reset/Restore check) tells ⌃fn-F from ⌃F, while ⌃fn-← stays ⌃←; a Fn-held key has no shifted equivalents; propertyList still drops Fn. (2) HotKeyShortcutValidation.heldKeyEquivalent(of:): a fixed command's item holds its registry key unless an App Shortcut applies, any other item its live key; the default for keystrokeHolders (the pane's closure removed) and for both recorders' menu check (menuItemPath now compares the held key with canDispatch, each menu's items before its submenus' as before), so the Quick Detour pane's recorder gets it too. MenuKeyEquivalentMatcher unchanged.
Not changed (reported): the recorder records a press made with Fn as the shortcut without it; the TASK-56 fast path ignores Fn, so a Globe+⌘ press can be answered for a ⌘ item AppKit would not fire (a miss would be the safe side); an AppKit item with no registry key that AppKit emptied is still read live (none known).
Tests: failing first (8 assertions in 4 tests against the old code; the recorder half of the Fn test needs the new itemKey parameter). New in ShortcutConflictTests: testFnIsPartOfAShortcutOnAKeyWithACharacter, testAHolderHoldingFnIsComparedWithFn (pure, reset check, recorder with an injected Fn key), testTheRealMenuBarsFnItemsAreNotNamedForAShortcutWithoutFn, testTheRecordersCheckAFixedCommandByItsRegistryKey (Shortcuts and Quick Detour recorders), testRecordingASeededDuplicateAgainOnItsOwnRowIsRefused.
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-374, endpoint, screen locked so no Accessibility): suite seeded with New Window on ⌘C; the row showed 'Same key as Copy'; clicking New Window's recorder and pressing ⌘C (press_key) was refused with '⌘C is the shortcut of Edit > Copy.' and the binding stayed; in an earlier launch New Window recorded ⌘K, then New Tab's ⌘C was refused for Edit > Copy (with Copy's live key already back, so that one does not separate old and new code). Not verified at runtime: Fn (no Fn item with ⌘ or ⌃ on the bar; tests with an injected key).

Review (code-review medium --fix): 6 findings, 2 fixed by the review. Fixed: the TASK-56 fast path (MenuKeyEquivalentMatcher.item(matchingCharacters:)) now requires the item and the press to agree on holdsFn: with a binding now allowed on ⌃F beside a ⌃fn-F item, a fn-⌃F press in a delegate-driven menu would otherwise fire the binding instead of AppKit's item (test MenuKeyEquivalentMatcherTests.testFnOnAKeyWithACharacterIsNotIgnored; side effect: run_menu_item key=e no longer finds Emoji & Symbols' fn-E). The real-bar test filters with holdsFn. Left: displayString shows no Fn glyph (a Fn holder is never named today); menuItemPath reads each item's held key per recording keystroke (small); isFunctionKey not shared with HotKeyShortcut.init(event:) (that one checks every scalar); heldKeyEquivalent reads the registry key for fixed commands only, where the pane's old closure did for any registry command not excluded (no other such item holds a key: parameterised commands' dynamic items carry none) — intended.
Tests run after the review: ShortcutConflictTests, ShortcutBindingStoreTests, ShortcutsSettingsPaneTests, ShortcutMenuTests, SpaceJumpTests, MenuKeyEquivalentMatcherTests, HotKeyShortcutTests, QuickDetourHotKeyTests, MainMenuCharacterizationTests: 189 tests, 0 failures; AutomationToolsTests, AutomationWindowKindsTests, PaletteCommandWindowTests: 42 tests, 0 failures. The runtime check ran before the review's matcher change (which only changes Fn presses).

Correction to the first notes block: MenuKeyEquivalentMatcher is changed (the review's fix, above), not unchanged; the fast path is no longer under 'Not changed'. After the advisor pass: the spikes reproduce what their headers say (fn-items.swift has an app item given Fn again: AppKit's log line and the dropped mask; dup-released.swift runs both variants), the Fn and recorder tests loop over US and French, an arrow press carrying Fn and the numeric-pad bit is pinned as a fast-path match. Run: ShortcutConflictTests, ShortcutBindingStoreTests, ShortcutsSettingsPaneTests, ShortcutMenuTests, SpaceJumpTests, MenuKeyEquivalentMatcherTests, HotKeyShortcutTests, QuickDetourHotKeyTests, MainMenuCharacterizationTests, SettingsAndPopupUndoTests, AutomationPrivateAccessTests, AutomationToolsTests, AutomationWindowKindsTests, PaletteCommandWindowTests: 248 tests, 0 failures. Copy's live key was not read in the own-row runtime launch: that it was empty rests on TASK-350's runtime measurement and dup-released.swift.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Settings > Shortcuts now compares Fn: on a key with a character a menu item holding Fn is a different shortcut from the same key without it (KeyEquivalent.normalized keeps Fn there; arrows and F-keys, whose every press carries Fn, are compared without it), so macOS's own Fn items are never named for a binding, as AppKit's matching (measured) never fires one for the other; the TASK-56 fast-path matcher follows (from the review). Both shortcut recorders (Settings > Shortcuts and Quick Detour) read a fixed command's item by its registry key through one rule, HotKeyShortcutValidation.heldKeyEquivalent, shared with the holders of TASK-350, so re-recording ⌘C on the row of a binding seeded on Copy's key is refused for Edit > Copy. Measured on the way: an item AppKit emptied for a duplicate gets its key back once the other lets go, which narrows (2) to that own-row case and checks made while the duplicate holds. Tests failing first, US layout plus the real bar (189 + 42 tests pass); checked at runtime through the endpoint. Not done: a press made with Fn is still recorded without it.
<!-- SECTION:FINAL_SUMMARY:END -->
