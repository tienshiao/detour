---
type: Feature
title: "Automation endpoint: turning it on and who may connect"
description: How the automation endpoint is turned on (the user's setting, a test run's DETOUR_MCP=1, never the test host), the files it writes, the Host, Origin and bearer checks and their threat model, and the per-client Allow/Deny prompt that gives each approved client its own token, with the alternatives the user rejected.
tags: [automation, mcp, security]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:12Z }
sources:
  - id: automation-dir
    resource: ../../Detour/Automation
    title: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
  - id: task-228-1
    resource: backlog:TASK-228.1
    title: "Automation: an MCP endpoint in Detour, first slice for testing"
  - id: task-228-5
    resource: backlog:TASK-228.5
    title: "Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint"
  - id: approvals
    resource: ../../Detour/Automation/AutomationApprovals.swift
    title: AutomationApprovals.swift, AutomationClients.swift and AutomationApprovalPanel.swift (the authorize route, the client store, the prompt)
  - id: helper
    resource: ../../Helpers/detour-mcp/main.swift
    title: detour-mcp, the bundled stdio helper
  - id: approval-tests
    resource: ../../DetourTests/AutomationClientApprovalTests.swift
    title: AutomationClientApprovalTests and AutomationPrivateAccessTests
---

The [automation endpoint](./automation-endpoint.md) listens only when the
user turns it on, or in a scripted test run with an isolated data
directory, and every request must pass a loopback Host and Origin check and
a bearer token. With the user's setting each client gets its own token, but
only after the person allows it in Detour's own prompt.

# How it is turned on

`AutomationGate.mode` decides once at launch:[^automation-dir]

| How | Listens on | Notes |
|---|---|---|
| The user's setting (`AutomationEndpointEnabled` in the data directory's defaults suite), Settings > General > Automation | a port the system picks at each start (`AutomationEndpointPort` fixes one, advanced) | Not a fixed port (user decision, 2026-11-14): while Detour is not running, another account could listen on a fixed one and collect the token from a client configured with the address.[^task-228-1] Clients use the bundled helper, which reads the port. Turned on and off at runtime by `AutomationController.setEnabled`; the window's indicator has Turn Off Automation too. |
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
| `mcp-clients/<SHA-256 of the client's name>.token` (0600, folder 0700) | the user's setting | Written by the bundled helper: the token Detour gave that client.[^helper] |

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

# Approving a client

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
   panel: input goes only to the windows `list_windows` names, and
   `set_window_frame` refuses it, so an approved agent cannot approve
   another.
3. The HTTP request is held until the answer (`AutomationApprovals`):
   Allow stores a record and answers 200 `{token, client_id, name}`; Deny
   answers 403; no answer within 5 minutes is a denial. One prompt per
   name at a time: a second request for that name waits (one waiter at most;
   a third is 429), then gets a prompt of its own, never the first one's
   answer, so a second process cannot ride on a prompt the user expected.
   At most 3 names are asked about at once (429 beyond). A name denied or
   unanswered in the last 10 minutes is refused without a prompt (403 with
   `Retry-After`), and so is the title that prompt showed, under any name.
   A client that closes its connection withdraws its request and the panel
   closes; the first such hang-up per name or title is let off (the person
   may have closed the client), a second within 10 minutes counts as a
   denial. At most 5 prompts are shown in any 10 minutes, whatever the
   names (429 with `Retry-After` beyond); turning automation off closes
   every panel and answers every held request 503. An Allow whose answer
   could not be sent (the client went away) is revoked at once, so no
   approval exists whose token nobody holds.
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

What the rate limits do not stop: a local program that varies both name
and title still gets up to 5 prompts in 10 minutes, and while it holds the
budget or the 3 prompt places a real client gets 429 (a local denial of
service, not access; the user can turn automation off). The name is
self-reported, so the prompt says so.

How a client is revoked (Disconnect, Settings' Revoke) and what the helper
does with a denial or a revoked token: [clients and
disconnecting](./automation-endpoint-clients.md).

# Alternatives rejected

Recorded with the user's decisions, 2026-11-13/14:[^task-228-5]

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
  froze the whole endpoint (see "A modal action and the main queue" in
  [the tools](./automation-endpoint-tools.md#traps)), and in an app that is
  not active it goes unseen.
- **A fixed port for the user's endpoint** (47823 at first): another
  account could squat it while Detour is not running (user decision,
  2026-11-14).[^task-228-1]

# Traps

- **Accessibility sees no windows on a locked screen.** With the session
  locked, `AXWindows` of the running build returned the application element
  itself for every window (and `AXUIElementCopyElementAtPosition` failed),
  so an external AXPress on the approval panel's Allow could not be made,
  and `screencapture -l` of the panel failed ("could not create image").
  The panel was on screen per `CGWindowListCopyWindowInfo` (layer 3,
  onscreen). The runtime check approved the client by writing its record
  and the helper's token file beforehand instead; the click itself is
  covered by tests with a fake prompter.[^task-228-5]
  `docs/harness/task2285-approval-check.py <Detour.app>` runs the whole
  check, AXPress included, on an unlocked screen (`--preapprove` for a
  locked one); find the panel with a compiled `CGWindowListCopyWindowInfo`
  lister, not `swift -e` in a loop, which took seconds per try and let the
  5-minute prompt time out.
- **SIGTERM runs no quit path.** The SIGTERM source ends native hosts and
  re-raises the signal, so `applicationWillTerminate` never runs. It removes
  the endpoint file too, and only if the file's `pid` is this process. A
  crash still leaves the file behind, which is why the client checks the
  `pid`.

# Tests

`AutomationHTTPTests` (authorisation, gate, credential files),
`AutomationEndpointTests` (refusals over a real socket),
`AutomationClientApprovalTests` (the store, per-client authorisation, the
authorize route, the approval flow with a fake prompt, the connection
deadline); details in [the endpoint's tests](./automation-endpoint-tests.md).[^approval-tests]

# Related

- [Automation endpoint (MCP)](./automation-endpoint.md): the hub.
- [Private windows](./automation-endpoint-private-windows.md): the second
  opt-in on the same Settings section.
- [Clients and disconnecting](./automation-endpoint-clients.md): the
  helper, the indicator, Disconnect and Revoke.

[^automation-dir]: Detour/Automation (gate, credentials, HTTP, authorisation, MCP server, tools, endpoint)
[^task-228-1]: Automation: an MCP endpoint in Detour, first slice for testing
[^task-228-5]: Automation: per-client approval prompt and tokens, and a Private-window opt-in, for the MCP endpoint
[^approvals]: AutomationApprovals.swift, AutomationClients.swift and AutomationApprovalPanel.swift (the authorize route, the client store, the prompt)
[^helper]: detour-mcp, the bundled stdio helper
[^approval-tests]: AutomationClientApprovalTests and AutomationPrivateAccessTests
