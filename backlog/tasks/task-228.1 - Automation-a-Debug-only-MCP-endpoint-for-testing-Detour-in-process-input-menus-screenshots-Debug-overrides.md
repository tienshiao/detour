---
id: TASK-228.1
title: >-
  Automation: an MCP endpoint in Detour, first slice for testing (in-process
  input, menus, screenshots), off until turned on
status: To Do
assignee: []
created_date: '2026-11-14T01:08:00Z'
updated_date: '2026-11-14T01:26:00Z'
labels:
  - tooling
  - automation
dependencies: []
references:
  - .claude/skills/verify/SKILL.md
  - wiki/playbooks/runtime-verification.md
  - TASK-89
  - TASK-324
  - TASK-228.2
parent_task_id: TASK-228
priority: medium
ordinal: 392000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The first slice of TASK-228, filed 2026-11-14 at the user's request. It replaces TASK-89, which described the testing need more narrowly and is archived in its favour.

Builds (user decision 2026-11-14): the MCP server is not Debug-only; it ships in Release too. This overrides TASK-89's "absent from Release" rule. Because it can read pages and act with the user's sessions, it is off until turned on: in Release by the user, for a test run by an isolated DETOUR_DATA_DIR. Tools that only make sense for testing Detour itself (Debug overrides that stand in for system settings, such as Reduce Motion, or the space toss's hop and gravity) stay in Debug builds.

Why now: on TASK-324 the agent could not verify Download Linked File, a split pane, a hidden sidebar or Reduce Motion in the running app.
- Clicks posted only to Detour's process are ignored by an inactive app and by WebKit.
- Clicks through the HID event stream work only when Detour is frontmost, so each test stole focus and moved the user's pointer while they were working, and focus kept slipping mid-run.
- A context-menu item never responded to synthetic clicks.
- Reduce Motion is a protected system-wide setting.
- System Events 'click at' performs an accessibility press, not a mouse event, which misled a click-point test (TASK-324 notes).
- A clipboard-based check risked the user's clipboard.
Earlier, on TASK-86, many interaction checks were handed to the user although each was doable in-process (TASK-89).

Scope of this slice:
- A local MCP endpoint (HTTP on localhost) that this agent can call with curl and that Claude Code can register as an MCP server.
- Input is posted inside the app (NSApp.postEvent / NSWindow.sendEvent), so nothing comes to the front and the user's pointer never moves.
- Tools for state, input, menus and screenshots.
The rest of TASK-228 (fuller authorisation and connection UI, Private windows, CDP coverage, tools for tabs no window owns) stays open there, but this slice must not ship a Release endpoint that is reachable without the user turning it on.

Known in-process techniques (from TASK-89 and the wiki playbooks):
- evaluateJavaScript el.click() goes through real link activation.
- Synthesized NSEvents through NSApp.postEvent; WindowDragView's tracking loop aborts with window.sendEvent from a Task.
- Key equivalents via NSApp.mainMenu.performKeyEquivalent.
- NSApp.appearance for dark mode.
- contentView.cacheDisplay for web content, and tabSidebar.view.layer.render for the sidebar (cacheDisplay leaves the sidebar blank).
- A locked screen blocks paint and events.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Over a localhost MCP endpoint a client can list windows, spaces and tabs (selection, URL, title), select a tab, open a URL, and run a menu action or key equivalent
- [ ] #2 A client can click, modifier-click, right-click and type at a point in a window, or on an element of a tab by CSS selector, without the app coming to the front or the real pointer moving
- [ ] #3 A client can list the items of an open menu (including a web page's context menu) and choose one
- [ ] #4 A client can take a PNG of a window's content and of its sidebar, switch light or dark, and set Debug overrides (at least Reduce Motion and the space toss's hop and gravity)
- [ ] #5 The /verify skill and the runtime-verification playbook show how to use it, replacing the paste-a-harness-into-AppDelegate approach
- [ ] #6 Demonstrated end to end with no manual steps by re-running the TASK-324 checks that needed a human: Download Linked File, a download in a split pane, with the sidebar hidden, and with Reduce Motion
- [ ] #7 Off until turned on: in Release the endpoint does not listen until the user enables it (a setting, off by default, listening on localhost only); a test run can enable it only with an isolated DETOUR_DATA_DIR; Private windows are not reachable
- [ ] #8 The testing-only tools (Debug overrides such as Reduce Motion) are absent from Release builds (verified on the built product)
- [ ] #9 Tests cover the gate (not listening while off; the test-run switch refused without an isolated DETOUR_DATA_DIR; a Private window refused) and each tool's happy path and error cases (unknown window or tab, no open menu, a selector that matches nothing)
- [ ] #10 While a client is connected, Detour shows that an agent is connected (visible in every browser window without opening Settings) and the user can disconnect it from there; the indicator goes away when the last client disconnects
- [ ] #11 Tools that act on page content (input by selector, screenshots of web content) address a target context through an identifier that can later name an extension popup, options page, side panel or service worker, not only a tab. This way TASK-228.2 adds context kinds without changing existing tool signatures
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14, user decision: the 'agent connected' indicator, with a way to disconnect, ships in this first slice (moved from TASK-228's AC #3), since Release users can turn the endpoint on.

2026-11-14: TASK-228.2 (extension testing tools for an external compatibility suite) builds on this endpoint. AC #11 was added so the targeting model here does not have to be reworked there.
<!-- SECTION:NOTES:END -->
