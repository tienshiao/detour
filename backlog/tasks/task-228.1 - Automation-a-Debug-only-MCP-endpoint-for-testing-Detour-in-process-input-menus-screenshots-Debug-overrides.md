---
id: TASK-228.1
title: >-
  Automation: an MCP endpoint in Detour, first slice for testing (in-process
  input, menus, screenshots), off until turned on
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14T01:08:00Z'
updated_date: '2026-11-14T02:47:00Z'
labels:
  - tooling
  - automation
dependencies: []
references:
  - .claude/skills/verify/SKILL.md
  - wiki/playbooks/runtime-verification.md
  - TASK-89
  - TASK-324
  - TASK-228.2
parent_task_id: TASK-228
priority: medium
ordinal: 392000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The first slice of TASK-228, filed 2026-11-14 at the user's request. It replaces TASK-89, which described the testing need more narrowly and is archived in its favour.

Builds (user decision 2026-11-14): the MCP server is not Debug-only; it ships in Release too. This overrides TASK-89's "absent from Release" rule. Because it can read pages and act with the user's sessions, it is off until turned on: in Release by the user, for a test run by an isolated DETOUR_DATA_DIR. Tools that only make sense for testing Detour itself (Debug overrides that stand in for system settings, such as Reduce Motion, or the space toss's hop and gravity) stay in Debug builds.

Why now: on TASK-324 the agent could not verify Download Linked File, a split pane, a hidden sidebar or Reduce Motion in the running app.
- Clicks posted only to Detour's process are ignored by an inactive app and by WebKit.
- Clicks through the HID event stream work only when Detour is frontmost, so each test stole focus and moved the user's pointer while they were working, and focus kept slipping mid-run.
- A context-menu item never responded to synthetic clicks.
- Reduce Motion is a protected system-wide setting.
- System Events 'click at' performs an accessibility press, not a mouse event, which misled a click-point test (TASK-324 notes).
- A clipboard-based check risked the user's clipboard.
Earlier, on TASK-86, many interaction checks were handed to the user although each was doable in-process (TASK-89).

Scope of this slice:
- A local MCP endpoint (HTTP on localhost) that this agent can call with curl and that Claude Code can register as an MCP server.
- Input is posted inside the app (NSApp.postEvent / NSWindow.sendEvent), so nothing comes to the front and the user's pointer never moves.
- Tools for state, input, menus and screenshots.
The rest of TASK-228 (fuller authorisation and connection UI, Private windows, CDP coverage, tools for tabs no window owns) stays open there, but this slice must not ship a Release endpoint that is reachable without the user turning it on.

Known in-process techniques (from TASK-89 and the wiki playbooks):
- evaluateJavaScript el.click() goes through real link activation.
- Synthesized NSEvents through NSApp.postEvent; WindowDragView's tracking loop aborts with window.sendEvent from a Task.
- Key equivalents via NSApp.mainMenu.performKeyEquivalent.
- NSApp.appearance for dark mode.
- contentView.cacheDisplay for web content, and tabSidebar.view.layer.render for the sidebar (cacheDisplay leaves the sidebar blank).
- A locked screen blocks paint and events.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Over a localhost MCP endpoint a client can list windows, spaces and tabs (selection, URL, title), select a tab, open a URL, and run a menu action or key equivalent
- [ ] #2 A client can click, modifier-click, right-click and type at a point in a window, or on an element of a tab by CSS selector, without the app coming to the front or the real pointer moving
- [ ] #3 A client can list the items of an open menu (including a web page's context menu) and choose one
- [ ] #4 A client can take a PNG of a window's content and of its sidebar, switch light or dark, and set Debug overrides (at least Reduce Motion and the space toss's hop and gravity)
- [ ] #5 The /verify skill and the runtime-verification playbook show how to use it, replacing the paste-a-harness-into-AppDelegate approach
- [ ] #6 Demonstrated end to end with no manual steps by re-running the TASK-324 checks that needed a human: Download Linked File, a download in a split pane, with the sidebar hidden, and with Reduce Motion
- [ ] #7 Off until turned on: in Release the endpoint does not listen until the user enables it (a setting, off by default, listening on localhost only); a test run can enable it only with an isolated DETOUR_DATA_DIR; Private windows are not reachable
- [ ] #8 The testing-only tools (Debug overrides such as Reduce Motion) are absent from Release builds (verified on the built product)
- [ ] #9 Tests cover the gate (not listening while off; the test-run switch refused without an isolated DETOUR_DATA_DIR; a Private window refused) and each tool's happy path and error cases (unknown window or tab, no open menu, a selector that matches nothing)
- [ ] #10 While a client is connected, Detour shows that an agent is connected (visible in every browser window without opening Settings) and the user can disconnect it from there; the indicator goes away when the last client disconnects
- [ ] #11 Tools that act on page content (input by selector, screenshots of web content) address a target context through an identifier that can later name an extension popup, options page, side panel or service worker, not only a tab. This way TASK-228.2 adds context kinds without changing existing tool signatures
- [ ] #12 Every tool declares an outputSchema and returns structuredContent (JSON) alongside any text, and failures carry a stable machine-readable error code (for example unknown_window, unknown_context, selector_no_match, no_open_menu, timeout, gate_closed) that tests assert on
- [ ] #13 A minimal client in the repo (a scripts/ CLI or small module) performs the MCP handshake and session header and calls any tool with JSON arguments, printing the structured result. Scripts, /verify and an external test repo can drive the endpoint with no model in the loop
- [ ] #14 Authorisation: every request needs the bearer token Detour generates (Release: shown in Settings with a reset that disconnects clients; test run: written to a file in the isolated DETOUR_DATA_DIR) and is refused with a non-local Origin header; an unauthenticated request gets a plain 401 with no OAuth metadata, so an OAuth-only client fails clearly. Tests cover a missing or wrong token and a foreign Origin
- [ ] #15 A stdin/stdout helper bundled in the app (for example Detour.app/Contents/Helpers/detour-mcp) finds the running Detour's port and token itself and relays to the HTTP endpoint, so Claude Desktop and any other local MCP client connect with one command line and never handle the token
- [ ] #16 Client compatibility: the endpoint accepts the last few MCP protocol versions at initialize; the text result of every tool carries the same JSON as structuredContent; input schemas are flat objects with basic types (no $ref, oneOf or unusual formats) so OpenAI and Gemini models accept them; screenshot tools take a save_to path as well as returning an image; related actions share one tool (for example one click tool with a modifiers argument) to keep the tool list small
- [ ] #17 Several clients can be connected at once: the connected indicator lists them by the name each sends at initialize, and each can be disconnected separately
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Phases (each committed separately; user agreed 2026-11-13):
1. Connection and access (ACs 1, 7, 9, 11-14, 16): localhost HTTP + MCP, gate, token + Origin/Host checks, first tools, scripts/ client.
2. Input and menus (ACs 2, 3).
3. Screenshots, appearance, Debug overrides (ACs 4, 8).
4. Connected indicator, Settings toggle, bundled stdin/stdout helper (ACs 10, 15, 17).
5. /verify + playbook, TASK-324 checks end to end (ACs 5, 6).

Phase 1 design:
- Detour/Automation/ (new). Pure, nonisolated pieces: JSONValue; HTTP/1.1 request parser (Content-Length and chunked bodies, keep-alive, 4 MB cap) and response writer; request authorisation (Host must be 127.0.0.1/localhost/[::1] on our port, Origin absent or local, Authorization: Bearer <token> compared in constant time; 401 carries WWW-Authenticate: Bearer realm="Detour" and no resource_metadata); the gate (off unless the Release setting is on, or DETOUR_MCP=1 with DETOUR_DATA_DIR set and not the default directory).
- Endpoint: NWListener on 127.0.0.1 only (loopback interface, acceptLocalOnly), state behind a Mutex, each parsed request handed to the main actor. POST /mcp JSON-RPC (single or batch) answered as application/json; notifications 202; GET 405; DELETE ends the session. Published URL uses 127.0.0.1, never localhost (Node resolves localhost to ::1 first).
- MCP core (@MainActor, no sockets, so it is unit-testable): initialize negotiates 2025-11-25 / 2025-06-18 / 2025-03-26 / 2024-11-05, issues Mcp-Session-Id, records clientInfo per session (for the phase 4 indicator); unknown session 404, missing session 400; MCP-Protocol-Version header checked when present; ping, tools/list, tools/call. Each tool result: structuredContent plus the same JSON as text; failures isError with {error: {code, message}}. outputSchemas list no required top-level fields, so an error result still validates. Input schemas flat (a test walks every schema and rejects $ref/oneOf/anyOf/allOf and non-basic types).
- Files in the data directory, 0600: mcp-token (persistent, so a client config survives relaunch) and mcp-endpoint.json (url, port, pid, token; removed at quit). Test runs listen on an ephemeral port unless DETOUR_MCP_PORT is set.
- Phase 1 tools: list_windows (window_id = NSWindow.windowNumber, which is also the CGWindowID 228.3 needs), list_spaces, list_tabs (favorites, pinned entries live or dormant, normal tabs; split group, sleeping, loading), select_tab (switches the window's space when needed; wakes dormant pinned/favorite entries the way a sidebar click does), open_url (the palette's typed-URL path, so Link Routes and internal pages behave as typed), run_menu_item (menu path or key equivalent; action dispatched to the given window's responder chain and validated there, because an inactive app has no key window). Private windows and spaces are left out of the lists and refused by ID (private_unreachable).
- Context identifiers (AC 11): tab:<uuid> now; the parser has room for popup:/options:/sidepanel:/worker:<extension id> in 228.2.
- scripts/detour-mcp: Python 3 stdlib CLI (initialize, notifications/initialized, tools/list, tools/call with JSON args) that reads mcp-endpoint.json from the DETOUR_DATA_DIR directory.
- Tests: parser, authorisation, gate, MCP core (negotiation, sessions, schema flatness, error shapes), tools against real BrowserWindowControllers (happy paths, unknown window/tab, private refusal, dormant pinned), endpoint over a real socket (401, foreign Origin 403, bad Host 403, initialize + tools/call, unknown session 404).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14, user decision: the 'agent connected' indicator, with a way to disconnect, ships in this first slice (moved from TASK-228's AC #3), since Release users can turn the endpoint on.

2026-11-14: TASK-228.2 (extension testing tools for an external compatibility suite) builds on this endpoint. AC #11 was added so the targeting model here does not have to be reworked there.

2026-11-14, user decision: the endpoint must serve deterministic scripts as well as agents. Regression runs replay scenarios without spending tokens, and an agent only writes new scenarios and diagnoses failures. MCP stays the single surface; there is no separate REST API. WebDriver/BiDi and AppleScript (TASK-319) were considered and rejected for this use: WebDriver is a large spec for little gain, and AppleScript handles structured results and async poorly. ACs #12 and #13 were added. The scenario format and runner belong in the external test repo, not in Detour.

2026-11-13, user discussion (agreed): authorisation is a bearer token plus an Origin check, not localhost alone (any local process, and a web page using DNS rebinding, can reach a localhost port). Threat model: the token stops web pages and local programs that cannot read the user's files (sandboxed apps, other accounts); it does not stop malware running as the user, which could read the token file anyway. Claude Code connects directly (claude mcp add --transport http ... --header 'Authorization: Bearer ...'); Claude Desktop's config only launches stdin/stdout servers and its connectors run in the cloud, so it needs the bundled helper (AC #15), which also spares Claude Code users the token. Client survey (from memory, to re-check against each client's docs before writing setup instructions): Cursor, VS Code, Windsurf, Gemini CLI and Cline take a local HTTP URL with headers; Codex CLI, Zed, Goose and LM Studio vary; every local client can launch a helper; claude.ai, ChatGPT and cloud agents cannot reach localhost (out of scope, recorded on TASK-228). ACs #14-#17 added.

Indicator placement (proposed, not yet confirmed by the user): a small badge at the top of the sidebar, with a titlebar fallback when the sidebar is hidden, and Disconnect in its menu.
<!-- SECTION:NOTES:END -->
