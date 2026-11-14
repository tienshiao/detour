---
type: Feature
title: Automation endpoint (MCP)
description: "Detour's local MCP server for agents and scripts (TASK-228.1, TASK-228.4, TASK-228.2): how it is turned on, who may connect (Host, Origin, bearer token), the HTTP and MCP layers, the tools and their stable error codes, how clicks, keys and menus are delivered inside the app without activating it, screenshots and what they cannot draw, the page tools (JavaScript, page text and elements, console and network capture, waits, sleeping and unselected tabs) and their limits, the extension tools (install, list, enable, permissions, popup, options and worker contexts, the channel into a service worker, extension console) and their limits, the per-extension compatibility report (static scan of chrome.* references checked in the live worker and a probe page, the stub registry and its call counts, API-naming runtime errors, unsupported manifest keys and permissions, worker failures) and the stable output for diffing against a baseline, the connected-agent indicator and disconnecting, the bundled stdio helper and client setup, the scripts/detour-mcp client, and the traps met building it (menu-bar titles, animated commands, modal actions and the main queue, key ordering, window-server materials, SIGTERM, never-shown tabs, Resource Timing status, inert host rows, real native hosts, a popup's profile in the test host)."
tags: [automation, mcp, testing, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T09:20:00Z }
sources:
  - id: automation-dir
    resource: ../../Detour/Automation
    title: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
  - id: client
    resource: ../../scripts/detour-mcp
    title: scripts/detour-mcp (stdlib Python client)
  - id: task-228
    resource: backlog:TASK-228
    title: "Automation: an MCP server so agents can drive and inspect Detour"
  - id: task-228-1
    resource: backlog:TASK-228.1
    title: "Automation: an MCP endpoint in Detour, first slice for testing"
  - id: controller
    resource: ../../Detour/Automation/AutomationController.swift
    title: AutomationController.swift (lifecycle, clients, token, indicator text)
  - id: helper
    resource: ../../Helpers/detour-mcp/main.swift
    title: detour-mcp, the bundled stdio helper
  - id: input
    resource: ../../Detour/Automation/AutomationInput.swift
    title: AutomationInput.swift (delivery, keys, elements, the menu tracker)
  - id: task-228-4
    resource: backlog:TASK-228.4
    title: "Automation: page inspection tools on the MCP endpoint"
  - id: page
    resource: ../../Detour/Automation/AutomationPageCapture.swift
    title: AutomationPageCapture.swift and AutomationPage.swift (capture script, buffers, page scripts)
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
  - id: task-228-2
    resource: backlog:TASK-228.2
    title: "Automation: extension testing tools on the MCP endpoint"
  - id: extension-tools
    resource: ../../Detour/Automation/AutomationTools+Extensions.swift
    title: AutomationTools+Extensions.swift (addressing, the extension tools)
  - id: channel
    resource: ../../Detour/Automation/AutomationExtensionChannel.swift
    title: AutomationExtensionChannel.swift (the channel into an extension's background, the command runner)
  - id: extension-tests
    resource: ../../DetourTests/AutomationExtensionTests.swift
    title: AutomationExtensionTests and AutomationExtensionChannelTests
  - id: compat-report
    resource: ../../Detour/Automation/AutomationTools+CompatReport.swift
    title: AutomationTools+CompatReport.swift and AutomationCompatReport.swift (the report, the probe page, the scan)
  - id: stubs
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillStubs.swift
    title: ExtensionPolyfillStubs.swift (the stub registry and the counting module)
  - id: compat-tests
    resource: ../../DetourTests/AutomationCompatReportTests.swift
    title: AutomationCompatReportTests
  - id: webkit-manifest
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtension.cpp
    title: "WebKit, WebExtension.cpp (the manifest keys it reads, supportedPermissions)"
---

# What it does

A local [MCP](https://modelcontextprotocol.io) server inside Detour, so an
agent (Claude Code, another MCP client) or a plain script can read the
browser's state and act on it: list windows, spaces and tabs, select a tab,
open a URL, run a menu command, click, type, and choose from the menu that is
open, take screenshots, and read a page: run JavaScript, read its text, HTML and
interactive elements, its console and network records, and wait for
something to happen in it (TASK-228.4). Built first for testing Detour itself
(replacing harness patches pasted into AppDelegate), and shipped in Release
too, off until turned on.[^task-228-1] TASK-228.2 adds extensions:
installing and managing them in a test run, and their popup, options page
and service worker as contexts the same tools reach (see "Extension
contexts").[^task-228-2]

# How it is turned on

`AutomationGate.mode` decides once at launch:[^automation-dir]

| How | Listens on | Notes |
|---|---|---|
| The user's setting (`AutomationEndpointEnabled` in the data directory's defaults suite), Settings > General > Automation | a port the system picks at each start (`AutomationEndpointPort` fixes one, advanced) | Not a fixed port (user decision, 2026-11-14): while Detour is not running, another account could listen on a fixed one and collect the token from a client configured with the address. Clients use the bundled helper, which reads the port. Turned on and off at runtime by `AutomationController.setEnabled`; the window's indicator has Turn Off Automation too. |
| `DETOUR_MCP=1` for a test run | an ephemeral port, or `DETOUR_MCP_PORT` | Only with `DETOUR_DATA_DIR` set and not `Detour`: a scripted run can never open the user's real profile. A refused request is logged, never silent. |
| The XCTest host | never | Tests start their own endpoint. |

When listening, the data directory holds two files, both created 0600:
`mcp-token` (the bearer token, kept across launches) and
`mcp-endpoint.json` (`url`, `port`, `pid`, `token`, `test_run`), written once
the listener is ready and removed at quit, and on SIGTERM (see Traps). The
published URL is `http://127.0.0.1:<port>/mcp`, never `localhost`: Node
resolves `localhost` to `::1` first, where nothing listens.

# Who may connect

Loopback alone is not a boundary: any local process can reach the port, and
so can a web page (a cross-origin POST is still delivered, and DNS rebinding
lets a page read the answer). `AutomationAuthorization.decide` checks every
request before its body is looked at, in this order:

1. `Host` must be `127.0.0.1`, `localhost` or `[::1]` with our port: a
   rebound host name stops here (403).
2. `Origin`, when present, must be an `http://` loopback origin. Browsers send
   one on every cross-origin POST; MCP clients outside a browser send none
   (403).
3. `Authorization: Bearer <token>`, compared in constant time (401).

The 401 carries `WWW-Authenticate: Bearer realm="Detour"` and no OAuth
`resource_metadata`, so an OAuth-only client fails at once instead of
starting a discovery flow Detour does not offer. Threat model: the token
stops web pages and local programs that cannot read the user's files
(sandboxed apps, other accounts); malware running as the user can read the
token file, and could drive the browser in other ways anyway. Private
windows and spaces are never listed and are refused by ID
(`private_unreachable`).

Before any token is shown, a connection costs little: the endpoint holds
at most 64 and closes one that has not sent an authorised request within
10 s, so a local process without the token cannot exhaust Detour's file
descriptors (which SQLite and WebKit's IPC need).

Private windows stay out of menus too: a menu that opened over a Private
window (the person's context menu there, or the menu bar while one is in
front and Detour is active) is refused by `list_menu` and
`choose_menu_item`, and the Window menu's entries for Private windows (titled
with their page) are neither listed nor run. This errs towards refusing: an
agent's own menu opened while a Private window is in front is refused too.

Clients must not leak the token: `scripts/detour-mcp` bypasses HTTP proxies
(urllib sent the `Authorization` header to a configured proxy even for
127.0.0.1), and Copy Token marks the pasteboard item transient, concealed
and local-only, so clipboard managers and Universal Clipboard skip it.

# How it works

Three layers, each testable alone:

- **Socket** (`AutomationEndpoint`, nonisolated, state in a `Mutex`): an
  `NWListener` bound to 127.0.0.1 (`requiredLocalEndpoint`, loopback
  interface, `acceptLocalOnly`). It reads with `AutomationHTTP.parse`
  (Content-Length and chunked bodies, 4 MB cap, keep-alive and pipelining),
  authorises, and hands each request to the main actor. One request per
  connection is answered at a time.
- **MCP** (`MCPServer`, main actor, no socket): Streamable HTTP in its
  simplest form. POST carries JSON-RPC (single or batch) and is answered as
  `application/json`. Notifications get 202, GET gets 405 (no server-sent
  stream), DELETE ends a session. `initialize` negotiates 2025-11-25,
  2025-06-18, 2025-03-26 or 2024-11-05 (others get the newest), issues
  `Mcp-Session-Id` and records the client's `clientInfo` title or name for
  the connected indicator. A missing session is 400, an unknown one 404
  (which tells the client to start a new one), and beyond 32 sessions the
  least recently seen is dropped.
- **Tools** (`AutomationTools`, main actor): each declares a flat input
  schema and an output schema, and returns `structuredContent` with the same
  JSON as text (older clients read only text). A failure is `isError` with
  `{error: {code, message}}`; the codes (`AutomationErrorCode`) are a
  contract, added to and never renamed. Output schemas list no required
  fields, so an error result validates too. Unknown arguments are refused,
  so a misspelt argument in a script fails instead of being ignored.

Input schemas are kept to one object of string, integer, number, boolean and
string-array properties, with no `$ref`, `oneOf`, `anyOf`, `allOf` or
formats: OpenAI and Gemini models reject those. `MCPServerTests` walks every
tool's schema to hold it.

## The tools

| Tool | Does | Notes |
|---|---|---|
| `list_windows` | Windows with `window_id`, `window_number` (the CGWindowID), frame, key/main, active space, selected tab | `window_id` is a small stable number per window, not `windowNumber`, which is only assigned once a window is on screen. |
| `list_spaces` | Spaces with profile, counts, the windows showing each | |
| `list_tabs` | A space's favourites, pinned entries (live or dormant) and tabs, in sidebar order, plus its pinned folders | `id` is what `select_tab` takes; `tab_id` and `context` are null for a dormant item. |
| `select_tab` | Selects an item as a row click does | Switches the window's space first; wakes a dormant pinned entry or favourite; `dormant_refused` when its extension keeps it dormant. |
| `open_url` | The palette's typed-URL path (`openTypedURL`): a new tab, or `in_place` | Link Routes apply as for a typed URL; `routed` says the URL went elsewhere. |
| `run_menu_item` | A main-menu command by path or key equivalent, sent to that window's responder chain and validated there | Works with Detour in the background, where there is no key window. |
| `click` | A click by element (`context` + CSS `selector`), by page point (`context` + CSS-pixel `x`, `y`) or by window point (`window_id` + `x`, `y`, the content's top-left origin); `button` left/right, `modifiers`, `count` 2 for a double click | Closes an open menu first. `completed` false: the click opened a menu or an alert that is still open. |
| `type_text` | Key presses for `text` into a tab's page (after clicking `selector`, if given) or a window's focused control; `interval_ms` paces them | US key codes; other characters as key presses with no physical key. |
| `press_key` | One key with modifiers (`return`, `shift+tab`, `cmd+a`) | A Cmd key goes through the target's key equivalents (`handled`); menu commands are `run_menu_item`. |
| `hit_test` | What a click at a window point would reach: view class, accessibility role and label, frame | Read-only; aims `click` without a screenshot. |
| `list_menu` | The open menu's items (index, title, enabled, checked, submenu, identifier); waits `timeout_ms` for one to open; `path` for a submenu | A page's context menu shows WebKit's `WKMenuItemIdentifier…` identifiers. |
| `choose_menu_item` | Chooses an item by title, index or identifier, then closes the menu | WebKit's own items run for real (Download Linked File downloaded at runtime). |
| `close_menu` | Closes the open menu without choosing | |
| `screenshot` | A PNG of a window's content, its sidebar (`part`) or a tab's page (`context`), as image content and/or written to `save_to` (an existing file only with `overwrite`); `scale` 1 or 2, never above the display's | `source` app (default): drawn inside Detour, no grant, works in the background, no shadow, but no glass (see Traps). `source` screen: the window server's picture through ScreenCaptureKit, exact; needs Screen Recording (checked with `CGPreflightScreenCaptureAccess`, never prompted), else `permission_denied`. |
| `set_appearance` | Light, dark, or following the system, for all of Detour (`NSApp.appearance`) | Until quit or the next call. |
| `evaluate_js` | Runs `expression` or `script` (a function body with `return`) in a tab's main frame, `world` page (default) or isolated (`WKContentWorld` "DetourAutomation": the DOM, not the page's globals); awaits promises | Result as JSON with its `type`; what JSON cannot hold is converted in the page (nodes `<div#id.class>`, cycles `[Circular]`, functions, undefined null). A throw is `script_error` with `error.details` {name, message, stack}; a syntax error too (from WebKit's exception). `timeout_ms` (default 10 s) gives `timeout`; the script runs on. Results over 1 MB are cut (`truncated`). |
| `read_page` | url, title, ready_state, viewport, and by `mode`: `text` (default, `innerText`), `html` (`outerHTML`), `elements`, `summary` | `selector` narrows; `max_length` cuts text and html, `max_elements` the list, with `truncated`. Elements: tag, role (explicit or implicit), name (aria-labelledby, aria-label, label, text, alt, title, placeholder), a selector unique in the document (`#id`, then `tag[data-testid|name|aria-label=…]`, then an `nth-of-type` path), rect in CSS pixels, visible (`checkVisibility`), in_viewport, disabled. Runs in the isolated world. The argument is `mode`, not `format`, a JSON Schema keyword the flatness test refuses. |
| `console_messages` | A tab's console calls, uncaught errors and unhandled rejections, all frames, after `after_seq`, filtered by `levels` | See "Page capture". `stable: true` leaves out `seq` and `timestamp` and names extension origins by extension id. |
| `network_requests` | A tab's navigation and resource loads (Resource Timing) and its fetch and XHR calls, after `after_seq`, by `sources`, `failed_only` | See "Page capture" for the limits. |
| `wait_for` | Polls every 100 ms until `load` (not loading and readyState complete), `selector` (with `visible`), `expression` truthy (a throw counts as false; the last one is in the timeout's message) or `url` (a plain substring) | `timeout` after `timeout_ms` (default 10 s). Exactly one condition. |
| `wake_tab` | Loads a sleeping tab's page (`BrowserTab.wake()`) without selecting it | `woken` false when it was awake. |
| `set_debug_override` | Debug builds only: `reduce_motion` (this process, via `MotionPreference`), `space_toss_hop` and `space_toss_gravity` (the data directory's defaults keys `SpaceCelebration` already read in Debug); `default` clears | Absent from Release (checked on a Release build: its tool list and its binary's strings). |
| `list_extensions` | Installed extensions sorted by id (or one, by id or name): version, source, global switch, `loaded`/`load_failed`, per normal profile `turned_on`, `loaded`, `worker_parked`, `open_contexts`, `context_errors`; the manifest's permission lists, the saved decisions, WebKit's manifest warnings and every load error recorded this session | Reads whenever the endpoint is on. Load errors come from `ExtensionErrorLog` (see "Extension contexts"). `stable: true` is the diffable form (see "Diffing against a baseline"). |
| `install_extension` | Test runs only. An unpacked folder or a `.crx`, turned on in `profile_id` (default: the only normal profile); waits for it to load | No prompt. A CRX goes through `CRXInstallGate` with a file URL (its developer signature), may replace an installed id, and never updates. A keyless folder installed again keeps its id. `install_failed` for no or a bad manifest or a refused CRX. |
| `uninstall_extension` | Test runs only. Settings' Uninstall, every profile, no prompt | Closes the endpoint's popups of it first. |
| `set_extension_enabled` | Test runs only. One normal profile's switch (`profile_id`) or the global one | The Private profile is `private_unreachable`. |
| `set_extension_permission` | Test runs only. Saves a grant or denial and applies it to every profile's context (`setPermissionDecision`): an API permission, a match pattern, or a URL with `type` url | `warnings` names a decision with no effect: a host outside the manifest's host patterns stays inert, an undeclared API permission is not restored next launch, `nativeMessaging` gates real hosts only. |
| `open_extension_context` | `kind` popup (in a window, at its button, with a click's user gesture), options (a tab, in the background or selected in `window_id`), worker (start it and wait for it to answer) | Returns the `context` string. `sidepanel` is `unsupported_context` on this build. |
| `close_extension_context` | Closes the endpoint's popup, or the options page's tab | `context_not_open` when it is not open. |
| `call_extension_api` | Calls the function at a dotted path (`chrome.storage.local.get`) with `args` (a JSON array as a string), awaits it, returns the result as `evaluate_js` does | In `worker:` through the channel; in a popup, options page or tab through `callAsyncJavaScript`. A missing member is a `TypeError` (`script_error`). |
| `read_extension_global` | Reads the value at a dotted path (`self.cache.size`) | How a worker's own globals are read. |
| `extension_compat_report` | What an extension uses that Detour lacks: its `chrome.*`/`browser.*` references checked in the worker and a page, the stubs it references or called, API-naming TypeErrors, unsupported manifest keys and permissions, worker failures | Whenever the endpoint is on (not gated: it installs nothing). `probe: false` skips the runtime checks. See "The compatibility report". |

Tools that act on page content take a `context` (`tab:<uuid>`, or a bare
tab id): a tab of a non-Private space, normal or pinned, or a live favorite.
The page tools (`evaluate_js`, `read_page`, `console_messages`,
`network_requests`, `wait_for`, `wake_tab`, and `screenshot` with a context)
take it whether or not a window shows the tab (`resolvePage`); the input
tools still need a window and answer `not_displayed` without one (input to
those tabs is TASK-228.6). A sleeping tab (no web view) answers `tab_asleep`
in every page and input tool; before TASK-228.4 the input tools said
`not_displayed`. Extension contexts (`popup:<ext>`, `options:<ext>`,
`worker:<ext>`, `extension:<ext>`) go in the same argument
(`resolvePageTarget`); see "Extension contexts" for which tool takes which.

## How input is delivered

Nothing is posted at the HID level, so Detour never comes to the front and
the person's pointer never moves (`AutomationInput`):[^input]

- **A page** gets the events handed to its web view: `mouseDown(with:)`, a
  60 ms pause (WebKit takes a down and an up in the same turn as no click),
  `mouseUp(with:)`; keys through `keyDown(with:)` and `keyUp(with:)`, after
  the web view is made its window's first responder (which does not activate
  the app). The page sees trusted events (`isTrusted`) with the modifiers
  and US `event.code`s, while Detour is in the background.
- **A native view** under a window point gets `mouseDown(with:)` directly,
  with the mouse-up posted to the app's queue first, where a control's
  tracking loop finds it. Checked at runtime with Detour in the background:
  the sidebar's Add Space button opened the space editor.
- **Every event goes out from `RunLoop.main.perform`**, as `run_menu_item`'s
  actions do (see Traps): a native context menu runs its whole tracking loop
  inside `rightMouseDown`, so the click answers `completed: false` after
  the wait while the menu stays open and the endpoint keeps answering.
- **Menus**: `AutomationMenuTracker` follows
  `NSMenu.didBeginTrackingNotification` and `didEndTrackingNotification` for
  every menu in the app; the newest one open is what `list_menu` shows.
  Choosing calls `performActionForItem(at:)` while the menu is still
  tracking (WebKit's items need their live menu), then `cancelTracking()`.

# Page capture

What `console_messages` and `network_requests` read (`AutomationPageCapture`):[^page]

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
- **One handler**, `detourAutomationCapture`, in the page world. The tab comes
  from `message.webView` (looked up among reachable tabs, then cached); the
  frame URL and main-frame flag from `message.frameInfo`, never from the page.
  Fields are whitelisted and strings cut to 8000 characters, since the page
  can post anything to the handler.
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
  `Space.makeUserContentController(for:)`, never for a Private profile (nor a
  quarantine, which uses the Private profile). Stopping removes both (there
  is no public way to remove one user script: all are removed and the others
  added back) and forgets every record. A page that already ran the script
  keeps its wrappers until it reloads, posting to a handler that is gone,
  silently. `seq` starts again after a restart.
- **Noticeable by the page**, accepted while automation is on: the wrapped
  `console.log.toString()`, `fetch` and `XMLHttpRequest.prototype`, and the
  handler under `window.webkit.messageHandlers`. A page could also post
  records of its own into its tab's buffer.

Limits of `network_requests`: no headers or bodies; a cross-origin
resource's sizes and timing are 0 unless it sends `Timing-Allow-Origin`; a
load that failed outright (refused, blocked) has no Resource Timing entry
(fetch and XHR report it as `error`); requests made by workers are not seen;
a fetch appears twice, as `fetch` and as `resource`. `status` of resource and
navigation entries comes from `PerformanceResourceTiming.responseStatus`,
which the WebKit on this machine (macOS 26, November 2026) does not expose:
it is null there (checked in tests and at runtime), and only fetch and XHR
carry a status.

# Extension contexts

What TASK-228.2 (part 1) adds, for a suite that installs third-party
extensions and drives them:[^task-228-2][^extension-tools]

## Addressing

An extension is named by its id, or by its exact manifest name (localised
or as written, ignoring case): two with that name are
`ambiguous_extension`, none `unknown_extension`. Ids survive relaunch, and
a reinstall of the same folder keeps a keyless extension's random id (the
install passes Reload's `forcedID` when an installed unpacked extension came
from that folder), so a scenario's saved id still resolves.

A context is `<kind>:<extension>`, with `@<profile uuid>` appended when the
extension is on in more than one normal profile (else
`ambiguous_profile`); only a UUID after the last `@` counts, so a name with
an `@` still reads as a name. Off in every profile is
`extension_disabled`. The Private profile is never a target: not listed,
not installable into, `private_unreachable` by id.

| Context | What it is | Tools |
|---|---|---|
| `popup:<ext>` | The action popup the endpoint opened (or one the extension opened with `action.openPopup()`), while it is up; else `context_not_open` | `evaluate_js`, `read_page`, `wait_for`, `click`, `type_text`, `press_key`, `screenshot`, `call_extension_api`, `read_extension_global`, `console_messages` (also after it closed) |
| `options:<ext>` | The tab of one of the profile's spaces showing the options page (`existingOptionsPageTab`); `unsupported_context` without an options page | The same; input needs it shown in a window (`open_extension_context` with `window_id`) |
| `worker:<ext>` | The background service worker, or background page | `call_extension_api`, `read_extension_global`, `console_messages`, `wait_for` with `worker_started`; every page tool is `unsupported_context` |
| `extension:<ext>` | Every context of the extension | `console_messages` only |
| `sidepanel:<ext>` | No side panel on `main` (only the epic branch has them) | `unsupported_context` everywhere |

## The popup

`AutomationExtensionPopups` opens it with an `ExtensionPopoverController`
built for the profile and the window's active tab, anchored where a click
on the extension's button would anchor it (its pinned button in the
address bar, else the address bar, else the content's top right when the
sidebar is hidden), and `show` records the user gesture a click records, so
`activeTab` works. An extension whose action has no popup for the tab is
`unsupported_context`: `show` would fire `action.onClicked` instead.
`show` reloads the popup and presents the popover once the page has loaded
(or after 0.5 s); `wait_for load` covers that. The popover is in its own
window, a child of the browser window, so input goes there and results name
the browser window. All of it works with Detour in the background (checked
at runtime: popups opened, clicked, typed into and captured while another
app was active). A popup a person opened from the toolbar is not tracked
and not reachable.

## The worker channel

Nothing public evaluates script in an extension's service worker, and an
MV3 worker's CSP forbids `eval` and `new Function`, so `worker:` takes
commands, not code: call the function at a path with JSON arguments, read
the value at a path, or ping.[^channel] The polyfill bundle's last module
(background contexts only) parks a request, `automation.awaitCommand`, as
`notifications.awaitEvent` does ([polyfill layer](../extensions/polyfill-layer.md)).
The endpoint answers it with a command; the worker acknowledges it at once
(`automation.ack`), parks again, runs it, and sends the result
(`automation.result`). So a call that never settles holds up nothing else,
and several run side by side.

Why this channel and not another:

- A `runtime.onMessage` listener would be seen by the extension's own
  listeners. A Proxy on, or a replacement of, `chrome`/`browser` is never
  done ([never replace the globals](../decisions/never-replace-chrome-globals.md)).
- A native port would push without parking, but opening and closing ports
  changes how long WebKit keeps the background alive and can make it forget
  another port (TASK-141), which would skew a compatibility run. A pending
  native-message reply is not activity and touches no port bookkeeping
  ([service worker unload rules](../platform/service-worker-unload-rules.md)).
- A hidden extension page relaying through `chrome.*` runs in a page, not
  in the worker, and cannot read the worker's globals.

What follows from parking:

- **A park keeps nothing alive, and a dead one is silent.** WebKit unloads
  an idle background after about 30 s and says nothing; a reply to the dead
  worker's park goes nowhere. A delivered command must be acknowledged
  within 1.5 s; if it is not, the background is started
  (`loadBackgroundContent`) and the command goes to the new worker's park,
  up to three times. A call to an unloaded worker therefore takes about
  1.7 s (measured at runtime: the worker's polyfill lines appeared again in
  its console). With no park at all the background is started at once.
- **A worker that restarted mid-command** loses the command, which is not
  run twice: the call answers `worker_not_running`. A late acknowledgement
  of a command already sent again is honoured, and the worker skips an id it
  has seen.
- **The channel is open while the endpoint is on.** `AutomationController`
  opens it in the same main-actor turn as the launch's start, before any
  worker's first message is handled, so every background parks in a test
  run. A worker that started while automation was off was answered `stop`
  and parks again only at its next start: turning the endpoint on in
  Settings leaves running workers unreachable until they cycle
  (`worker_not_running`, whose message says so). Stopping the endpoint
  stops every park and fails what waits.
- **Who may park.** Only the verified extension's background context
  (`senderIsBackgroundContext`), never in the Private profile; a page that
  tries is refused (tested from an options page). The extension's own code
  in its worker could still call the request itself and answer its own
  commands; a test of that extension accepts that. The channel's requests
  do not count as the extension's background activity (which delays
  updates, TASK-123).
- **Cost when automation is off:** one `automation.awaitCommand` round trip
  per worker start, answered `stop`.
- **What a call can do:** `call` invokes the function on the object holding
  it (`this` is `chrome.storage.local` for `chrome.storage.local.get`),
  promise form only (a callback-only API gets no callback); `get` does not
  await. Results go through the same serialiser as `evaluate_js`.
  `worker_not_running` when no live background took the command in time,
  `timeout` when it took it and did not finish.

## The console of extension contexts

`console_messages` on an extension context reads what the polyfill's
[console bridge](../extensions/console-bridge.md) forwards, kept by
`AutomationExtensionConsole` per extension and profile while the endpoint is
on (ring of 1000, one `seq` for all the extension's contexts, the same entry
shape as a tab's plus `context_kind` and `context`). The bridge now sends
the console method (`consoleLevel`: `log` still reaches os_log as info), an
`origin` (`uncaught`, `unhandledrejection`) and an error's stack and
location. The kind comes from the sender: the native-message bridge or the
background page's frame is `worker`, a tracked popup web view `popup`, a web
view showing the options page `options`, anything else `page`. It is
recorded before the os_log path's native cap, but the bridge's in-page
limiter still applies: past a burst of 50 messages, about 20 a second, with
repeats folded into "(repeated N times)"; `console.debug` is not bridged,
and content scripts have no bridge. The options page's tab is not captured
by page capture (it is built from the extension's configuration), so read
it as `options:<ext>`, not `tab:<id>`. Recording starts in the same
main-actor turn as the channel opens, before the listener is ready (since
TASK-228.2 part 2; before, it started once listening), so a worker that
starts at launch keeps its start-up errors too.

## Load errors

`ExtensionErrorLog` keeps, per extension and this session, every error
WebKit reported when reading the installed files (at launch or after an
install), when the controller refused a context, and every context error it
posted (`errorsDidUpdateNotification`, a background that failed to load
among them), deduplicated with a count and cut at 50; forgotten on
uninstall. Before, all of these were only logged. A recovery reload clears
`context.errors`, so the copy is what tells a run that a worker failed at
all. `WKWebExtension.errors` (manifest warnings) is read live.

# The compatibility report

`extension_compat_report {extension, profile_id?, probe?, timeout_ms?}`
answers what an extension tried to use that Detour does not have, for a
suite that runs many third-party extensions and diffs each run against a
baseline (TASK-228.2 part 2).[^compat-report] It never wraps or replaces
`chrome` or `browser` ([never replace the globals](../decisions/never-replace-chrome-globals.md)),
so nothing an extension sees changes shape; the five parts are built from
what can be read without that.

## 1. References, checked at runtime

A static scan (`AutomationCompatReport.scan`, off the main thread) reads
the installed copy's `.js` and `.mjs` files (Detour's own `_detour_*` files
and `_metadata/` left out; at most 3000 scripts, 16 MB a file, 160 MB in
all, in path order, `scan.truncated`/`skipped` say what a bound cut) and
counts each `chrome.X.Y` and `browser.X.Y`, also with `?.`, a bracket with
a string (`chrome['scripting']`) or `globalThis.`/`window.`/`self.` before
it. Only the first two segments are kept: `chrome.storage.local.get` is
the api `storage.local`, `chrome.sidePanel` alone the api `sidePanel`. Only
namespaces in Chrome's published list (plus Firefox's and Safari's) count,
which keeps out `chrome.google.com` in a URL and a library's own
`browser.version`. Not followed: aliases (`const api = chrome.storage`),
computed names, and minified code that renamed the global.

Each file gets roles from the installed manifest and the pages: the
worker, `background.scripts` and a background page's scripts are
`background`, manifest content scripts `content_script`, any HTML page's
`<script src>` `page`, followed through `importScripts`, static and dynamic
`import` and `export … from` (relative specifiers only); a file reached from
none of them is `other`. A member missing in the worker matters less when
only a content script names it.

Every referenced api is then checked in two live contexts with the
runner's `probe` command (present, `typeof`, and whether the function, or
an event's `addListener`, is WebKit's own by the `[native code]` test;
for a stub that is an object, such as `storage.managed`, the test reads its
first counted function). Each reference is probed under every global the
extension uses for it, since `chrome` and `browser` can be different objects
and the polyfill fills in `chrome` only:

- **worker**: through the channel, which starts the worker if needed.
  `worker.started` false with `start_error` (`worker_not_running`,
  `timeout`) when it did not answer; its column is then `not_checked`.
- **page**: a probe page of the report's own, `_detour_probe.html`, an
  empty document written into the installed copy (WebKit reads an
  extension's resources from disk when they are requested, so a file
  written after load is served) and loaded in a hidden web view from the
  context's configuration, so the polyfill runs in it and none of the
  extension's scripts do; closed once it answered. Its console and stub
  calls are not the extension's (`probe` context kind, never recorded).
  Content scripts' surface is not checked: nothing reaches their world.

Status per context: `available`, `missing` (the namespace or the member is
not there; a member present with the value undefined, like
`runtime.lastError`, counts as there), `stubbed` (in the stub registry and
not WebKit's own function), `not_checked`.

## 2. Stubs and their calls

`ExtensionPolyfillStubs` is the one registry of the polyfill's stand-ins
(read from `ExtensionAPIPolyfill`, November 2026):[^stubs] `privacy.services`
(settings read false, set does nothing), `privacy.network`/`websites`
(empty), every `webRequest` event and `handlerBehaviorChanged`,
`action.getUserSettings` (always on the toolbar), `storage.managed` (no
policy source), `sessions.getRecentlyClosed`/`getDevices` (always `[]`) and
`sessions.onChanged`, `idle.onStateChanged`, `notifications.onButtonClicked`,
`history.onVisited`/`onVisitRemoved` (TASK-146), `history.getVisits` and its
no-op writers, and the four `management` events. `notifications.onClicked`
and `onClosed` are not stubs (delivered since TASK-247). A module that
starts delivering an event leaves the list in the same change.

The polyfill's counting module (`countingModuleJS`, after every module that
defines a stub, before the automation channel) wraps each registry function
that is the polyfill's own, on the polyfill's objects or a native wrapper
the polyfill already patched and rooted (`chrome.action`), keeping `this`,
the arguments, the result and the `_detourPolyfill` marker. Calls of one
task go in one batch, `automation.stubCalls`, from any extension context
(not content scripts, which run no bundle). The handler keeps registry
paths only, per extension, profile, path and context kind
(`AutomationExtensionStubCalls`), and answers `stop` while automation is
off or in the Private profile: the context then stops sending for its
lifetime, so with the endpoint off the cost is one request per context
that calls a stub. The request is an `automation.` one and is not the
worker's activity. Counts start in the same turn as the channel opens, so
a worker's start-up calls count; the report waits 300 ms after its probes
for the batch the probe's own worker start sent.

## 3. Runtime errors

The extension's recorded console (every context, uncaught errors and
rejections included) is searched for JavaScriptCore's wording of a missing
API: "undefined is not an object (evaluating 'chrome.sidePanel.open')",
"chrome.x.y is not a function. (In 'chrome.x.y()', 'chrome.x.y' is
undefined)", "Can't find variable: chrome". Each is reported once per api,
expression and error name, with the contexts it came from and one message
line (from the error's name on, origins normalised); repeats are counted in
`run`. A chain that is a prefix of a longer one in the same text is folded
in; Detour's own `[Detour polyfill]` warnings and unchecked lastError lines
are skipped; a minified alias (`e.sidePanel.open`) names no global and is
not attributed. Content scripts' errors never reach the console bridge.

## 4. The manifest

Top-level keys (`manifest.keys`, only those not plainly supported, and
`supported_keys`), from what WebKit's parser reads (`WebExtension.cpp` on
main, read 2026-11-14)[^webkit-manifest] and what Detour reads itself (`key`,
`update_url`): `unsupported` (WebKit parses `commands`, but Detour never calls
`performCommand(for:)`, so shortcuts do not run; `chrome_url_overrides`;
`side_panel` on this build; `incognito`, which Detour's per-profile switch
replaces; `omnibox` and the other Chrome-only keys), `ignored`
(informational: `minimum_chrome_version`, `author`, …), `unverified`
(`devtools_page`, `icon_variants`) and `unknown`. API permissions are
`supported` when WebKit kept them (its live `requestedPermissions` and
`optionalPermissions`, which drop names it does not support, so this
follows the installed WebKit), `polyfill` (history, management,
notifications, idle, fontSettings, sessions, search, offscreen, favicon),
`stubbed` (privacy; webRequest, whose listeners never fire although WebKit
keeps the name), `ignored` (`background`) or `unsupported`. Host patterns
WebKit refuses are listed, and `WKWebExtension.errors` as `warnings`.

