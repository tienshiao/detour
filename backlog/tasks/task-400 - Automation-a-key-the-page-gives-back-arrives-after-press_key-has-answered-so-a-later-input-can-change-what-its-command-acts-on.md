---
id: TASK-400
title: >-
  Automation: a key the page gives back arrives after press_key has answered, so
  a later input can change what its command acts on
status: To Do
assignee:
  - '@claude'
created_date: '2026-11-16T21:44:00Z'
labels:
  - automation
  - mcp
  - keyboard
dependencies: []
references:
  - Detour/Automation
  - wiki/features/automation-endpoint-input.md
priority: low
type: task
ordinal: 481000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-16 during the second two-lane batch (TASK-364, its final notes); measured there in part. Since TASK-364 the automation endpoint marks every key-down `press_key` hands a view, and a key the page gives back (WebKit re-sends a key the page does not take through `NSApp.sendEvent`) is routed to the main menu of the window it was pressed in (`AutomationKeyResend`). That key comes back after `press_key` has already answered (the page answered after more than a second once at runtime), so its command acts on whatever the window holds when it arrives: a `select_tab` sent in between can change which tab Cmd+W closes. That is what AppKit's own resend does for a person's key, so it is not a regression. Either document it for agents (the tool's description: wait, or check the result, before the next input), or make `press_key` wait until the page has taken or given back the key (with a bound) before it answers. Wiki: wiki/features/automation-endpoint-input.md ("A key the page gives back").
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Either press_key answers only once the page has taken or given back the key (bounded), or the tool's description tells agents a given-back key may act after the answer
- [ ] #2 A test covers the chosen behaviour (a select_tab sent right after a press_key of Cmd+W)
<!-- AC:END -->
