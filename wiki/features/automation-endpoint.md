---
type: Feature
title: Automation endpoint (MCP)
description: "Detour's local MCP server for agents and scripts (TASK-228): what it does, how it is turned on, its socket, MCP and tools layers, the tool groups at a glance, and the pages on access and approval, Private windows, window kinds, input delivery, the agent pointer, screenshots, page tools, extension contexts, the compatibility report, capture staging, clients and tests."
tags: [automation, mcp, testing, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: automation-dir
    resource: ../../Detour/Automation
    title: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
  - id: task-228
    resource: backlog:TASK-228
    title: "Automation: an MCP server so agents can drive and inspect Detour"
  - id: task-228-1
    resource: backlog:TASK-228.1
    title: "Automation: an MCP endpoint in Detour, first slice for testing"
  - id: task-228-2
    resource: backlog:TASK-228.2
    title: "Automation: extension testing tools on the MCP endpoint"
  - id: task-228-4
    resource: backlog:TASK-228.4
    title: "Automation: page inspection tools on the MCP endpoint"
  - id: tests
    resource: ../../DetourTests/MCPServerTests.swift
    title: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
---

A local [MCP](https://modelcontextprotocol.io) server inside Detour, so an
agent (Claude Code, another MCP client) or a plain script can read the
browser's state and act on it. This page is the hub: what the endpoint
does, how it is built, and where each part is described.

# What it does

Agents list windows, spaces and tabs, select a tab, open a URL, run a menu
command, click, type, and choose from the menu that is open, take
screenshots, and read a page: run JavaScript, read its text, HTML and
interactive elements, its console and network records, and wait for
something to happen in it (TASK-228.4).[^task-228-4] Built first for testing
Detour itself (replacing harness patches pasted into AppDelegate), and
shipped in Release too, off until turned on.[^task-228-1] TASK-228.2 adds
extensions: installing and managing them in a test run, and their popup,
options page and service worker as contexts the same tools
reach.[^task-228-2] Later slices of TASK-228 add capture staging for the
website, per-client approval, more window kinds, and a visible agent
pointer.[^task-228]

Input is delivered inside the app, never as HID events: Detour stays in the
background and the person's pointer never moves.

# How it is turned on

`AutomationGate.mode` decides once at launch:[^automation-dir] the user's
setting (Settings > General > Automation, a port the system picks at each
start, clients approved one by one in Detour's own prompt), or a test run
(`DETOUR_MCP=1` with an isolated `DETOUR_DATA_DIR`, one shared token). The
XCTest host never listens. Details, the files it writes and who may
connect: [turning it on and who may connect](./automation-endpoint-access.md).

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
tool's schema to hold it.[^tests]

# The tools at a glance

Every tool, with its arguments and notes, is in [the
tools](./automation-endpoint-tools.md).

| Group | Tools | Gate |
|---|---|---|
| Windows, spaces, tabs, commands | `list_windows`, `list_spaces`, `list_tabs`, `select_tab`, `open_url`, `run_menu_item` | whenever the endpoint is on |
| Input and menus | `click`, `type_text`, `press_key`, `hit_test`, `list_menu`, `choose_menu_item`, `close_menu` | on; Settings takes input in test runs only |
| Screenshots and appearance | `screenshot`, `set_appearance`, `set_debug_override` | the override is Debug only |
| Page tools | `evaluate_js`, `read_page`, `console_messages`, `network_requests`, `wait_for`, `wake_tab` | on |
| Extensions | `list_extensions`, `open_extension_context`, `close_extension_context`, `call_extension_api`, `read_extension_global`, `extension_compat_report`; `install_extension`, `uninstall_extension`, `set_extension_enabled`, `set_extension_permission` | the last four in test runs only |
| Capture staging and Debug | `seed_world`, `list_displays`, `set_window_frame`, `open_ui`, `navigation_swipe` | test runs (`list_displays` always); `open_ui` and `navigation_swipe` Debug only |

# Pages

- [Turning it on and who may connect](./automation-endpoint-access.md):
  the gate, the files, the Host, Origin and bearer checks, the per-client
  approval prompt and the rejected alternatives.
- [Clients and disconnecting](./automation-endpoint-clients.md): the
  connected-agent indicator, Disconnect and Revoke, the bundled
  `detour-mcp` helper, the `scripts/detour-mcp` client, a worked check.
- [Private windows](./automation-endpoint-private-windows.md): the
  "Allow agents to use Private windows" opt-in.
- [Window kinds](./automation-endpoint-windows.md): browser, Quick
  Detour, quarantine and Settings windows, and who reaches which.
- [The tools](./automation-endpoint-tools.md): every tool, the `context`
  argument, `run_menu_item`'s traps.
- [How input is delivered](./automation-endpoint-input.md): pages, native
  views, sidebar rows, AppKit controls, which window is key, the input
  traps.
- [The agent pointer](./automation-endpoint-agent-pointer.md): the overlay
  that shows where agents click and type.
- [Screenshots](./automation-endpoint-screenshots.md): in-app and
  window-server pictures and what each cannot draw.
- [Page tools and capture](./automation-endpoint-page-tools.md): the
  console and network capture script and its limits.
- [Extension contexts](./automation-endpoint-extensions.md): addressing,
  the popup, the worker channel, the extension console, load errors.
- [The compatibility report](./automation-endpoint-compat-report.md): what
  an extension uses that Detour lacks, and diffing against a baseline.
- [Capture staging](./automation-endpoint-staging.md): seeding a world,
  placing windows, UI on demand, Arc's folder.
- [Tests](./automation-endpoint-tests.md): what each suite covers.

# Related

- [In-process UI automation](../playbooks/in-process-ui-automation.md): the
  techniques the input tools build on.
- [Runtime verification](../playbooks/runtime-verification.md): `/verify`
  drives the app through the endpoint.
- [Extension compatibility run](../playbooks/extension-compat-run.md): the
  extension tools end to end, with a baseline diff.
- [Link Routes](./link-routing.md): what `open_url` applies to a new tab.

[^automation-dir]: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
[^task-228]: Automation: an MCP server so agents can drive and inspect Detour
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^task-228-2]: Automation: extension testing tools on the MCP endpoint
[^task-228-4]: Automation: page inspection tools on the MCP endpoint
[^tests]: MCPServerTests, AutomationHTTPTests, AutomationToolsTests, AutomationEndpointTests
