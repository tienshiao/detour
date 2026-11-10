---
id: TASK-319
title: >-
  Automation: AppleScript / JavaScript for Automation dictionary and Shortcuts
  actions
status: To Do
assignee: []
created_date: '2026-11-10T09:35:00Z'
updated_date: '2026-11-10T09:38:00Z'
labels:
  - automation
  - tooling
dependencies: []
references:
  - TASK-228
  - TASK-89
  - TASK-132
  - Detour/Browser/TabStore.swift
  - TASK-320
priority: low
type: feature
ordinal: 381000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested 2026-11-10 by the user: automation support, to make it easier to automate things and to test things. It would expose browser-level UI state and actions (spaces, profiles, the sidebar, splits, Peek, Quick Detour) that a page-level protocol such as CDP or an MCP server built on it does not really expose.

The macOS options, as understood when filing (check each against current documentation before planning):
- AppleScript, through a scripting definition (an .sdef named by OSAScriptingDefinition in Info.plist, with NSAppleScriptEnabled) implemented with Cocoa Scripting: an object model (KVC accessors, object specifiers) plus NSScriptCommand subclasses. JavaScript for Automation (JXA, osascript -l JavaScript) reads the same dictionary, so it comes with no extra work, and so do Script Editor's dictionary browser and the Shortcuts and Automator 'Run AppleScript' / 'Run JavaScript' actions. A caller needs the user's one-time Automation (Apple Events) consent; receiving events needs no entitlement for a non-sandboxed app. Safari, Chrome and Arc all have such dictionaries (windows, tabs, URL, title, make new tab, close; Arc's adds spaces), and launcher integrations script browsers through them, so Arc users' scripts are a reason to model it on Arc's where it makes sense (Arc sunsets 2026-12-22).
- Shortcuts, through App Intents (macOS 13+; Detour targets 15.4): native actions with typed parameters and entities (Open URL in Space, Get Tabs of Space, Switch to Space, Open Quick Detour), which also show up in Spotlight and Siri. The Shortcuts app can already run AppleScript, so the dictionary alone reaches Shortcuts; App Intents is the native, discoverable layer on top.
- Automator: Apple points users to Shortcuts, and Automator also runs AppleScript. No separate work expected.

A possible object model, to settle in the plan: application > browser windows (active space, selected tab, sidebar shown/hidden, palette) > spaces (name, emoji, colour, profile, pinned entries and folders, tabs) > tabs (id, URL, title, loading, sleeping, audible, muted, pinned, split partner, has Peek); profiles; Quick Detour windows. Commands: make new tab (in a space, at a position, in a split), open URL (through Link Routes or into a named space), select, close, move to space, pin/unpin, reload, go back/forward, open Peek, open in Quick Detour, sleep, focus address bar, maybe 'do JavaScript'. The model is about tabs and spaces, not windows: a tab's web view lives in one window at a time (web view ownership) and may be asleep, so a command aimed at a tab must work whether or not a window hosts it.

Testing angle: (1) a script can set up and read state in the real app without the env-gated harnesses in docs/harness/; (2) from an agent's shell this needs a one-time Automation consent for the terminal app (osascript is blocked inside the Bash sandbox), which is narrower than the Accessibility or Screen Recording grants that block CGEvent and screencapture today; (3) a dictionary can probably be unit-tested in-process with NSAppleScript in the test host targeting the current application (to verify: whether Apple Events to self skip the consent prompt). Overlap to settle with TASK-89 (debug-only hook) and TASK-228 (MCP server): one command layer under all three, or AppleScript as the stable user-facing surface and the others on top. Gestures such as drags and animations will still need harnesses.

Open questions for the user:
- Which builds get it, and is it on by default (Release users scripting Detour is the point of AppleScript and Shortcuts) or behind a setting.
- 'do JavaScript' in a page: Safari and Chrome gate it behind a Develop-menu 'Allow JavaScript from Apple Events' switch that is off by default. Same here, or left out.
- Private windows and quarantine Quick Detours: excluded from the object model, or listed without page content.
- How closely to mirror Arc's dictionary (term names) so existing Arc scripts port with small edits.
- Whether Shortcuts (App Intents) is in the first cut or a follow-up.

Likely an epic once the questions are answered (dictionary and object model, commands, JavaScript gate, App Intents, tests and the verify-skill playbook).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The choice of surfaces (AppleScript/JXA dictionary, App Intents, neither of Automator's own) and the relationship to TASK-89 and TASK-228 are recorded in the task, with the rejected alternatives
- [ ] #2 A script (AppleScript and JXA) can list windows, spaces and tabs with their URL and title, open a URL in a named space, select, close and move a tab, and switch a window's space, including for a tab no window currently hosts or that is asleep
- [ ] #3 Running JavaScript in a page is refused unless the user has turned it on, and Private windows follow the rule chosen for them
- [ ] #4 Tests cover the object model and each command's happy path and error cases (unknown space or tab, closed tab, sleeping tab), plus the JavaScript gate
- [ ] #5 A wiki playbook shows how to script Detour against an isolated DETOUR_DATA_DIR for runtime verification
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-10: the command layer this needs is shared with TASK-320 (browser commands in the Command Palette): one registry of commands (identifier, title, typed parameters, availability rule, action through the menu item's code) that the menus, the palette, the AppleScript/JXA dictionary, App Intents and TASK-228's MCP tools all read. Settle its shape there or here, not twice.
<!-- SECTION:NOTES:END -->
