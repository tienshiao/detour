---
id: TASK-411
title: >-
  Command palette: suggest the HTTP servers running locally, with the directory
  each one serves from, when typing localhost
status: Done
assignee:
  - '@claude'
created_date: '2026-11-19T05:55:00Z'
updated_date: '2026-11-19T21:33:00Z'
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
- [x] #1 Listening ports that do not answer HTTP (e.g. a database) are not listed; servers owned by other users are not listed
- [x] #2 Choosing a row navigates to that server's URL with the scheme it answered on, both in new-tab and navigate-in-place modes
- [x] #3 Discovery and probing run off the main thread with short timeouts; typing in the palette never waits for them, and rows appear when the scan finishes
- [x] #4 Matching, ranking, de-duplication and row formatting are pure functions with unit tests; discovery sits behind a protocol so tests use a fake list of servers, and one test runs a local fixture HTTP server and a non-HTTP listener to check the real scan
- [x] #5 Checked at runtime with /verify: two dev servers in different directories appear with the right directories, and a non-HTTP listener does not
- [x] #6 Each server is probed for HTTPS as well as HTTP (self-signed dev certificates count as HTTPS); its row shows and opens the scheme it answered on
- [x] #7 The Quick Detour launcher shows the same local-server rows, and choosing one opens it like its other rows
- [x] #8 Typing a prefix of `localhost`, `localhost:` or `127.` / `0.0.0.0` followed by a port prefix, or a bare port prefix (e.g. `51`), offers every matching local server that answers HTTP, following the row and ranking rules below
- [x] #9 Local history rows whose origin has no running server rank below rows for running servers; they are not hidden
- [x] #10 For local-address input the top hit and inline completion prefer an open tab, then a running server, then history: `localhost:51` completes to a running `localhost:5173`, not to a history port that is no longer running
- [x] #11 Typing part of a running server's folder name (e.g. `website` for ~/Projects/website) matches its tab, history or server row, even without `localhost` in the text
- [x] #12 The scan starts when the palette or Quick Detour opens and its result is reused while it stays open; a result that lands late adds folder labels without moving rows, and never changes rows under a selection made with the arrow keys (`PaletteRows.latePassOutcome`)
- [x] #13 A running server attaches to the open tab or history row for the same origin (scheme, host, port) that is listed: that row shows the folder, and no separate server row is added. A server gets a row of its own only when no listed tab or history row covers its port. When the field completes to a running server (localhost/127.0.0.1 input), row 0 is the server row, titled with its directory, even if the server was visited before (user choice 2026-11-19, replacing 'the history row with the folder')
- [x] #14 Rows stay one line (36 pt, six visible rows, TASK-184). The folder is grey text, not a chip: the shortest trailing path that tells the running servers apart (website, or client/website when two share a name). History rows show it after the address (localhost:5173 · website), tab rows before Switch to Tab. A server's own row is titled with its full directory (~ for home, truncated in the middle) and shows localhost:port · process on the right (user choice 2026-11-19). Quick Detour's space chip stays as it is
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Scanner (nonisolated, Sendable), three steps: enumerate the user's TCP listeners through libproc (pid, port, bound address, executable, cwd); probe each one once with a raw NWConnection (TLS with loopback-only certificate acceptance, then plain HEAD; "HTTP/" in the reply counts), caching the result by pid, port and bound address so only the enumeration reruns; then filter. The pid exclusion is a parameter so tests can scan the test host's own fixture server. Prototype the libproc code as a standalone swiftc script first and check it against lsof.
2. Pure rules (LocalServerRules, table-tested): which listeners count as project servers (cwd not /, executable not inside an .app bundle, port outside the dynamic range 49152-65535; on this Mac that keeps the two node servers and codetoaster and drops ControlCenter, Discord, Stream Deck, Docker, Tailscale and claude); one server per port, picked deterministically; folder labels (shortest trailing path that tells the servers apart, ~ for home); query matching (prefixes of localhost: / 127.0.0.1: complete inline; bare port, 0.0.0.0 and folder name only list rows after the verbatim row, so Return still searches); loopback port of a URL.
3. LocalServerDirectory (main actor): keeps the last scan, coalesces scans, started when a palette shows (window palettes and the Quick Detour launcher).
4. SuggestionProvider: localSuggestions takes a Sendable server snapshot; serverTopHit and the folder-port tab match are static, so the instant pass and the background pass share them. Order for local input: open tab, then running server, then history. Server rows only for ports no tab or history row covers; history rows for local ports with nothing running go last.
5. New SuggestionItem.localServer case: activate, display text, PaletteRows.url(of:), automation palette output (kind and folder).
6. View: folder labels in a side table keyed by port; when a scan lands, visible cells are reconfigured explicitly and the background pass runs again as a late pass (server top hit only while nothing has completed the field and the selection has not moved). History rows show "address · folder" (middle truncation), tab rows show the folder before Switch to Tab, server rows show the directory as title and "localhost:port · process" as the address.
7. Tests: rules, provider order and dedupe (including 51 + Return and website + Return still searching), the view's late-scan path, and one real scan over LoopbackHTTPServer plus a non-HTTP listener. Then /verify through the MCP palette tool against the dev servers running on this Mac; demo before committing.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-11-18): bare port and 127./0.0.0.0 input also trigger the source; HTTPS is detected by probing; Quick Detour gets the rows too. A bare-port trigger must not stop a plain number from searching on Enter when no server matches (AddressInputClassifier rules from TASK-83 stand).