## 5. The worker

`background` (service_worker, service_worker_module, scripts, page, none),
whether it answered the probe, whether a `backgroundContentFailedToLoad` was
recorded this session (`failed_to_load`), whether
`Profile.recoverFromBackgroundLoadFailure` reloaded it
(`recovery_attempted`; `ExtensionErrorLog.recordRecovery` counts them), and
its load errors (normalised, once each; counts in `run`).

## Diffing against a baseline

Everything outside the report's `run` object is stable over the same files:
arrays sorted, no timestamps, no profile ids, extension origins written
`webkit-extension://<extension id>` (a context's base URL is new at every
load), paths relative to the extension's root and the installed folder
removed from messages. `run` holds `profile_id`, the stub call counts, error
and load-error repeat counts, recovery attempts, and how many console
records were read. `summary` gathers the short lists worth diffing
first (`missing_in_worker`, `missing_in_page`, `stubbed_referenced`,
`stubs_called`, `runtime_error_apis`, `unsupported_manifest_keys`,
`unsupported_permissions`, `worker_started`). Whether a stub was called and
which errors appear depend on the scenario, not on timing, as long as the
scenario drives the same code.

The other tools have a `stable: true` form for the same purpose:
`list_extensions` drops profile ids (profiles sorted by name),
`worker_parked`, `open_contexts` and repeat counts, lists load errors once
each, sorted, and normalises origins in messages; `console_messages` drops
each entry's `seq` and `timestamp` and normalises origins (an extension
context's records with its own id; a tab's with the id of the loaded
context that has that origin, else `unknown`). Console entries keep their
order of arrival, which between two contexts can change from run to run,
so a baseline is better kept as a sorted set of lines (the playbook's
script does that). `next_seq`, `dropped` and `capturing` are cursor state,
never compared.

