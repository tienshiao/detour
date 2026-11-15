---
id: TASK-320
title: >-
  Command palette: browser commands (a shared command registry, also for
  AppleScript, Shortcuts and MCP)
status: Done
assignee:
  - '@claude'
created_date: '2026-11-10T09:38:00Z'
updated_date: '2026-11-15T19:58:00Z'
labels:
  - command-palette
  - automation
dependencies: []
references:
  - TASK-319
  - TASK-228
  - Detour/Browser/CommandPalette/SuggestionItem.swift
  - Detour/Browser/CommandPalette/SuggestionProvider.swift
  - Detour/App/AppDelegate.swift
  - wiki/features/command-palette.md
priority: low
type: feature
ordinal: 382000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-10 by the user: actual commands in the Command Palette (Arc and VS Code style: type 'pin', 'new space', 'move to…', 'split' and run it), noted as overlapping TASK-319 (AppleScript / JXA and Shortcuts) and TASK-228 (MCP server).

Today the palette's rows are only URLs and searches: SuggestionItem has searchInput, historyResult, openTab, searchSuggestion, siteSearch and siteSearchHint (wiki/features/command-palette.md, suggestion-pipeline.md). Browser actions exist only as menu items built one by one: about 49 in AppDelegate.setupMainMenu and about 32 in the sidebar's context menus, plus the favorites bar, archive page, Quick Detour and page context menus. Each is a selector sent through the responder chain, enabled by its own validateMenuItem rule. There is no list of commands to search, script or call.

Proposal: one command registry that the palette, TASK-319 and TASK-228 all read.
- A command has an identifier, a title and search aliases, a symbol, the key equivalent of its menu item (shown in the row), typed parameters (tab, space, profile, URL, position), an availability rule for a context (window kind: normal, Private, Quick Detour, quarantine; selection; whether the tab is pinned, split, asleep, playing; extension or dev-mode state), and an action that runs through the same code as the menu item.
- The menu items, the palette rows, AppleScript commands and App Intents (TASK-319) and MCP tools (TASK-228) are views of it, so a command's availability (e.g. not in a Private window) and its behaviour are defined once.
- Commands whose parameter is a space, tab or profile ('Move tab to <space>', 'Switch to <space>', 'Open in Quick Detour') need a second step in the palette that lists the choices: decide whether that is a nested list, a chip like site search's, or typed arguments.

