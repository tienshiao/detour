---
id: TASK-228
title: 'Automation: an MCP server so agents can drive and inspect Detour'
status: To Do
assignee: []
created_date: '2026-10-29T04:10:00Z'
updated_date: '2026-11-14T06:27:00Z'
labels:
  - tooling
  - automation
dependencies: []
references:
  - TASK-320
  - TASK-319
priority: low
ordinal: 264000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested Oct 28 2026 as a future feature. An MCP (Model Context Protocol) server built into Detour would let an MCP client, such as Claude Code, Claude Desktop or another agent, drive the browser and read its state. Three uses:
1. Automations: a user's agent works in their real browser, with their sessions and extensions (like Claude in Chrome, or Playwright MCP for Chromium).
2. Web development debugging: an agent working on a site reads the console, network requests, DOM and screenshots from the page as it runs in Detour.
3. Testing Detour itself: verification today uses env-gated harnesses pasted into AppDelegate and reverted afterwards (docs/harness/*.patch, the /verify skill), plus in-process NSEvent tricks, because CGEvent and screencapture need TCC grants. A stable MCP surface could replace much of that. Custom harnesses may still be needed for things it cannot reach, such as stub NSDraggingInfo drops and frame-level animation checks.

Related work to reconcile rather than duplicate:
- TASK-89 (debug-only in-process automation hook) covers use 3 with a narrower design. Decide whether this task supersedes it, builds on it, or stays separate.
- TASK-132.13 and TASK-132.14 (chrome.debugger attach, sendCommand, captureScreenshot and input on the Claude extension epic branch) build CDP-style command plumbing and synthesized input for unselected tabs, which these tools may share.
- The WebView ownership model (only one window owns a tab's WKWebView, other windows show a snapshot) and sleeping tabs mean a tool aimed at a tab has to handle a tab that is unattached or asleep.

Open questions for whoever picks this up (the user decides the product ones):
- Which builds get it: Debug only, Release behind a setting that is off by default, or both with different tool sets. It can read page content and act with the user's logged-in sessions, so treat it as a security surface (TASK-89 requires its hook to be absent from Release).
- Transport and how a client connects: stdio through a helper binary, or a local HTTP or socket endpoint. Also how a client is authorised, and how the user sees that an agent is connected and can stop it.
- Scope per connection: all profiles and spaces, or one profile or space, with Private windows excluded by default.
- How much of Chrome DevTools Protocol to mirror versus Detour-specific tools such as spaces, profiles, split tabs and the sidebar.
- Whether it runs against an isolated `DETOUR_DATA_DIR` for testing, which the /verify skill already relies on.

This is likely an epic. Split it into subtasks (transport and auth, tab and navigation tools, page inspection, input, screenshots, Detour-specific tools, docs and verify-skill integration) once the open questions are settled.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An MCP client can connect to a running Detour, list its windows, spaces and tabs, open and select tabs, navigate, and read a tab's URL, title and page text or DOM
- [ ] #2 An MCP client can run JavaScript in a tab, read console messages and network requests, take a screenshot of a tab or window, and send clicks and keys, including to tabs no window currently owns
- [ ] #3 Access is off until the user turns it on. A connected agent is visible in the UI and can be disconnected. Private windows are not reachable unless the user explicitly allows it
- [ ] #4 The build and transport decision and the relationship to TASK-89 are recorded in the task, with the alternatives that were rejected
- [ ] #5 The /verify skill (or a wiki playbook) shows how to verify a Detour change through the MCP server against an isolated DETOUR_DATA_DIR
- [ ] #6 Tests cover the authorisation gate (refused without access, refused for a Private window) and each tool's happy path and error cases (unknown tab, closed tab, sleeping tab)
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-10: related new tasks. TASK-319 (AppleScript / JXA dictionary and Shortcuts actions) and TASK-320 (browser commands in the Command Palette) want the same command layer as this one's Detour-specific tools: one registry of commands (identifier, title, typed parameters, availability rule, action through the menu item's code) that menus, palette, AppleScript, App Intents and MCP tools all read. Decide the relationship when planning.

2026-11-14: The testing slice is TASK-228.1 (Debug + DETOUR_DATA_DIR only, a localhost MCP endpoint, in-process input and menus, screenshots, Debug overrides). It supersedes TASK-89, which is archived. The product questions above (Release exposure, auth UI, Private windows, CDP coverage) stay open for the rest of this task.

2026-11-14, user decision: the MCP server is not Debug-only; it ships in Release too (overriding TASK-89's 'absent from Release' rule). This answers the 'which builds' open question; access stays off until the user turns it on (AC #3).

2026-11-14: the 'agent connected' indicator and disconnect moved into TASK-228.1 (user decision). AC #3 here keeps the rest: fuller authorisation and the Private-window opt-in.

2026-11-13: cloud-hosted agents (claude.ai and ChatGPT connectors, cloud agents) cannot reach a localhost endpoint and are out of scope; reaching them would need a tunnel that exposes the user's browser to the internet. Open for the fuller authorisation in AC #3: Detour as its own local OAuth authorisation server (the MCP spec's HTTP auth), showing an 'X wants to control Detour: Allow / Deny' prompt, so OAuth-only clients work and nobody copies tokens. TASK-228.1 ships bearer token + Origin check + a bundled stdin/stdout helper instead.

2026-11-14 (user decision): TASK-228.1's Disconnect blocks a client by the name it reports, which a client can change; real per-client revocation belongs here, with the approval prompt in AC #3 ('X wants to control Detour: Allow / Deny') giving each client its own token that Disconnect revokes. The user-enabled endpoint now uses a port the system picks per launch (no fixed 47823).

2026-11-13: split the parent's remaining ACs into subtasks. TASK-228.4 covers page inspection (ACs #1 and #2: JS, page text and DOM, console, network, waits, sleeping and unselected tabs). TASK-228.5 covers the approval prompt with per-client tokens and the Private-window opt-in (AC #3; it has open design questions for the user). TASK-228.6 covers input to tabs no window shows (AC #2's last part). It waits for epic-claude-extension, whose AutomationParking (TASK-132.3) already solves that, so main does not grow a second mechanism. Order: 228.4, then 228.2 (which builds on 228.4's evaluate/console), then 228.3. 228.5 waits for the user's answers. 228.6 waits for the epic merge.
<!-- SECTION:NOTES:END -->
