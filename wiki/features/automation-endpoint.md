---
type: Feature
title: Automation endpoint (MCP)
description: "Detour's local MCP server for agents and scripts (TASK-228.1, TASK-228.4, TASK-228.2, TASK-228.3, TASK-228.5): how it is turned on, who may connect (Host, Origin, a test run's shared token, per-client tokens the user approves in Detour's own prompt, and the rejected alternatives), the Private-window opt-in, the HTTP and MCP layers, the tools and their stable error codes, how clicks, keys and menus are delivered inside the app without activating it, screenshots and what they cannot draw, the page tools (JavaScript, page text and elements, console and network capture, waits, sleeping and unselected tabs) and their limits, the extension tools (install, list, enable, permissions, popup, options and worker contexts, the channel into a service worker, extension console) and their limits, the per-extension compatibility report (static scan of chrome.* references checked in the live worker and a probe page, the stub registry and its call counts, API-naming runtime errors, unsupported manifest keys and permissions, worker failures) and the stable output for diffing against a baseline, capture staging (a demo world seeded from a fixture file and its format, displays and exact window placement read back from the window server, paced typing, Debug UI on demand, the test-run guard on Arc's folder, who takes the focus), the connected-agent indicator and disconnecting (revoking an approved client), the bundled stdio helper and where it keeps each client's token, the scripts/detour-mcp client, and the traps met building it (menu-bar titles, animated commands, modal actions and the main queue, key ordering, window-server materials, SIGTERM, never-shown tabs, Resource Timing status, inert host rows, real native hosts, a popup's profile in the test host, a window's open animation, focus during captures)."
tags: [automation, mcp, testing, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T12:00:00Z }
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
  - id: task-228-3
    resource: backlog:TASK-228.3
    title: "Automation: capture tooling on the MCP endpoint"
  - id: staging
    resource: ../../Detour/Automation/AutomationTools+Staging.swift
    title: AutomationTools+Staging.swift and AutomationWorldFixture.swift (seed_world, displays, placement, open_ui)
  - id: capture-kit
    resource: ../../docs/capture/README.md
    title: docs/capture (the website capture kit, capture.py, demo-world.json)
  - id: task-228-5
    resource: backlog:TASK-228.5
    title: "Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint"
  - id: approvals
    resource: ../../Detour/Automation/AutomationApprovals.swift
    title: AutomationApprovals.swift, AutomationClients.swift and AutomationApprovalPanel.swift (the authorize route, the client store, the prompt)
  - id: approval-tests
    resource: ../../DetourTests/AutomationClientApprovalTests.swift
    title: AutomationClientApprovalTests and AutomationPrivateAccessTests
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
| `DETOUR_MCP=1` for a test run | an ephemeral port, or `DETOUR_MCP_PORT` | Only with `DETOUR_DATA_DIR` set, not `Detour` in any spelling, and inside Application Support (a name with `..` that climbs out, such as `../Application Support/Detour`, is refused): a scripted run can never open the user's real profile. A refused request is logged, never silent. |
| The XCTest host | never | Tests start their own endpoint. |

When listening, the data directory holds `mcp-endpoint.json` (0600: `url`,
`port`, `pid`, `test_run`, and in a test run only `token`), written once the
listener is ready and removed at quit, and on SIGTERM (see Traps). The other
files depend on the mode (TASK-228.5):[^task-228-5]

| File (in the data directory) | Mode | What it holds |
|---|---|---|
| `mcp-token` (0600) | test run | The shared bearer token, kept across launches. The user's endpoint deletes a leftover one at start and never creates one. |
| `mcp-clients.json` (0600) | the user's setting | The approved clients: `client_id`, `name`, `title`, `version`, `created`, `last_used`, `token_sha256`. Never a token. |
| `mcp-clients/<SHA-256 of the client's name>.token` (0600, folder 0700) | the user's setting | Written by the bundled helper: the token Detour gave that client. |

