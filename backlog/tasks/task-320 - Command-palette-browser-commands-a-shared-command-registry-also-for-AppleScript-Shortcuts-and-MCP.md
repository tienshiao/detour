---
id: TASK-320
title: >-
  Command palette: browser commands (a shared command registry, also for
  AppleScript, Shortcuts and MCP)
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-10T09:38:00Z'
updated_date: '2026-11-14T21:45:00Z'
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
- [ ] #1 The registry's shape (command, parameters, availability, action) and how menus, palette, AppleScript/Shortcuts (TASK-319) and MCP (TASK-228) use it are recorded in the task, with rejected alternatives
- [ ] #2 Typing part of a command's title or alias in the palette lists it with its key equivalent, and Return runs it through the same code as its menu item
- [ ] #3 A command that needs a space, tab or profile asks for it in the palette and runs on the choice
- [ ] #4 A command unavailable in the context (window kind, selection, tab state) is not offered, by the same rule that disables its menu item
- [ ] #5 Tests cover the availability rules and the palette's ranking of commands against URL and history rows; the runtime check exercises the palette in a normal and a Private window
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
