---
id: TASK-320
title: >-
  Command palette: browser commands (a shared command registry, also for
  AppleScript, Shortcuts and MCP)
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-10T09:38:00Z'
updated_date: '2026-11-14T22:32:00Z'
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
- [ ] #3 A command that needs a space, tab or profile asks for it in the palette and runs on the choice
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
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Built the shared command registry and moved the main menu onto it; the palette now offers browser commands. The task stays In Progress: how commands show up is provisional, and AC #3 (parameterised commands in the palette) is the user's call. The options and a recommendation are in the notes.

- Registry (Detour/Commands): every main-menu command has a stable hand-written ID (API for TASK-327), title, aliases, symbol, default key equivalent, typed parameters, the window kinds whose controller answers it, and an availability rule and contextual title over a lazy CommandContext that the browser and Quick Detour controllers implement. Both validateMenuItem implementations now answer the registry's rule.
- Menus: every item is built from its command (identifier = command ID); titles, keys, actions, targets, tags and enablement are unchanged. MainMenuCharacterizationTests were written on the old menu and pass unchanged. Dynamic items keep their builders.
- CommandDispatch: responder resolution in a given window plus AppKit's tiered enable decision, now shared by the TASK-56 fast path, run_menu_item and the palette.
- Palette: commands rank in after the verbatim row (3+ characters, at most 2 rows), or are listed alone after ">". Rows show the window's title for the command and the live item's shortcut. Return dismisses the palette and runs the command through its live menu item, sent to the window's controller. Unavailable commands are not offered, by the menu's rule, in normal, Private, Quick Detour and quarantine windows.
- Verification: tests (412 of 424 passed; the 12 failures are Quick Detour page-load waits under a locked screen, and those suites passed before the lock; rerun owed on an unlocked screen). Runtime through the endpoint with the screen locked: menus by key and path; palette commands in a normal and a Private window; Private menu enablement. Not run at runtime: Quick Detour (the endpoint cannot address it) and the rows' visual appearance.
- Follow-ups for the lead: TASK-319/228 can use CommandDispatch + isAvailable per command ID. Context menus, the Dock menu and non-menu keys are not on the registry yet.
<!-- SECTION:FINAL_SUMMARY:END -->
