---
id: TASK-327
title: >-
  Keyboard shortcuts: assign and customize the shortcuts of browser commands in
  Settings
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14T19:47:00Z'
updated_date: '2026-11-15T07:37:00Z'
labels:
  - keyboard
  - menus
  - settings
dependencies: []
references:
  - TASK-320
  - TASK-295
  - TASK-193.2
  - TASK-125
  - Detour/App/AppDelegate.swift
  - Detour/App/MenuKeyEquivalentMatcher.swift
  - Detour/Browser/Settings/ShortcutRecorderView.swift
  - Detour/Browser/QuickDetour/HotKeyShortcut.swift
  - wiki/features/quick-detour.md
  - wiki/features/settings.md
priority: medium
type: feature
ordinal: 401000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-14 by the user: let people assign shortcuts to commands that have none and change the ones that exist ("hot keys").

Today every shortcut is fixed in code. About 57 menu items in AppDelegate.setupMainMenu carry a literal keyEquivalent, and some keys are handled outside menus altogether: the Control+Tab Recent Tabs switcher, ⌘Z / ⇧⌘Z interception in BrowserWebView, Escape for Peek, and the find bar. Users coming from Arc or Chrome expect their own muscle memory (TASK-295 already has to pick between ⌃1–9 and ⌘1–9 for space jumps, and TASK-125 is about what ⌘W does). The only shortcut that can be changed today is the Quick Detour global hotkey (TASK-193.2), in Settings > Links.

Existing pieces to build on: ShortcutRecorderView + HotKeyShortcut / HotKeyRecordingOutcome / HotKeyShortcutValidation (recording, Escape cancels, Delete clears, refusing taken keys with the menu path) and MenuKeyEquivalentMatcher (fast menuHasKeyEquivalent path, layout-dependent limits written down in its doc comment). macOS already lets users rebind menu items by title in System Settings > Keyboard > Keyboard Shortcuts > App Shortcuts (NSUserKeyEquivalents). Detour's own setting has to coexist with that: decide which one wins and how Settings shows a system override.

Overlap with TASK-320: a shared command registry (identifier, title, availability, action) is the natural list of what can be bound. Decide whether this task waits for it, builds the minimum registry itself, or starts from the menu items only.