[Extension compatibility run](../playbooks/extension-compat-run.md) is the
end-to-end playbook, with `docs/harness/task2282-compat-run.py`.

# Who is connected, and stopping them

`AutomationController` runs the endpoint (off, starting, listening, failed;
a generation counter makes a start still in flight harmless after a stop)
and posts `didChangeNotification` for the UI:[^controller]

- **The indicator.** While a client is connected, every browser window
  (Private ones too) shows an orange capsule at the bottom right of its
  content naming the client ("Claude Code + 1"), whether the sidebar is shown
  or not. The sidebar's title row had no room, and a sidebar placement would
  have needed a second home when it is hidden. Its menu lists Disconnect for
  each client, Allow … Again for disconnected ones, Turn Off Automation and
  Automation Settings…. It lives in `contentContainerView` above the page
  (pages go in below the drag handle), so `removeContentViews()` must skip it,
  or the first tab switch removes it.
- **Disconnect** ends the session and blocks the client's name: a
  Streamable HTTP client whose session ends simply starts a new one, so
  ending the session alone does nothing. The blocked client's `initialize`
  gets 403 until the user allows it again or turns automation off and on.
  It is a "please stop", not a revocation: the name is the client's own, so
  a client could come back under another (its menu item says so; Turn Off
  stops every client). Kept that way by user decision (2026-11-14); real
  per-client revocation belongs to TASK-228's remaining authorisation work,
  an approval prompt that gives each client its own token.