User, 2026-11-18: running servers merge into the existing tab/history rows rather than competing as a separate list (ranking ACs); folder-name matching is in scope; rows stay one line and the folder never replaces Quick Detour's space chip (it is text beside the address, the chip says where the page was visited, the folder says what runs on the port now). Ports get reused across projects, so a history title for localhost:3000 may name another project; saving the folder with local visits is a possible follow-up, out of scope here.

2026-11-18 build 1 (uncommitted, awaiting the user's look):
- Scanner: libproc enumeration matches lsof exactly, 9 ms for ~1000 processes. Probe = raw NWConnection, TLS (any cert, loopback only) and plain HEAD at once, cached per pid/port/address.
- Filter decision: cwd not /, executable not under /Applications, ~/Applications or /System, port below 49152. A plain ".app/Contents/" rule was rejected because Homebrew and system python3 run from Python.app, which would hide python -m http.server.
- Known gap: servers in Docker containers (their forwards belong to com.docker.backend in /Applications) are not offered.
- Server rows: title = abbreviated directory (middle truncation), address = "localhost:port · process". This departs from AC #14's wording (folder after the address) because the title has the room for the whole directory.
- Tests: LocalServerRulesTests 17, LocalServerSuggestionTests 23, LocalServerScannerTests 3, all passing, plus SuggestionProviderTests, PaletteRowsTests, PaletteCommandRowsTests, SiteSearchPaletteTests, QuickDetourCrossProfilePaletteTests and QuickDetourLauncherTests (157 total, 0 failures).
- Runtime (DETOUR_MCP, launcher): node 3000/3002, codetoaster 4000, python 8765 and a self-signed https 8443 offered with the right folders; ControlCenter, Docker, Discord, Stream Deck and claude ports absent; 127.0.0.1:30 left out the ::1-only server; bare port and folder name kept the verbatim row first; a visited server became one history row with its folder.
- Screenshot showed server-row titles cut at the end and the address squeezed; fixed (middle truncation, address keeps its width) but the fix is not yet seen on screen. The launcher panel takes keyboard focus, so captures picked up the user's typing; stopped.

2026-11-18 build 2 (after an advisor review):
- A history row is "not running" only when nothing listens on its port. The check now uses every port the user's processes listen on, not the offered servers, so a Docker forward is not demoted.
- A plain-HTTP timeout is not cached (asked again on the next scan); definitive answers are cached per listener.
- LocalServerDirectory.shared is inert in the XCTest host (NoLocalServers).
- Full suite: 5080 tests, 25 skipped, 1 failure: AutomationPageTests.testEvaluateTimesOutAndRefusesBadArguments (script_error vs timeout). It passed 14/14 when its suite was rerun alone, so it looks load-related and unrelated.
- Not verified: the window palette (Cmd+T/Cmd+L) and the open-tab "folder · Switch to Tab" text were never driven at runtime; the server-row truncation fix has not been seen on screen.

Code review (/code-review --fix, 2026-11-19): 6 findings, all fixed. (1) A late scan could change row 0 while the field kept a server completion, so Return opened something else; now the field's completion follows the new top row while the user has not arrowed. (2) Xcode's /usr/bin/python3 runs from /Applications/Xcode.app/Contents/Developer and was filtered as an installed app; toolchains under .app/Contents/Developer now count. (3) A slow HTTPS server (handshake done, request timed out) was cached as HTTP or not-HTTP; it is now noAnswer and probed again. (4) A history row cut by the 12-row cap no longer hides the server's row. (5) Detour's own ports count as listening. (6) folderLabels no longer traps on duplicate ports. Two new tests. Known gap: command rows inserted later by PaletteRows can still push the covering history row off the list.
Tests after the fixes: 18 palette, launcher and local-server suites, 266 tests, 0 failures (LocalServerRulesTests 17, LocalServerScannerTests 7, LocalServerSuggestionTests 26, SuggestionProviderTests 34, plus the palette, launcher and staging suites). The earlier full suite: 5080 tests, 1 failure (AutomationPageTests.testEvaluateTimesOutAndRefusesBadArguments, script_error vs timeout), which passed 14/14 when run alone, so it looks load-related.
/verify after the fixes (DETOUR_MCP=1, launcher via open_ui, the app stopped right after): a /usr/bin/python3 http.server in a py-site folder was offered (process Python, the Xcode fix); localhost listed marbi-api 3000 as the top hit, marbi-web 3002 and codetoaster 4000, and the visited 8765 once as its history row with folder py-site; 8765 and py-s listed it after the verbatim row. Not verified on screen: the browser-window palette (Cmd+T/L), tab rows' folder · Switch to Tab text, and middle truncation of long directory titles. The endpoint has no browser-palette tool, and the launcher panel takes key focus.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The command palette and the Quick Detour launcher now offer the HTTP and HTTPS servers running on this Mac, with the folder each one serves from. LocalServerScanner lists the user's TCP listeners with libproc and keeps project servers: started from a folder, not an installed app, on a port below 49152, reachable from localhost. It probes each one over TLS and plain HTTP at once, caching definite answers per pid and port. LocalServerDirectory shares the scan between palettes. Typing localhost, 127.0.0.1, 0.0.0.0, a bare port or a folder name matches. Rank is open tab > running server > history: a running server can complete the field, joins its tab or history row as grey folder text, and gets its own row (directory title, localhost:port · process) only when no listed row covers it. History rows on ports nothing listens on sink. A late scan reruns the pass without moving an arrowed selection. Tests: 48 new across three suites (50 after the review); 266 in the 18 affected suites pass. Runtime-checked in the launcher. Not seen on screen: the browser-window palette, tab-row folder text, long-path truncation. Gaps: Docker containers aren't offered; command rows can push a covering history row past the cap. Wiki: features/local-server-suggestions.
<!-- SECTION:FINAL_SUMMARY:END -->