Open questions for the user:
- Scope: menu commands only, or also the non-menu keys (Recent Tabs switcher, in-page keys) and commands that have no menu item?
- Whether a shortcut can be a key with no ⌘/⌥/⌃ (single-key shortcuts conflict with typing in pages).
- Conflicts: refuse a key that is already taken, or let the user reassign it and clear the old binding.
- Whether shortcuts can be global (system-wide like Quick Detour) or app-only; the expectation is app-only except the existing Quick Detour hotkey.
- Where the list lives: a new Settings pane ("Shortcuts") or a section of an existing one.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The scope (which commands can be bound), the storage format and how it interacts with macOS App Shortcuts (NSUserKeyEquivalents) are decided with the user and recorded in the task, with rejected alternatives
- [x] #2 Settings lists the bindable commands with their current shortcuts; the user can record a new shortcut, clear one, and assign one to a command that has none
- [x] #3 A changed shortcut takes effect at once in every window, menus show it, and it persists across relaunch
- [x] #4 A shortcut already used by another command, by the Quick Detour hotkey, or reserved by macOS is refused or reassigned as decided, and the user is told which command or system shortcut holds it
- [x] #5 Restore Defaults resets one command or all of them to the built-in shortcuts
- [x] #6 Tests cover the binding store (defaults, overrides, clearing, persistence) and conflict detection; the runtime check (/verify) records a shortcut in Settings and fires it in a browser window
- [ ] #7 The wiki gets a page on keyboard shortcuts (where they are defined, how overrides apply, known layout limits), and the website keyboard-shortcuts page notes that shortcuts can be customized when this ships
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Binding store (Detour/Commands/ShortcutBindings.swift): user overrides only, keyed by CommandID, in UserDefaultsScope.defaults under CommandShortcuts ({id: {key, modifiers}} or {} for none); defaults stay in the registry; recording the default drops the override; unknown IDs ignored and kept on writes (Restore Defaults removes them too); a pure resolver where an override wins over a colliding default; overrides cached per change; didChange notification.
2. Registry: BrowserCommands.menus (the bar's menus and their commands; all = their concatenation). BrowserCommand.bindability: bindable = parameterless; New Quick Detour Window read-only (its pane); Undo, Redo, Cut, Copy, Paste, Select All fixed (PROVISIONAL); parameterised not listed. KeyEquivalent: normalized form, property list, names for F-keys, Home/End, Page Up/Down, Forward Delete.
3. Applying: ShortcutBindingStore.apply(to:) at setupMainMenu and on every change (AppDelegate observer); palette column, TASK-56 fast path, run_menu_item read the live items; context-menu hints (sidebar Copy URL, Quick Detour Open in and its capsule, redrawn on change) read the live item.
4. Conflicts: HotKeyShortcutValidation with rules (.globalHotKey unchanged; .appShortcut): ⌘ or ⌃ unless F1-F20 (⌥ alone types in a page's text field, measured); refused when the live main menu holds it (own item and Quick Detour item excluded by identifier), the Quick Detour setting, Control-Tab or ⌘Z in pages, macOS's reserved list and CopySymbolicHotKeys; the message names the holder (the application menu by the app's name).
5. App Shortcuts: measured with spikes (docs/harness/task327); a row with one shows 'Set in System Settings', recorder off, nothing written.
6. Settings > Shortcuts pane (after Search): search, Restore Defaults, list grouped by menu, row = title, note, recorder, reset; a reset onto a key another override holds is refused with the holder named; refusals on a line under the list; the Quick Detour hotkey suspended while recording.
7. Tests: ShortcutBindingStoreTests, ShortcutConflictTests, ShortcutMenuTests, ShortcutsSettingsPaneTests; pane-order and pane-list tests; TestEnvironmentSetup resets the store.
8. /verify through Accessibility and real key events plus the endpoint: record in the pane, fire in a browser window, clear, refusal, page-field behaviour, light/dark captures, relaunch persistence, an App Shortcut on the real menu. Owed (screen locked): the 'Set in System Settings' row, Restore Defaults and a row reset pressed in the app.
9. Wiki: features/keyboard-shortcuts (new); browser-commands, settings, quick-detour, app-shell; log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Decisions (AC #1 stays unchecked: all PROVISIONAL, the user's call)

- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): scope = the commands of TASK-320's registry that have one main-menu item (BrowserCommand.bindability). Bindable: every parameterless command, AppKit's application and window items included (Hide, Hide Others, Show All, Quit, Minimize, Zoom). Listed read-only: New Quick Detour Window (its shortcut is the Quick Detour hotkey's, with a link to that pane), Undo, Redo, Cut, Copy, Paste, Select All (fixed: the text items act on the focused field on the keys every Mac app uses; ⌘Z/⇧⌘Z are also taken in pages by BrowserWebView outside any menu). Not listed: parameterised commands (space.switch, extension.*), Check for Updates… where Sparkle does not run. Not bindable at all (no menu item): the Control+Tab recent-tab switcher, ⌘Z/⇧⌘Z inside a page (BrowserWebView.performKeyEquivalent), Escape for Peek, the find bar's keys, sidebar/page/Dock context menus. Alternatives: also bind the text items and Undo/Redo (then the in-page ⌘Z interception would have to follow Undo's binding); also non-menu keys.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): a shortcut needs ⌘, ⌥ or ⌃, except F1-F20 alone (HotKeyShortcutRules.appShortcut). ⌥ alone is allowed, as the brief and the Quick Detour recorder have it (see the runtime note on whether ⌥+letter takes typing). Alternative: require ⌘ or ⌃ for letters.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): conflicts are refused and the holder named, never reassigned: the live main menu's items (other commands with the user's bindings and App Shortcuts on them, AppKit's own items such as Emoji & Symbols; message 'X is the shortcut of File > New Tab.'), the Quick Detour hotkey's setting ('X is the Quick Detour shortcut (Settings > Quick Detour).'), Detour's keys outside menus (Control-Tab, ⌘Z/⇧⌘Z in pages), macOS's (CopySymbolicHotKeys plus a short list it does not report: ⌘Tab, ⇧⌘Tab, ⌥⌘⎋ Force Quit, ⌃⌘Q Lock Screen, ⇧⌘Q / ⌥⇧⌘Q Log Out). Alternative: reassign and clear the old binding.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): app-only shortcuts; the Quick Detour global hotkey stays on its own pane and its recorder.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): a new Settings pane 'Shortcuts' (toolbar after Search, symbol keyboard): search field, Restore Defaults (no confirmation, as System Settings' own), one list grouped by menu (floating group rows), each row title + recorder + per-row reset; refusals on a line under the list. No switches needed, no Learn more link (no guide page). Alternative: a section of General; a confirmation on Restore Defaults.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): storage = user overrides only, in UserDefaultsScope.defaults (the data directory's suite, as PeekEnabled and the Quick Detour hotkey settings are), key CommandShortcuts: {commandID: {key, modifiers (NSEvent raw bits)}} or {} for none. A missing ID is the registry default (a later default reaches users who never changed it); recording the default removes the entry; unknown IDs and unreadable values are ignored and kept on every write; Restore Defaults removes the whole key (unknown IDs too, so nothing returns after an upgrade). Resolution: overrides win over a colliding default (TASK-295's future defaults), first command in menu order wins between two overrides. Alternatives: a JSON blob or a DB table; keeping unknown IDs on Restore Defaults; storing key codes (layout-independent) instead of characters.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): macOS App Shortcuts win; a row whose item has one shows macOS's shortcut and 'Set in System Settings', recorder off, nothing written. Alternative: write over it (not possible: AppKit's getters return the App Shortcut while one applies, see below).

## Measured: how AppKit applies NSUserKeyEquivalents to code-built menus (macOS 26 / Darwin 25.6, 2026-11-14)

Standalone AppKit spikes (scratchpad, not in the repo) building their menus in code, run with -NSUserKeyEquivalents '{...}' as a launch argument (argument domain: no write to the app's defaults):
- An entry is applied by the item's title when the item is inserted into a menu (not at creation), and again whenever the item is retitled (Pin Tab -> Unpin Tab picked up the 'Unpin Tab' entry). While one applies, keyEquivalent and keyEquivalentModifierMask return the App Shortcut's, userKeyEquivalent returns its key (empty otherwise), NSMenu.performKeyEquivalent fires on that key and not on the code's.
- A key set in code while an entry applies is kept underneath and becomes the item's again once the title has no entry (retitled away and back). So Detour writes its bindings once per change and never re-applies after validation retitles an item.
- The menu-path form (System Settings' 'File->Close Tab', stored '\\033File\\033Close Tab') is matched against the parent ITEMS' titles, not the submenus' titles, and wins over a plain-title entry. Detour's menu-bar items are NSMenuItem() (title 'NSMenuItem'), so path-form App Shortcuts never apply to Detour today; plain-title ones do. Titling the bar items fixes it (an entry applied after the parent was titled, even once the items were in). NOT changed here (out of scope; reported to the lead).
- Detection in Detour: ShortcutRowState.systemShortcut(of:) = the live item's getters when userKeyEquivalent is non-empty. The conflict check sees App Shortcuts through the same getters.

## Decision 2 tightened after measuring (PROVISIONAL)

- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): a command's shortcut needs ⌘ or ⌃ (⌥ and ⇧ may join them), or is a function key F1-F20 (alone or with any modifier). Tightened from the brief's '⌘, ⌥ or ⌃' because of the runtime measurement below: with a page's text field focused, ⌥R typed '®' into the field and Reload Page (bound to ⌥R) did not fire. Alternative: allow ⌥ alone (it fires everywhere except in a page's text field). The Quick Detour global hotkey keeps '⌘, ⌥ or ⌃' (a Carbon hotkey takes the key first).

## Runtime (/verify), Debug build 15:19, DETOUR_DATA_DIR=DetourVerify-327, DETOUR_MCP=1, screen unlocked until about 15:28

Settings driven through Accessibility (AXPress on the recorder by identifier) and real key events posted to the process (CGEventPostToPid); browser windows through the endpoint.
- Settings > Shortcuts opened (open_ui settings pane=shortcuts); all nine toolbar items fit the 740 pt window; 63 rows (no Check for Updates… in a run without Sparkle); the window opened at the screen's cap (1330 pt capture).
- Recorded ⌥⌘E for Reload Page by a real key press: the row showed ⌥⌘E, its reset button appeared, Restore Defaults enabled, the data dir's suite (com.detourbrowser.mac.DetourVerify-327) held CommandShortcuts {page.reload: {key e, modifiers 1572864}}.
- Fired in the browser window by a real ⌥⌘E key event (AppKit's own key-equivalent path, window key): the fixture page reloaded (performance.timeOrigin changed); a real ⌘R no longer reloaded it.
- Refusal: ⌃R was refused with 'X is the shortcut of Window > Move & Resize > Return to Previous Size.' (an item AppKit adds; named by path) and recording continued.
- Cleared Close Tab with Delete: stored {}, run_menu_item key=cmd+w answered unknown_menu_item, a real ⌘W left both tabs open.
- Gave Import from Arc… F6 (no modifier) and Reload Page ⌃U: with the page's <input> focused, ⌃U reloaded and F6 opened the Import from Arc window (the page also saw the F6 keydown); ⌥R (recorded before the rule was tightened) typed '®' in the field and did not fire, but fired with the page body or the sidebar focused.
- Captured the pane light and dark (screencapture -l) with changed rows: reset buttons on the changed rows, 'None' placeholders, F6, read-only rows dimmed with no box, the Quick Detour row's link; looked right in both.
- Relaunched with the same data dir (SIGTERM, then launch): run_menu_item key=ctrl+u ran View > Reload Page and key=cmd+w found no item, so the bindings survived the relaunch and were applied to the new menu bar.

- After the relaunch (launched with -NSUserKeyEquivalents '{"Show All History" = "@~y";}' as an argument, never written to defaults): run_menu_item key=cmd+opt+y ran Navigate > Show All History and key=cmd+y found no item, so a plain-title App Shortcut reached Detour's real menu item as in the spikes.
- The screen locked at about 15:28 with the load average at 150-200: Accessibility then returned no windows and the app's main thread sat in a LaunchServices sysctl. NOT verified at runtime, OWED on an unlocked screen: the 'Set in System Settings' row in the pane (relaunch with the argument above, open the pane, look at Navigate > Show All History), Restore Defaults and a per-row reset pressed in the pane, the pane's rows read after the relaunch (persistence was shown through the menu, above), the tightened ⌥ rule refusing ⌥R in the pane (unit-tested), a capture of the pane with a refusal on its warning line. ShortcutsSettingsPaneTests click the real reset and Restore Defaults buttons.
- Cleaned up: the app stopped by pid, the fixture server stopped, this run's NSWindow Frame / NSSplitView keys and the com.detourbrowser.mac.DetourVerify-327 suite deleted.

## Tests

Final run (after the code review's fixes and the tightened rule), 11 suites, 182 tests, 0 failures: ShortcutBindingStoreTests 21, ShortcutConflictTests 10, ShortcutMenuTests 10, ShortcutsSettingsPaneTests 16, HotKeyShortcutTests 27, QuickDetourHotKeyTests 22, MenuKeyEquivalentMatcherTests 15, MainMenuCharacterizationTests 9, BrowserCommandRegistryTests 22, SettingsPaneColumnsTests 22, SettingsSwitchRowTests 8.
Before the rule change, a wider run passed 23 suites, 353 tests, 0 failures (the above plus HotKeyRegistrationTests, SettingsGuideLinkTests, SettingsPaneHeightTests, PaletteCommandsTests, PaletteCommandRowsTests, PaletteCommandWindowTests, QuickDetourOpenInWindowTests, CopyURLTests, AutomationStagingTests, AutomationToolsTests, HelpMenuTests, UserDefaultsScopeTests). Full suite not run here (the lead runs it).
TestEnvironmentSetup now resets the shared store at bundle start, so a run cut short cannot leave a binding for the menu suites.

## Code review (code-review medium --fix on the uncommitted diff)

Fixed by the review: the test target did not compile (main-actor registry IDs as stored defaults in a nonisolated test class); a stale search expectation ('file new' also lists Open in through its alias); a per-row reset onto a built-in key another override now holds is refused with the holder named (it would silently leave the row with none; new test); Quick Detour's Open in capsule now redraws on a binding change; overrides parsed once per change instead of once per row; one reload per search edit; dead code removed (BrowserCommands.menu(of:), ShortcutOverride.keyEquivalent, KeyEquivalent.isFunctionKey).
Done after the review: the refused reset beeps like other refusals; the ⇧⌘Z 'redoing in a page' reservation removed, because BrowserWebView's ⇧⌘Z branch compares charactersIgnoringModifiers with 'z', which is 'Z' while Shift is held, so it never fires (a bug that predates this task; Redo's own item holds ⇧⌘Z).
Left as is: (a) conflicts on shifted punctuation are not seen (a recording stores '=' + ⇧, Zoom In is '+' + ⌘; AppKit fires both on ⇧⌘=, measured), the same known limit as the Quick Detour recorder: fixing it needs the shifted character on the current layout; (b) the resolver counts only bindable commands' keys, so a future change to a FIXED command's default could land on a user's key unnoticed (validation stops it at record time today).

## For the lead (out of scope here)

- Path-form App Shortcuts ('File->Close Tab') never apply to Detour because the menu-bar items are untitled NSMenuItem() (measured above); titling them in setupMainMenu would fix it.
- BrowserWebView's ⇧⌘Z redo interception never matches (see above).
- TASK-295: declare the nine space jumps as parameterless commands (space.jump-1 ... space.jump-9) with their default keys in the Spaces section of BrowserCommands.menus; they are then listed and bindable with no pane change. If their items are the dynamic per-space ones, updateSpacesMenu must give them ShortcutBindingStore.shared.keyEquivalent(for:), and the TASK-56 invariant test (only Next/Previous Space carry keys in the Spaces menu) changes; the resolver already lets a user's override win over a new colliding default.
- AC #7's website part: the shortcuts page (Help > Keyboard Shortcuts) should say shortcuts can be changed in Settings > Shortcuts when this ships; it could then also be the pane's Learn more link.

## Notes after the commit (3c0ab27)

- Superseded entries: the 'Decision 2 tightened' section replaces the first decision-2 note (⌘ or ⌃ unless a function key, not ⌘/⌥/⌃), and the code-review section replaces the first decision-3 note's list (⌘Z only in pages: the ⇧⌘Z reservation was removed). The plan was rewritten to match what shipped.
- Departures from the brief's wording, all PROVISIONAL: decision 2 is narrower (⌘ or ⌃); Undo and Redo are read-only although the brief's scope was every registry command; Restore Defaults also deletes unknown IDs although the brief says they are kept (ordinary writes keep them).
- Not exercised at runtime: the build that was launched (15:19) predates the tightened ⌥ rule, the ⇧⌘Z removal and the refused-reset beep, which came after the code review too; they are unit-tested only (182-test run). AC #5 is checked on test evidence (the tests click the real reset and Restore Defaults buttons), not on a press in the running app.
- AC #4's known hole: recording ⇧⌘= for a command is not seen as a conflict with Zoom In (⌘+), though AppKit fires both on that keystroke (measured in docs/harness/task327/menu-matching.swift).
- Side effect outside the task: the Quick Detour recorder's refusal now names the application menu 'Detour > Settings…' instead of 'NSMenuItem > Settings…' (HotKeyShortcutValidation's menu path now titles the app menu by the app's name).
- For the user: the row 'Open Quick Detour in Space' is also Open Peek in New Tab in a browser window (one item, one shortcut); the pane opens at the screen's height cap (1330 pt here) because the Settings height rule makes every row its natural height, which the user may want capped lower.
- The spikes, the Accessibility helper (axdrive.swift) and the fixture page are in docs/harness/task327 for redoing the owed checks.

2026-11-14 user decision: approved as built: main-menu commands only; ⌘ or ⌃ required except F1–F20; a taken key is refused with the holder named, never reassigned; Restore Defaults asks no confirmation; App Shortcuts set in System Settings win.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Users can now assign, change, clear and reset the shortcuts of the main menu's commands in a new Settings > Shortcuts pane. The task stays In Progress: AC #1 (scope, storage, how App Shortcuts interact) is provisional and needs the user's decision; AC #7 waits for the website note when this ships.

- Storage (ShortcutBindingStore): only the user's overrides, keyed by command ID, in the data directory's defaults suite. Built-in shortcuts stay in the registry, so a later default reaches anyone who never changed that command. Unknown IDs are kept. An override wins over a default on the same key.
- Applying: the main menu items get the effective shortcut when the bar is built and again on every change. Every window, the palette's shortcut column, the TASK-56 fast path and the context-menu hints follow.
- Refusing keys (HotKeyShortcutValidation, with one rule set per use): a shortcut needs ⌘ or ⌃ unless it is a function key. This was tightened after measuring that with ⌥ alone, a page's text field types the character instead. A key held by the live menu (other commands, AppKit's own items, App Shortcuts), by the Quick Detour hotkey, by Detour outside menus or by macOS is refused, and the holder is named.
- App Shortcuts (NSUserKeyEquivalents) win: the row says 'Set in System Settings'. Spikes measured how AppKit applies them; path-form entries never reach Detour's untitled menu-bar items (reported, not changed).
- Verification: a final run of 182 tests in 11 suites passed, after an earlier 353-test run across 23 suites. At runtime, a shortcut was recorded with a real key press in the pane and fired in a browser window through AppKit's own key handling. Clearing, ⌘/⌃/F-key/⌥ behaviour in a page field, a refusal naming an AppKit item, light and dark captures, persistence across a relaunch, and an App Shortcut reaching the real menu were also checked. Owed on an unlocked screen: the 'Set in System Settings' row, and pressing Restore Defaults and a row reset in the pane (both are covered by tests).
<!-- SECTION:FINAL_SUMMARY:END -->
