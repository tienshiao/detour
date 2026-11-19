---
type: Component
title: Local server suggestions
description: How the command palette and the Quick Detour launcher offer the HTTP and HTTPS servers running on this Mac with the folder each one serves from - the libproc scan, which listeners count as a project's server, the HTTP/HTTPS probe and its cache, what typed text matches, and how a running server joins the tab and history rows.
resource: ../../Detour/Browser/CommandPalette/LocalServerScanner.swift
tags: [command-palette, quick-detour, localhost, libproc, network]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-19T21:45:00Z }
sources:
  - id: scanner
    resource: ../../Detour/Browser/CommandPalette/LocalServerScanner.swift
    title: LocalServerScanner.swift (scan, libproc listing, probe, LocalServerDirectory)
  - id: rules
    resource: ../../Detour/Browser/CommandPalette/LocalServers.swift
    title: LocalServers.swift (LocalServerRules)
  - id: provider
    resource: ../../Detour/Browser/CommandPalette/SuggestionProvider.swift
    title: SuggestionProvider.swift (localSuggestions, serverRows, serverTopHit)
  - id: palette-view
    resource: ../../Detour/Browser/CommandPalette/CommandPaletteView.swift
    title: CommandPaletteView.swift (startLocalServerScan, localServersDidArrive)
  - id: task-411
    resource: backlog:TASK-411
    title: "Command palette: suggest the HTTP servers running locally with the directory each one serves from"
---

# Role

Typing `localhost`, a port or a project's folder name in the
[command palette](./command-palette.md) or the
[Quick Detour launcher](./quick-detour-launcher.md) offers the web servers
running on this Mac, each with the folder it was started from
(TASK-411).[^task-411] They are a fourth source next to open tabs, history
and search suggestions in the [suggestion pipeline](./suggestion-pipeline.md).

# How it works

## The scan

`LocalServerScanner.scan()` runs off the main thread:

1. **List listeners** with libproc: `proc_listpids(PROC_UID_ONLY, getuid())`
   (the user's own processes only), each one's file descriptors
   (`PROC_PIDLISTFDS`), and for each socket `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`;
   a TCP socket in `TSI_S_LISTEN` gives its port (`insi_lport`, big-endian)
   and bound address. `proc_pidpath` gives the executable and
   `PROC_PIDVNODEPATHINFO` the working directory. Detour is not sandboxed,
   so this needs no entitlement. About 10 ms on the user's Mac.
2. **Filter** (`LocalServerRules.isProjectServer`): a working directory that
   is neither empty nor `/`; an executable not under `/Applications`,
   `~/Applications` or `/System` (except a toolchain inside an app's
   `Contents/Developer`, such as Xcode's `python3`); a port below the dynamic
   range (49152-65535); and a bound address localhost reaches (any address or
   loopback, not a LAN address alone). Detour's own listeners are never
   offered.
3. **One candidate per port**, the lowest pid (the parent of forked workers),
   so the label is stable between scans.
4. **Probe** each candidate (below) in a task group; offer those that
   answered HTTP or HTTPS.

The scan also returns `listeningPorts`: every listening port, filtered or
not, Detour's own included. History rows on a loopback port in that set are
"live"; others are demoted (below).

## Which listeners count

The filter was measured against what was listening on the user's Mac on
2026-11-18. Kept: `node` servers started from project folders and a tool run
from `~/Projects`. Left out: Control Center's AirPlay ports (5000, 7000),
Discord, Stream Deck and editor helpers (started from `/`), Docker's port
forwards and Tailscale (installed apps), Claude Code's IDE bridges (dynamic
ports).

"Installed app" means under the app folders, not "inside any `.app`":
Homebrew's and the system's Python run from a `Python.app` inside their
framework, and with Xcode selected `/usr/bin/python3` runs from
`/Applications/Xcode.app/Contents/Developer/.../Python.app`. Both must still
count for `python3 -m http.server`.

Known gap: a server in a Docker container is never offered, since Docker's
backend owns its port.

## The probe

`LocalServerScanner.probe` opens two raw `NWConnection`s to the loopback
address at once, restricted to the loopback interface, each sending
`HEAD / HTTP/1.1`:

- one over TLS with a verify block that accepts any certificate (dev
  servers sign their own, and the connection cannot leave loopback);
- one plain.

A reply starting `HTTP/` counts. TLS answering wins (many HTTPS servers
answer a plain request with a 400), then the plain answer. Results are
cached per (pid, port, address): a definite answer (`https`, `http`,
`notHTTP`) once, so reopening the palette costs no connections; a restart is
a new pid and is probed again; entries for listeners that went away are
pruned. A **timeout is not cached** (`noAnswer`), and neither is a TLS
handshake that completed but whose request timed out: an HTTPS dev server
compiling its first page would otherwise be cached as HTTP or not-HTTP for
its life. A TLS attempt that times out *before* its handshake is a plain
HTTP server waiting for bytes it cannot read, not a slow HTTPS one (a
loopback handshake takes milliseconds), so the plain answer decides. The
timeout is 800 ms.

## Sharing the scan

`LocalServerDirectory.shared` (main actor) keeps the last scan and the scan
in flight. A palette's `show()` uses the last scan at once and starts a
refresh; palettes opened together join one scan. Under XCTest `.shared`
uses an inert scanner, so suites never see the machine's servers.

## What typed text matches

`LocalServerRules.match(_:servers:home:)`, on the trimmed field text:

| Text | Servers | Completes the field |
|---|---|---|
| a prefix of `localhost` (from `loc`), then `:` and a port prefix | ports with that prefix | yes, to `localhost:<port>` |
| a prefix of `127.0.0.1` (from `127.`), then a port prefix | IPv4 servers only (`::1`-only ones cannot be reached) | yes |
| a prefix of `0.0.0.0` (from `0.0.`) and a port prefix | ports with that prefix; rows open `localhost` | no |
| digits alone, up to five (`51`) | ports with that prefix | no |
| two or more letters starting the folder's last component or one of its `-_. ` words (`web`, `site` for `my-site`) | those servers | no |
| anything with whitespace | none | |

Results are ordered with an exact port first, then ascending. Text that only
lists servers puts them after the verbatim row, so Return still does what the
text alone does (`51` searches, `website` searches); Down picks a server.

## Joining tabs and history

Rank for local input: open tab > running server > history
(`localSuggestions`):

- **Top hit**: the tab top hit if any; else, when completing,
  `serverTopHit` (completion `host:port`); else history. A server top hit
  is the server's own row, even for a server that was visited before.
- **A visited server** is shown once, as its tab or history row with the
  folder after the address; `serverRows` adds a row of its own (at most four)
  only for ports no listed tab or history row covers. A history row counts as
  covering only if it fits under the 12-row cap.
- **Dead ports**: host and history rows on a loopback port not in
  `listeningPorts` sink below the live ones, keeping their order
  (`stablyDemoting`). With no scan yet, nothing is demoted.
- **Folder names** also match open tabs on that server's port.

Rows stay one line. A server row's title is its directory (`~` for home,
truncated in the middle) with `localhost:<port> · <process>` on the right;
history rows show `· <folder>` after the address and tab rows show
`<folder> · Switch to Tab`. The folder is the shortest trailing path that
tells the running servers apart (`website`, or `client/website`);
`folderLabels`. In the launcher the space chip stays as it is.

