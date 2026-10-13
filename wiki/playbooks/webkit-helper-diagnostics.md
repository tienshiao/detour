---
type: Playbook
title: WebKit helper diagnostics
description: How to attribute CPU in a WebKit helper process (Networking, WebContent, GPU) to a site, a service worker or an extension without a debugger, using sample, lsof, the on-disk origin directories and the log.
tags: [playbook, webkit, diagnostics, cpu, indexeddb, extensions]
status: stable
stale_after: 2027-04-01T00:00:00Z
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-12T23:47:45Z }
sources:
  - id: task-50
    resource: backlog:TASK-50
    title: Favourites and Peeks register their backing tabs with the extension contexts
  - id: task-90
    resource: backlog:TASK-90
    title: 1Password worker stuck in a reconnect loop pins the Networking process
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process leaks IOSurfaces until the per-process limit
  - id: storage-scope
    resource: ../../Detour/Browser/WebKitStorageScope.swift
    title: WebKitStorageScope.swift (which identifier a profile's store has)
  - id: notes-cpu
    resource: "Agent session notes, 2026-09-19 (not in the repository)"
    title: Session notes on WebKit helper CPU diagnostics
  - id: notes-itp
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on the extension data store and ITP
  - id: notes-stalls
    resource: "Agent session notes, 2026-10-01 (not in the repository)"
    title: Session notes on hidden web view load stalls
  - id: task-175
    resource: backlog:TASK-175
    title: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
---

Activity Monitor says `com.apple.WebKit.Networking` or a
`com.apple.WebKit.WebContent` is burning a core and nothing on screen
explains it. This playbook gets from "which process" to "which origin, in
which profile, doing what" with command-line tools only. Stack signatures
are from macOS 26 and may shift with WebKit updates.

# When to use

- A WebKit helper holds high CPU with no visible activity, or with no
  windows open.
- The Detour process itself sits at tens of percent together with a
  WebContent process.
- You are about to kill a helper and want to know what it hosts first.

# Steps

## 1. List the processes

```bash
ps -axo pid,ppid,%cpu,rss,lstart,command | grep -E 'Detour|com.apple.WebKit' | grep -v grep
```

In a sandboxed agent shell, `ps`, `sample`, `lsof`, `top` and `vmmap` need
the sandbox off. Several Detour processes may exist (installed app, Debug
build, test host), and other WebKit apps have helpers of the same names.
The helpers are XPC services: their parent is launchd (`ppid` 1), not the
app.[^task-175] What ties a helper to its app is the process the system
holds responsible for it, which is also what Activity Monitor groups by:

```bash
python3 - <<'PY'
import ctypes, subprocess
f = ctypes.CDLL(None).responsibility_get_pid_responsible_for_pid
for line in subprocess.run(['ps', '-axo', 'pid=,lstart=,comm='], capture_output=True, text=True).stdout.splitlines():
    if 'com.apple.WebKit.' in line:
        pid = int(line.split()[0])
        print(pid, line.split('/')[-1], ' '.join(line.split()[1:6]), '-> responsible pid', f(pid))
PY
```

For web processes Detour's own log is quicker: every WebKit line about a
page carries `PID=<web process>`, and a web process's own lines are
relayed as `WebContent[<pid>]` under Detour's pid.

## 2. Sample the hot process

```bash
sample <pid> 3 -file "$OUT/sample-<pid>.txt"
```

Read the "Sort by top of stack" section at the end first, then the call
tree above it. Write the file to an absolute path: sandboxed and
unsandboxed commands may see different `$TMPDIR` values.

| Process | Hot frames | Meaning |
|---|---|---|
| Networking | `IDBServer::UniqueIDBDatabase::takeNextRunnableTransaction` under `NetworkStorageManager::establishTransaction`, and **no** `SQLiteIDBBackingStore` work frames | IndexedDB transactions are being queued and never run: a client is stuck, not busy[^notes-cpu] |
| Networking | the same function reached through `NetworkStorageManager::abortTransaction` | an abort storm: a client opens and aborts transactions in a loop[^task-90] |
| Detour (UI process) | `WebExtensionContext::runtimeSendMessage` → `getCurrentTab` → `openTabs` → `WebExtensionTab::webView()` | a flood of `runtime.sendMessage` from a content script[^task-50] |
| WebContent | `RejectedPromiseTracker::reportUnhandledRejections` → `JSEventListener` → `JSWebExtensionAPIRuntime::sendMessage` | the other half of that flood: an unhandled-rejection reporter whose own `sendMessage` rejects[^task-50] |
| WebContent (hidden tab) | main thread parked at one address inside a page script, 0% CPU | not a hang: the process is at background priority, see [hidden web view load stalls](../platform/hidden-webview-load-stalls.md)[^notes-stalls] |
| WebContent | every main-thread sample in `IPC::Connection::sendSyncMessage` → `waitForSyncReply` (under `RemoteAudioSession::ensureConnection` in the case found), and `ps -o time` not advancing at all | blocked on a process that will never answer: look for an [abandoned GPU process](../platform/abandoned-gpu-process.md)[^task-175] |
| GPU (not the app's current one) | main thread stuck in one place, a few hundredths of a second of CPU in its whole life | WebKit dropped it and it never exited; killing it unfreezes the pages waiting on it[^task-175] |

## 3. Which origin: open files

```bash
lsof -nP -p <networking pid> | grep -E 'IndexedDB|ServiceWorkers|LocalStorage'
```

Website data lives under `~/Library/WebKit/com.detourbrowser.mac/`:

```
WebsiteDataStore/<store uuid>/Origins/<top hash>/<frame hash>/{IndexedDB,LocalStorage,ServiceWorkers}
WebsiteData/Default/…                                  the default (non-identifier) store
```

- **Which profile.** In the production data directory the store uuid is
  the profile's id; look it up in the `profile` table of `browser.db`.
  In an isolated data directory it is a derived identifier
  (`WebKitStorageScope`), recorded in that directory's
  `webKitStorageIdentifier` table.
- **Which site.** Each origin directory has an `origin` file:

  ```bash
  strings "<origin dir>/origin" | tail -1
  ```

  A host that is a UUID is an extension origin (`webkit-extension://<uuid>`).
  `grep -la <uuid> …/Origins/*/*/origin` finds which store holds a given
  extension origin.[^notes-itp]
- **Look for deleted files first.** If `lsof` lists IndexedDB files whose
  paths no longer exist on disk (unlinked while open, write-ahead log size
  frozen), something deleted the origin's storage underneath a live
  client. That was the whole explanation of the TASK-90 abort storm, and
  checking it first would have saved the session.[^notes-itp] See
  [data store and ITP](../extensions/data-store-and-itp.md).

## 4. Which database, and is it still being written

```bash
# database name (stored as UTF-16LE; a plain select prints one character)
sqlite3 "file:<…>/IndexedDB.sqlite3?immutable=1" \
  "select hex(value) from IDBDatabaseInfo where key='DatabaseName'" | xxd -r -p | iconv -f UTF-16LE -t UTF-8
# is anything landing?
stat -f '%Sm %z %N' <…>/IndexedDB.sqlite3-wal ; sleep 5 ; stat -f '%Sm %z %N' <…>/IndexedDB.sqlite3-wal
```

The write-ahead log whose modification time keeps advancing is the active
database. `sqlite3` cannot query the IndexedDB `Records` table (it uses a
custom `IDBKEY` collation), but text can be pulled from the log:

```bash
LC_ALL=C tail -c 400000 "<…>/IndexedDB.sqlite3-wal" | strings -n 10 | sort | uniq -c | sort -rn | head -40
```

That is how an extension's own diagnostic log was read when its console
output was private.[^task-90] macOS `strings` has no `-e l`, so UTF-16
text is not found this way.

## 5. Which WebContent process hosts the service workers

Do not guess from CPU. Detour's log names it:[^notes-cpu]

```bash
/usr/bin/log show --last 30m --info --predicate \
  'processIdentifier == <detour pid> AND category == "ProcessSuspension" AND eventMessage CONTAINS "workerType=service"'
# → [PID=N] WebProcessProxy::updateRemoteWorkerProcessAssertion: workerType=service
```

Extension background workers share that process, so killing it restarts
them too.

## 6. Confirm with the log

| Suspicion | Query |
|---|---|
| `sendMessage` flood to a tab WebKit does not know | `process == "Detour" AND category == "Extensions"` → `Tab not found for message for content script message` |
| A worker in an error loop | `category == "extension-polyfill"` → `[SW <id>]` lines at a flat rate (about 20 per second in TASK-90) |
| Tracking prevention purge | Networking, `deleteAndRestrictWebsiteDataForRegistrableDomains` then `SWServerRegistration::clear` |

Recipes: [reading runtime logs](./reading-runtime-logs.md). Causes:
[diagnosing extension problems](./diagnosing-extension-problems.md).

## 7. Are there windows at all

```bash
osascript -e 'tell application "System Events" to tell process "Detour" to get {name, visible} of windows'
```

A result of `,` means no windows. (Needs Automation permission for the
shell's host process, and names every process called Detour.)

# The GPU process

High CPU is not the GPU process's failure mode; running out of IOSurfaces
is. Count them:[^task-104]

```bash
vmmap --summary <gpu pid> | grep '^IOSurface'          # last column = region count
vmmap <gpu pid> | grep '^IOSurface' | grep -c PURGE=E  # purged but still allocated
```

`vmmap` on a WebContent process printed nothing. Killing the GPU process
is safe (WebKit relaunches it and the WebContent processes reconnect).
Everything else is on
[GPU IOSurface limit](../platform/gpu-iosurface-limit.md).

# Traps

- **Killing the busiest WebContent.** It may be someone's tab. Identify
  the worker process by the log, and the app a helper belongs to by its
  responsible process (step 1), not by `ppid`.[^notes-itp]
- **"0% CPU" has two meanings.** `ps -o %cpu` is a decaying average. Read
  `ps -o time` twice a few seconds apart: a de-prioritised process creeps
  forward, a blocked one does not move.[^task-175]
- **Reading throughput into a stuck queue.** A hot
  `takeNextRunnableTransaction` with no backing-store frames means nothing
  is running.
- **Assuming the culprit.** The same Networking signature has had
  different owners on different days; in TASK-90 it was an extension's
  own diagnostics database, not the site that was suspected first. Use
  the open files and the write-ahead log, not memory of the last
  case.[^task-90]
- **Blaming Detour's log reporter.** The polyfill's console bridge is
  injected only in background and popup contexts and swallows its own
  transport's rejection, so it is not part of a content-script
  `sendMessage` loop.[^notes-cpu]
- **A killed worker comes back and the files vanish again.** If the cause
  is a purge, killing only resets the clock (about 60 seconds in TASK-90).
- **Machine load.** Measurements of load behaviour depend on how busy the
  machine is; check `uptime` before comparing runs.[^notes-stalls]
- **Deleting under `~/Library/WebKit/com.detourbrowser.mac/`.** That
  directory is shared by every Detour on the machine. Read there; never
  enumerate and delete.

# Related

- [Reading runtime logs](./reading-runtime-logs.md) — the log half of every step here.
- [Abandoned GPU process](../platform/abandoned-gpu-process.md) — a whole diagnosis done with these steps on a running app.
- [Diagnosing extension problems](./diagnosing-extension-problems.md) — symptom to cause.
- [Data store and ITP](../extensions/data-store-and-itp.md) — why extension storage gets deleted.
- [Tab and window bridge](../extensions/tab-and-window-bridge.md) — why an unregistered tab causes a message flood.
- [GPU IOSurface limit](../platform/gpu-iosurface-limit.md) — the GPU process investigation.
- [Profile data removal](../architecture/profile-data-removal.md) — how store identifiers map to profiles.

[^task-50]: TASK-50
[^task-90]: TASK-90
[^task-104]: TASK-104
[^notes-cpu]: Session notes on WebKit helper CPU diagnostics
[^notes-itp]: Session notes on the extension data store and ITP
[^notes-stalls]: Session notes on hidden web view load stalls
[^task-175]: TASK-175