- **Idle sessions end** after 10 minutes without a request, since most
  clients never send DELETE. A client that comes back gets 404 and starts a
  new session, as the transport expects.
- **Reset Token** (Settings) writes a new token, swaps it into the running
  endpoint and ends every session.

# Setting up a client

Settings > General > Automation copies what a client needs:

- **The bundled helper**, `Detour.app/Contents/MacOS/detour-mcp`, for any
  client that launches a command (Claude Desktop, Cursor, Claude Code). It
  relays MCP's stdio transport, one JSON-RPC message per line, to the
  endpoint, finding the URL and token in `mcp-endpoint.json` itself (with
  `DETOUR_DATA_DIR` for a test run), so the client's configuration holds no
  secret. When the session ended, the token was reset or Detour restarted
  on another port, it reads the file again, replays the client's
  `initialize` and retries once, but after a failed connection only when it
  was refused: a timed-out or dropped request may already have acted, so it
  gets an error instead of running twice. With Detour not running, each request gets
  a JSON-RPC error saying so. At the end of stdin it ends its session, so the
  indicator goes away at once. Signed by `sign-app.sh` on its own, without
  Detour's entitlements.
  - Claude Code: `claude mcp add detour -- "/Applications/Detour.app/Contents/MacOS/detour-mcp"`
  - Other clients: `{"mcpServers":{"detour":{"command":"…/detour-mcp"}}}`
