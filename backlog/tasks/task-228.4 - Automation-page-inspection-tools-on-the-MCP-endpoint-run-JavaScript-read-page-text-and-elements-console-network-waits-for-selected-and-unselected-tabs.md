---
id: TASK-228.4
title: >-
  Automation: page inspection tools on the MCP endpoint (run JavaScript, read
  page text and elements, console, network, waits), for selected and unselected
  tabs
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14T06:26:00Z'
updated_date: '2026-11-14T07:06:00Z'
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
- [x] #1 evaluate_js returns a script's JSON result, an awaited promise's value, or the thrown error (name, message, stack), in the page world or Detour's isolated world; a non-serialisable result is reported clearly, not dropped
- [x] #2 read_page returns URL, title, readyState and the page's text, HTML (whole or by selector) or its interactive elements with a CSS selector that click/type_text accept, cut at max_length with truncated set
- [x] #3 console_messages returns console calls, uncaught errors and unhandled rejections from a tab (main frame and subframes) after a cursor, with level filter; capture runs only while the endpoint is on and never in Private profiles
- [x] #4 network_requests returns the page's navigation and resource loads after a cursor (URL, type, timing, size, status where known; fetch/XHR method, status and failures), with its limits documented
- [x] #5 wait_for waits with timeout_ms for load complete, a selector (optionally visible), a truthy expression, or a URL match, and answers timeout when it does not happen
- [x] #6 Sleeping tabs answer tab_asleep in every page and input tool; wake_tab wakes one without selecting it; an unselected tab's page works for JS, read_page, console, network, wait_for and screenshot
- [x] #7 Tests cover each tool's happy path and errors (unknown, closed, sleeping and Private tab, bad arguments, script exception, timeout), and the wiki automation page and /verify playbook describe the tools
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14 implementation (bfbf5eb code+tests, 2bc49a7 wiki/playbook/verify skill):
- New files: Detour/Automation/AutomationTools+Page.swift (evaluate_js, read_page, console_messages, network_requests, wait_for, wake_tab; resolveTab/resolvePage, which need no window), AutomationPage.swift (callAsyncJavaScript with a deadline, the evaluate wrapper + in-page safe serialiser, read_page/elements/wait scripts, isolated world "DetourAutomation"), AutomationPageCapture.swift (page-world capture script, handler detourAutomationCapture, per-tab ring buffers of 1000 with seq).
- New codes: tab_asleep, script_error (with error.details {name, message, stack, thrown_type}; AutomationToolError gained details). Input tools now answer tab_asleep for a sleeping tab; not_displayed stays for a live tab no window shows.
- Capture: AutomationController starts it once listening and stops it in stop(); Space.makeUserContentController(for:) installs it into new web views of non-Private profiles while active; start() installs into every reachable tab's controller and evaluates the script once in loaded pages (main frame only). stop() removes script + handler (removeAllUserScripts + re-add the others) and clears buffers.
- Decisions: wait_for url is a plain substring (no glob). read_page's argument is `mode` (not `format`, a JSON Schema keyword MCPServerTests' flatness walk refuses). network: fetch/XHR rows are separate from their Resource Timing rows (source fetch/xhr vs resource); the navigation entry is posted after the load event (posted at document start it was incomplete, duration 0). console/network for a sleeping tab answer tab_asleep (AC #6), so records from before it slept are not readable until it wakes.
- Findings: PerformanceResourceTiming.responseStatus is not exposed by this WebKit (status null for resource/navigation rows; fetch/XHR carry status). A tab opened in the background and never shown has a 0x0 web view: scripts, text and console work, but no element is visible and takeSnapshot has no bitmap, so screenshot answers not_displayed ("select it once"); a tab shown once and then left keeps its frame and its screenshot works with no window (tests + runtime). Not forced (would resize a page nobody asked to change).
- Tests: AutomationPageTests 14/0 (new); all automation suites (Page, Input, Capture, Tools, Controller, MCPServer, Endpoint, HTTP, Helper) 104/0.
- Runtime (Debug build, DETOUR_DATA_DIR=DetourVerify2284 DETOUR_MCP=1, python http.server fixture on 127.0.0.1:8774, Detour in the background): on the UNSELECTED fixture tab: console_messages gave the console.log/warn, uncaught Error (line/column/source_url), unhandled rejection, info after the 404 fetch, and the iframe's console.error (main_frame false, frame_url /frame.html); network_requests gave fetch 404 (method GET, ok false), resources, both navigations; failed_only kept the 404 fetch; an XHR to /nope.txt gave source xhr status 404; wait_for a button added after 1.5 s matched at 1470 ms, #never timed out (timeout); evaluate_js returned values, awaited a promise (7), script_error for a throw, timeout at 300 ms; read_page text and elements (#go, #field, path selector html > body > a); screenshot of the unselected tab saved and looked right; click on it answered not_displayed and the window's selection never changed. After select_tab, clicking the path selector navigated and wait_for url matched; network showed the new navigation after the cursor. Cleaned up (SIGTERM by pid, data dir, WebKit stores, defaults domain + plist, window/split keys).
- Not checked at runtime: sleeping tabs and wake_tab (no way to put a tab to sleep from the endpoint; covered by tests), Private refusal (tests), turning the endpoint off/on in a running app (tests).
- For TASK-228.6 / the epic merge: the epic's TASK-132.15/.16 instrumentation overlaps AutomationPageCapture; decide then whether both share one source.

Full suite after the commits: 4158 tests, 19 skipped, 1 failure: ProfileDataRemovalTests.testDeletingAProfileRemovesItsWebKitDataFromDisk (timed out waiting for an extension worker's storage); passes alone (1/0), so a load-induced timeout unrelated to this change. Not run: /code-review (the lead's).
<!-- SECTION:NOTES:END -->
