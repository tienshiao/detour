---
id: TASK-228.5
title: >-
  Automation: per-client approval prompt and tokens, and a Private-window
  opt-in, for the MCP endpoint
status: To Do
assignee: []
created_date: '2026-11-14T06:26:00Z'
updated_date: '2026-11-14T09:27:00Z'
labels:
  - tooling
  - automation
  - security
dependencies:
  - TASK-228.1
references:
  - wiki/features/automation-endpoint.md
parent_task_id: TASK-228
priority: medium
type: feature
ordinal: 398000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Split from TASK-228 AC #3 on 2026-11-13. TASK-228.1 gave one shared bearer token, a Disconnect that blocks a client by the name it reports (a 'please stop', not a revocation), and no route to Private windows.

Two parts:
1. Per-client authorisation (user decision 2026-11-14): a new client gets an 'X wants to control Detour: Allow / Deny' prompt in Detour's own UI, and Allow gives that client its own token. Disconnect revokes that token. Settings lists the approved clients, with Revoke. Open design questions for the user:
   - (a) Is the prompt delivered through MCP's OAuth flow? Detour would be a local authorisation server (metadata discovery, dynamic client registration, PKCE, /authorize showing the native prompt and redirecting back), so OAuth-only HTTP clients connect without copying a token. Or through a plain token request that the bundled stdio helper makes (POST to the endpoint with the client's name; the prompt; the token is kept for that client)? A system-picked port per launch (user decision) breaks OAuth clients configured with a URL unless the helper is used anyway.
   - (b) What happens to the shared token in mcp-token: kept for scripts and test runs (DETOUR_MCP=1 never prompts), or replaced?
   - (c) Where the helper keeps its per-client token.
2. Private windows: off by default; a setting the user turns on makes Private windows and spaces reachable (listing, page tools, input, menus). Turning it off ends access at once.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With automation on, a new client's first connection shows Detour's own Allow / Deny prompt naming the client; Deny refuses it, Allow gives it a token of its own
- [ ] #2 Disconnect (indicator) and Revoke (Settings, which lists approved clients) invalidate that client's token at once; other clients keep working
- [ ] #3 Test runs (DETOUR_MCP=1 with an isolated DETOUR_DATA_DIR) and scripts/detour-mcp keep working without a prompt
- [ ] #4 Private windows and spaces stay unreachable unless the user turns on a setting that allows them; turning it off refuses them again at once
- [ ] #5 The chosen design and the rejected alternatives are recorded here and in the wiki automation page; tests cover approval, denial, revocation, the Private opt-in on and off
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Design (lead, 2026-11-14), following the user's decisions (helper requests, shared token for test runs only, Private opt-in):

Modes:
- Test run (DETOUR_MCP=1 with an isolated DETOUR_DATA_DIR): unchanged. One shared token in mcp-token, written into mcp-endpoint.json, no prompt. scripts/detour-mcp and the harnesses keep working.
- The user's setting: per-client tokens only. mcp-endpoint.json carries url, port and pid, never a token. The shared token is not accepted. At start in this mode the endpoint deletes a leftover mcp-token. Settings drops Copy Token / Copy URL and keeps the helper setup commands.

Approval flow (user mode):
1. The helper reads mcp-endpoint.json. On the client's initialize it takes clientInfo.name (and title, version) and looks for its saved token for that name. Location: <data dir>/mcp-clients/<sha256 of the name>.token, 0600, in a 0700 directory. That is the same threat model 228.1 accepted for mcp-token (malware running as the user is out of scope). Keychain was rejected for now: ad-hoc-signed Debug helpers change their keychain ACL identity at every build, and test runs would prompt.
2. With no token, the helper sends POST /mcp/authorize {client_name, client_title?, client_version?} with no bearer. The Host and Origin checks still apply, and the body is capped small.
3. Detour shows its own non-modal panel. A modal alert on the main queue froze the endpoint (wiki trap), and an app-modal alert in a background app goes unseen. The panel says '“<name>” wants to control Detour', what that allows, and that the name is the client's own. It has Allow and Deny, and Detour bounces the Dock with requestUserAttention. The HTTP request is held until the answer, up to 5 minutes (then a deny).
   - One prompt per name at a time: a second request for that name waits on the first.
   - At most 3 prompts at once; beyond that the request is refused at once.
   - A name denied within the last 10 minutes is refused without a prompt, so a looping client cannot spam prompts.
4. Allow writes a client record {client_id (UUID), name, title, created, last_used, token_sha256} to <data dir>/mcp-clients.json (0600) and answers 200 {token, client_id}. Deny answers 403.
5. Authorisation of /mcp: the bearer's SHA-256 is compared, in constant time, against each record's hash. The matching client_id rides on the request into MCPServer. The session records the client_id, and the indicator shows the approved name, not clientInfo. last_used is updated, coalesced.
6. Disconnect (indicator) and Revoke (Settings) delete the record and end that client's sessions. Further requests with that token get 401, and other clients keep working. The name-blocking 'please stop' of 228.1 goes in user mode; it may stay for test runs or be dropped.
7. The helper on a 401 with its client token deletes its token file. It answers the client with a JSON-RPC error ('Detour revoked this client's access; restart the client to ask again') and does not re-prompt in the same run. The next helper start asks again.
8. Settings > Automation lists approved clients (name, approved, last used) with Revoke, and 'Allow agents to use Private windows'.

Private opt-in:
- An AutomationAllowPrivate key in the data directory's defaults suite, read through AutomationEnvironment (a closure), so every check reads it per call and turning it off refuses at once.
- While on: Private windows, spaces and tabs are listed and reachable by all tools, menus over Private windows are allowed, and page capture installs in Private profiles too; turning it off removes it.
- Extension tools keep refusing the Private profile as an install target. Its contexts follow the opt-in.
- Default off. A test run can turn it on only through the same setting.

Tests:
- AutomationAuthorization with client records: a hash match, no match, a revoked token, a test-run token in user mode refused.
- The authorize endpoint with an injected prompter (allow, deny, timeout, rate limit, concurrent requests for one name).
- The helper requesting, saving and reusing a token, and its revoked-token path (AutomationHelperTests style).
- MCPServer sessions carrying client_id, and Disconnect revoking.
- Private opt-in on and off for list, page, input and menu tools, and the capture install/remove.
- Settings UI checked at runtime with /verify (screenshots), and the panel shown with Detour in the background.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-13, user decisions on the open questions:
(a) The bundled stdio helper requests the token. It asks the endpoint for a token under the client's name, Detour shows its native Allow / Deny prompt, and the helper keeps the per-client token. Local OAuth (discovery, dynamic client registration, PKCE) is not built: a URL-configured client breaks whenever the per-launch port changes, and it adds code and attack surface.
(b) The shared mcp-token stays for test runs only: DETOUR_MCP=1 with an isolated DETOUR_DATA_DIR, plus scripts/detour-mcp against such a run. Without a prompt there. With the user's setting, every client goes through approval, and Settings no longer offers Copy Token.
(c) Private windows: an opt-in setting under Automation, off by default ('Allow agents to use Private windows'). Turning it off refuses them again at once. While it is on, the page capture script also runs in Private pages.
<!-- SECTION:NOTES:END -->
