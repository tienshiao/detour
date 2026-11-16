---
type: Feature
title: "Automation endpoint: page tools and capture"
description: The automation endpoint's page tools (evaluate_js, read_page, console_messages, network_requests, wait_for, wake_tab) on selected, unselected and sleeping tabs, and the page-world capture script behind the console and network records, covering its ring buffers, when it is installed (only while the endpoint listens, Private pages only while allowed), what a page can notice, and the limits of the records.
tags: [automation, mcp, webkit]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: task-228-4
    resource: backlog:TASK-228.4
    title: "Automation: page inspection tools on the MCP endpoint"
  - id: page
    resource: ../../Detour/Automation/AutomationPageCapture.swift
    title: AutomationPageCapture.swift and AutomationPage.swift (capture script, buffers, page scripts)
  - id: tests
    resource: ../../DetourTests/AutomationPageTests.swift
    title: AutomationPageTests
---

The [automation endpoint](./automation-endpoint.md)'s page tools read and
run script in a tab's page (TASK-228.4).[^task-228-4] Each tool's
arguments are in [the tools table](./automation-endpoint-tools.md); this
page covers which tabs they reach and how console and network records are
captured.

# Which tabs

The page tools (`evaluate_js`, `read_page`, `console_messages`,
`network_requests`, `wait_for`, `wake_tab`, and `screenshot` with a
context) take a `context` (`tab:<uuid>`, or a bare tab id) whether or not a
window shows the tab (`resolvePage`): a tab of a non-Private space (or of a
Private one while [allowed](./automation-endpoint-private-windows.md)),
normal or pinned, or a live favorite. The input tools still need a window
and answer `not_displayed` without one (input to those tabs is planned in
TASK-228.6). A sleeping tab (no web view) answers `tab_asleep` in
every page and input tool; `wake_tab` loads its page without selecting it.
Before TASK-228.4 the input tools said `not_displayed` for a sleeping tab
too.

`evaluate_js` and `read_page` run in the page world or in an isolated
`WKContentWorld` ("DetourAutomation": the DOM, not the page's globals);
`read_page` always runs in the isolated world.

# Page capture

What `console_messages` and `network_requests` read
(`AutomationPageCapture`):[^page]

- **A user script in the page world**, at document start, in every frame
  (`forMainFrameOnly: false`). It wraps `console.log/info/warn/error/debug`
  (the wrapper calls the original, so the page's console is unchanged),
  listens for `error` (uncaught, as `ErrorEvent`s only) and
  `unhandledrejection`, observes Resource Timing (`PerformanceObserver`,
  `resource`, buffered), sends the navigation's entry once after the load
  event (it exists from the start but is complete only then: sent at once it
  had duration 0), and wraps `fetch` and `XMLHttpRequest` for method,
  status and failures. The fetch wrapper returns a promise that settles as
  the page's own, so a fetch the page leaves unhandled is still unhandled for
  it. Every hook is in a try/catch, the code is `let`/`const` only, and a
  symbol on `window` makes a second run a no-op.
- **One handler**, `detourAutomationCapture`, in the page world. The tab
  comes from `message.webView` (looked up among reachable tabs, then
  cached); the frame URL and main-frame flag from `message.frameInfo`, never
  from the page. Fields are whitelisted and strings cut to 8000 characters,
  since the page can post anything to the handler.
- **Per tab, two ring buffers** (console, network) of 1000 entries with their
  own increasing `seq`. Tools take `after_seq`, return `next_seq` (pass it
  back to read only newer entries; with `has_more` it is the last returned)
  and `dropped` (entries after the cursor the ring overwrote). Records
  survive navigation. Buffers of closed tabs are pruned (at most every 5 s,
  on a record or a read).
- **Only while the endpoint listens.** `AutomationController` starts capture
  once listening and stops it in `stop()`. Starting adds the script and the
  handler to every reachable tab's user content controller and runs the
  script once in pages already loaded (main frame only: their subframes are
  recorded from their next load). New web views get it from
  `Space.makeUserContentController(for:)`; a Private space's only while
  Private access is allowed, and never a Quick Detour or quarantine page
  (`inSpace: false`). Stopping removes both (there is no public way to
  remove one user script: all are removed and the others added back) and
  forgets every record. A page that already ran the script keeps its
  wrappers until it reloads, posting to a handler that is gone, silently.
  `seq` starts again after a restart.
- **Noticeable by the page**, accepted while automation is on: the wrapped
  `console.log.toString()`, `fetch` and `XMLHttpRequest.prototype`, and the
  handler under `window.webkit.messageHandlers`. A page could also post
  records of its own into its tab's buffer.

The options page of an extension is not captured this way (it is built from
the extension's configuration); read its console as `options:<ext>` (see
[extension contexts](./automation-endpoint-extensions.md)).

# Limits of `network_requests`

No headers or bodies; a cross-origin resource's sizes and timing are 0
unless it sends `Timing-Allow-Origin`; a load that failed outright (refused,
blocked) has no Resource Timing entry (fetch and XHR report it as `error`);
requests made by workers are not seen; a fetch appears twice, as `fetch`
and as `resource`. `status` of resource and navigation entries comes from
`PerformanceResourceTiming.responseStatus`, which the WebKit on this machine
(macOS 26, November 2026) does not expose: it is null there (checked in
tests and at runtime), and only fetch and XHR carry a status.[^task-228-4]

# Traps

- **A tab never shown has no size.** A tab opened in the background has a
  web view with a zero frame until a window first hosts it. Its page loads
  and runs scripts, and `read_page` text works, but its viewport is 0 × 0,
  so no element is visible, and WebKit's snapshot of it has no bitmap:
  `screenshot` answers `not_displayed` ("select it once"). A tab shown once
  keeps its frame after the window moves on, and its screenshot works with
  no window (checked in tests and at runtime). Giving such a web view a
  frame on demand was not done: it would resize and relayout a page nobody
  asked to change.[^task-228-4]

# Tests

`AutomationPageTests` (`evaluate_js` in both worlds, awaited promises,
converted values, thrown errors, syntax errors and timeouts; `read_page`
text, html, summary and elements whose selectors `click` takes; console
records from the main frame and a subframe with cursors and level filters;
network records of the navigation, resources, a 404 fetch, an XHR and a
refused fetch; `wait_for`'s four conditions and timeouts; `wake_tab`; every
page tool on a tab no window shows; unknown, closed, sleeping and Private
tabs; capture off until started, reaching an already loaded page once,
removed on stop, never in a Private profile without the opt-in; the ring
buffer).[^tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [The tools](./automation-endpoint-tools.md): each page tool's arguments
  and output.
- [Runtime verification](../playbooks/runtime-verification.md): the page
  tools in `/verify`.

[^task-228-4]: Automation: page inspection tools on the MCP endpoint
[^page]: AutomationPageCapture.swift and AutomationPage.swift (capture script, buffers, page scripts)
[^tests]: AutomationPageTests
