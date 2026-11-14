---
id: TASK-228.6
title: >-
  Automation: input to tabs no window shows, through the epic's tab parking,
  once epic-claude-extension merges
status: To Do
assignee: []
created_date: '2026-11-14T06:26:00Z'
labels:
  - tooling
  - automation
dependencies:
  - TASK-228.4
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 399000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Split from TASK-228 AC #2 ('send clicks and keys, including to tabs no window currently owns') on 2026-11-13. A web view in no window loses mouseup and click (measured for TASK-132.3). The epic branch epic-claude-extension already solves this with AutomationParking (Detour/Browser/Window/AutomationParking.swift there): an attached tab that no window displays is parked hidden in a window's AutomationParkingView, isolated from the window's responder chain, and its input goes straight to the view (ExtensionDebugger+Input.swift). Building a second mechanism on main would collide with that at merge time, so this waits for the epic to reach main.

When it does: the MCP endpoint attaches a TabAutomationOwner (for example extensionID 'mcp', reason 'automation') to a tab it sends input to and that no window shows, and drops it after the call or at session end. The indicator and the user's Stop apply to it. Reconcile the endpoint's console and network capture (TASK-228.4) with the debugger's per-session instrumentation (TASK-132.16): one instrumentation source, or a documented reason for two.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 click, type_text, press_key and element clicks reach a tab no window shows, as trusted events, without showing it, moving the pointer or activating Detour
- [ ] #2 The tab is attached for the call through the epic's TabAutomationOwner machinery and released afterwards; the user's Stop ends it
- [ ] #3 The console/network capture overlap with the debugger instrumentation is resolved or its reason recorded; tests cover a parked tab's click and typing
<!-- AC:END -->
