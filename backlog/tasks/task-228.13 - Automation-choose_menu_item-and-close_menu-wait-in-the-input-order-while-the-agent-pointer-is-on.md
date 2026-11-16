---
id: TASK-228.13
title: >-
  Automation: choose_menu_item and close_menu wait in the input order while the
  agent pointer is on
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
updated_date: '2026-11-16T09:56:00Z'
labels:
  - automation
dependencies: []
references:
  - TASK-228.11
  - wiki/features/automation-endpoint-agent-pointer.md
parent_task_id: TASK-228
priority: low
type: feature
ordinal: 437000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The user's decision 2026-11-15 on a question TASK-228.11's review left open. With the agent pointer on, the endpoint's clicks and keys are queued so each lands in the order sent; choose_menu_item and close_menu skip that queue, so 'click X, then choose menu item Y' can run Y before the click lands.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 With the agent pointer on, choose_menu_item and close_menu run only after every earlier input call has been delivered
- [x] #2 With the pointer off, behaviour is unchanged
- [x] #3 A test covers a click followed by a menu choice in both modes
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. AutomationTools+Input: wrap the close_menu and choose_menu_item handlers in inArrivalOrder (the FIFO click/type_text/press_key already use while the pointer is on); off, inArrivalOrder runs the body directly, so nothing changes. choose_menu_item's timeout_ms then counts from when its turn comes. list_menu and hit_test (read-only) stay out.
2. Doc comments (inArrivalOrder, AutomationInputOrder) name the menu tools.
3. Tests in AutomationAgentPointerTests: pointer on, a right click on a native view with a context menu glides (real 600 ms wait) and choose_menu_item (timeout_ms 150) / close_menu sent during the glide wait for the click and act on the menu it opened (fails without the change: no_open_menu); pointer off, a click then a menu choice works as before and the menu tools never wait on the order (held queue).
4. /verify via DETOUR_MCP=1 + scripts/detour-mcp, pointer on: two clients, a right click and choose_menu_item / close_menu sent during its 600 ms staging glide.
5. Wiki agent-pointer page (planned -> done), tools/tests pages, log line, lint; Backlog notes; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implementation (Nov 15 2026): close_menu and choose_menu_item handlers (AutomationTools+Input.swift) now run inside inArrivalOrder, the FIFO click/type_text/press_key already used while the pointer is on; with the pointer off inArrivalOrder runs the body directly, so nothing changes. The whole handler is in the order (argument checks included, as click does), so choose_menu_item's timeout_ms counts from its turn. Nothing run inside the order calls these tool handlers (AutomationInputOrder is not reentrant; the input tools call AutomationMenuTracker.closeAll directly). list_menu and hit_test (read-only) stay out.

Chosen by Claude (not yet confirmed by the user): choose_menu_item holds the order while it polls for a menu (up to timeout_ms, default 2 s, cap 30 s), so another client's later click waits behind a choice whose menu never opens; alternative: take the turn, then poll for the menu outside the order (a later click could then close the menu before the choice). Follows from 'in order'; a small diff to flip.

Tests: AutomationAgentPointerTests +2 — testWithThePointerOnAMenuChoiceWaitsForTheClickBeforeIt (right click on a native view with a context menu, 600 ms glide; choose_menu_item timeout_ms 150 and close_menu sent from the test during the glide act on the menu it opens) and testWithThePointerOffMenuToolsNeverWaitInTheInputOrder (pointer off: right click then choose_menu_item chosen with no glide; with the order held by another call the menu tools answer at once; turned on, close_menu waits until the order is free). Both fail with the menu handlers taken out of the order (8 assertion failures: no_open_menu, waits not observed). Runs: AutomationAgentPointerTests 14/14; AutomationAgentPointer + Input + Tools + MCPServer + WindowKinds + PrivateAccess 81/81.

Runtime (/verify, DETOUR_MCP=1, DetourVerify-22813, Debug build from this tree, pointer on through set_debug_override, set_window_frame first so the glide is 600 ms): two endpoint clients. Client A right-clicked the page (#area); 150 ms later client B sent choose_menu_item title Reload timeout_ms 100: click 0.000-0.721 s, choice 0.154-0.724 s, chose Reload, the page reloaded (performance.timeOrigin changed). Same race with close_menu: closed true (0.152-0.948 s), no menu left open. Detour stayed in the background (app_active false before and after). Script: scratchpad TASK-228.13/verify.py. Defaults keys and data folder removed.

Review (/code-review medium --fix, forked): fixed in the tree: the held-order test resumes its continuation in a teardown block; the off-mode menu calls run in a task with a 3 s wait, so a regression that makes them wait fails instead of hanging; a comment rewrapped, a misleading test comment removed. Skipped: choose_menu_item holding the order while it polls (the provisional choice above); list_menu outside the order (read-only, planned; a list_menu answered during another client's glide can describe the menu before that click's, so choose by index could then pick from a different menu: for the user); run_menu_item outside the order (out of scope: it can still run ahead of a gliding click; possible follow-up); extracting choose_menu_item's body into a method (re-indent churn only). After the fixes: AutomationAgentPointerTests 14/14 + AutomationInputTests 16/16 = 30/30.

2026-11-16: the user confirmed: choose_menu_item keeps its queue turn while it waits (up to timeout_ms) for a menu to open; run_menu_item and list_menu stay outside the input order.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
With the agent pointer on, choose_menu_item and close_menu now run in the input arrival order (AutomationTools.inArrivalOrder / AutomationInputOrder) with click, type_text and press_key, so a menu choice sent during a click's glide acts on the menu that click opens instead of failing with no_open_menu; timeout_ms counts from its turn. Pointer off: unchanged (the menu tools never wait on the order). Two new AutomationAgentPointerTests (both fail without the change); affected suites 81/81 before review, 30/30 after its test fixes; checked at runtime with two endpoint clients (right click + choose_menu_item Reload / close_menu sent 150 ms into a 600 ms glide). Provisional: choose_menu_item holds the order while it waits for a menu. Open for the user: list_menu and run_menu_item stay outside the order.
<!-- SECTION:FINAL_SUMMARY:END -->
