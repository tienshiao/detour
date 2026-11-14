---
type: Feature
title: Automation endpoint (MCP)
description: "Detour's local MCP server for agents and scripts (TASK-228.1): how it is turned on, who may connect (Host, Origin, bearer token), the HTTP and MCP layers, the tools and their stable error codes, how clicks, keys and menus are delivered inside the app without activating it, screenshots and what they cannot draw, the connected-agent indicator and disconnecting, the bundled stdio helper and client setup, the scripts/detour-mcp client, and the traps met building it (menu-bar titles, animated commands, modal actions and the main queue, key ordering, window-server materials, SIGTERM)."
tags: [automation, mcp, testing, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T08:00:00Z }
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
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
---

# What it does

A local [MCP](https://modelcontextprotocol.io) server inside Detour, so an
agent (Claude Code, another MCP client) or a plain script can read the
browser's state and act on it: list windows, spaces and tabs, select a tab,
open a URL, run a menu command, click, type, and choose from the menu that is
open, take screenshots. Built first for testing Detour itself
(replacing harness patches pasted into AppDelegate), and shipped in Release
too, off until turned on.[^task-228-1] TASK-228.2 adds extension
contexts.

# How it is turned on

`AutomationGate.mode` decides once at launch:[^automation-dir]

| How | Listens on | Notes |
|---|---|---|
| The user's setting (`AutomationEndpointEnabled` in the data directory's defaults suite), Settings > General > Automation | 47823, or `AutomationEndpointPort` | A fixed port, so a client configured once keeps working. Turned on and off at runtime by `AutomationController.setEnabled`; the window's indicator has Turn Off Automation too. |
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
| `set_debug_override` | Debug builds only: `reduce_motion` (this process, via `MotionPreference`), `space_toss_hop` and `space_toss_gravity` (the data directory's defaults keys `SpaceCelebration` already read in Debug); `default` clears | Absent from Release (checked on a Release build: its tool list and its binary's strings). |

Tools that act on page content take a `context` (`tab:<uuid>`, or a bare
tab id). `popup:`, `options:`, `sidepanel:` and `worker:` already parse and
answer `unknown_context`, so TASK-228.2 adds extension contexts without
changing signatures.

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
  It is a control for the user, not a security boundary: the token is the
  boundary.
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
  `initialize` and retries once. With Detour not running, each request gets
  a JSON-RPC error saying so. At the end of stdin it ends its session, so the
  indicator goes away at once. Signed by `sign-app.sh` on its own, without
  Detour's entitlements.
  - Claude Code: `claude mcp add detour -- "/Applications/Detour.app/Contents/MacOS/detour-mcp"`
  - Other clients: `{"mcpServers":{"detour":{"command":"…/detour-mcp"}}}`
- **The URL and the token**, for clients that speak HTTP with a header.

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
errors), `AutomationControllerTests` (on and off with the endpoint file, a
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
- [Link Routes](./link-routing.md): what `open_url` applies to a new tab.

[^automation-dir]: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
[^client]: scripts/detour-mcp (stdlib Python client)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests, AutomationInputTests, AutomationCaptureTests, AutomationControllerTests, AutomationHelperTests
[^input]: Detour/Automation/AutomationInput.swift
[^controller]: Detour/Automation/AutomationController.swift
