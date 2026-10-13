---
type: Reference
title: WebKit source lookup
description: How to read the WebKit source that explains a behaviour seen in Detour — fetching files and older revisions from GitHub, which files answered which questions, and how far a source reading can be trusted.
tags: [webkit, reference, debugging, extensions]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-12T23:47:17Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: notes-source
    resource: "Agent session notes, 2026-09-14 (not in the repository)"
    title: Reading WebKit's WKWebExtension implementation; worker unload and native port facts
  - id: webkit-repo
    resource: https://github.com/WebKit/WebKit
    title: WebKit source repository (paths and recipes re-checked 2026-10-04)
  - id: task-68
    resource: backlog:TASK-68
    title: The armed keep-alive does not stop WebKit unloading a worker with no relayed WebSocket
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process leaks IOSurfaces until the 16384 per-process limit
  - id: task-109
    resource: backlog:TASK-109
    title: Does the GPU process ever get the memory-pressure pool flush
  - id: task-121
    resource: backlog:TASK-121
    title: A standalone video URL shows the error page with "Plug-in handled load"
  - id: task-22
    resource: backlog:TASK-22
    title: Verify runtime.onInstalled is delivered, or emit it ourselves
  - id: task-70
    resource: backlog:TASK-70
    title: Tracking prevention deletes an extension origin's script-written storage
  - id: task-69
    resource: backlog:TASK-69
    title: The per-site content blocking switch does not take effect
  - id: task-132-21
    resource: backlog:TASK-132.21
    title: A window with nothing selected reports no tabs to extensions
  - id: runtime-patching
    resource: ../../docs/chrome-runtime-patching.md
    title: chrome.runtime patching design note
  - id: task-175
    resource: backlog:TASK-175
    title: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
  - id: task-176
    resource: backlog:TASK-176
    title: Reload on a tab whose web process is unresponsive does nothing; terminate the process and reload
---

Much of what Detour knows about WebKit came from reading WebKit's source
after an experiment showed something odd. WebKit is open source and the
system framework is built from it, so the source usually explains the
behaviour — with the caveats at the end of this page. There is no local
WebKit checkout; files are fetched one at a time.

# Fetching a file

Current `main`:

```sh
curl -sSL https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm \
  | grep -n 'unloadBackgroundContentIfPossible'
```

`raw.githubusercontent.com` is plain HTTPS with no authentication. Pipe to
`grep -n` or save to a temporary file; these sources are thousands of lines
long.

# Fetching the revision closest to the shipped WebKit

The WebKit in a macOS release is months older than `main`. To read a file as
it was around the time the installed system was built, ask the commits API
for the last commit to that file before a date, then fetch the file at that
commit:[^notes-source]

```sh
curl -sS 'https://api.github.com/repos/WebKit/WebKit/commits?path=Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm&until=2026-06-15T00:00:00Z&per_page=1' \
  | python3 -c 'import json,sys; c=json.load(sys.stdin)[0]; print(c["sha"], c["commit"]["committer"]["date"])'
curl -sSL https://raw.githubusercontent.com/WebKit/WebKit/<sha>/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm
```

- Pick the `until` date from the macOS release's age, a few months before it
  shipped.
- Looking up a release tag did not work: a `matching-refs/tags/WebKit-7626`
  query returned nothing.[^notes-source]
- When a finding matters, check it in both `main` and the older revision and
  say which you read. "Identical in main and the pre-June-2026 revision" is
  the form the worker-unload facts were recorded in.[^notes-source]

Both recipes were re-run successfully on 2026-10-04.[^webkit-repo]

# Where things are

Paths are relative to the repository root and were checked against `main` on
2026-10-04.[^webkit-repo]

## Web Extensions

