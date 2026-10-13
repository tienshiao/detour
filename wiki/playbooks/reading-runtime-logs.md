---
type: Playbook
title: Reading runtime logs
description: Unified log recipes for Detour and its WebKit helper processes — categories, predicates, which process logs what, how to read extension console output, and the traps that produce false hits or empty results.
tags: [playbook, logs, extensions, webkit, diagnostics]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-12T23:47:45Z }
sources:
  - id: plan-doc
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan ("Log filters", keep-alive and ITP verification lines)
  - id: polyfill-handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (console bridge, ExtensionConsoleLogPublic)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (keep-alive and connectNative log lines)
  - id: deploy-script
    resource: ../../scripts/deploy-1password-test.sh
    title: deploy-1password-test.sh (--log filter)
  - id: api-explorer
    resource: ../../TestExtensions/api-explorer/background.js
    title: API Explorer background.js (relay probe at worker start)
  - id: task-21
    resource: backlog:TASK-21
    title: Verify the native keep-alive and the WebSocket relay in the signed build
  - id: task-71
    resource: backlog:TASK-71
    title: Which chrome.offscreen implementation runs in the signed build
  - id: task-1
    resource: backlog:TASK-1
    title: 1Password extension log hygiene
  - id: notes-logs
    resource: "Agent session notes, 2026-09-12 (not in the repository)"
    title: Session notes on reading the unified log during harness runs
  - id: notes-signed
    resource: "Agent session notes, 2026-09-21 (not in the repository)"
    title: Session notes on a signed-build verification session
  - id: notes-seeding
    resource: "Agent session notes, 2026-10-03 (not in the repository)"
    title: Session notes on seeding extensions for runtime checks
  - id: notes-1password
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on the 1Password integration
  - id: notes-gpu
    resource: "Agent session notes, 2026-09-28 (not in the repository)"
    title: Session notes on the GPU IOSurface limit
  - id: notes-itp
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on the extension data store and ITP
  - id: task-175
    resource: backlog:TASK-175
    title: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
---

Detour logs through `os.Logger` under the subsystem `com.detourbrowser.mac`,
and WebKit's own lines (subsystem `com.apple.WebKit`) are often the ones
that settle a question. Both are read with the `log` tool. This page says
which category and which process to ask, and lists the ways a query comes
back empty or wrong.

# When to use

Any runtime question about extensions, service workers, native messaging,
tracking prevention or process lifetime; verifying a fix in a running app;
reconstructing what happened in the last few minutes.

# Steps

## 1. Call the tool so that it works

```bash
/usr/bin/log show --last 10m --style compact --info --debug --predicate '<predicate>'
/usr/bin/log stream --level info --predicate '<predicate>' > "$OUT/stream.log" &
```

- Use the full path. Some shells define their own `log` function, which
  fails with "too many arguments".[^notes-logs]
- `log show` and `log stream` refuse to run inside a sandboxed agent shell
  ("Cannot run while sandboxed"). Run them with the sandbox off, and run a
  stream as a background command of that unsandboxed shell.[^notes-itp]
- Put long predicates in a script file. Quoting them inline across shells
  is where most "no results" come from.

## 2. Filter to the right process

A helper's lines forwarded by WebKit (`WebContent[<pid>] …`) are logged
under Detour's pid, so one `processIdentifier == <detour pid>` query shows
the UI process and its web processes together; the GPU and Networking
processes' own lines need their pids.[^task-175]

`process == "Detour"` matches every Detour on the machine: an installed
app, a Debug build started from Xcode, an isolated verification run and
the XCTest host all have that process name and the same bundle id. Filter
by pid instead.[^notes-logs]

```bash
PID=$(pgrep -f "$APP/Contents/MacOS/Detour")      # the build path, not a wrapper's $!
/usr/bin/log show --last 5m --info --predicate "processIdentifier == $PID AND subsystem BEGINSWITH 'com.detour'"
```

## 3. Pick the category

Detour's categories (subsystem `com.detourbrowser.mac`), from the code:

| Category | What it carries |
|---|---|
| `EXT-LOAD` | context load, base URL, background load failures and recovery (`Profile`) |
| `extension-manager` | install/enable, `connectNative` outcomes, every keep-alive line |
| `native-messaging` | host launch, `NM SEND` / `NM RECV` / `NM EOF` / `NM EXIT`, tagged `[1PW-DEBUG]`; message sizes only, never message contents |
| `websocket-relay` | `Relaying a WebSocket for <id>`, `Relayed WebSocket open` / `closed` / `failed` |
| `extension-polyfill` | polyfill requests and the worker console bridge (`[SW <id>] …`) |
| `extension-idle`, `offscreen-host`, `extension-notifications`, `ext-popup`, `extensions`, `module-bundler` | the API of that name |
| `EXT-ITP` | `ITP: logged user interaction for <id> origin <uuid>` |
| `extension-installer`, `extension-updater` | install and update pipeline |
| `profiles`, `storage`, `app` | profile data removal, database errors, launch |
| `gpu-recycle` | GPU process surface counts and recycles |
| `gpu-orphan` | each kill of a GPU process WebKit abandoned (notice) |
| `web-process` | a web process replaced because it never read a load request (notice) |
| `content-blocker`, `InternalPageBridge` | those features |

WebKit lines worth knowing, and who logs them:

| Line | Process | Category |
|---|---|---|
| `SWContextManager::terminateWorker` (message carries the WebContent pid) | Detour | `ServiceWorker`[^notes-logs] |
| `WebPageProxy::close`, `loadServiceWorker`, `workerTerminated` | query both Detour and Networking | |
| `SWServerRegistration::clear`, `runRegisterJob` | `com.apple.WebKit.Networking` | `ServiceWorker` |
| `deleteAndRestrictWebsiteDataForRegistrableDomains … N domainsToDeleteAllScriptWrittenStorageFor` | Networking | `Storage` / `ServiceWorker`, needs `--debug` |
| `[PID=N] WebProcessProxy::updateRemoteWorkerProcessAssertion: workerType=service` | Detour | `ProcessSuspension` |
| `Updating process assertion type to …` | Detour | `ProcessSuspension` |
| `Tab not found for message for content script message` | Detour | `Extensions` (WebKit's, capital E) |
| `per client IOSurface limit` | `com.apple.WebKit.GPU` | `Layers` |
| `GPUProcessProxy::didBecomeUnresponsive: GPUProcess with PID N became unresponsive, terminating it`, `GPUProcessProxy::didFinishLaunching`, `GPU process (…) took N seconds to launch` | Detour | `Process`[^task-175] |
| `Could not signal service com.apple.WebKit.GPU: 1: Operation not permitted` (follows every terminate; the process exits by itself or not at all) | Detour | none (libxpc) |
| `WebContent[pid] GPUProcessConnection::create` / `didInitialize` / `didClose` (a `create` with neither of the others after it is a connection to a process that never answered) | Detour, relayed from the web process | `Process` |
| `WebProcessProxy::didBecomeUnresponsive:` / `didBecomeResponsive:` (the second is also logged whenever the view is hidden, with the process still blocked) | Detour | `Process` |
| `WebPageProxy::reload:`, `stopLoading:`, `didStartProvisionalLoadForFrame`, `updateActivityState: view visibility state changed` | Detour | `Loading`, `ViewState` |

The two filters the plan document keeps:

```bash
log show --last 30m --style compact --info --debug --predicate 'process == "Detour" AND (category == "native-messaging" OR category == "EXT-LOAD" OR (subsystem == "com.apple.WebKit" AND category == "ServiceWorker"))'
log show --last 30m --style compact --info --debug --predicate 'process == "com.apple.WebKit.Networking" AND category == "ServiceWorker" AND (eventMessage CONTAINS "runRegisterJob" OR eventMessage CONTAINS "clear" OR eventMessage CONTAINS "erminat")'
```

## 4. Mind the level

| Level | Stored? | Consequence |
|---|---|---|
| notice, error | persisted | found by `log show` later |
| info | memory only, short-lived | needs `--info`; capture with `log stream --level info` during the session |
| debug | memory only | needs `--debug`; gone soonest |

The keep-alive, relay and console-bridge lines are info level. Detour's
info-level console-bridge lines were seen to age out after about seven
minutes while WebKit's ServiceWorker lines lasted longer;[^notes-logs] the
plan document gives "roughly an hour" for debug-level lines. The two
figures do not agree, so treat both as "not long". During a long hold,
snapshot incrementally. A missing info line in a later
`log show` is not evidence the code did not run: TASK-71 chased exactly
that.[^task-71] When a fix has to be verifiable afterwards, log the
decisive line at notice.[^notes-gpu]

For `--start` / `--end`, use whole seconds. Fractional seconds silently
return nothing.[^notes-1password]

## 5. Read extension console output

A service worker's `console.*` output is forwarded by the
[console bridge](../extensions/console-bridge.md) as
`[SW <extension id>] <text>` in `extension-polyfill`, with the text
**private by default** (it can contain secrets). To read it:

```bash
# one run only, nothing persisted (argument domain):
"$APP/Contents/MacOS/Detour" -ExtensionConsoleLogPublic YES
# or, for an app you cannot pass arguments to; revert afterwards:
defaults write com.detourbrowser.mac ExtensionConsoleLogPublic -bool YES
defaults delete com.detourbrowser.mac ExtensionConsoleLogPublic
```

The flag is read once per launch, so set it before launching. When it is
on, the app logs `Extension console bridge is logging message text
PUBLICLY` at notice. The defaults domain is shared by every Detour on the
machine, isolated runs included.

When the flag was off and the run cannot be repeated, an extension that
keeps its own diagnostics may still tell you: see
[WebKit helper diagnostics](./webkit-helper-diagnostics.md) for reading
text out of an IndexedDB write-ahead log.

## 6. What a healthy keep-alive session looks like

In `extension-manager`, for an extension with a connected native host:[^task-21]

```
Keep-alive port opened for <id>
Keep-alive armed for <id>: 1 native host(s) connected
Keep-alive ping #n sent to <id>
Keep-alive reply #n from <id> (N ms)          ← every 30 s
```

and no `Keep-alive disarmed`, no `terminateWorker`, no
`SWServerRegistration::clear` while the host stays connected. After the
last host disconnects: `Keep-alive disarmed for <id>: no native host
connected`, then WebKit's `WebPageProxy::close` 30 s later.
Background: [native port keep-alive](../extensions/native-port-keep-alive.md),
[service worker unload rules](../platform/service-worker-unload-rules.md).

# Traps

- **A count of 1 is the header.** `log stream` prints its filter as the
  first line of output, so `grep -c <string from the predicate>` returns 1
  with no real hit.[^notes-signed]
- **Keep-alive lines carry no profile name.** Tell workers apart by the
  base URL in nearby lines or by `connectNative from … in profile X`.[^notes-signed]
- **Each line once per profile.** An extension enabled in several profiles
  has a context, a worker and a keep-alive port in each, so harness lines
  come in groups.[^notes-logs]
- **"1 native host(s)" may be a WebSocket.** A relayed WebSocket counts as
  a host for the keep-alive by design; only the wording says "native".[^task-21]
- **`superseded by a newer one` at a reload is expected.** WebKit's unload
  reports no port disconnect, so the old keep-alive port is only noticed
  when the new one opens.[^task-21]
- **API Explorer's relay failures are deliberate.** Its worker probes
  `wss://example.invalid/api-explorer` at every start, which logs
  `hostname could not be found` and a 1006 close.[^task-21]
- **`SWServerRegistration::clear` is not always a purge.** It also appears
  on an ordinary worker unload, followed by `removeContextConnection`.
  Only a clear right after `deleteAndRestrictWebsiteDataForRegistrableDomains`
  is tracking prevention.[^notes-itp] See
  [data store and ITP](../extensions/data-store-and-itp.md).
- **The deploy script's `--log` filter is narrow.** It streams
  `1PW-DEBUG`, `extension-polyfill` and `EXT-LOAD` only; `extension-manager`
  and `websocket-relay` are not in it, and it does not ask for info level.[^task-21]
- **`log stream` on a helper pid** returned nothing in one session; use
  `log show` with a time window for Networking and GPU lines.[^notes-itp]
- **Secrets.** Never log or quote native-messaging payloads; the code logs
  type and size only since TASK-1.[^task-1] After a session with console
  text public, turn the flag off, and purge the log store if the output
  held anything sensitive (`sudo log erase --all`).

# Related

- [Diagnosing extension problems](./diagnosing-extension-problems.md) — what the lines mean.
- [Signed-build verification](./signed-build-verification.md) — a full capture session.
- [WebKit helper diagnostics](./webkit-helper-diagnostics.md) — when the log is not enough.
- [Console bridge](../extensions/console-bridge.md) — where `[SW …]` lines come from and their rate limit.
- [GPU IOSurface limit](../platform/gpu-iosurface-limit.md) — the GPU-process queries.
- [Abandoned GPU process](../platform/abandoned-gpu-process.md) — a timeline reconstructed from the `Process` and `Loading` lines.
- [Hidden web view load stalls](../platform/hidden-webview-load-stalls.md) — reading `ProcessSuspension`.

[^notes-logs]: Session notes on reading the unified log during harness runs
[^notes-signed]: Session notes on a signed-build verification session
[^notes-1password]: Session notes on the 1Password integration
[^notes-gpu]: Session notes on the GPU IOSurface limit
[^notes-itp]: Session notes on the extension data store and ITP
[^task-21]: TASK-21
[^task-71]: TASK-71
[^task-1]: TASK-1
[^task-175]: TASK-175