- **The URL and the token**, for clients that speak HTTP with a header.

# A worked check

`docs/harness/task324-endpoint-checks.py` re-runs TASK-324's hands-on
download checks with no manual steps: it launches the given build with its
own data directory, serves a fixture, and checks each download's flight from
the `Download flight from x,y to x,y; catcher …; motion …` log line
(category `downloads`, added for this): Download Linked File from the right
click, a download in a split pane from the click in the right pane, with the
sidebar hidden to the window's corner with no catcher, and with Reduce Motion
(the Debug override) no flight. All passed on 2026-11-14 with Detour in the
background; it cleans up its downloads, data directory, defaults keys, its
own preferences domain (`com.detourbrowser.mac.<data dir>`) and the WebKit
stores recorded in its database (under `~/Library/WebKit`, outside the data
directory, so deleting the directory alone orphans them).

# The scripting client

`scripts/detour-mcp` (Python 3, standard library only) reads
`mcp-endpoint.json` from `$DETOUR_DATA_DIR` (or `--data-dir`), runs the
handshake, calls, and deletes its session.[^client] `tools` lists the
tools; `call TOOL key=value …` prints the structured result; `batch` runs
JSON lines in one session. Exit status 0 is success, 1 means the tool
reported an error, 2 a transport or protocol failure (including a stale
endpoint file whose process is gone).

