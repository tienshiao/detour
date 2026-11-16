---
id: TASK-390
title: >-
  Windows: browser-window commands typed in a never-main key window (the
  automation approval panel) act on the browser window behind it
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:42:00Z'
labels:
  - keyboard
  - menus
  - windows
dependencies: []
references:
  - Detour/Browser/Window/BrowserWindowController.swift
  - Detour/Commands/FieldUndo.swift
priority: low
type: bug
ordinal: 471000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-348, its code review); read from code, not run. TASK-348 made the Quick Detour launcher panel answer every browser-window command of the registry (`BrowserCommands.all` with responder `.windowController`) itself, so none falls through to the browser window behind it. Any other key window that never becomes main and does not answer those commands still lets them through: AppKit's nil-target search goes on to the main window's `BrowserWindowController`. Example from the review: the automation endpoint's approval panel (non-activating, key only if needed); with Full Keyboard Access on it can be key, and Cmd+W, Cmd+D or Shift+Cmd+T there would act on the browser window behind it.

Proposed general fix (the review's): `BrowserWindowController.validateMenuItem` disables `.windowController` commands when a non-main key window hands them to it, as `nonBrowserKeyWindow` / `FieldUndo.keyWindowHandingUndo(to:in:)` already decide for Undo and Redo (TASK-349, TASK-366). A command addressed to the window (the endpoint's `run_menu_item`, the window's own keys) must stay its own. Wiki: wiki/features/browser-commands.md, wiki/architecture/browser-undo.md.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With a key window that never becomes main and does not answer them (the approval panel made key), the browser-window commands (Cmd+W, Cmd+D, Shift+Cmd+T and the rest of .windowController) are disabled and do nothing to the browser window behind it
- [ ] #2 A command addressed to a browser window still acts there; the Quick Detour launcher keeps its own answers (TASK-348) and Undo/Redo the TASK-349 rule
- [ ] #3 A registry-driven test covers it
<!-- AC:END -->
