---
type: Feature
title: Automation endpoint (MCP)
description: "Detour's local MCP server for agents and scripts (TASK-228.1): how it is turned on, who may connect (Host, Origin, bearer token), the HTTP and MCP layers, the tools and their stable error codes, the scripts/detour-mcp client, and the traps met building it (menu-bar titles, animated commands, modal actions and the main queue, SIGTERM)."
tags: [automation, mcp, testing, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-14T03:30:00Z }
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
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
---

# What it does

A local [MCP](https://modelcontextprotocol.io) server inside Detour, so an
agent (Claude Code, another MCP client) or a plain script can read the
browser's state and act on it: list windows, spaces and tabs, select a tab,
open a URL, run a menu command. Built first for testing Detour itself
(replacing harness patches pasted into AppDelegate), and shipped in Release
too, off until turned on.[^task-228-1] Later phases of TASK-228.1 add
in-app input, menus, screenshots, a connected indicator and a bundled
stdin/stdout helper; TASK-228.2 adds extension contexts.

# How it is turned on

`AutomationGate.mode` decides once at launch:[^automation-dir]

| How | Listens on | Notes |
|---|---|---|
| The user's setting (`AutomationEndpointEnabled` in the data directory's defaults suite) | 47823, or `AutomationEndpointPort` | A fixed port, so a client configured once keeps working. The Settings row comes in a later phase. |
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

## The tools (phase 1)

| Tool | Does | Notes |
|---|---|---|
| `list_windows` | Windows with `window_id`, `window_number` (the CGWindowID), frame, key/main, active space, selected tab | `window_id` is a small stable number per window, not `windowNumber`, which is only assigned once a window is on screen. |
| `list_spaces` | Spaces with profile, counts, the windows showing each | |
| `list_tabs` | A space's favourites, pinned entries (live or dormant) and tabs, in sidebar order, plus its pinned folders | `id` is what `select_tab` takes; `tab_id` and `context` are null for a dormant item. |
| `select_tab` | Selects an item as a row click does | Switches the window's space first; wakes a dormant pinned entry or favourite; `dormant_refused` when its extension keeps it dormant. |
| `open_url` | The palette's typed-URL path (`openTypedURL`): a new tab, or `in_place` | Link Routes apply as for a typed URL; `routed` says the URL went elsewhere. |
| `run_menu_item` | A main-menu command by path or key equivalent, sent to that window's responder chain and validated there | Works with Detour in the background, where there is no key window. |

Tools that act on page content take a `context` (`tab:<uuid>`, or a bare
tab id). `popup:`, `options:`, `sidepanel:` and `worker:` already parse and
answer `unknown_context`, so TASK-228.2 adds extension contexts without
changing signatures.

# The client

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
session and a split, kept-alive request over a real socket).[^tests]

# Related

- [In-process UI automation](../playbooks/in-process-ui-automation.md): the
  techniques the input tools of the next phase build on.
- [Runtime verification](../playbooks/runtime-verification.md): what the
  endpoint is meant to replace for `/verify`.
- [Link Routes](./link-routing.md): what `open_url` applies to a new tab.

[^automation-dir]: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
[^client]: scripts/detour-mcp (stdlib Python client)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