```bash
DETOUR_DATA_DIR=DetourVerify DETOUR_MCP=1 "$APP/Contents/MacOS/Detour" &
export DETOUR_DATA_DIR=DetourVerify
scripts/detour-mcp call list_windows
scripts/detour-mcp call open_url window_id=1 url=https://example.com
scripts/detour-mcp call run_menu_item window_id=1 'path=["File","New Tab"]'
```

Claude Code connects directly:
`claude mcp add --transport http detour <url> --header "Authorization: Bearer <token>"`.

# Traps

- **Menu-bar titles.** A menu-bar item's own title is AppKit's placeholder
  `NSMenuItem`; the bar shows its submenu's title, and the application menu's
  submenu has none (it is the app's name). Paths match on those.
- **An item with a submenu has an action.** AppKit gives it
  `submenuAction:`, which only its menu's own tracking may send; sending it
  raised `-[NSMenu submenuAction:]: unrecognized selector`. Such items are
  refused before their action is looked at.
- **Commands can finish later than they return.** Next Space animates the
  sidebar to the space and switches the window when the animation ends, so a
  script polls the state after `run_menu_item` rather than reading it at
  once.
- **A modal action and the main queue.** A command that runs a modal alert
  (Quit's confirmation) does not return until the alert closes. Sent from a
  main-queue block (`DispatchQueue.main.async`, or a main-actor job, which is
  one), it froze the whole endpoint: GCD does not drain the main queue inside
  one of its own blocks, so neither the wait's timer nor any other main-actor
  job ran. The command is sent from `RunLoop.main.perform` instead. The
  modal's nested run loop then drains the main queue, and `run_menu_item`
  answers `completed: false` after 1.5 s while other calls keep working. This
  was checked in the running app with Cmd+Q.
- **A direct text insert overtakes queued keys.** WebKit holds key events
  until the page has handled the previous ones, and
  `insertText(_:)` does not wait: "Ab!é" arrived as "Abé!". A character
  with no US key is sent as a key press carrying it (key code 0xFF, which
  the page reports as `code` "Unidentified"), so it stays in order. Also,
  WKWebView's `NSTextInputClient` conformance is not one a Swift `as?`
  cast sees.
- **Hit tests behind an open menu are wrong.** With a context menu open, a
  hit test in the window found `NSMenuHighlightView`, and Escape sent to the
  window's first responder does not reach a tracking menu. Input tools close
  open menus first; `close_menu` closes one on its own.
- **The test host moves posted events.** A native control's tracking loop
  reads the queued mouse-up, which in the XCTest host comes back with its
  location moved, so a button's action never fires there.
  `AutomationInputTests` checks that the view gets the mouse-down; the
  action is checked in the running app.
- **In-app captures cannot draw window-server materials.** `cacheDisplay`
  draws the content view (web content included, even with Detour in the
  background) but leaves the sidebar blank, so the sidebar is drawn again
  from its layer. Neither path reproduces the sidebar's glass
  (`NSGlassEffectView` or `NSVisualEffectView`, composited by the window
  server with backdrop filters and blend modes): in dark mode the captured
  sidebar comes out light while the real one is dark (compared with
  `screencapture -l` of the same window), and glass panels drawn over the
  content (the command palette, find bar, toasts, hover cards) come out as
  blank boxes. Redrawing the views stacked above the sidebar from their
  layers was tried and made it worse: the palette's full-window view painted
  the whole sidebar white. `source: "screen"` (ScreenCaptureKit,
  `SCContentFilter(desktopIndependentWindow:)`, shadow ignored) gives the
  exact picture, also with Detour in the background; a test run launched
  from a terminal that has the Screen Recording grant inherits it.
- **A bitmap context is in pixels.** `NSGraphicsContext(bitmapImageRep:)`
  does not scale to the rep's `size`; drawing a 1x capture into a 2x rep
  without a CTM scale filled only its bottom-left quarter.
- **Local event monitors do not see the endpoint's input.** AppKit runs
  `NSEvent.addLocalMonitorForEvents` handlers only for events going through
  `NSApp.sendEvent`, and the input tools hand events to views directly (that
  is what makes them work in the background). The window's web-click monitor,
  which places a download's flight (TASK-324), saw none of them, so a
  download started through the endpoint flew from the middle of the page.
  The tools now post `AutomationInput.didDeliverEventNotification` (object:
  the window, the event under `eventKey`) before each mouse-down and
  key-down, and that monitor listens to it too. Control-Tab's switcher,
  sidebar swipes and the hover card do not yet.
- **A tab never shown has no size.** A tab opened in the background has a
  web view with a zero frame until a window first hosts it. Its page loads
  and runs scripts, and `read_page` text works, but its viewport is 0 × 0, so
  no element is visible, and WebKit's snapshot of it has no bitmap:
  `screenshot` answers `not_displayed` ("select it once"). A tab shown once
  keeps its frame after the window moves on, and its screenshot works with
  no window (checked in tests and at runtime). Giving such a web view a
  frame on demand was not done: it would resize and relayout a page nobody
  asked to change.
- **A property named `format`** trips `MCPServerTests`' flat-schema walk,
  which refuses JSON Schema keywords anywhere, property names included; most
  validators would accept it, but `read_page` calls it `mode`.
- **A content script needs site access the manifest does not grant.**
  hello-world declares `content_scripts` matching `<all_urls>` and no
  `host_permissions`; WebKit does not count content-script matches as
  requested patterns, so its content script ran on no page, and
  `set_extension_permission` for `<all_urls>` was saved but inert (its
  warning said so). An extension with matching `host_permissions` (API
  Explorer) is fine.
- **A CRX that uses native messaging reaches the real host.** Installing the
  store's 1Password CRX started its worker at once, and it connected to the
  installed 1Password app's browser helper (which refused the unsigned
  Debug build and exited). Point `DETOUR_NATIVE_MESSAGING_HOSTS_DIR` (Debug
  builds) at an empty folder for such runs; with it the same install
  connected to nothing.
- **A popup taller than its popover does not scroll from script.** WebKit
  lays the popup out at its content size inside the 600-point popover;
  `scrollIntoView`, `scrollTo` and `scrollTop` left `scrollY` at 0 (API
  Explorer, 3617 points tall), so the input tools answer
  `element_not_visible` for anything below 600 points. Whether a person's
  scroll wheel scrolls it was not checked. Use `call_extension_api` or
  `evaluate_js` for such elements.
- **A popup's profile must outlive the test.** Releasing a profile whose
  controller hosted a popup traps in `WKProcessPool` dealloc, in whichever
  suite runs next; `AutomationExtensionTests` keeps its profiles alive
  ([WebKit test host traps](../platform/webkit-test-host-traps.md)).
- **A command that never settles** (a promise left pending) used to hold the
  worker's only park, so every later call answered `worker_not_running`;
  the result now travels in its own request and the worker parks again at
  once.
- **SIGTERM runs no quit path.** The SIGTERM source ends native hosts and
  re-raises the signal, so `applicationWillTerminate` never runs. It removes
  the endpoint file too, and only if the file's `pid` is this process. A
  crash still leaves the file behind, which is why the client checks the
  `pid`.

# Tests

`AutomationHTTPTests` (framing, authorisation, gate, credential files,
JSON), `MCPServerTests` (negotiation, sessions, routing, result and error
shapes, schema flatness, stable codes, context ids), `AutomationToolsTests`
(the tools against real windows on `TabStore.shared`, including a Private
window, a dormant pinned entry, another space, validation through the
window, and a slow command), `AutomationEndpointTests` (refusals, a whole
session and a split, kept-alive request over a real socket),
`AutomationInputTests` (trusted clicks by selector, by page and by window
point, modifier and double clicks, typing in order with US codes, Return,
a page's context menu listed and closed, a native view's mouse-down and a
native context menu chosen from, and the input errors),
`AutomationCaptureTests` (window, sidebar and page PNGs as image content
and on disk, scale 2, the page's own colours from WebKit's snapshot, light
and dark, the Debug overrides and that they exist only in Debug, and the
errors), `AutomationPageTests` (TASK-228.4: evaluate_js in both worlds, awaited
promises, converted values, thrown errors, syntax errors and timeouts;
read_page text, html, summary and elements whose selectors click takes;
console records from the main frame and a subframe with cursors and level
filters; network records of the navigation, resources, a 404 fetch, an XHR
and a refused fetch; wait_for's four conditions and timeouts; wake_tab;
every page tool on a tab no window shows; unknown, closed, sleeping and
Private tabs; capture off until started, reaching an already loaded page
once, removed on stop, never in a Private profile; the ring buffer),
`AutomationExtensionTests` (TASK-228.2: the management tools refused
outside a test run; install from a folder, list and address by id or name,
ambiguity, a reinstall keeping the id; no manifest, a bad manifest, a bad
CRX, a relative path, the Private and an unknown profile refused; the worker
answering calls, reads and its console, a never-settling call timing out and
not blocking the next, a closed channel; the popup driven with
evaluate_js, read_page, call_extension_api, click, console and screenshot,
then closed; the options page in the background and in a window, and a page
refused the channel; turning on and off per profile and globally, permission
decisions with their warnings, uninstall; side panels, unknown extensions and
two profiles), `AutomationExtensionChannelTests` (the channel by hand:
delivery and results, side-by-side commands, a wake with no park, a dead
park's command sent to the next start, supersession, a restart mid-command,
another extension unable to answer, unload and stop),
`AutomationCompatReportTests` (TASK-228.2 part 2: the scan's reference forms,
imports, roles, Detour files, bounds and order; manifest keys and permissions;
JavaScriptCore error messages; origin normalising; the registry; a report for
a real extension with references checked in the worker and the probe page, a
stub called from the worker and from the popup, TypeErrors from a caught and an
uncaught error, unsupported keys and permissions, two reports equal outside
`run`, `probe: false`; an unknown and a turned-off extension, a closed
channel; the counts' handler taking registry paths only and answering stop;
`stable` list and console), `AutomationControllerTests` (on and off with the endpoint file, a
stop during a start, Reset Token, disconnect and allow, idle sessions, the
indicator's text and its place above the page through tab switches) and
`AutomationHelperTests` (the built helper relaying a session, starting a new
one, its error without Detour, ending its session at the end of stdin, and
the setup strings Settings copies).[^tests]

# Related

- [In-process UI automation](../playbooks/in-process-ui-automation.md): the
  techniques the input tools of the next phase build on.
- [Runtime verification](../playbooks/runtime-verification.md): what the
  endpoint is meant to replace for `/verify`.
- [Extension compatibility run](../playbooks/extension-compat-run.md): the
  extension tools end to end, with a baseline diff.
- [Link Routes](./link-routing.md): what `open_url` applies to a new tab.

[^automation-dir]: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
[^client]: scripts/detour-mcp (stdlib Python client)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests, AutomationInputTests, AutomationCaptureTests, AutomationControllerTests, AutomationHelperTests, AutomationExtensionTests, AutomationExtensionChannelTests
[^compat-report]: AutomationTools+CompatReport.swift and AutomationCompatReport.swift (the report, the probe page, the scan)
[^stubs]: ExtensionPolyfillStubs.swift (the stub registry and the counting module)
[^webkit-manifest]: WebKit, WebExtension.cpp (the manifest keys it reads, supportedPermissions)
[^input]: Detour/Automation/AutomationInput.swift
[^controller]: Detour/Automation/AutomationController.swift
[^page]: AutomationPageCapture.swift and AutomationPage.swift (capture script, buffers, page scripts)
[^task-228-2]: Automation: extension testing tools on the MCP endpoint
[^extension-tools]: AutomationTools+Extensions.swift (addressing, the extension tools)
[^channel]: AutomationExtensionChannel.swift (the channel into an extension's background, the command runner)
