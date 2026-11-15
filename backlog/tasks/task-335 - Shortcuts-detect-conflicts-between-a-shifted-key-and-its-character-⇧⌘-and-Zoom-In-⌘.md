---
id: TASK-335
title: >-
  Shortcuts: detect conflicts between a shifted key and its character (⇧⌘= and
  Zoom In ⌘+)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14T23:45:00Z'
updated_date: '2026-11-15T00:38:00Z'
labels:
  - keyboard
  - settings
dependencies: []
references:
  - TASK-327
  - TASK-193.2
  - Detour/Browser/QuickDetour/HotKeyShortcut.swift
  - Detour/App/MenuKeyEquivalentMatcher.swift
priority: low
type: bug
ordinal: 409000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-14 in TASK-327, a known limit since TASK-193.2. Both shortcut recorders (Settings > Shortcuts and the Quick Detour hotkey) compare a recorded key with menu key equivalents by character and modifiers. Zoom In is ⌘+, which fires on the keystroke ⇧⌘= on a US layout, so recording ⇧⌘= for another command is not refused although both fire on the same keystroke. The same goes for other shifted punctuation (⌘? and ⇧⌘/ and so on), and it depends on the keyboard layout.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Recording a keystroke that would also fire an existing menu item through its shifted character is refused with that item named, in both recorders, on the current keyboard layout
- [x] #2 The mapping uses the current layout (UCKeyTranslate or equivalent), not a US table, and the layout limits are recorded in the wiki
- [x] #3 Tests cover ⇧⌘= vs ⌘+, ⇧⌘/ vs ⌘?, and an unshifted key that must not be refused
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Spike (docs/harness/task335): AppKit's matching of shifted-character items (⌘+, ⌘?, ⌘{, ⌘!) against real CGEvents, and UCKeyTranslate on installed layouts (US, French, German, Russian) without switching the user's input source.
2. KeyboardLayout (new): the current keyboard layout's 'uchr' data (TISCopyCurrentKeyboardLayoutInputSource) and UCKeyTranslate for a key code with or without Shift; installed layouts by input source ID for tests.
3. HotKeyShortcut.shiftedKeyEquivalent: with Shift held, the key's Shift-level character on the layout with the modifiers minus Shift (nil for letters, named keys, no character).
4. HotKeyShortcutValidation (both recorders): after the direct menu search, search the menu for the shifted key equivalent; refuse with a new problem naming the item and the shortcut it shows ('⇧⌘= is ⌘+ on this keyboard, the shortcut of View > Zoom In.'). Shifted-character translator injected with the current layout as default.
5. Settings > Shortcuts' 'Used by macOS' mark: a macOS shortcut held with Shift also marks the row whose key is its shifted character (same mapping).
6. Tests: ⇧⌘= vs ⌘+, ⇧⌘/ vs ⌘?, ⌘= and ⌥⇧⌘= not refused, letters unchanged, both rule sets, US and French layouts through UCKeyTranslate, the mark.
7. Wiki (keyboard-shortcuts, quick-detour known limits, AZERTY note), matcher doc comment, review, commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Spike (docs/harness/task335, macOS 26, US layout, real CGEvents into NSMenu.performKeyEquivalent): ⇧⌘= fired an item on ⌘+; ⇧⌘[ ⌘{; ⇧⌘1 ⌘!; ⇧⌘0 ⌘); ⇧⌘; ⌘:; ⌘ + keypad + fired ⌘+; ⌘= and ⌥⇧⌘= fired nothing; with an exact '=' + ⇧⌘ item also in the menu, the exact one fired in either order; ⇧⌘/ fired neither ⌘? nor ⇧⌘? (this Mac has macOS's Show Help menu ⇧⌘/ enabled, symbolic hotkey code 44 + ⇧⌘; not separated further, so the ⌘? case is refused on the model, not on a measurement). UCKeyTranslate on installed layouts without switching the input source: US = → +, / → ?; French key 18 & / 1, US '/' place = / +; German 0 → =; US ⌘⇧= gives '=' in the ⌘ table, so Shift-only translation is used.
Implementation: KeyboardLayout (TISCopyCurrentKeyboardLayoutInputSource 'uchr' data, UCKeyTranslate with kUCKeyTranslateNoDeadKeysMask, Shift only; installed(id:) for tests); HotKeyShortcut.shiftedKeyEquivalent; HotKeyShortcutValidation (both overloads, so both recorders) searches the whole menu for the key itself first, then for the shifted key equivalent, and refuses with .usedByMenuAsShifted: '⇧⌘= is ⌘+ on this keyboard, the shortcut of View > Zoom In.'; SystemHotKey.menuKeyEquivalents so the 'Used by macOS' mark also covers a Shift-held macOS shortcut's character.
AZERTY disagreement (TASK-295): NOT fixed by this mapping. Mission Control's ⌃1 has no Shift, so on AZERTY it maps to '&' + ⌃ only and the default '1' + ⌃ row stays unmarked while the recorder refuses ⌃ on that key by key code. Consistent in Detour's model; whether AppKit's key-equivalent localization moves '1' + ⌃ onto the unshifted key is not measured (needs the input source switched). Recorded in the wiki.
Runtime (/verify, Debug build 16:31, DETOUR_DATA_DIR=DetourVerify-335, DETOUR_MCP=1; Settings driven by Accessibility press and key events posted to the pid): Settings > Shortcuts, recording Reload Page, ⇧⌘= refused with 'is ⌘+ on this keyboard, the shortcut of View > Zoom In.' and recording continued; ⌘= accepted (reset afterwards); ⇧⌘/ refused as a macOS shortcut (Show Help menu enabled here). Quick Detour pane recorder: ⇧⌘= refused with the same message (screenshot checked), Escape kept ⌥⌘N. The review's fixes (the pane passes its injected shifted-character closure to the recorder check; a shared helper in SystemHotKey; a doc comment) came after this run and were covered by tests only.
Tests: ShortcutConflictTests (+8 incl. the review's), ShortcutsSettingsPaneTests (+1), HotKeyShortcutTests, QuickDetourHotKeyTests, ShortcutMenuTests, MenuKeyEquivalentMatcherTests, SpaceJumpTests, MainMenuCharacterizationTests: 139 tests, 0 failures.
Code review (medium --fix): fixed the pane's recorder check ignoring the injected layout (+ test), duplicate work in menuKeyEquivalents, a stale doc. Left: reset/resolver still compare by character (a reset of Zoom In while another command holds ⇧⌘= is not refused; also bindings saved before this change are not re-checked) — out of scope, in the wiki limits; layouts whose ⌘ table differs (Dvorak – QWERTY ⌘) read the plain Shift character — wiki limit; the current layout is re-read per key code on pane reload (minor).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Both shortcut recorders (Settings > Shortcuts and the Quick Detour hotkey, through HotKeyShortcutValidation) now refuse a key recorded with Shift when a menu item is on that key's shifted character with the other modifiers, which AppKit fires on the same press (measured: ⇧⌘= fires Zoom In's ⌘+, ⌘= and ⌥⇧⌘= do not, an exact item wins). The shifted character comes from the current keyboard layout via UCKeyTranslate (new KeyboardLayout), not a US table; the 'Used by macOS' mark uses the same mapping. Checked at runtime in both recorders; tests cover ⇧⌘= vs ⌘+, ⇧⌘/ vs ⌘?, unshifted and ⌥ keys not refused, US and French layouts. Wiki records the measurements and the layout limits (AZERTY digit mark disagreement not settled, ⌘-table layouts, reset path).
<!-- SECTION:FINAL_SUMMARY:END -->
