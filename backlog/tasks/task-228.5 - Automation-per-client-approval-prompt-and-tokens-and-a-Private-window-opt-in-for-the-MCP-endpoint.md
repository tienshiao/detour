---
id: TASK-228.5
title: >-
  Automation: per-client approval prompt and tokens, and a Private-window
  opt-in, for the MCP endpoint
status: To Do
assignee: []
created_date: '2026-11-14T06:26:00Z'
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
