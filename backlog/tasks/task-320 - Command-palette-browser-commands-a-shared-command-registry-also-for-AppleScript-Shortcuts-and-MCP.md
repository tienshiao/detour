---
id: TASK-320
title: >-
  Command palette: browser commands (a shared command registry, also for
  AppleScript, Shortcuts and MCP)
status: To Do
assignee: []
created_date: '2026-11-10T09:38:00Z'
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
