---
id: TASK-411
title: >-
  Command palette: suggest the HTTP servers running locally, with the directory
  each one serves from, when typing localhost
status: To Do
assignee: []
created_date: '2026-11-19T05:55:00Z'
updated_date: '2026-11-19T06:44:00Z'
labels:
  - command-palette
  - dev-mode
  - feature
dependencies: []
priority: medium
ordinal: 492000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-11-18. When typing `localhost` (or `localhost:5`, `127.0.0.1`…) in the command palette, the only suggestions today come from history, open tabs and web search, so a dev server that was started for the first time, or on a new port, has to be typed out in full, and with several servers running it is hard to remember which port belongs to which project. A new suggestion source lists the HTTP/HTTPS servers listening on this Mac right now, each labelled with the working directory of the process serving it (the project it belongs to), e.g. `localhost:5173 — ~/Projects/website (node)`.

Context for the worker:
- Detour is not App Sandboxed (`Detour/Resources/Detour.entitlements` has no app-sandbox key), so it can enumerate the current user's processes, their listening TCP sockets and their working directories through libproc (`proc_listpids`, `proc_pidinfo` / `proc_pidfdinfo`) without shelling out to `lsof`. Other users' and root processes are not readable and are out of scope.
- A listening port is not necessarily HTTP (Postgres 5432, Redis 6379, Detour's own MCP endpoint, Xcode helpers…): only servers that actually answer HTTP should be listed.
- Related: TASK-83 (`AddressInputClassifier`: localhost/IP input navigates over http://), TASK-186 (dev mode, local-development URL rule), TASK-409 (Quick Detour launcher shares the suggestion pipeline; decide whether it gets this source too).

Decisions (user, 2026-11-18): the source also triggers on a bare port and on `127.` / `0.0.0.0` input; HTTPS is detected by probing; the Quick Detour launcher shows these rows too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Listening ports that do not answer HTTP (e.g. a database) are not listed; servers owned by other users are not listed
- [ ] #2 Choosing a row navigates to that server's URL with the scheme it answered on, both in new-tab and navigate-in-place modes
- [ ] #3 Discovery and probing run off the main thread with short timeouts; typing in the palette never waits for them, and rows appear when the scan finishes
- [ ] #4 A server already shown as an open tab or history row for the same host:port is not duplicated; the local-server row ranks where it is useful for the typed text
- [ ] #5 Matching, ranking, de-duplication and row formatting are pure functions with unit tests; discovery sits behind a protocol so tests use a fake list of servers, and one test runs a local fixture HTTP server and a non-HTTP listener to check the real scan
- [ ] #6 Checked at runtime with /verify: two dev servers in different directories appear with the right directories, and a non-HTTP listener does not
- [ ] #7 Typing a prefix of `localhost`, `localhost:` or `127.` / `0.0.0.0` followed by a port prefix, or a bare port prefix (e.g. `51`), shows one row per matching local server that answers HTTP, with host:port, the serving process's working directory (home abbreviated to ~) and process name
- [ ] #8 Each server is probed for HTTPS as well as HTTP (self-signed dev certificates count as HTTPS); its row shows and opens the scheme it answered on
- [ ] #9 The Quick Detour launcher shows the same local-server rows, and choosing one opens it like its other rows
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-11-18): bare port and 127./0.0.0.0 input also trigger the source; HTTPS is detected by probing; Quick Detour gets the rows too. A bare-port trigger must not stop a plain number from searching on Enter when no server matches (AddressInputClassifier rules from TASK-83 stand).
<!-- SECTION:NOTES:END -->
