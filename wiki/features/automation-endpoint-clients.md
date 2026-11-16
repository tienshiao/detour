---
type: Feature
title: "Automation endpoint: clients and disconnecting"
description: The automation endpoint's client side, which covers the connected-agent indicator, Disconnect and Revoke, idle sessions and Reset Token, setting up a client through the bundled detour-mcp stdio helper (where it keeps each client's token, how it retries), the scripts/detour-mcp scripting client, and a worked download check driven through it.
tags: [automation, mcp, testing]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: controller
    resource: ../../Detour/Automation/AutomationController.swift
    title: AutomationController.swift (lifecycle, clients, token, indicator text)
  - id: helper
    resource: ../../Helpers/detour-mcp/main.swift
    title: detour-mcp, the bundled stdio helper
  - id: client
    resource: ../../scripts/detour-mcp
    title: scripts/detour-mcp (stdlib Python client)
  - id: task-228-1
    resource: backlog:TASK-228.1
    title: "Automation: an MCP endpoint in Detour, first slice for testing"
  - id: task-228-5
    resource: backlog:TASK-228.5
    title: "Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint"
  - id: endpoint-checks
    resource: ../../docs/harness/task324-endpoint-checks.py
    title: docs/harness/task324-endpoint-checks.py (TASK-324's download checks through the endpoint)
---

How agents and scripts connect to the [automation
endpoint](./automation-endpoint.md), how the person sees who is connected,
and how they stop a client. Who may connect at all, and the approval
prompt, are on [turning it on and who may
connect](./automation-endpoint-access.md).

# Who is connected, and stopping them

`AutomationController` runs the endpoint (off, starting, listening, failed;
a generation counter makes a start still in flight harmless after a stop)
and posts `didChangeNotification` for the UI:[^controller]

- **The indicator.** While a client is connected, every browser window
  (Private ones too) shows an orange capsule at the bottom right of its
  content naming the client ("Claude Code + 1"; an approved client by the
  name it was approved under), whether the sidebar is shown or not. The
  sidebar's title row had no room, and a sidebar placement would have
  needed a second home when it is hidden. Its menu lists Disconnect for
  each client, Allow … Again for names blocked in a test run, Turn Off
  Automation and Automation Settings…. It lives in `contentContainerView`
  above the page (pages go in below the drag handle), so
  `removeContentViews()` must skip it, or the first tab switch removes it.
  A capture hides it with a Debug override (see [capture
  staging](./automation-endpoint-staging.md#traps)).
- **Disconnect** of an approved client (the user's setting) revokes its
  token (`AutomationController.revoke`): the record goes, every session of
  that client ends, its next request is 401 (checked at runtime: the
  indicator's Disconnect chosen through the endpoint's own `click` and
  `choose_menu_item`, then the helper's next call), and other clients keep
  working.[^task-228-5] Asking again shows the prompt again. Settings'
  Revoke does the same, with the endpoint on or off.
- **Disconnect in a test run** keeps TASK-228.1's name blocking, because the
  shared token cannot be revoked without cutting off every client: it ends
  the sessions and blocks the client's name, whose `initialize` gets 403
  until the user allows it again or turns automation off and on. A "please
  stop", not a revocation (the name is the client's own; a Streamable HTTP
  client whose session ends just starts another, which is why the name is
  blocked).[^task-228-1] Approved clients are never name-blocked.
- **Idle sessions end** after 10 minutes without a request, since most
  clients never send DELETE. A client that comes back gets 404 and starts a
  new session, as the transport expects.
- **Reset Token** (Settings, test runs only) writes a new shared token,
  swaps it into the running endpoint and ends every session. The user's
  endpoint has no shared token: `token()` and `resetToken()` refuse there
  rather than create `mcp-token` again.

A call already running when a client is disconnected, revoked or automation
is turned off (a long `type_text` with `interval_ms`, an `evaluate_js`)
finishes; the refusal starts from the next call.

# Setting up a client

Settings > General > Automation copies what a client needs, lists the
allowed clients (name, client name, when allowed, last used) with Revoke,
and has the [Private switch](./automation-endpoint-private-windows.md); its
status line shows the address only in a test run:

- **The bundled helper**, `Detour.app/Contents/MacOS/detour-mcp`, for any
  client that launches a command (Claude Desktop, Cursor, Claude Code).[^helper]
  It relays MCP's stdio transport, one JSON-RPC message per line, to the
  endpoint, finding the URL in `mcp-endpoint.json` itself (with
  `DETOUR_DATA_DIR` for a test run), so the client's configuration holds no
  secret. In a test run it uses the file's shared token. With the user's
  setting it keeps a token per client: on the client's `initialize` it
  reads `<data dir>/mcp-clients/<SHA-256 of clientInfo.name>.token` (0600 in
  a 0700 folder, opened without following links) or asks for one (see
  [approving a client](./automation-endpoint-access.md#approving-a-client),
  with a 630 s timeout, longer than the prompt's 5 minutes plus up to 5
  more queued behind another prompt for the same name) and saves it.
  - A denial, or a 401 with a token Detour already accepted in this run
    (revoked: the file is deleted), is answered with a JSON-RPC error for
    the rest of the run ("Detour revoked this client's access; restart the
    client to ask again"), never a new prompt.
  - A saved token refused before Detour accepted it in this run (revoked
    while the client was not running) is deleted and asked for again,
    once; a closing DELETE refused with 401 (disconnected, then the client
    quit) deletes the file too, so the next start asks.
  - When the session ended, the token was reset (test run) or Detour
    restarted on another port, it reads the file again, replays the
    client's `initialize` and retries once, but after a failed connection
    only when it was refused: a timed-out or dropped request may already
    have acted, so it gets an error instead of running twice.
  - With Detour not running, each request gets a JSON-RPC error saying so.
  - At the end of stdin it ends its session, so the indicator goes away at
    once.
  - Signed by `sign-app.sh` on its own, without Detour's entitlements.
  - Claude Code: `claude mcp add detour -- "/Applications/Detour.app/Contents/MacOS/detour-mcp"`
  - Other clients: `{"mcpServers":{"detour":{"command":"…/detour-mcp"}}}`
- **The URL and the token**, test runs only, for clients that speak HTTP
  with a header. The user's endpoint offers neither: clients go through
  the helper.

# The scripting client

`scripts/detour-mcp` (Python 3, standard library only, test runs only: an
endpoint file with no token gets a message pointing at the helper) reads
`mcp-endpoint.json` from `$DETOUR_DATA_DIR` (or `--data-dir`), runs the
handshake, calls, and deletes its session.[^client] `tools` lists the
tools; `call TOOL key=value …` prints the structured result; `batch` runs
JSON lines in one session. Exit status 0 is success, 1 means the tool
reported an error, 2 a transport or protocol failure (including a stale
endpoint file whose process is gone). Like the helper it bypasses HTTP
proxies.

```bash
DETOUR_DATA_DIR=DetourVerify DETOUR_MCP=1 "$APP/Contents/MacOS/Detour" &
export DETOUR_DATA_DIR=DetourVerify
scripts/detour-mcp call list_windows
scripts/detour-mcp call open_url window_id=1 url=https://example.com
scripts/detour-mcp call run_menu_item window_id=1 'path=["File","New Tab"]'
```

In a test run, Claude Code can also connect directly:
`claude mcp add --transport http detour <url> --header "Authorization: Bearer <token>"`.

# A worked check

`docs/harness/task324-endpoint-checks.py` re-runs TASK-324's hands-on
download checks with no manual steps:[^endpoint-checks] it launches the
given build with its own data directory, serves a fixture, and checks each
download's flight from the `Download flight from x,y to x,y; catcher …;
motion …` log line (category `downloads`, added for this): Download Linked
File from the right click, a download in a split pane from the click in the
right pane, with the sidebar hidden to the window's corner with no catcher,
and with Reduce Motion (the Debug override) no flight. All passed on
2026-11-14 with Detour in the background. It cleans up its downloads, data
directory, defaults keys, its own preferences domain
(`com.detourbrowser.mac.<data dir>`) and the WebKit stores recorded in its
database (under `~/Library/WebKit`, outside the data directory, so deleting
the directory alone orphans them).

# Tests

`AutomationControllerTests` (on and off with the endpoint file, a stop
during a start, a test run's shared token, Reset Token, disconnect and
allow; the user's endpoint publishing no token, Disconnect and Revoke, idle
sessions, the indicator) and `AutomationHelperTests` (the built helper's
relaying, restarts, per-client tokens); details in [the endpoint's
tests](./automation-endpoint-tests.md).

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Runtime verification](../playbooks/runtime-verification.md): `/verify`
  drives the app through this client.

[^controller]: AutomationController.swift (lifecycle, clients, token, indicator text)
[^helper]: detour-mcp, the bundled stdio helper
[^client]: scripts/detour-mcp (stdlib Python client)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^task-228-5]: Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint
[^endpoint-checks]: docs/harness/task324-endpoint-checks.py (TASK-324's download checks through the endpoint)