| Path | What was learned there |
|---|---|
| `Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm` | `unloadBackgroundContentIfPossible` and the background-context unload rules[^task-68]; `determineInstallReasonDuringLoad` and when `runtime.onInstalled` fires[^task-22] — see [service worker unload rules](./service-worker-unload-rules.md), [runtime.onInstalled](../extensions/runtime-installed-event.md) |
| `Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIPortCocoa.mm` | `portPostMessage` and `addPorts`, the only places that record background port activity[^notes-source] |
| `Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIRuntimeCocoa.mm` | UI-process side of `runtime.*`: `runtimeConnectNative`, `runtimeReload` |
| `Source/WebKit/UIProcess/Extensions/WebExtensionController.cpp` | Controller load and unload[^task-22] |
| `Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionWindowCocoa.mm` | `WebExtensionWindow::tabs()` drops a window's whole tab list unless the active tab is in it[^task-132-21] — background for the [Claude extension epic](../extensions/claude-extension-epic.md) |
| `Source/WebKit/WebProcess/Extensions/API/Cocoa/` | Web-process side of each API (`WebExtensionAPIRuntimeCocoa.mm`, …) |
| `Source/WebKit/WebProcess/Extensions/Bindings/JSWebExtensionWrapper.cpp` | The weak JS wrapper cache behind [chrome.runtime patching](../extensions/chrome-runtime-patching.md) |

Pattern: an API named `X` has a UI-process file
`…/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPI<X>Cocoa.mm` and a
web-process file `…/WebProcess/Extensions/API/Cocoa/WebExtensionAPI<X>Cocoa.mm`.

## Everything else

| Path | What was learned there |
|---|---|
| `Source/WebCore/platform/graphics/cg/IOSurfacePool.cpp`, `.h` | The pool is capped by bytes, never by count; `collectionTimerFired` only marks surfaces volatile[^task-104] — see [GPU IOSurface limit](./gpu-iosurface-limit.md) |
| `Source/WebKit/GPUProcess/GPUProcess.cpp`, `GPUConnectionToWebProcess.cpp` | `lowMemoryHandler` and `prepareToSuspend` discard every connection's pool[^task-109] |
| `Source/WebKit/UIProcess/GPU/GPUProcessProxy.cpp` | `gpuProcessExited` and how pages reconnect |
| `Source/WebKit/Shared/EntryPointUtilities/Cocoa/XPCService/XPCServiceMain.mm` | A helper exits on a dropped XPC connection by posting `exitProcess` to its main run loop, so a helper with a blocked main thread never exits[^task-175] — see [abandoned GPU process](./abandoned-gpu-process.md) |
| `Source/WebKit/WebProcess/GPU/media/RemoteAudioSession.cpp` | `ensureConnection` sends `EnsureAudioSession` synchronously with no timeout[^task-175] |
| `Source/WebKit/UIProcess/WebProcessPool.cpp` | `ensureGPUProcess`: the GPU process is per pool until asked for, which is why `_gpuProcessIdentifier` can be 0 on one web view and not another[^task-175] |
| `Source/WebKit/UIProcess/AuxiliaryProcessProxy.cpp` | `startResponsivenessTimer` is deferred while the process launches[^task-176] — see [unresponsive web process](./unresponsive-web-process.md) |
| `Source/WebKit/UIProcess/ProcessThrottler.cpp` | Foreground and background activities; prints the "Updating process assertion type" log line — see [hidden web view load stalls](./hidden-webview-load-stalls.md) |
| `Source/WebKit/UIProcess/WebPageProxy.cpp` | `decidePolicyForNewWindowAction` — see [WKWebView delegate order](./wkwebview-delegate-order.md); the responsiveness timer is stopped when the view is hidden, which reports a blocked process as responsive[^task-176]; `gpuProcessID` |
| `Source/WebCore/loader/FrameLoader.cpp` | `loadURL`, the new-window path |
| `Source/WebKit/WebProcess/WebCoreSupport/WebLocalFrameLoaderClient.cpp` | `committedLoad` cancels a media document's main resource with error 204[^task-121] — see [media and picture-in-picture](./media-and-pip.md) |
| `Source/WebKit/NetworkProcess/Classifier/ResourceLoadStatisticsStore.cpp` | What a tracking-prevention pass deletes[^task-70] — see [data store and ITP](../extensions/data-store-and-itp.md) |
| `Source/WebCore/contentextensions/ContentExtensionsBackend.cpp` | `ignore-previous-rules` only cancels rules in the same rule list; block results of every list are merged[^task-69] — see [content blocking](../features/content-blocking.md) |

