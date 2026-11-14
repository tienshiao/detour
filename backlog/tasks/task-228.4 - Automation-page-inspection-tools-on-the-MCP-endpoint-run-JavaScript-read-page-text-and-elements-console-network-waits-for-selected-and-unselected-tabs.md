---
id: TASK-228.4
title: >-
  Automation: page inspection tools on the MCP endpoint (run JavaScript, read
  page text and elements, console, network, waits), for selected and unselected
  tabs
status: To Do
assignee: []
created_date: '2026-11-14T06:26:00Z'
labels:
  - tooling
  - automation
dependencies:
  - TASK-228.1
references:
  - wiki/features/automation-endpoint.md
  - Detour/Automation
parent_task_id: TASK-228
priority: medium
type: feature
ordinal: 397000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Split from TASK-228 (ACs #1 and #2) on 2026-11-13, so the parent's tab tools land before TASK-228.2 builds on them. TASK-228.1 shipped state, input, menus and screenshots. Agents and the extension suite (TASK-228.2) still need to read and assert on a page.

Scope:
- evaluate_js: runs a script in a tab's page (page world by default, or Detour's own isolated automation world) through callAsyncJavaScript. Awaits promises. Returns the JSON result or the thrown error (name, message, stack). A timeout gives the timeout error.
- read_page: URL, title and readyState. Also, as asked: the visible text, the HTML of the document or of a selector, or a list of interactive elements (role, name, a CSS selector that finds it again, rect in CSS pixels). Long output is cut at max_length and marked as cut.
- console_messages: console.* calls, uncaught errors and unhandled rejections, recorded per tab while the endpoint is on, read after a cursor (seq) with level filters.
- network_requests: what the page loaded (Resource Timing for every resource and the navigation). fetch and XHR add method, status and failures. Documented limits: no headers or bodies, and cross-origin timing is zeroed without Timing-Allow-Origin.
- wait_for: a tab finishing loading, a selector matching (optionally visible), a JS expression turning truthy, or the URL matching. All with timeout_ms.
- Sleeping tabs answer a new tab_asleep code everywhere, including 228.1's input tools, which answered not_displayed for that case. A wake_tab tool loads a sleeping tab's web view without selecting it.
- Unselected tabs (no window shows the web view): JS, read_page, console, network, wait_for and the page screenshot work. Input to them is TASK-228.6 (it needs the epic branch's AutomationParking).

Capture design: a WKUserScript in the page world at document start, all frames. It posts to a script message handler, and the tab comes from message.webView. It is installed only while the endpoint is listening, into non-Private profiles only; pages already loaded get it once by evaluateJavaScript. It is removed when the endpoint stops, and each tab keeps a bounded ring buffer. Wrapping console.* can be noticed by a page; that is accepted while automation is on and documented.

Overlap to reconcile later: the epic branch (TASK-132.15/.16) has its own per-debugger-session console/network instrumentation and Runtime.evaluate. When the epic merges, decide whether both share one instrumentation source (note in TASK-228.6).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 evaluate_js returns a script's JSON result, an awaited promise's value, or the thrown error (name, message, stack), in the page world or Detour's isolated world; a non-serialisable result is reported clearly, not dropped
- [ ] #2 read_page returns URL, title, readyState and the page's text, HTML (whole or by selector) or its interactive elements with a CSS selector that click/type_text accept, cut at max_length with truncated set
- [ ] #3 console_messages returns console calls, uncaught errors and unhandled rejections from a tab (main frame and subframes) after a cursor, with level filter; capture runs only while the endpoint is on and never in Private profiles
- [ ] #4 network_requests returns the page's navigation and resource loads after a cursor (URL, type, timing, size, status where known; fetch/XHR method, status and failures), with its limits documented
- [ ] #5 wait_for waits with timeout_ms for load complete, a selector (optionally visible), a truthy expression, or a URL match, and answers timeout when it does not happen
- [ ] #6 Sleeping tabs answer tab_asleep in every page and input tool; wake_tab wakes one without selecting it; an unselected tab's page works for JS, read_page, console, network, wait_for and screenshot
- [ ] #7 Tests cover each tool's happy path and errors (unknown, closed, sleeping and Private tab, bad arguments, script exception, timeout), and the wiki automation page and /verify playbook describe the tools
<!-- AC:END -->
