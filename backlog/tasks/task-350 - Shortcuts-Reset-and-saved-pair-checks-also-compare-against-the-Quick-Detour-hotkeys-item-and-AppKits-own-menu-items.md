---
id: TASK-350
title: >-
  Shortcuts: Reset and saved-pair checks also compare against the Quick Detour
  hotkey's item and AppKit's own menu items
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T04:51:00Z'
updated_date: '2026-11-16T09:56:00Z'
labels:
  - keyboard
  - settings
dependencies: []
references:
  - TASK-343
  - TASK-335
  - Detour/Commands/ShortcutBindings.swift
  - wiki/features/keyboard-shortcuts.md
priority: low
type: bug
ordinal: 429000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 in TASK-343's review. Recording a shortcut refuses one that collides with the Quick Detour hotkey's menu item or an AppKit-provided item, but the TASK-343 checks (a row's Reset, and saved pairs on one keystroke shown in Settings > Shortcuts) compare only with the registry's bindable commands.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Reset is refused, holder named, when the default it restores fires on the same keystroke as the Quick Detour hotkey's item or an AppKit menu item
- [x] #2 Saved bindings that share a keystroke with those are marked in Settings > Shortcuts like other pairs
- [x] #3 Tests cover both, on the US and one other layout
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Holders outside the store (HotKeyShortcutValidation.keystrokeHolders): walk the live main menu once with AppKit's eligibility (MenuKeyEquivalentMatcher.canFire: not a separator, not hidden unless allowsKeyEquivalentWhenHidden, has an action), every item that is not one of the store's commands (by identifier) nor the Quick Detour item: AppKit's insertions (Emoji & Symbols, Start Dictation, Window items), the fixed Edit commands, System Settings App Shortcuts on them; plus the Quick Detour hotkey from its setting (on or off), as rule 4 names it. Each with its menu path / title and key equivalent.
2. One matcher (ShortcutResolution.outsideHolderConflicts, pure): for each key, an exact holder first (AppKit fires the exact item first), then one on the same keystroke through a shifted character in either direction (TASK-343's shiftedEquivalents mapping); shifted equivalents computed once per key and holder.
3. Reset (ShortcutsSettingsViewController.reset): after the store's two checks, refused with the holder named when the default is one keystroke with an outside holder. Messages per holder kind (a menu item cannot be changed here; the Quick Detour shortcut is changed on its pane).
4. Saved pairs: the pane computes the outside conflicts once per reload and marks the command's row 'Same key as <holder>' (same orange note); the tooltip names the holder and, for a shifted pair, which runs; for an exact duplicate no runner is claimed (not measured). Only the editable row is marked (Quick Detour's row shows its link, AppKit items have no row): Chosen by Claude.
5. Tests (ShortcutConflictTests): gate: fresh store vs the real menu bar has no outside conflict and no refused reset on US and French; reset refused vs the Quick Detour setting exact and shifted (US and French keys), vs an unidentified item on French only, either direction; saved pairs marked vs an item (⇧⌘/ vs ⌘? on US only, ⌘+ vs ⇧⌘=), vs the Quick Detour setting, vs a fixed command on the real menu; note and tooltip text.
6. /verify: Settings > Shortcuts with a seeded binding sharing the Quick Detour key / an AppKit item: row note, reset refusal text.
7. Wiki keyboard-shortcuts + log, review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation: HotKeyShortcutValidation.keystrokeHolders walks the live menu once (MenuKeyEquivalentMatcher.canDispatch eligibility) and lists every item that is not one of the store's commands nor the Quick Detour item (in practice the fixed Edit commands, AppKit's Emoji & Symbols ⌘Space / ⌃⌘Space / fn-E and Start Dictation fn-D, App Shortcuts on them), then the Quick Detour hotkey from its setting (on or off). ShortcutResolution.outsideHolderConflicts (pure): an exact holder first, then one on the same keystroke through a shifted character in either direction (TASK-343's mapping). Reset: after the store's two checks, refused with the holder named ('⌘R is the Quick Detour shortcut (Settings > Quick Detour). Change that one first.' / '... is the shortcut of Edit > X, which cannot be changed here.'). Saved shortcuts: the pane computes outsideConflicts once per reload and marks the command's row 'Same key as <holder>'; a pair of commands is named first.
Measured (docs/harness/task350/dup-key-equivalents.swift, macOS 26): AppKit keeps a key equivalent on one item of the menu bar only. Installing a bar with two items on ⌘C leaves the later one empty; setting an item to a key the installed bar already holds leaves it empty. Found at runtime: a binding saved on ⌘C (New Window) left Edit > Copy with no key at launch, so the first build (live keys only) did not mark it. A command's item is now read with its registry key unless an App Shortcut applies.
Chosen by Claude (not yet confirmed by the user): only the command's row is marked (an AppKit item has no row; the Quick Detour row shows its link in that slot); alternative: also mark the Quick Detour row. Also: the tooltip claims no runner for an exact duplicate with a menu item ('only one of them can have it'), and for the Quick Detour hotkey says it takes the key first while it is on (a Carbon hotkey comes before menus). Not logged at launch (the store's pair log covers commands only).
Tests: ShortcutConflictTests +9 (shipped defaults vs the real menu bar: no outside conflict on US and French; a saved ⌘C marked against Edit > Copy; Copy holding its registry key after AppKit cleared its item; resets refused for the Quick Detour setting exact and on its ⇧⌘= keystroke on US and French keys; for an item no command is, exact and French-only ⇧⌘à; either direction; saved shortcuts marked: ⇧⌘/ vs ⌘? on US only, ⌘+ vs ⇧⌘= on both, French-only ⌥⇧⌘à, the Quick Detour shortcut and keystroke; a command pair named first). Run after the review: ShortcutConflictTests, ShortcutsSettingsPaneTests, ShortcutBindingStoreTests, ShortcutMenuTests, SpaceJumpTests, HotKeyShortcutTests, QuickDetourHotKeyTests, MenuKeyEquivalentMatcherTests, MainMenuCharacterizationTests, SettingsSwitchRowTests, SettingsPaneColumnsTests, SettingsPaneHeightTests: 242 tests, 0 failures.
Runtime (/verify, DETOUR_DATA_DIR=DetourVerify-350, suite seeded: Quick Detour hotkey ⌘R and off, Reload Page ⌥⌘E, New Window ⌘C; then Show All History ⌘R, Toggle Sidebar ⌃⌘Space; read through Accessibility, screenshots): New Window's row 'Same key as Copy'; Reload Page's reset pressed through Accessibility was refused with '⌘R is the Quick Detour shortcut (Settings > Quick Detour). Change that one first.' and kept ⌥⌘E, list kept its height; Show All History's row 'Same key as Quick Detour'; Toggle Sidebar on ⌃⌘Space showed 'Used by macOS' (macOS's note first; Emoji & Symbols is also a macOS shortcut). Not verified at runtime: a non-US layout (tests only); the tooltips (unit tests only); the review's tooltip rewording for the Quick Detour case came after the runtime run.
Review (code-review medium --fix): 7 findings, 1 fixed by the review (identifier checked before userKeyEquivalent), 1 by me (Quick Detour exact tooltip names the hotkey as taking the key first). Left: Restore Defaults does not check holders outside the commands (product choice, out of scope); a row with an App Shortcut is compared by its binding (pre-existing, same for pairs); the shipped-defaults test reads the real menu bar, so an 'All Applications' App Shortcut on the Mac could affect it (as testTheRealMenuBar can); the inline both-direction match duplicates firesOnSameKeystroke to read shifted equivalents once; canFire wrapper kept.

2026-11-16: the user confirmed: only the command's row gets the "Same key as" note; the exact-clash tooltip says "only one of them can have it"; clashes with outside holders are not written to the launch log.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A row's Reset and the saved-shortcut marks in Settings > Shortcuts now also compare with what the binding store does not resolve: the menu items that are no bindable command (the fixed Edit commands, AppKit's Emoji & Symbols and Start Dictation, App Shortcuts on them) and the Quick Detour hotkey from its setting, exactly or through a shifted character on the current layout, in either direction. A reset onto one is refused with the holder named; a saved shortcut sharing one's keystroke gets the orange 'Same key as <holder>' note on its row. Measured on the way: AppKit keeps a key equivalent on one item of the menu bar, so a binding saved on ⌘C empties Edit > Copy's item at launch; a command's item is therefore read with its registry key. Tests on US and French (+9; 242 tests in the shortcut and Settings suites pass); checked at runtime (Same key as Copy / Quick Detour, Reload Page's reset refused for a Quick Detour hotkey on ⌘R). Provisional: only the command's row is marked. Not done: Restore Defaults does not check these holders.
<!-- SECTION:FINAL_SUMMARY:END -->