Starting set to choose from: new tab / window / Private window / Quick Detour; close, duplicate, pin/unpin, mute, sleep, reload, copy URL; split with…, separate split, move to space…; switch space, new space, rename space, edit space colour or emoji; open Peek in new tab; show History, Archive, Downloads, Settings panes; toggle sidebar; dev mode and Web Inspector (Console, Network); find in page; extension actions (open an extension's popup or options, turn an extension on or off for the profile).

Open questions for the user:
- How commands show up: always mixed with URL and history rows, only after a prefix ('>' as in VS Code), or ranked in when the text matches a command's name or alias well.
- What a parameterised command looks like in the palette (see above).
- Whether the first cut builds the registry and moves existing menu items onto it, or adds palette commands first and moves menus later.
- Order relative to TASK-319 and TASK-228: the registry is the shared base, so it may be worth doing first.

Constraints from the codebase: the palette is scoped to its window's profile (TASK-209) and its suggestions never cross into Private windows (TASK-137); commands acting on tabs must handle a tab no window hosts or that is asleep (web view ownership); palette dismissal and focus rules (wiki/features/command-palette.md 'Dismissal and focus') apply after a command runs.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The registry's shape (command, parameters, availability, action) and how menus, palette, AppleScript/Shortcuts (TASK-319) and MCP (TASK-228) use it are recorded in the task, with rejected alternatives
- [x] #2 Typing part of a command's title or alias in the palette lists it with its key equivalent, and Return runs it through the same code as its menu item
- [x] #3 A command that needs a space, tab or profile asks for it in the palette and runs on the choice
- [x] #4 A command unavailable in the context (window kind, selection, tab state) is not offered, by the same rule that disables its menu item
- [x] #5 Tests cover the availability rules and the palette's ranking of commands against URL and history rows; the runtime check exercises the palette in a normal and a Private window
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. (a) Characterization tests on the untouched code: a golden snapshot of the real main menu (path, title, key equivalent, mask, action, target, tag, separators) and an enablement + post-validation-title matrix for normal, Private, Quick Detour and quarantine windows, resolved as run_menu_item resolves (no key window needed).
2. (a) The registry (Detour/Commands/): BrowserCommand (stable string CommandID, title, aliases, SF Symbol, default KeyEquivalent, typed parameters, the window kinds whose controller answers it, an availability rule and a contextual title over a lazy CommandContext protocol, the action selector and target kind, palette presence). A golden test of the identifier list (unique, never title-derived); a test that every main-menu item is a registry command.
3. (b) The main menu built from the registry (same titles, key equivalents, masks, selectors, nil targets; NSMenuItem.identifier = command ID). Both validateMenuItem implementations (BrowserWindowController, QuickDetourWindowController) delegate to the registry rule, reproducing today's per-controller quirks. One shared dispatch helper (responder target in a given window + AppKit's tiered enable decision) used by menuHasKeyEquivalent, run_menu_item and the palette. Dynamic items (spaces, extensions, Develop inspect/reload) keep their builders and tags, declared as parameterised commands. Test: registry availability equals real-menu resolution for every command and window kind (AC #4).
4. (c) Palette commands: SuggestionItem.command; the owner (browser window, Quick Detour window; not the launcher) hands the palette a command source; pure ranking (word-prefix match on title/aliases) mixed after the verbatim row (capped, min length), '>' prefix = commands only (no history, network, completion, filler; Return with no row does nothing); rows show the live menu item's key equivalent and the contextual title; Return dismisses the palette then performs the command as run_menu_item does. Availability evaluated only for matched candidates, memoized per showing.
5. Tests: registry rules over fake contexts, ranking, palette integration (normal/Private/Quick Detour), menu/palette/MCP-menu/Quick Detour suites. /verify: palette commands in a normal and a Private window, menu items by key and by path through the automation endpoint, menu enablement in Private and Quick Detour.
6. Record AC #1 (shape, how menus/palette/AppleScript/MCP use it, rejected alternatives), provisional decisions, AC #3 options + recommendation (not built), what is left (context menus, dock menu). Wiki: new commands page, app-shell, command-palette, suggestion-pipeline. Task stays In Progress.

AC #3 (chip, decided by the user 2026-11-14): 7. Pure layer: CommandChoice (value: space/tab/profile/extension id, title, subtitle, icon), per-command choice lists (Switch to Space = what the Spaces menu offers the window minus the active space; Move Tab to Space = what the sidebar's Move to offers (non-incognito spaces, nothing in a Private window) minus the current space, filtered by canMoveTab/canMovePinnedEntry; extension commands = what their menu builders enable), the text filter, and the chip state machine (enter, Backspace at the start restores the typed text, Escape leaves then dismisses; Cmd+L palettes dismiss at once, as site search). A parameterised command is offered only when its rule holds and it has a choice. 8. Registry: kinds with a natural list are palette-eligible (url/position keep needsParameter); new tab.move-to-space command (BrowserWindowController.moveSelectedTabToSpace(_:) -> the sidebar's didRequestMoveTabAt path), not offered for a split (the sidebar has no Move to on a split row). 9. CommandDispatch.perform with an argument: a transient item with representedObject, validated and sent as the dynamic item is. 10. CommandPaletteView chip mode (chip = command symbol + title, rows = choices, no history/network/filler, Return runs, Return with no row does nothing); both owners. 11. Tests: pure choice/filter/state-machine tests; window tests for Move Tab to Space and Switch to Space via the chip in a normal window and their absence in a Private window; palette/registry/menu suites. 12. /verify with posted key events, chip captures light/dark, move + switch through the chip, Private window offers no cross-profile targets. Wiki: command-palette, browser-commands, site-search link.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
## Registry shape (AC #1)

Code: Detour/Commands/ (BrowserCommand.swift, BrowserCommands.swift, CommandDispatch.swift); palette side Detour/Browser/CommandPalette/PaletteCommands.swift. Wiki: wiki/features/browser-commands.md.

- Command (BrowserCommand): `id: CommandID` (dotted lowercase string, written out by hand, never derived from a title; pinned by BrowserCommandRegistryTests because TASK-327 will persist bindings keyed by it), `title` (what the menu item is built with), `aliases`, `symbol` (SF Symbol), `keyEquivalent` (default; the live item can differ, e.g. the Quick Detour hotkey setting), `parameters: [CommandParameter]` (space, tab, profile, url, position, extension), `action` (selector) + `tag`, `responder` (CommandResponder: `.windowController(kinds)` = the window kinds whose controller implements the action, target nil / responder chain; `.appDelegate(explicitTarget:)`; `.updater`; `.appKit`), `rule` + `contextualTitle` over a `CommandContext`, `palette: PalettePresence` (offered / notOffered(reason) / needsParameter).
- Availability: `CommandContext` is a protocol of facts about a window (kind: normal, Private, Quick Detour, quarantine; selected tab, has URL, pinned; Peek; back/forward; undo; closed tabs; archive; next/previous space; tab stepping; Cmd+O destination). BrowserWindowController and QuickDetourWindowController implement it lazily (each fact computed when a rule reads it; some read the DB). Missing facts default to false (fail closed). `isAvailable(in:)` = kind in `kinds` && rule. Both controllers' validateMenuItem are now `BrowserCommands.validate(item, in: self)` (retitle, then the rule); the palette offers a command by the same `isAvailable(in:)` (AC #4).
- Action: the selector through the responder chain. `CommandDispatch` resolves a command or item in a GIVEN window (first responder up to the window, its delegate, NSApp, its delegate), applies AppKit's tiered enable decision, and `perform` sends from the command's LIVE menu item (sender, tag, target as a click gives). Shared by the key-equivalent fast path, run_menu_item and the palette.
- Menus: AppDelegate.setupMainMenu keeps the layout and adds every item with `add(_:to:)` = `command.makeMenuItem()` (title, key, mask, action, tag, identifier = command ID) + the responder's target. Dynamic items (spaces, extension submenus, Develop inspect/reload) keep their builders with the parameterised commands' actions.
- Palette: the owner gives the palette `PaletteCommands.source(for: controller)` (candidates = offered commands its kind answers; resolve(id) evaluated only for matched candidates, memoized per showing). Return dismisses the palette, then `CommandDispatch.perform` in that window.
- How TASK-319 (AppleScript/App Intents) should use it: one script command / intent per command ID with its `parameters`, run with `CommandDispatch.perform` against the named window (resolution does not need the window to be key), gated by `isAvailable(in:)` of that window's controller (so Private rules hold for scripts too).
- How TASK-228 (MCP) should use it: `list_commands` (IDs, titles, availability for a window) and `run_command` by ID beside run_menu_item (which keeps working by path/key and now shares CommandDispatch).
- TASK-327: bindings keyed by CommandID applied to the live items; defaults = `keyEquivalent`; the palette shows the live item's shortcut so it follows.

Rejected alternatives:
- An action closure per command instead of selectors: the menu, run_menu_item, the TASK-56 fast path, HotKeyShortcutValidation (skips the QD item by action), updateSpacesMenu (finds Manage Spaces… by action) and AppKit's own items all work by selector/target; a closure would have had to find its window itself.
- An eager snapshot struct of every fact per validation: validation runs per item and on every key equivalent, and some facts query the DB.
- Palette asking validateMenuItem through the responder chain while it is open: its field editor is first responder then; the rule over the window controller is what the item answers once the palette is gone.
- Leaving "which windows answer it" to the responder chain only: declared as `kinds` so the palette and scripts can tell without resolving; a test holds it to instancesRespond(to:).
- Moving the menu layout (order, separators, conditional Check for Updates…, delegates, dynamic sections) into registry data: more change than the move needed.
- Moving the dynamic items onto the registry now: their availability is per parameter (nil action when an extension has no popup), which rules do not express yet.

## PROVISIONAL decisions

- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): commands show up both ways — ranked in among URL and history rows when the typed text (3+ characters) matches a title or alias by word prefixes, at most 2 rows, placed right after the verbatim row (the top hit and Return on the text unchanged); and a ">" prefix lists commands only (no history pass, no network suggestions, no completion/filler; Return with no match does nothing). Thresholds 3 characters / 2 rows are guesses. Alternatives: only after ">" (never mixed), or always mixed in with no ">" mode; other thresholds.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): not offered in the palette — New Tab and Open Location… (they open the palette), Undo/Redo (act on whatever had focus), Back/Forward (once the palette is dismissed the page has the keys and WKWebView's own goBack:/goForward: answer ahead of the controller, disabled without a history item, so the row would do nothing), AppKit's Cut/Copy/Paste/Select All/Hide/Hide Others/Show All/Quit/Minimize/Zoom, and every parameterised command. Alternative: offer Quit/Minimize/Hide, or route Back/Forward straight to the controller from the palette (would differ from Cmd+[ with the page focused).
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): the Quick Detour launcher panel offers no commands (it belongs to no window); a Quick Detour window's and a quarantine's palette do. Alternative: app-level commands (New Window, Settings…) in the launcher too.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): the command ID names. They are not persisted anywhere yet, so free to rename until TASK-327 stores bindings. Worth a look: `extension.*` (per-extension, parameterised: show-popup, options, inspect-offscreen, reload-unpacked) vs `extensions.*` (the Extensions menu's own: add, manage, check-for-updates); `location.open` (Open Location…); `page.open-in-space` (Cmd+O, both Quick Detour's Open in and Open Peek in New Tab); `help.guide` (Detour Help). Alternative: one prefix per menu (file.*, edit.*, view.*, …), which ties IDs to the menu layout.
- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): the first cut builds the registry and moves the main menu onto it before adding palette commands (the brief's order). Alternative: palette commands first, menus later.
- Matching note for the user: a 3-letter query matches aliases too, e.g. "arc" ranks in Show Archived Tabs (alias "archive") and Switching from Arc (alias "arc"); "chr" → Add Extensions… (alias "chrome web store"); "res" → Reopen Closed Tab ("restore tab") and Actual Size ("reset zoom"); "con" → Web Inspector ("console"); "dev" → Web Inspector ("devtools"). Whether that is "matching well" is the user's call (raise the threshold, or rank aliases in only on a prefix match).

## AC #3: parameterised commands in the palette (not built; the user's call)

Declared in the registry (`parameters`) and kept out of the palette: space.switch (space), extension.show-popup / extension.options / extension.inspect-offscreen / extension.reload-unpacked (extension). The starting set's "Move tab to <space>", "Switch to <space>", "Open in Quick Detour" would join them.
Options:
1. Nested list (Arc/Raycast): choosing "Move Tab to Space…" replaces the rows with the spaces; typing filters them; Return runs; Escape/Backspace goes back to the command list. Needs a "back" state and a title for the second step.
2. A chip like site search (TASK-287): choosing the command puts a chip ("Move to Space") at the start of the field, the rows are the choices filtered by what is typed, Return runs on the selected choice, Backspace on an empty field leaves the mode. Reuses the palette's existing mode machinery (chip view, enter/leave, Backspace restoring the text, the color).
3. Typed arguments (">move to work"): the command parses its argument from the text. No second step, but ambiguous (space names with spaces, partial names), poor discoverability, and the argument has to be matched before the command is known.
Recommendation: option 2 (the chip). One field and one interaction model the palette already has and tests; it works the same for space, tab and profile pickers; typed text still filters. Option 1 is the fallback if the user wants a visible breadcrumb.

## What is left off the registry

Sidebar context menus (TabSidebarViewController's tab/folder/space/pinned/favourite menus, about 22 items), the favourites bar (1), the archive page (5), the page's context-menu additions (BrowserWebView.willOpenMenu, 4), the Quick Detour title bar menus (3), the Dock menu (2: New Window, New Private Window), the automation menu items (BrowserWindowController+Automation, 5), Settings' menus (not commands). Keys outside menus: Control+Tab switcher, Escape for Peek, the find bar, the Undo/Redo interception in BrowserWebView. Commands with no menu item at all (duplicate, mute, sleep, split with…, separate split, move to space, new/rename space, colour/emoji) do not exist as commands yet.

## Code review (code-review medium --fix, over main...batch-b plus the working tree) and what was done

The three commits (0b52c8c, b10ab60, 1bea240) were made as checkpoints before this review and /verify; the fixes land as a fourth commit.
- Fixed by the review: the palette now sends a window-controller command to the controller whose rule offered it (`CommandDispatch.perform(…, controller:)`), not to whatever answers first along the responder chain (WKWebView's own goBack:/goForward: while the page has the keys; NSWindow declares selectNextTab:/selectPreviousTab: for window tabbing). New test testNextTabRunsInTheControllerNotTheWindowsOwnTabbing.
- Fixed by the review: Check for Updates… is offered only while Sparkle's own validation enables its live item.
- Done after the review: Back and Forward are offered in the palette again (the exclusion I had added was for the responder-chain problem the fix removes). Correction to the PROVISIONAL "not offered" list above: Back/Forward are no longer in it. Consequence, recorded in the wiki: the palette's Back on a child tab with no history closes it to its opener (TASK-325), which Cmd+[ with the page focused does not (WKWebView takes it; known since TASK-325). New test testBackFromThePaletteClosesAChildTabToItsOpener.
- Done after the review: a command refused when Return runs it (its state changed after the row was offered) beeps, as a disabled menu key equivalent does.
- Left as is: rows are resolved once per showing (cleared on show and when the window rescopes the palette), so a ">" list can go stale while the palette stays open; Return then re-validates and beeps. Each resolve walks the main menu twice (~45 commands × ~80 items on ">", negligible). Command rows in mixed mode take slots before history rows, so they can push the last history or tab match past the 12-row cap.

## Tests (final HEAD 5d64fca)

One run of every affected suite (34 suites, 424 tests): 412 passed, 12 failed. The 12 are page-load/paint waits in Quick Detour windows ("timed out after 10.0 s waiting for the page titled …"): QuickDetourWindowTests 6, QuarantineWindowTests 4, QuickDetourOpenInWindowTests 2. The screen locked at 14:06 (CGSSessionScreenIsLocked). The same three suites passed at b10ab60 before the lock (225-test run: QuickDetourWindowTests 16/16, QuarantineWindowTests 22/22, QuickDetourOpenInWindowTests 4/4), and QuarantineWindowTests also passed two minutes into the lock. The failing tests never open a palette, and nothing after b10ab60 is on their path. OWED: rerun these three suites on an unlocked screen.
Passing suites: MainMenuCharacterizationTests 9, BrowserCommandRegistryTests 23, PaletteCommandsTests 18, PaletteCommandRowsTests 14, PaletteCommandWindowTests 9, MenuKeyEquivalentMatcherTests 15, HelpMenuTests 8, AutomationToolsTests, AutomationPrivateAccessTests, MCPServerTests (run_menu_item), HotKeyShortcutTests, PeekWindowCommandsTests, CopyURLTests, BuildInfoTests, OpenInQuickDetourMenuTests, QuickDetourHotKeyTests, PaletteRowsTests, PaletteSelectionTests, PaletteReturnKeyTests, SiteSearchPaletteTests, CommandPaletteFocusTests, EmptyStatePaletteTests, PaletteTabScopeTests, PaletteHistoryScopeTests, PaletteTabScopeWiringTests, PaletteEntryPointScopeTests, SuggestionProviderTests, QuickDetourLauncherTests, SiteColorTests, SiteSearchChipColorTests, FaviconLinkBridgeTests.
MainMenuCharacterizationTests' structure and enablement tests were written and passed on the untouched menu (0b52c8c) and pass unchanged after the move (b10ab60 onwards).

## Runtime (/verify, Debug build 14:29, DETOUR_DATA_DIR=DetourVerify-320, endpoint; screen LOCKED throughout)

- Menus by key equivalent: cmd+d pinned the selected tab; cmd+option+up (Previous Tab) moved the selection; cmd+w closed a tab; cmd+t opened the palette; cmd+shift+n opened a Private window.
- Menus by path: Navigate › Show All History opened the History tab. (File › Unpin Tab by path was refused because the shared item still read "Pin Tab", having not been validated since. run_menu_item matches the item's current title, as before.)
- Palette, normal window: `>pin` + Return unpinned the selected pinned tab; `reopen`, Down, Return (the command ranked in after the verbatim row) reopened the tab closed just before.
- Private window: File › Pin (cmd+d), Navigate › Show Archived Tabs, Spaces › Next Space and Manage Spaces… were disabled. In its palette, `>pin` + Return did nothing (the tab stayed unpinned) and `>close tab` + Return closed the Private tab.
- Not verified at runtime:
  - the rows' appearance (key-equivalent labels, symbols): the screen was locked, and app-source screenshots do not draw the palette's glass anyway (the tests check the rows' contents);
  - Quick Detour and quarantine windows: the endpoint addresses browser windows only (covered by MainMenuCharacterizationTests, PaletteCommandWindowTests);
  - Check for Updates… (only a production run starts Sparkle);
  - the effect of `toggle side` in the Private window (not observable through the endpoint).
- Cleaned up: the app was stopped by pid; its `NSWindow Frame`/`NSSplitView` defaults keys and the DetourVerify-320 suite were deleted.

Correction to the counts above (from the logs): BrowserCommandRegistryTests 22, PaletteCommandRowsTests 13, PaletteCommandWindowTests 9; pre-lock run at b10ab60 (finished 14:02): QuickDetourWindowTests 16/16, QuarantineWindowTests 22/22, QuickDetourOpenInWindowTests 17/17. Failing at HEAD with the screen locked: QuickDetourWindowTests 6 of 16, QuarantineWindowTests 4 of 22, QuickDetourOpenInWindowTests 2 of 17 (all page-load or paint waits).

- PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): the palette sends a window's commands straight to its controller (whose rule offered them), so Back and Forward are offered and the palette's Back on a child tab with no history closes it to its opener (TASK-325), which Cmd+[ with the page focused does not (WKWebView's own goBack: takes it); alternative: keep Back/Forward out of the palette, or send commands along the responder chain as the menu does (then Back from the palette is the page's own and does nothing without history).
- Wording correction: NSWindow declares selectNextTab:/selectPreviousTab: (window tabbing), but a Detour window was not seen to take them (the characterization's resolution from the window followed the controller's rule: on with two tabs, off empty, off in a one-tab Private window); the controller-first dispatch makes that moot. The demonstrated case is WKWebView's goBack:/goForward:.
- Lock attribution is INFERRED, not shown: the control suite FaviconLinkBridgeTests (8/8) loaded pages under the same lock. The evidence is that the three failing suites passed at b10ab60 and that nothing after it is on the failing tests' path (they open no palette). Rerun owed on an unlocked screen.

2026-11-14 lead: the 12 Quick Detour / quarantine failures were the locked screen. Rerun on an unlocked screen at f0f38d7 (TASK-320 rebased on main with 326/292.11/325/328/329): QuickDetourWindowTests 16/16, QuarantineWindowTests 22/22, QuickDetourOpenInWindowTests 17/17 (55/55). Rebased neighbours: 210 tests, 0 failures, 1 skipped (opt-in whole-list test).

2026-11-14 user decision: approved as built: command rows after 3+ characters, at most 2, below the typed row; '>' lists commands only; New Tab, Open Location…, Undo/Redo and parameterised commands not offered. AC #3: parameterised commands ask for their argument with a chip in the field, like site search (nested list and typed arguments rejected). Implementation of the chip follows.

## AC #3: the chip (2026-11-15, branch palette-chip: b77eb8c, 200e0c0, 3187099, 5edf4ab)

Built as the user decided on 2026-11-14 (a chip in the field, like site search; nested list and typed arguments rejected).
- Commands: space.switch (existing), tab.move-to-space and tab.split-with (new, no menu item; the sidebar's Move to and create-split paths through BrowserWindowController.moveSelectedTabToSpace(_:) / splitSelectedTabWith(_:)), extension.show-popup and extension.options (palette titles Show Extension Popup / Extension Options; choices from ExtensionMenuItems, shared with the Extensions menu).
- Choices (CommandChoices, pure): Switch to Space = what the Spaces menu offers (every normal space in Settings > Spaces order, another profile's too, its row naming the profile) but the window's own; none in a Private window. Move Tab to Space = what the sidebar's Move to offers (normal spaces; nothing from a Private window) but the tab's own space and spaces the store would refuse (canMoveTab / canMovePinnedEntry); not for a tab in a split (the sidebar has no Move to on a split row); a pinned entry moves as a pinned entry. Split with Tab = the window space's unpinned tabs in no split but the selected one (Private windows: their own tabs only); not for a pinned or split tab. A command is offered only when its rule holds and it has a choice (PaletteCommands.resolve), so Move Tab to Space with one space is not listed.
- Profiles: CommandChoices.profiles (normal profiles; none from a Private window) is built and tested but no command takes a profile yet (the lead's call: no invented profile command).
- Palette (CommandPaletteView chip mode, PaletteChip): Return or a click on a parameterised command's row puts the command's symbol and title in the chip (PaletteChipView, site search's chip, renamed from SiteSearchChipView, now with a symbol), placeholder Choose a space/tab/extension, rows = choices, first selected. The field filters (title prefix, then words, then contains in title or address); arrows keep the field; Return runs on the selected choice, nothing with none; no history, search suggestions, completion or filler; Space after a keyword, Tab and a leading > stay the filter. Backspace at the start puts back the typed text (plus a space and the filter, as site search), Escape leaves then dismisses, a Cmd+L palette dismisses at once (PaletteChip.escapeAction, shared with site search).
- Running: CommandDispatch.performFromPalette (both owners) checks the choice against commandChoices(for:) now and refuses a stale one (beep); perform(_:argument:in:controller:) sends an item built from the command with the value as representedObject to the controller (or the app delegate), validated by its rule.

PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): the new command IDs tab.move-to-space and tab.split-with (API once shipped; free to rename until then); alternative names under space.* / split.*.
PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): row and chip titles without an ellipsis (Switch to Space, Move Tab to Space, Split with Tab); alternative: Move Tab to Space… in the row, as menu items that ask for more.
PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): Develop's per-extension items (Inspect Offscreen, Reload Unpacked) stay out of the palette (the Develop menu lists every profile's extensions, the palette only its window profile's); alternative: offer them with the window profile's extensions only.
PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): Split with Tab puts the chosen tab to the right of the selected one (as Split with Next Tab); alternative: to its left, or a second chip for the side.

Tests at 5edf4ab (37 suites, one run): 552 tests, 0 failures. New: CommandChoicesTests 16, PaletteCommandChipTests 15, PaletteCommandChipWindowTests 8 (Move Tab to Space for a tab and a pinned entry, not for a split; Switch to Space; Split with Tab; a normal window never lists a Private window's space; a Private window offers neither space command and splits only its own tabs; a choice gone before Return is refused). Updated: BrowserCommandRegistryTests 23 (IDs pinned, parameterised commands offered, the chip commands' rules), PaletteCommandsTests 19, PaletteCommandWindowTests 9, SpaceJumpTests 15, PaletteCommandRowsTests 13, SiteColorTests 9. Also passing: SiteSearchPaletteTests 25, MainMenuCharacterizationTests 10, ShortcutMenuTests 10, MenuKeyEquivalentMatcherTests 16, PaletteRows/Selection/ReturnKey/Focus/EmptyState/TabScope*/SuggestionProvider, Help, Shortcut* suites, HotKeyShortcutTests, PeekWindowCommandsTests, OpenInQuickDetourMenuTests, ExtensionMenuPopupDecisionTests, ExtensionOptionsPageEntryTests, AutomationToolsTests, MCPServerTests, SplitTabTests, SiteSearchRuleTests, QuickDetourWindowTests 16.

Runtime (/verify, Debug build 00:04, DETOUR_DATA_DIR=DetourVerify-320chip, endpoint, seed_world: Home and Reading in Personal, Work in a second profile; screen unlocked): keys delivered by the endpoint as NSEvents to the field editor (type_text, press_key return/delete/escape); the palette opened with run_menu_item File > New Tab.
- >move tab, Return: chip Move Tab to Space (symbol and title, the space's blue, white text), rows Reading and Work (Work naming its profile); captured with source=screen in light and dark and looked at. rea + Return: the tab moved from Home to Reading (list_tabs).
- >switch, Return: chip; Backspace: >switch back with the command list; Return, Escape: chip gone, field cleared, palette open; Escape: dismissed. >switch, Return, work, Return: the window switched to Work. Its chip took Work's orange with dark text.
- Private window (AutomationAllowPrivate on for the run): >space lists no command; > lists Split with Tab and no space command; >split, Return: the chip lists only the window's other Private tab; Return formed the split in the Private space. With it open, the normal window's Switch and Move chips list Home and Reading only (no Private space).
- A click on the command row: the endpoint's click on a palette row does not send the table's action (any row, a plain command too; not this change's), so a real HID click (CGEvent, window brought front) was used: it entered the chip and the field kept the keys (rea + Return switched to Reading).
- Not run at runtime: the extension commands (no extension installed in the run; pure tests cover their choices), Split with Tab in a normal window (window tests), the Cmd+L palette's one-step Escape (unit tests).
- Seen: in a Private window the chip takes the Private space's 2C2C2E, close to the palette's dark glass, so the chip's edge barely shows (site search's chip there does the same, TASK-290's color rule).
- Cleaned up: the app stopped by pid; its NSWindow Frame / NSSplitView keys, its defaults suite and data folder deleted.

Code review (code-review medium --fix over 084197b..HEAD): 9 findings. Fixed: a choice gone stale by Return did nothing silently (now refused with a beep, performFromPalette, new test); dead chip state removed; the chip's title follows a re-scoped palette; a window with no space lists no extension; emoji icons cached; the two owners' duplicated dispatch folded into performFromPalette. Kept by decision: Move Tab to Space hides spaces the store would refuse (the brief: refused choices are not listed; the action's doc corrected); the profile list without a consumer (the lead's call). Left: choices are computed again on entry and on Return (canMoveTab reads the database only for extension pages).

## After the review: smoke /verify on the reviewed build, a focus fix (2026-11-15)

The checkpoint commits (b77eb8c, 200e0c0, 3187099) were made before code review and /verify; 5edf4ab holds the review fixes, and the first /verify ran on the build before them. So /verify ran again on the reviewed build (DETOUR_DATA_DIR=DetourVerify-320chip2 and -320chip3, same seeded world):
- Focus after a chip command, read through press_key's target: after Move Tab to Space, Switch to Space (twice) the page (BrowserWebView) had the keys; after Split with Tab NOTHING had focus ('Nothing in window 1 has keyboard focus'): the split re-hosts the selected tab's web view after the palette's dismissal gave it focus. Fixed: the browser window restores the page's focus again after a chip command runs, as after switching to a tab. Rerun on the fixed build: BrowserWebView after the split. New assertions in PaletteCommandChipWindowTests (the page has the keys after Move and after Split); the Split one fails without the fix (checked by commenting it out).
- Site search's chip (now PaletteChipView with a stack view, width cap 200 instead of 180): yt + cats shows YouTube with the same 8 pt sides and no symbol.
- Extension commands end to end: API Explorer installed for the Personal profile (install_extension, test run); >show ext + Return: chip Show Extension Popup listing API Explorer with its icon; Return with the window key (set_window_frame activate) opened its popup at the faux address bar, as the Extensions menu item does. In the background (no key window) the action does nothing, as its menu item's AppDelegate.extensionMenuClicked reads the key window (not changed here).
- Correction to the earlier note: the endpoint's click not reaching the palette table's action was measured on this branch's build only (a plain command row too), not on main.
- A row click was checked with a real HID click (CGEvent, Detour activated and its window brought front with set_window_frame).
Cleaned up: apps stopped by pid; defaults keys, suites and data folders of DetourVerify-320chip, -320chip2, -320chip3 deleted.

PROVISIONAL (chosen by Claude while the user was away, not confirmed by the user): a normal window's Switch to Space and Move Tab to Space list every normal profile's spaces, as the Spaces menu and the sidebar's Move to do (the row names the other profile). Alternative: the window's profile only, as the palette's open-tab and history rows are (TASK-209); a one-line filter in CommandChoices.

Tests after the fix: PaletteCommandChipWindowTests 8, PaletteCommandChipTests 15, PaletteCommandWindowTests 9, CommandPaletteFocusTests 4, all passing.

2026-11-15 user decision: the space chips (Switch to Space, Move Tab to Space) keep listing every normal profile's spaces, matching the Spaces menu (as built; no change).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Built the shared command registry, moved the main menu onto it, and made the palette offer browser commands, including those that need a space, tab or extension.

- Registry (Detour/Commands): every main-menu command has a stable hand-written ID, title, aliases, symbol, default key equivalent, typed parameters, the window kinds that answer it, and an availability rule and contextual title over a lazy CommandContext. Both validateMenuItem implementations answer the registry's rule; the menu is built from it (MainMenuCharacterizationTests unchanged); CommandDispatch is shared by the key-equivalent fast path, run_menu_item and the palette.
- Palette commands: rows rank in after the verbatim row (3+ characters, at most 2) or alone after '>' (the user's decision, 2026-11-14); Return dismisses the palette and runs the command through its menu item, sent to the window's controller; unavailable commands are not offered, by the menu's rule, in normal, Private, Quick Detour and quarantine windows.
- AC #3 (the user's choice of a chip, 2026-11-14): Switch to Space, Move Tab to Space, Split with Tab (both new) and the extension popup and options commands put their chip in the field; the field filters the window's choices (Spaces menu order, the sidebar's Move to and split rules, never a Private window's space, Private windows only their own tabs); Return runs the command on the choice through the path its menu or sidebar item takes, then the page gets the keys back; Backspace and Escape leave the chip as site search does. A command with no choice in the window is not offered. A profile list is built but no command takes a profile yet.
- Verification: affected suites at 5edf4ab, 552 tests, 0 failures, plus the chip and focus suites after the focus fix; runtime through the endpoint with key events: Move Tab to Space, Switch to Space, Split with Tab and Show Extension Popup through the chip, the chip in light and dark, Backspace and two-step Escape, focus after each command, a Private window offering no space commands and splitting only its own tabs; a row click via a real HID click.
- Provisional and left for the user: other profiles' spaces in a normal window's lists (as the menus), new IDs tab.move-to-space and tab.split-with, titles without ellipsis, Develop's per-extension items not in the palette, the split side. Not on the registry yet: context menus, the Dock menu, keys outside menus.
<!-- SECTION:FINAL_SUMMARY:END -->
