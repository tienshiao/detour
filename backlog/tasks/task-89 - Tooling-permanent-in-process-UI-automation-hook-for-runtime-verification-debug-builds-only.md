---
id: TASK-89
title: >-
  Tooling: permanent in-process UI automation hook for runtime verification
  (debug builds only)
status: To Do
assignee: []
created_date: '2026-09-19 19:45'
labels:
  - tooling
dependencies: []
references:
  - .claude/skills/verify/SKILL.md
  - Detour/App/AppDelegate.swift
priority: low
ordinal: 89000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Runtime verification of UI changes is currently done with a throwaway, env-gated harness pasted into AppDelegate for each task and reverted afterwards (TASK-86 rewrote it twice). That is slow, easy to forget to revert, and it nudges the agent into leaving interaction checks to the user: on TASK-86, click / Cmd-click on a History row, the Cmd+Y keystroke, dark mode, a split pane, the second-window snapshot and the incognito empty state were all handed over as 'needs a hands-on check' although each was doable in-process.

What is actually blocked for the agent's shell: posting input to the app from outside (CGEvent is silently dropped without the Accessibility grant) and screencapture (black without Screen Recording). Everything in-process works and has been used before: calling actions directly, evaluateJavaScript (el.click() goes through the real link-activation policy), delivering a synthesized NSEvent (modifier clicks, key equivalents via NSApp.mainMenu.performKeyEquivalent, the scroll-wheel swipe trick), NSApp.appearance for dark mode, contentView.cacheDisplay for web content and tabSidebar.view.layer.render for the sidebar (cacheDisplay leaves the sidebar blank).

Goal: decide on and build a reusable way to drive and observe the app, so an agent can verify interactions itself and nothing temporary is ever committed by accident.

Options to weigh (pick one in the plan, with reasons):
1. A permanent automation hook compiled ONLY into Debug builds (#if DEBUG) and inert unless an env var is set: reads a script (JSON steps from a file, or a local socket) and appends results to a log file. Candidate steps: run a menu action / selector, open a URL or internal page, select a tab, click an element in the selected tab by CSS selector (optionally with modifiers), send a key equivalent, set appearance light/dark, create a split / second window / incognito window, wait, dump state (selected tab, url, title, tab list) and page DOM via a JS expression, snapshot window and sidebar to PNG.
2. An XCUITest target. Likely hits the same TCC wall (the runner needs Accessibility) - verify before dismissing.
3. Granting the agent's shell host Accessibility / Screen Recording. Cheapest, but machine-specific, broad, and does not help other contributors.

Constraints: must not exist in Release builds at all (it can drive the browser and read page content - treat it as a security surface, not just dead code); must only ever run against an isolated DETOUR_DATA_DIR, never the production profile; launch/kill conventions stay as in the verify skill (match the DerivedData path, never the /Applications app).

What still needs a human regardless, and should stay out of scope: the real system keystroke path (another app or a system shortcut grabbing the key), network-dependent content on the user's own data, and aesthetic judgement.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A written decision between the options (hook / XCUITest / TCC grants), including whether XCUITest really is blocked by TCC on this setup
- [ ] #2 The chosen tooling can, without any temporary source edits: open a page or run a menu action, click and Cmd-click an element in the selected tab, send a key equivalent such as Cmd+Y, switch light/dark appearance, and produce a state/DOM dump plus PNG snapshots of the window content and the sidebar
- [ ] #3 Nothing of it is present in a Release build (verified on the built product, e.g. symbols/strings absent), and in Debug it is inert unless explicitly enabled
- [ ] #4 It refuses to run unless DETOUR_DATA_DIR points at a non-production data directory
- [ ] #5 The verify skill (.claude/skills/verify) documents how to use it, replacing the paste-a-harness-into-AppDelegate approach
- [ ] #6 Demonstrated end to end by re-running the TASK-86 hands-on list (row click, Cmd-click opens in the same space, Cmd+Y, dark mode, split pane, incognito empty state) with no manual steps
<!-- AC:END -->