The published URL is `http://127.0.0.1:<port>/mcp`, never `localhost`: Node
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
3. `Authorization: Bearer <token>` (401). Which tokens count depends on the
   mode (`AutomationAuthorization.Credentials`):
   - a test run takes its one shared token, compared in constant time;
   - the user's setting takes only approved clients' tokens: the
     presented token's SHA-256 is compared in constant time with every
     record's (`AutomationClientStore.client(presenting:)`), and the shared
     token is never accepted. Its one route without a token is
     `POST /mcp/authorize` (exactly that path), where a client asks for
     one (see "Approving a client").

The 401 carries `WWW-Authenticate: Bearer realm="Detour"` and no OAuth
`resource_metadata`, so an OAuth-only client fails at once instead of
starting a discovery flow Detour does not offer. Threat model: a token
stops web pages and local programs that cannot read the user's files
(sandboxed apps, other accounts); malware running as the user can read the
token files, and could drive the browser in other ways anyway. The
approved client rides on the request into `MCPServer` as a field the
endpoint sets after the match (`AutomationHTTP.Request.client`), never as
anything the client sent.

Before any token is shown, a connection costs little: the endpoint holds
at most 64 and closes one that has not sent an authorised request within
10 s, so a local process without a token cannot exhaust Detour's file
descriptors (which SQLite and WebKit's IPC need). An authorize request
waiting for the user's answer is spared by that deadline but is never
counted as authorised; at most 8 are held at once, and the answer always
closes the connection (see below).

Clients must not leak a token: `scripts/detour-mcp` and the helper bypass
HTTP proxies (urllib sent the `Authorization` header to a configured proxy
even for 127.0.0.1), and Copy Token (test runs only) marks the pasteboard
item transient, concealed and local-only, so clipboard managers and
Universal Clipboard skip it.

## Approving a client

With the user's setting, every client goes through Detour's own Allow /
Deny prompt once, and gets a token of its own (user decisions,
2026-11-13).[^task-228-5][^approvals]

1. The bundled helper, on the client's `initialize`, looks for the token it
   saved under the client's `clientInfo.name`. With none it sends
   `POST /mcp/authorize` with `{client_name, client_title?, client_version?}`
   and no bearer. The endpoint checks the head before reading the body:
   POST, `application/json`, a `Content-Length` of at most 4 KB, no chunked
   body (405, 415, 411, 413). Names are cleaned before anything shows or
   keys on them: control, format (bidirectional overrides, zero-width),
   separator, private-use and unassigned characters removed, white space
   collapsed, 64 characters at most.
2. Detour shows `AutomationApprovalPanel`: '"<name>" wants to control
   Detour', what that allows, and that the name is the client's own claim
   (with the raw name and version when a title was given). A non-activating
   floating panel on every Space, ordered front without activating Detour,
   with one Dock bounce (`requestUserAttention(.informationalRequest)`).
   Allow is not the default button, Escape denies, and both buttons are
   enabled only 1 s after the panel appears, so a click or Return meant for
   the app in front cannot approve anything. No automation tool reaches the
   panel: input goes only to browser windows, and `set_window_frame`
   refuses it, so an approved agent cannot approve another.
3. The HTTP request is held until the answer (`AutomationApprovals`):
   Allow stores a record and answers 200 `{token, client_id, name}`; Deny
   answers 403; no answer within 5 minutes is a denial. One prompt per
   name at a time: a second request for that name waits (one waiter at most;
   a third is 429), then gets a prompt of its own, never the first one's
   answer, so a second process cannot ride on a prompt the user expected.
   At most 3 names are asked about at once (429 beyond). A name denied or
   unanswered in the last 10 minutes is refused without a prompt (403 with
   `Retry-After`). A client that closes its connection withdraws its
   request and the panel closes; turning automation off closes every panel
   and answers every held request 503. An Allow whose answer could not be
   sent (the client went away) is revoked at once, so no approval exists
   whose token nobody holds.
4. Every later request is checked on the endpoint's queue, and again on
   the main actor (`MCPServer.isClientApproved`), so a request authorised
   just before a revocation is refused all the same. Sessions are bound to
   their client: another client's token (or the shared one) with that
   session id gets 404. The session and the indicator use the approved
   name, not what `clientInfo` says later. `last_used` is kept in memory
   on every request and written at most once a minute per client; every
   write serialises the current records under one lock, so a late write
   cannot bring back a revoked client. A malformed `mcp-clients.json`
   approves nobody.

What the rate limits do not stop: a local program can vary the name it
asks under, so each denial is followed by a new prompt (at most three at
a time); the user can turn automation off. The name is self-reported, so
the prompt says so.

Rejected (recorded with the user's decisions, 2026-11-13/14):

- **Local OAuth** (metadata discovery, dynamic client registration, PKCE,
  an `/authorize` page redirecting back): a client configured with a URL
  breaks whenever the per-launch port changes, so the helper is needed
  anyway, and it adds code and attack surface.
- **The Keychain for the helper's token**: ad-hoc-signed Debug helpers
  change their keychain ACL identity at every build, so every build would
  prompt, and test runs would too. The 0600 file in a 0700 folder has the
  threat model the shared token already had.
- **One shared token for the user's setting too**: Disconnect could only
  block a name the client chose (TASK-228.1's "please stop"); revocation
  needs a token per client.
- **Giving every waiter the first prompt's answer**: one Allow would hand
  tokens to processes the user never saw.
- **An app-modal alert for the prompt**: run from a main-queue block it
  froze the whole endpoint (Traps), and in an app that is not active it
  goes unseen.

## Private windows

Private windows, spaces and tabs are reachable only while the user turns on
"Allow agents to use Private windows" (Settings > General > Automation;
`AutomationAllowPrivate` in the data directory's defaults suite, off by
default; a test run turns it on only through the same key, never through a
tool).[^task-228-5] It is read at every check, never cached: the tools
through `AutomationEnvironment.allowsPrivate` (the controller points it at
its defaults), page capture and the extension channel, console and stub
counts through `AutomationPrivateAccess.isAllowed`. Turning it off refuses
again from the next call.

- **Off**: Private windows and spaces are left out of `list_windows`
  (`hidden_private_windows` counts them) and `list_spaces`, and refused by
  id (`private_unreachable`, whose message says the user can allow it).
  Menus stay out too: a menu that opened over a Private window (the
  person's context menu there, or the menu bar while one is in front and
  Detour is active) is refused by `list_menu` and `choose_menu_item`, and
  the Window menu's entries for Private windows (titled with their page)
  are neither listed nor run. This errs towards refusing: an agent's own
  menu opened while a Private window is in front is refused too. Whether a
  menu opened over a Private window is noted when it opens; whether that
  matters is asked at the call.
- **On**: every tool reaches them; windows and spaces carry
  `is_private: true`. Page capture is installed in the live pages of
  Private spaces and in new ones. A route into a Private window is followed
  by `open_url`.
- **Turned off again**: refused at once; capture is removed from Private
  pages and their records forgotten; the Private profile's worker parks are
  stopped (waiting commands fail), its endpoint-opened popups closed, its
  extension console and stub counts forgotten. Changing the key from
  outside (`defaults write`) changes what the tools allow at once (checked
  at runtime), but only the Settings checkbox installs or removes capture.
- **Never, whatever the setting**: the Private profile as a target of
  `install_extension`, `set_extension_enabled` or a permission (those skip
  the user's prompts); a route into a quarantine; the Private profile's
  Quick Detour and quarantine pages (no tool reaches Quick Detour windows,
  and capture never goes into them). Its extension contexts follow the
  setting but only when named (`popup:<ext>@<Private profile id>`): a
  client that names no profile resolves exactly as before. Its workers that
  were answered `stop` while the setting was off park only at their next
  start, as with turning the endpoint on.

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
| `list_windows` | Windows with `window_id`, `window_number` (the CGWindowID), frame (AppKit's), `screen_bounds` (the window server's, top-left points) and `display_id`, key/main, `is_private`, active space, selected tab | `window_id` is a small stable number per window, not `windowNumber`, which is only assigned once a window is on screen. |
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
| `set_debug_override` | Debug builds only: `reduce_motion` (this process, via `MotionPreference`), `space_toss_hop` and `space_toss_gravity` (the data directory's defaults keys `SpaceCelebration` already read in Debug), `automation_indicator` (off hides the connected-agent capsule for a capture, TASK-228.3; test runs only, `gate_closed` on the user's own endpoint); `default` clears | Absent from Release (checked on a Release build: its tool list and its binary's strings). |
| `list_extensions` | Installed extensions sorted by id (or one, by id or name): version, source, global switch, `loaded`/`load_failed`, per normal profile `turned_on`, `loaded`, `worker_parked`, `open_contexts`, `context_errors`; the manifest's permission lists, the saved decisions, WebKit's manifest warnings and every load error recorded this session | Reads whenever the endpoint is on. Load errors come from `ExtensionErrorLog` (see "Extension contexts"). `stable: true` is the diffable form (see "Diffing against a baseline"). |
| `install_extension` | Test runs only. An unpacked folder or a `.crx`, turned on in `profile_id` (default: the only normal profile); waits for it to load | No prompt. A CRX goes through `CRXInstallGate` with a file URL (its developer signature), may replace an installed id, and never updates. A keyless folder installed again keeps its id. `install_failed` for no or a bad manifest or a refused CRX. |
| `uninstall_extension` | Test runs only. Settings' Uninstall, every profile, no prompt | Closes the endpoint's popups of it first. |
| `set_extension_enabled` | Test runs only. One normal profile's switch (`profile_id`) or the global one | The Private profile is `private_unreachable`. |
| `set_extension_permission` | Test runs only. Saves a grant or denial and applies it to every profile's context (`setPermissionDecision`): an API permission, a match pattern, or a URL with `type` url | `warnings` names a decision with no effect: a host outside the manifest's host patterns stays inert, an undeclared API permission is not restored next launch, `nativeMessaging` gates real hosts only. |
| `open_extension_context` | `kind` popup (in a window, at its button, with a click's user gesture), options (a tab, in the background or selected in `window_id`), worker (start it and wait for it to answer) | Returns the `context` string. `sidepanel` is `unsupported_context` on this build. |
| `close_extension_context` | Closes the endpoint's popup, or the options page's tab | `context_not_open` when it is not open. |
| `call_extension_api` | Calls the function at a dotted path (`chrome.storage.local.get`) with `args` (a JSON array as a string), awaits it, returns the result as `evaluate_js` does | In `worker:` through the channel; in a popup, options page or tab through `callAsyncJavaScript`. A missing member is a `TypeError` (`script_error`). |
| `read_extension_global` | Reads the value at a dotted path (`self.cache.size`) | How a worker's own globals are read. |
| `seed_world` | Test runs only. Builds a world from a fixture file into an empty data directory: profiles, favourites, spaces, pinned entries in nested folders, splits, tabs, history visits, Link Routes, the active space | See "Seeding a world". `invalid_fixture` (with `details.path`), `not_empty` (with what is there). |
| `list_displays` | Displays with `display_id` (CGDirectDisplayID), `frame` and `visible_frame` in global top-left points, `scale`, `main`, `name`, pixel size | Virtual displays included. Read-only, whenever the endpoint is on. |
| `set_window_frame` | Test runs only. Moves and sizes a browser window (`window_id`) or another Detour window (`window_number`: Settings, the Arc import window) in top-left points, global or relative to `display_id`; `activate` brings Detour to the front with the window key | Returns `frame`, `screen_bounds` (the window server's), `settled`, `is_key`, `app_active`, `window_number`. `unknown_window`, `unknown_display`; a sheet, the approval panel, and a Private window unless allowed, are refused. |
| `open_ui` | Debug builds and test runs only. `space_editor` (a draft: name, emoji, color, profile_id; new or `space_id`), `arc_offer` and `arc_import` (from `arc_folder`, a fake Arc folder in the data directory or a temporary folder: never in or under Arc's own, in any case spelling, and with no symbolic or hard links inside, which the reader would follow to Arc's files), `settings` (`pane`, `row`) | Returns the window the UI is in (`window_number`, `frame`, `screen_bounds`). Absent from Release (its tool list was checked on a Release test run). |
| `extension_compat_report` | What an extension uses that Detour lacks: its `chrome.*`/`browser.*` references checked in the worker and a page, the stubs it references or called, API-naming TypeErrors, unsupported manifest keys and permissions, worker failures | Whenever the endpoint is on (not gated: it installs nothing). `probe: false` skips the runtime checks. See "The compatibility report". |

Tools that act on page content take a `context` (`tab:<uuid>`, or a bare
tab id): a tab of a non-Private space (or of a Private one while allowed),
normal or pinned, or a live favorite.
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
the person's pointer never moves (`AutomationInput`).[^input] The exceptions
are the test-run staging tools, which bring Detour forward on purpose:
`set_window_frame activate=true`, and `open_ui settings`/`arc_import`, whose
windows activate the app when shown (see "Capture staging"). How input
reaches each kind of target:

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
  `Space.makeUserContentController(for:)`; a Private space's only while
  Private access is allowed (see "Private windows"), and never a Private
  Quick Detour or quarantine page (`inSpace: false`). Stopping removes both (there
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
`extension_disabled`. The Private profile is never an install, turn-on or
permission target (`private_unreachable`); its contexts are listed and
reached only while Private access is allowed, and only when named with
`@<its id>` (see "Private windows").

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
  (`senderIsBackgroundContext`), in the Private profile only while Private
  access is allowed; a page that
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
off or in the Private profile while Private access is not allowed: the
context then stops sending for its lifetime, so with the endpoint off the cost is one request per context
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

# Capture staging

What TASK-228.3 adds so a release's website media is one script
(`docs/capture/capture.py`, [capture kit](../../docs/capture/README.md))
instead of a harness pasted into AppDelegate.[^task-228-3][^staging] The
virtual display, the wallpaper, screencapture and the encoder stay outside
the app.

## Seeding a world

`seed_world {fixture_path}` reads a JSON file, checks all of it, and only
then changes the store, so a malformed fixture changes nothing; every error
is `invalid_fixture` naming the field (`spaces[1].pinned[2].url`), and
unknown fields are refused so a misspelling fails. Only into an empty data
directory: one profile, one space, nothing pinned, no favourites, no tab with
a page (a fresh window's blank New Tab is allowed), no Link Routes or changed
Default, no history visits; anything else is `not_empty` with the list in
`error.details`. The format (version 1, `docs/capture/demo-world.json` is the
full example):

```json
{"version": 1,
 "profiles": [{"name": "Work", "favorites": [{"url": "https://slack.com/", "title": "Slack"}]}],
 "spaces": [{"name": "Work", "emoji": "🍊", "color": "FF7600", "profile": "Work",
   "pinned": [{"url": "…", "title": "…", "favicon_url": "…"},
              {"folder": "Design", "collapsed": false, "items": [ …pages, folders, splits… ]},
              {"split": [{"url": "…"}, {"url": "…"}], "fraction": 0.5}],
   "tabs": [{"url": "…", "title": "…", "selected": true}, {"split": [ …two pages… ]}]}],
 "history": [{"url": "…", "title": "…", "space": "Work", "ago": ["2h", "3d", 600], "typed": false}],
 "link_routes": [{"match": "domain_is", "pattern": "github.com", "target": "space:Work"},
                 {"source_app": "com.apple.TextEdit", "target": "quarantine"}],
 "active_space": "Work"}
```

- Profiles and spaces are named, and named once each (case-insensitive);
  spaces, history and routes refer to them by name. The first profile is the
  data directory's existing one, renamed (a profile with spaces is never
  deleted, and a new one would leave the default behind); the existing
  space is deleted after the new ones exist, and the undo stack is cleared.
- Pages are http(s) with a host; the title defaults to the host, the icon to
  the site's `/favicon.ico` (`favicon_url` overrides it: any http(s) URL,
  a local server's too). Folders nest up to 16 deep; a split is exactly two
  pages, `fraction` (0.1–0.9) the first one's share. `selected` picks one
  tab per space for the window to show on entry.
- History ages are seconds or `s`, `m`, `h`, `d`, `w` strings, within the 90
  days history keeps; visits are written with
  `HistoryDatabase.importVisits`. Routes take `match` (`is_equal_to`,
  `contains`, `domain_is`) with `pattern`, and/or `source_app`, and a
  `target` (`space:<name>`, `most_recent_space`, `private_window`,
  `quarantine`, `quick_detour`), checked with `linkRouteProblems` against
  the fixture's spaces.
- It is carried out by `TabStore.applyArcImport`, the Arc import's one-pass
  apply (the plan's entries gained `faviconURL` and folders `isCollapsed`):
  pinned entries and favourites come in dormant, tabs asleep, with the
  file's titles, so nothing has to load first (DemoStage opened every page
  and waited 20 s for titles and icons before pinning). Saved at once
  (`saveNow`), so the world is there after a relaunch (tested by reloading a
  `TabStore` from the same databases).

## Placing windows

`list_displays` and `set_window_frame` use global points with a top-left
origin (what `screencapture -R` takes; the main display's top-left is 0,0),
flipped from AppKit by the main display's height. After the move the tool
waits up to 2 s for the window server's bounds
(`CGWindowListCopyWindowInfo`) to equal the frame and returns both, with
`settled`. `list_windows` reports `screen_bounds` too. A recording region
must come from those bounds, not from the frame asked for (see Traps).

## UI on demand and Arc's folder

`open_ui` (Debug builds, test runs) replaces DemoStage's `spaceeditor`,
`arcoffer` and `settings*` commands. `space_editor` calls
`beginCreatingSpace(draft:)` / `beginEditingSpace(id:draft:)`; the editor
focuses (and selects) its name field, so `type_text window_id=… interval_ms=…`
types into it at a pace (tested: the characters arrive in order, paced).
`settings` uses `SettingsWindowController.showPane(named:)` and selects the
row in the pane's first table. The Arc ones read only a folder inside the
data directory or a temporary folder, compared after `realpath`, never
`ArcSidebarReader.userDataDirectory`.

A test run never reads the user's Arc folder, patch or no patch:
`AppDelegate` skips the launch offer when `AutomationGate.isTestRunRequested`
(`DETOUR_MCP=1` with an isolated data directory, whether or not the endpoint
started), and points `ArcSidebarReader.dataDirectoryOverride` (a `Mutex`,
read off the main thread) at `<data dir>/Arc`, so File › Import from Arc
finds nothing either. `open_ui arc_offer`/`arc_import` point it at the given
fixture folder for the rest of the run, so Choose… reads the fixture too.

# Who is connected, and stopping them

`AutomationController` runs the endpoint (off, starting, listening, failed;
a generation counter makes a start still in flight harmless after a stop)
and posts `didChangeNotification` for the UI:[^controller]

- **The indicator.** While a client is connected, every browser window
  (Private ones too) shows an orange capsule at the bottom right of its
  content naming the client ("Claude Code + 1"; an approved client by the
  name it was approved under), whether the sidebar is shown or not. The sidebar's title row had no room, and a sidebar placement would
  have needed a second home when it is hidden. Its menu lists Disconnect for
  each client, Allow … Again for names blocked in a test run, Turn Off
  Automation and Automation Settings…. It lives in `contentContainerView` above the page
  (pages go in below the drag handle), so `removeContentViews()` must skip it,
  or the first tab switch removes it.
- **Disconnect** of an approved client (the user's setting) revokes its
  token (`AutomationController.revoke`): the record goes, every session of
  that client ends, its next request is 401 (checked at runtime: the
  indicator's Disconnect chosen through the endpoint's own `click` and
  `choose_menu_item`, then the helper's next call), and other clients keep
  working. Asking again shows the prompt again. Settings' Revoke does the
  same, with the endpoint on or off.
- **Disconnect in a test run** keeps TASK-228.1's name blocking, because the
  shared token cannot be revoked without cutting off every client: it ends
  the sessions and blocks the client's name, whose `initialize` gets 403
  until the user allows it again or turns automation off and on. A "please
  stop", not a revocation (the name is the client's own). Approved clients
  are never name-blocked.
- **Idle sessions end** after 10 minutes without a request, since most
  clients never send DELETE. A client that comes back gets 404 and starts a
  new session, as the transport expects.
- **Reset Token** (Settings, test runs only) writes a new shared token,
  swaps it into the running endpoint and ends every session. The user's
  endpoint has no shared token: `token()` and `resetToken()` refuse there
  rather than create `mcp-token` again.

# Setting up a client

Settings > General > Automation copies what a client needs, lists the
allowed clients (name, client name, when allowed, last used) with Revoke,
and has the Private checkbox:

- **The bundled helper**, `Detour.app/Contents/MacOS/detour-mcp`, for any
  client that launches a command (Claude Desktop, Cursor, Claude Code). It
  relays MCP's stdio transport, one JSON-RPC message per line, to the
  endpoint, finding the URL in `mcp-endpoint.json` itself (with
  `DETOUR_DATA_DIR` for a test run), so the client's configuration holds no
  secret. In a test run it uses the file's shared token. With the user's
  setting it keeps a token per client: on the client's `initialize` it
  reads `<data dir>/mcp-clients/<SHA-256 of clientInfo.name>.token` (0600 in
  a 0700 folder, opened without following links) or asks for one (see
  "Approving a client", with a 330 s timeout, longer than the prompt's 5
  minutes) and saves it. A denial, or a 401 with its token (revoked: the
  file is deleted), is answered with a JSON-RPC error for the rest of the
  run ("Detour revoked this client's access; restart the client to ask
  again"), never a new prompt. When the session ended, the token was reset
  (test run) or Detour restarted on another port, it reads the file again,
  replays the client's `initialize` and retries once, but after a failed connection only when it
  was refused: a timed-out or dropped request may already have acted, so it
  gets an error instead of running twice. With Detour not running, each request gets
  a JSON-RPC error saying so. At the end of stdin it ends its session, so the
  indicator goes away at once. Signed by `sign-app.sh` on its own, without
  Detour's entitlements.
  - Claude Code: `claude mcp add detour -- "/Applications/Detour.app/Contents/MacOS/detour-mcp"`
  - Other clients: `{"mcpServers":{"detour":{"command":"…/detour-mcp"}}}`
- **The URL and the token**, test runs only, for clients that speak HTTP
  with a header. The user's endpoint offers neither: clients go through
  the helper.

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

`scripts/detour-mcp` (Python 3, standard library only, test runs only: an
endpoint file with no token gets a message pointing at the helper) reads
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

In a test run, Claude Code can also connect directly:
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
- **A new window is still growing.** Right after `showWindow`, AppKit's
  open animation scales the window up from its centre for a moment, so the
  window server's bounds were 698 × 478 at 41,61 while the frame said
  700 × 480 at 40,60 (in a test). That is most likely the ~9 pt shift of
  TASK-110's first loops, whose region came from the frame asked for.
  `set_window_frame` waits for the bounds to settle and returns them.
- **`resolvingSymlinksInPath` drops `/private`.** It turned
  `/private/tmp/x` into `/tmp/x` for some paths and not others, so a
  temporary folder failed the "inside a temporary folder" check. The Arc
  folder check compares `realpath` results.
- **A capture takes the keyboard focus.** A recording shows an active window
  (traffic lights in colour) only while Detour is the active app with that
  window key, so the capture script asks for `set_window_frame
  activate=true`, which takes the focus from the app in use until the run
  ends. screencapture itself records without touching focus. `open_ui
  settings` and `arc_import` bring their windows forward too (Settings'
  `showWindow` activates the app, the Arc window makes itself key). All are
  test-run only, so the user's own endpoint never takes the front. On Nov
  14 2026 Detour lost the front mid-take in most of four capture runs (to
  Google Chrome, then Mimestream, with the Mac in use: 22 s since the last
  input) and kept it in three diagnostic runs; the script now stops naming
  the app in front instead of fighting for the focus or keeping a grey take.
- **The connected-agent capsule shows in captures.** It is in every window
  while a client is connected, so the capture script hides it with the
  Debug override `automation_indicator off`; Release cannot hide it.
- **Local pages are dev-mode pages.** A fixture rewritten to a 127.0.0.1
  server (`capture.py --offline`) gets dev mode's host line, hazard border
  and toolbar: good for a dry run, not for the site's media.
- **Accessibility sees no windows on a locked screen.** With the session
  locked, `AXWindows` of the running build returned the application element
  itself for every window (and `AXUIElementCopyElementAtPosition` failed),
  so an external AXPress on the approval panel's Allow could not be made,
  and `screencapture -l` of the panel failed ("could not create image").
  The panel was on screen per `CGWindowListCopyWindowInfo` (layer 3,
  onscreen). The runtime check approved the client by writing its record
  and the helper's token file beforehand instead; the click itself is
  covered by tests with a fake prompter.
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
`stable` list and console), `AutomationStagingTests` (TASK-228.3: a seeded world round trip through a
relaunch, a malformed fixture refused with nothing applied, the fixture's
field errors, refusal outside a test run and in a data directory with
content, sort orders per pinned level; the test-run request and the Arc
folder override; displays, a window placed and read back, by window_id and
window_number, and the placement errors; open_ui only in Debug, the space
editor with a draft and paced typing into its name field, the Arc offer from
a fixture folder and its refusals, a Settings pane with a row, open_ui's
errors and its refusal outside a test run), `AutomationControllerTests` (on and off with the endpoint file, a
stop during a start, a test run's shared token and Reset Token, its
disconnect and allow; the user's endpoint publishing no token and deleting
a leftover one, refusing it, Disconnect and Revoke revoking and keeping
other clients, turning off with a prompt up; the Private setting read by
running tools; idle sessions, the indicator's text and its place above the
page through tab switches), `AutomationHelperTests` (the built helper
relaying a session, starting a new one, its error without Detour, ending
its session at the end of stdin, the setup strings Settings copies; with
per-client tokens: asking, saving 0600 in a 0700 folder and reusing with no
prompt, a revoked client told so with its token deleted and no new prompt,
a denied client getting no second prompt), `AutomationClientApprovalTests`
(TASK-228.5: the store's hashes, file mode, reload, revocation not undone
by a late write, coalesced `last_used`, a malformed file; per-client
authorisation and the shared token refused, the authorize route only after
Host and Origin and only at its exact path, its head checks, name
cleaning; the approval flow with a fake prompt: allow, deny and the
10-minute window, timeout, one prompt per name with its own answer, a
waiter refused after a denial, three names at once, a withdrawn request,
stop, a bad body; sessions bound to their client and refused once revoked
on the main actor; over a real socket: a token working until revoked and the
next request 401, bad heads refused before the body, a held request
outliving the 10 s deadline while an idle connection does not and the held
limit, a client hanging up) and `AutomationPrivateAccessTests` (listing, a
page tool, an input tool and a menu tool with the setting off, on and off
again; capture installed in and removed from Private pages, never in a
Private Quick Detour page; the Private profile never an install target,
its contexts following the setting).[^tests][^approval-tests]

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
[^task-228-3]: Automation: capture tooling on the MCP endpoint
[^staging]: AutomationTools+Staging.swift and AutomationWorldFixture.swift (seed_world, displays, placement, open_ui)
[^input]: Detour/Automation/AutomationInput.swift
[^controller]: Detour/Automation/AutomationController.swift
[^page]: AutomationPageCapture.swift and AutomationPage.swift (capture script, buffers, page scripts)
[^task-228-2]: Automation: extension testing tools on the MCP endpoint
[^extension-tools]: AutomationTools+Extensions.swift (addressing, the extension tools)
[^channel]: AutomationExtensionChannel.swift (the channel into an extension's background, the command runner)
[^task-228-5]: Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint
[^approvals]: AutomationApprovals.swift, AutomationClients.swift and AutomationApprovalPanel.swift (the authorize route, the client store, the prompt)
[^approval-tests]: AutomationClientApprovalTests and AutomationPrivateAccessTests
