---
id: TASK-228
title: 'Automation: an MCP server so agents can drive and inspect Detour'
status: To Do
assignee: []
created_date: '2026-10-29T04:10:00Z'
labels:
  - tooling
  - automation
dependencies: []
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