## A scan that lands late

`localServersDidArrive` sets the new servers, refreshes the folder text of
the rows on screen, and reruns the background pass as a late pass
(`PaletteRows.latePassOutcome`, so an arrowed selection never moves). A
server may take the top hit only if the field has no inline completion yet,
or its completion came from a server row. In such a pass the field's
completion follows the new top row while the user has not arrowed, so the
field never shows one address while Return opens another.

# Gotchas

- `PROC_PIDPATHINFO_MAXSIZE` is a macro Swift does not import; the buffer is
  `4 * MAXPATHLEN`.
- The scan must not count Detour's own listeners as servers (the automation
  endpoint, test fixtures), but their ports still belong in `listeningPorts`.
- Passing digits to `scripts/detour-mcp call open_ui text=8765` makes the CLI
  send a number; pass JSON (`'{"what":"quick_detour_launcher","text":"8765"}'`).
- The launcher panel takes key focus while `open_ui` drives it: a person
  typing elsewhere types into it. Keep such runs short and stop the app after.

# Tests

- `LocalServerRulesTests`: the filter table (Python.app, Xcode's python,
  dynamic boundary), candidates, labels, `loopbackPort`, match tables.
- `LocalServerScannerTests`: the real libproc listing and probe against a
  loopback HTTP fixture and a not-HTTP listener, a closed port, the shared
  directory, the probe cache (once, timeouts retried, a new pid reprobed),
  Detour's own listeners.
- `LocalServerSuggestionTests`: provider order, dead-port demotion, folder
  matches, Return in the palette, a late scan, an arrowed selection, a
  history row cut by the cap.

Runtime: `open_ui quick_detour_launcher` returns `local_server` rows (url,
directory, process, folder) and a history row's `folder`
([Automation endpoint staging](./automation-endpoint-staging.md)).

# Related

- [Suggestion pipeline](./suggestion-pipeline.md) - the other sources and the two passes.
- [Command palette](./command-palette.md) - the view, Return and the late pass.
- [Quick Detour launcher](./quick-detour-launcher.md) - the launcher shows the same rows.

[^task-411]: Command palette: suggest the HTTP servers running locally with the directory each one serves from