For a file not listed, search by the class name seen in a crash stack or a
log line. WebKit's log messages are string literals in the source, so
grepping a fetched file for the message text finds the code that printed it.

# Two findings that are easy to need again

Both verified 2026-09-14, identical in `main` and the older revision; details
on [service worker unload rules](./service-worker-unload-rules.md).[^notes-source]

- `unloadBackgroundContentIfPossible` runs every 30 s and keeps the
  background context only while it has open ports **and** the last port
  activity is under 2 minutes old. Only `portPostMessage`/`addPorts` from the
  background context itself set that time. Messages the browser sends to the
  worker do not count; the worker's replies do.
- `runtime.reload()` is a controller unload plus load, and `unload()` clears
  the native port map without reporting a disconnection. Native ports the app
  holds for that context get no disconnect callback.

# How far to trust a source reading

- **The shipped framework is not `main`.** A feature in `main` may be absent
  or behind a flag in the installed WebKit. Check the older revision, and for
  API presence check the runtime (`responds(to:)`, or listing an object's
  methods), which is how SPI such as `_gpuProcessIdentifier` and
  `_wantsPopup` was confirmed.
- **A source reading is a hypothesis until measured.** The pool-only
  explanation of the IOSurface growth read correctly and was still
  incomplete: the low-memory flush that the source says discards every pool
  freed about 15% in practice.[^task-109]
- **Cite the function, not the line.** Line numbers move weekly.
- **Record the direction of the check** in the task: what was observed first,
  which source function explains it, and what experiment confirmed the
  explanation.

# Related

- [Service worker unload rules](./service-worker-unload-rules.md) — the unload timer and port activity rule in full.
- [GPU IOSurface limit](./gpu-iosurface-limit.md) — a source reading corrected by measurement.
- [WKWebView delegate order](./wkwebview-delegate-order.md) — the experiment-first counterpart: a standalone spike.
- [chrome.runtime patching](../extensions/chrome-runtime-patching.md) — what the wrapper cache allows and forbids.
- [Extensions overview](../extensions/overview.md) — what WebKit provides and what Detour adds.
- [Native port keep-alive](../extensions/native-port-keep-alive.md) — the component built on the unload rules.
- [Reading runtime logs](../playbooks/reading-runtime-logs.md) — getting the log line whose text you then search for in the source.
- [Test host crashes](../playbooks/test-host-crashes.md) — getting the stack whose frames name the classes to look up.

[^notes-source]: Reading WebKit's WKWebExtension implementation; worker unload and native port facts
[^webkit-repo]: WebKit source repository (paths and recipes re-checked 2026-10-04)
[^task-68]: The armed keep-alive does not stop WebKit unloading a worker with no relayed WebSocket
[^task-104]: GPU process leaks IOSurfaces until the 16384 per-process limit
[^task-109]: Does the GPU process ever get the memory-pressure pool flush
[^task-121]: A standalone video URL shows the error page with "Plug-in handled load"
[^task-22]: Verify runtime.onInstalled is delivered, or emit it ourselves
[^task-70]: Tracking prevention deletes an extension origin's script-written storage
[^task-69]: The per-site content blocking switch does not take effect
[^task-132-21]: A window with nothing selected reports no tabs to extensions
[^task-175]: A GPU process WebKit failed to kill stays alive and freezes every tab connected to it
[^task-176]: Reload on a tab whose web process is unresponsive does nothing; terminate the process and reload
