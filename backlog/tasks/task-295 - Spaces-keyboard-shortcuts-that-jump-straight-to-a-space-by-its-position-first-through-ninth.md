---
id: TASK-295
title: >-
  Spaces: keyboard shortcuts that jump straight to a space by its position
  (first through ninth)
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-08T07:38:00Z'
updated_date: '2026-11-15T00:08:00Z'
labels:
  - spaces
  - menus
dependencies: []
references:
  - TASK-292.2
priority: medium
ordinal: 356000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Today the only keyboard route between spaces is Spaces › Next Space (⌥⌘→) and Previous Space (⌥⌘←), which step one at a time and don't wrap. With four or five spaces, getting from the first to the last takes several presses or a reach for the trackpad. Arc users expect a direct jump: Arc's help center gives Control-1, Control-2… on macOS (seen in the Wayback Machine capture of "Spaces: Distinct Browsing Areas", Jul 2026). The website's Spaces guide currently lists this as "Not in Detour" in its Coming from Arc box and answers "Is there a shortcut to jump to a specific Space?" with "Not by number".

Context for the choice of keys (the user's call): the only digit key equivalent in the app today is ⌘0 (View › Actual Size). ⌃1–⌃9 match Arc, but macOS can bind them to Mission Control's "Switch to Desktop N" when that shortcut is turned on in System Settings, in which case the system takes the keys first. ⌘1–⌘9 select tabs in Chrome and favorites/bookmarks in Safari, so they may be wanted for tabs or Favorites later. Spaces are ordered as in Settings › Spaces; Private windows have no other spaces to jump to.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The key binding is chosen with the user before implementation (⌃1–⌃9, ⌘1–⌘9 or another set), with the Mission Control conflict considered
- [x] #2 Each of the first nine spaces, in Settings › Spaces order, has a shortcut that switches the key window to it, listed in the Spaces menu next to the space's name
- [x] #3 A shortcut for a position with no space does nothing (no beep, no error), and the shortcuts are disabled in Private windows
- [x] #4 Reordering, adding or deleting spaces updates which space each shortcut opens without a relaunch
- [x] #5 Tests cover the position-to-space mapping, including fewer than nine spaces and more than nine
- [x] #6 Checked at runtime with /verify: the shortcuts switch spaces in the key window only
- [ ] #7 The website's Spaces guide (src/content/features/spaces.md: shortcuts table, FAQ and Coming from Arc box) is updated when this ships
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Registry: nine parameterless commands space.jump-1 ... space.jump-9 (Spaces menu, between Previous Space's separator and the per-space items), titled 'Switch to Space N', default ⌃N (PROVISIONAL), each with its own selector (jumpToSpace1: ...) because AppKit sends a menu delegate's fast-path hit with the NSMenu as sender (spike); responder .windowController(browser windows), rule commandWindowKind == .normal (not 'a space exists at N': a disabled item lets the key fall through, an enabled no-op swallows it), palette .notOffered.
2. Pure mapping SpaceJump.target(ofPosition:in:) over TabStore.nonIncognitoSpaces (= Settings > Spaces order), resolved when the key fires, so reorder/add/delete need no menu rebuild.
3. Menu: setupMainMenu adds the nine static items (allowsKeyEquivalentWhenHidden = true: measured that AppKit then fires a hidden item); updateSpacesMenu retitles item N to the space's emoji and name with its checkmark, hides positions with no space, and keeps the dynamic space.switch items for the tenth space on. MenuKeyEquivalentMatcher mirrors AppKit for hidden items that allow key equivalents.
4. Controller: BrowserWindowController.jumpToSpace1...9 -> jumpToSpace(position:), a no-op for a position with no space or a Private window.
5. Settings > Shortcuts: rows listed and bindable with no pane change; a row whose shortcut an enabled macOS shortcut holds (CopySymbolicHotKeys, key code -> character on the current layout, injected for tests) says 'Used by macOS' with a tooltip naming where to turn it off.
6. Tests: mapping (fewer than nine, more than nine, reorder), the menu (titles, hidden, keys, overflow items), AC #4 without a menu rebuild through the real menu path, registry (IDs, availability per window kind, palette), bindings (rebinding reaches the item), the TASK-56 invariant rewritten, the pane's macOS note; existing suites updated (characterization golden, registry ID list).
7. /verify: two windows, the shortcuts switch the key window only; rebinding in Settings > Shortcuts takes effect; ⌃7-⌃9 (not held by macOS here) by posted key events; ⌃1-⌃6 physical presses owed (posted events bypass symbolic hotkeys).
8. Wiki: browser-commands, keyboard-shortcuts, app-shell if touched; lint; log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Decisions

- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): default keys ⌃1–⌃9 (Arc's), rebindable in Settings > Shortcuts (TASK-327). Measured on the user's Mac 2026-11-14: CopySymbolicHotKeys reports ⌃1–⌃6 ENABLED (Mission Control 'Switch to Desktop 1–6', symbolic hotkeys 118–123) and ⌃7–⌃9 disabled, so out of the box a physical ⌃1–⌃6 goes to Mission Control on this Mac. Made visible: those rows in Settings > Shortcuts say 'Used by macOS' (orange, tooltip names System Settings > Keyboard > Keyboard Shortcuts / Mission Control). Alternative: ⌘1–⌘9 (free in Detour today apart from ⌘0 Actual Size; Chrome uses them for tabs, Safari for favourites, so they may be wanted for tabs or Favorites later). Flipping is the one KeyEquivalent line in BrowserCommands.jumpToSpace plus the tests that spell ⌃N.
- Quick Detour and quarantine windows: the commands are not answered there (registry kinds = browser windows, like Next/Previous Space), so the items are disabled. Private windows: answered but disabled by the rule (commandWindowKind == .normal), and jumpToSpace(position:) refuses in a Private window too.
- Not offered in the command palette (the title names a position, not a space).

## Design (measured with a spike, docs/harness/task295/hidden-items.swift, macOS 26)

- Nine static registry items (space.jump-1…9) after Previous Space's separator, so the keys work before the menu is ever opened; updateSpacesMenu titles item N with the space at position N (emoji + name), puts the key window's checkmark on it, hides it when there is none; spaces after the ninth keep the dynamic space.switch items.
- Position resolved when the command runs (SpaceJump.target over TabStore.nonIncognitoSpaces, = Settings > Spaces order), so add/delete/reorder need no rebuild.
- One action per position: a TASK-56 fast-path hit (menuHasKeyEquivalent returning true) is sent with the NSMenu, not the item, as sender.
- Rule is only the window kind, not 'a space exists at N': a key equivalent matched by a disabled item is not handled (falls through to the first responder, which can beep); an enabled no-op swallows it. Hidden items take no key equivalents unless allowsKeyEquivalentWhenHidden (set on the nine; AppKit then fires them); MenuKeyEquivalentMatcher now matches such hidden items as AppKit does.
- TASK-56 invariant test rewritten: every key-bearing item in a delegate-driven menu is a static registry item with an action of its own that the matcher answers (Next/Previous Space and the nine).

## Tests

After the code review's fix: 18 suites, 302 tests, 0 failures: SpaceJumpTests 15 (new), MenuKeyEquivalentMatcherTests 16, MainMenuCharacterizationTests 9, BrowserCommandRegistryTests 22, ShortcutsSettingsPaneTests 20 (4 new), ShortcutMenuTests 10, ShortcutBindingStoreTests 21, ShortcutConflictTests 10, HotKeyShortcutTests, QuickDetourHotKeyTests 22, HotKeyRegistrationTests, PaletteCommandsTests 18, PaletteCommandRowsTests, PaletteCommandWindowTests, AutomationToolsTests, HelpMenuTests, SettingsPaneColumnsTests 22, SettingsPaneHeightTests 20. Full suite not run (the lead runs it).

## Runtime (/verify), Debug build 15:55, DETOUR_DATA_DIR=DetourVerify-295, DETOUR_MCP=1, ten spaces from seed_world (docs/harness/task295/world.json)

- Spaces menu read through Accessibility (axmenu): S1…S9 each with ⌃1…⌃9 next to the emoji and name, S10 with no shortcut, checkmark on the key window's space.
- Two normal windows; real key events posted to the pid (CGEventPostToPid): window 1 key, ⌃8 -> window 1 on S8, window 2 stayed on S1; window 2 key, ⌃9 then ⌃7 -> window 2 on S9 then S7, window 1 stayed on S8.
- A Private window key: the items read disabled, ⌃3 changed neither normal window.
- Settings > Shortcuts (open_ui): 72 rows; searching 'space' listed Next/Previous Space and Switch to Space 1–9; rows 1–6 said 'Used by macOS' from the real CopySymbolicHotKeys, 7–9 did not (light and dark captures looked right). Recorded ⌘7 for Switch to Space 7 with a real key press: stored {space.jump-7: 7 + ⌘}, the menu item showed ⌘7; window 1 key: ⌃7 did nothing, ⌘7 switched it to S7. ⌃2 posted to the pid also switched (posted events skip system hotkeys). Row reset: back to ⌃7, the stored key removed.
- Cleaned up: app stopped by pid, this run's NSWindow Frame / NSSplitView keys and the DetourVerify-295 suite deleted.
- NOT verified: a PHYSICAL ⌃1–⌃6 press on this Mac (Mission Control holds them; posting at the HID level could switch the user's desktop); an empty position at runtime (covered by the spike and SpaceJumpTests); reorder/delete at runtime (covered by SpaceJumpTests through the real menu items with no rebuild). The runtime build predates the review's refactor of updateSpacesMenu (shared title helper, same behaviour; tests re-run after it).

## Code review (code-review medium --fix)

No correctness bugs. Fixed: the space title format shared by both item loops; the checkmark test rewritten readably. Left: macOS shortcuts re-read per pane reload (cheap); layoutCharacter on a real layout (settled by the runtime capture: rows 1–6 marked); on a layout whose digit row is shifted the 'Used by macOS' mark (by character) and the recorder's refusal (by key code) can disagree (recorded in the wiki).

## Runtime, second run (post-review build 16:01, DETOUR_DATA_DIR=DetourVerify-295b)

- With a page's <input> focused (fixture page from docs/harness/task327, served on loopback), a posted ⌃8 switched the key window to S8 and typed nothing into the field.
- The unfiltered Settings > Shortcuts pane (and filtered by Navigate, Develop) showed no 'Used by macOS' mark on any existing default; only Switch to Space 1–6 carry it here.
- Cleaned up as before (app by pid, fixture server, defaults keys, data-dir suite).
- Searched DetourTests, scripts and docs/capture for other users of the per-space items (selectSpaceFromMenu, switchToSpace, the 7000 tag, Spaces-menu lookups): none depend on the first nine being space.switch items. New files (SpaceJump.swift, SpaceJumpTests.swift): other checkouts need xcodegen generate.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Spaces › the first nine spaces now have shortcuts, ⌃1–⌃9 by default. Each one switches the key window to the space at that position in Settings › Spaces order, and the Spaces menu shows the shortcut next to the space's name. The task stays In Progress: AC #1 (the choice of keys) is PROVISIONAL and needs the user, and AC #7 (the website) waits until this ships.

- Nine parameterless registry commands (space.jump-1…9), static menu items titled and hidden by updateSpacesMenu, resolved by position when they run (SpaceJump), with one action each because a fast-path hit is sent with the menu as sender (measured). A position with no space swallows its key: the hidden item keeps its key equivalent and stays enabled with nothing to do. Disabled in Private windows; not answered in Quick Detour or quarantine windows; not in the palette.
- They are listed and bindable in Settings › Shortcuts with no pane change. A row whose key an enabled macOS shortcut holds now says 'Used by macOS'. On the user's Mac, Mission Control holds ⌃1–⌃6 (⌃7–⌃9 are free), so those six do not reach Detour from the keyboard until the user turns them off or rebinds them. ⌘1–⌘9 is the recorded alternative.
- Verification: 302 tests in 18 suites passed. At runtime, with two windows and real key events posted to the app, the shortcuts switched only the key window; a Private window did nothing; a ⌘7 rebinding recorded in Settings took effect, and a reset restored ⌃7. Owed: what a physical ⌃1–⌃6 press does on this Mac.
<!-- SECTION:FINAL_SUMMARY:END -->
