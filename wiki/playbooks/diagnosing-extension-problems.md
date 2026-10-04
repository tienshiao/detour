---
type: Playbook
title: Diagnosing extension problems
description: A symptom-to-cause table for Web Extension failures seen in Detour (dead popups, worker restarts, helper CPU, missing content scripts, log noise), with the first check for each and where the mechanism is explained.
tags: [playbook, extensions, diagnostics, 1password, service-worker]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T18:50:00Z }
sources:
  - id: plan-doc
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan
  - id: task-1
    resource: backlog:TASK-1
    title: 1Password extension log hygiene
  - id: task-3
    resource: backlog:TASK-3
    title: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
  - id: task-4
    resource: backlog:TASK-4
    title: Real frame enumeration for iframe autofill
  - id: task-15
    resource: backlog:TASK-15
    title: Polyfill must not replace the chrome/browser globals in service workers
  - id: task-17
    resource: backlog:TASK-17
    title: Rate-limit the worker console bridge
  - id: task-21
    resource: backlog:TASK-21
    title: Verify the native keep-alive and the WebSocket relay in the signed build
  - id: task-50
    resource: backlog:TASK-50
    title: Favourites and Peeks register their backing tabs with the extension contexts
  - id: task-55
    resource: backlog:TASK-55
    title: Building the Extensions menu loads every extension's popup page
  - id: task-67
    resource: backlog:TASK-67
    title: A replaced worker leaks its native hosts and keeps the keep-alive armed
  - id: task-68
    resource: backlog:TASK-68
    title: The armed keep-alive does not stop WebKit unloading a worker
  - id: task-70
    resource: backlog:TASK-70
    title: Tracking prevention deletes an extension origin's script-written storage
  - id: task-71
    resource: backlog:TASK-71
    title: Which chrome.offscreen implementation runs in the signed build
  - id: task-73
    resource: backlog:TASK-73
    title: The Private profile's extension worker stalls in an ephemeral data store
  - id: task-74
    resource: backlog:TASK-74
    title: Extensions do not load in the Private profile unless allowed
  - id: task-75
    resource: backlog:TASK-75
    title: Origin patterns with a port make chrome.permissions calls throw
  - id: task-80
    resource: backlog:TASK-80
    title: Polyfill chrome.storage.managed
  - id: task-81
    resource: backlog:TASK-81
    title: chrome.windows.getCurrent from a background worker reports Window not found
  - id: task-90
    resource: backlog:TASK-90
    title: 1Password worker stuck in a reconnect loop pins the Networking process
  - id: task-99
    resource: backlog:TASK-99
    title: Give each context a stable base URL so extension storage survives a relaunch
  - id: task-100
    resource: backlog:TASK-100
    title: Inject content scripts into srcdoc and about:blank frames
  - id: task-101
    resource: backlog:TASK-101
    title: Inline menu does not open from a form inside a cross-origin iframe
  - id: task-104
    resource: backlog:TASK-104
    title: GPU process leaks IOSurfaces until the per-process limit
  - id: notes-1password
    resource: "Agent session notes, 2026-09-13 (not in the repository)"
    title: Session notes on the 1Password integration
  - id: notes-seeding
    resource: "Agent session notes, 2026-10-03 (not in the repository)"
    title: Session notes on seeding extensions for runtime checks
  - id: notes-updates
    resource: "Agent session notes, 2026-09-25 (not in the repository)"
    title: Session notes on extension updates and options entry points
  - id: notes-itp
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on the extension data store and ITP
  - id: runtime-check
    resource: "Runtime check, 2026-10-04 (isolated profile, harness in docs/harness/task132.8-harness.patch)"
    title: Runtime check of the side panel with the real Claude extension, signed out
---

Extension failures in Detour tend to show up far from their cause: a popup
error that is a messaging bug, a "network" failure that is a GPU process
limit, a CPU spike that is a deleted database. This page maps the symptoms
that have been diagnosed to their causes. Find the row, run the first
check, then read the linked page for the mechanism. Rows describe causes
found in the past; most are fixed, and a row is here so that a regression
or a look-alike is recognised quickly.

# When to use

An extension misbehaves in Detour and works in Chrome, a worker keeps
restarting, a helper process is hot, or the log is full of extension
errors and you need to know which ones matter.

# Steps

## 1. Get the facts before theorising

1. Which build: Debug in an isolated profile, or the signed app? Native
   messaging to a real desktop app only works in the latter
   ([signed-build verification](./signed-build-verification.md)).
2. Capture the log with extension console text public
   ([reading runtime logs](./reading-runtime-logs.md)).
3. Note which profile, and whether the extension's pages run in a
   persistent or an ephemeral store. Many store-scoped behaviours
   (tracking prevention, storage, service workers) depend on it. Check
   which store the extension pages really use before reasoning about
   it.[^notes-itp]
4. If a helper process is hot, go to
   [WebKit helper diagnostics](./webkit-helper-diagnostics.md) first.

## 2. Match the symptom

### Messaging and API surface

| Symptom | Cause | First check | More |
|---|---|---|---|
| Popup shows the extension's generic load error; every `runtime.sendMessage` to the worker resolves `undefined` in a few milliseconds with no `lastError` | The `chrome` / `browser` global was replaced (a Proxy). WebKit's dispatcher unwraps those globals to find the worker's listeners and cannot unwrap a Proxy[^task-15] | `ExtensionPolyfillIntegrationTests.testRuntimeSendMessageReachesWorkerRunningThePolyfill` | [never replace chrome globals](../decisions/never-replace-chrome-globals.md) |
| A patched `chrome.runtime` member silently does nothing | WebKit re-creates some members on every read (`connectNative`) and serves others as read-only static values (`reload`); an assignment does not throw and does not stick[^task-15][^notes-updates] | read the member back after patching | [chrome.runtime patching](../extensions/chrome-runtime-patching.md) |
| `TypeError` on `chrome.storage.managed`, `chrome.privacy.services`, `webRequest.onAuthRequired` during worker init; the popup spins | WebKit lacks the API and the extension uses it unguarded[^task-3][^task-80] | worker console at start | [polyfill layer](../extensions/polyfill-layer.md), [storage](../extensions/storage.md) |
| `chrome.permissions.contains` / `request` throws synchronously; an inline menu never appears on a site with a non-default port | WebKit rejects origin patterns that carry a port[^task-75] | the thrown error says `not a valid pattern` | [permissions](../extensions/permissions.md) |
| `Unchecked runtime.lastError: Invalid call to windows.get(). Window not found.` at every worker start | `windows.getCurrent` from a background context has no window when the profile does not own the key window[^task-81] | whether the profile has the key window | [tab and window bridge](../extensions/tab-and-window-bridge.md) |
| `runtime.reload()` seems to do nothing | In WebKit it is an unload and load of the same context: same base URL, no delegate callback. The only trace is the worker restarting[^notes-updates] | worker start lines | [updates](../extensions/updates.md) |
| The Claude extension's side panel opens on Cmd+E but does not close on the next Cmd+E, signed out | The extension, not Detour. Its worker finds the panel with `runtime.getContexts` and sends the page `close_side_panel`; the listener that calls `window.close()` is in its signed-in components, which the "Log in" screen does not mount[^runtime-check] | record `runtime.onMessage` in the panel page: the message arrives | [side panel runtime check](./side-panel-runtime-check.md), [side panel](../extensions/side-panel.md) |
| Opening the Extensions menu or pressing a key makes an extension prompt to unlock | Something read `WKWebExtension.Action.popupWebView`, which creates and loads the popup page[^task-55] | grep for `popupWebView` | [popup and options UI](../extensions/popup-and-options-ui.md) |

### Worker lifetime

| Symptom | Cause | First check | More |
|---|---|---|---|
| All workers of a native-messaging extension restart about every two minutes | No port activity from the background, so WebKit's idle unload runs | `extension-manager`: is there a `Keep-alive armed` line? | [service worker unload rules](../platform/service-worker-unload-rules.md), [native port keep-alive](../extensions/native-port-keep-alive.md) |
| Worker terminated about a second after start, or unloaded while the keep-alive is armed; next load fails with `WKWebExtensionContextErrorDomain` code 6 | Tracking prevention purged the extension origin's script-written storage: Networking logs `deleteAndRestrictWebsiteDataForRegistrableDomains` and then `SWServerRegistration::clear`[^task-21][^task-68][^task-70] | is there an `ITP: logged user interaction` line (`EXT-ITP`) for that origin before the pass? | [data store and ITP](../extensions/data-store-and-itp.md) |
| `Keep-alive for <id>: ping #n … has no reply` | The worker is stalled, its timers suspended, or the port is dead; after two missed ticks Detour tears the ports down and reloads the background[^task-68] | what happened just before the first missed ping | [native port keep-alive](../extensions/native-port-keep-alive.md) |
| Armed count reads 2 or 3 for one profile; native host processes pile up after the desktop app restarts | A worker was replaced without its page closing; WebKit's `unload()` drops native ports with no disconnect callback, so old hosts were never torn down[^task-67] | count host children of Detour with `ps` | [native port keep-alive](../extensions/native-port-keep-alive.md) |
| Each worker drops its host after 10 seconds and tries a legacy host name | The desktop app was not running and unlocked when the browser started[^task-21] | start the app first, relaunch | [signed-build verification](./signed-build-verification.md) |
| "The background content failed to load due to an error" three times in an isolated profile | A hand-seeded extension without `extensionPermission` rows[^notes-seeding] | `select * from extensionPermission` | [seeding extensions](./seeding-extensions.md) |
| Worker in the Private profile gets no events; `sendMessage` comes back empty with no `lastError`; no content scripts in Private windows | WebKit hides ephemeral-session pages from a context without `hasAccessToPrivateData`[^task-73] | `Profile.loadExtensionContext` sets the flag for the incognito profile | [private profile extensions](../extensions/private-profile-extensions.md) |
| Extension does nothing at all in Private windows | It is off there unless allowed per extension[^task-74] | the "Allow in Private" switch | [private extensions opt-in](../decisions/private-extensions-opt-in.md) |

### CPU and storage

| Symptom | Cause | First check | More |
|---|---|---|---|
| Networking process near a full core in `takeNextRunnableTransaction` via `abortTransaction`; worker logging errors at a flat rate; the extension reports a closed desktop-app port | The extension's IndexedDB files were deleted underneath it (the purge above, on a store the interaction keeper skipped) and it re-initialises in a loop. The "port closed" is the extension's own `disconnect()` during re-init, not Detour refusing a port[^task-90] | `lsof` on the Networking pid: IndexedDB files that no longer exist on disk | [WebKit helper diagnostics](./webkit-helper-diagnostics.md) |
| One WebContent near 120% and the Detour process at 40–50% | A content script's `runtime.sendMessage` fails with WebKit's `Tab not found` because the web view was never reported to the extension contexts; an unhandled-rejection reporter then feeds itself[^task-50] | `category == "Extensions"`: `Tab not found for message for content script message` | [tab and window bridge](../extensions/tab-and-window-bridge.md) |
| Hundreds of thousands of `[SW …]` error lines in a minute | A worker error loop forwarded line by line; now capped by the bridge's rate limit[^task-17] | `[console bridge] dropped N messages` lines | [console bridge](../extensions/console-bridge.md) |
| Extension's cached data is cold after every relaunch | Each context load gets a new base URL, so the previous launch's origin storage is orphaned. Not tracking prevention[^task-99] | origin directory birth times | [storage](../extensions/storage.md) |

### Content scripts and frames

| Symptom | Cause | First check | More |
|---|---|---|---|
| `[Tabs] Could not collect all frames that were initially found` | Not a missing API: WebKit provides `webNavigation.getAllFrames` natively. It reports `url: ""` for `srcdoc` and script-filled `about:blank` frames and injects no content script into them[^task-4] | `testFrameKindsAsReportedByNativeGetAllFrames` | [frames and content scripts](../extensions/frames-and-content-scripts.md) |
| No extension control in a form inside a `srcdoc` or `about:blank` iframe | Same: no content script is injected there[^task-100] | the four-form fixture | [frames and content scripts](../extensions/frames-and-content-scripts.md) |
| Control appears in a cross-origin iframe but its menu does not open | Undiagnosed; suspects are listed in the task[^task-101] | compare the worker's port lines with the top-level case | [frames and content scripts](../extensions/frames-and-content-scripts.md) |
| A content script cannot fetch its own `webkit-extension://` resource, together with `WebGL: context lost` and video errors | Not an extension fault: the GPU process is out of IOSurfaces[^task-104] | `vmmap --summary <gpu pid>` | [GPU IOSurface limit](../platform/gpu-iosurface-limit.md) |

### Native messaging and trust

| Symptom | Cause | First check | More |
|---|---|---|---|
| `connectNative` fails for a real desktop app from a Debug or DerivedData build | The app trusts only the signed build in `/Applications`; its helper logs `parent browser was not valid` / `UnsupportedBrowser`[^notes-1password] | the helper's own log | [1Password integration](../extensions/1password-integration.md) |
| `Origin validation failed: extension … not in allowed_origins` | The host manifest does not list `chrome-extension://<id>/` for this extension id | the manifest under the search directories | [native messaging](../extensions/native-messaging.md) |
| `connectNative … N further attempts` | Repeated failing connects, summarised by the log limiter | the first line of the series | [native messaging](../extensions/native-messaging.md) |

## 3. Lines that look bad and are not

- `Keep-alive port for <id> superseded by a newer one` right after a
  reload or an idle unload.[^task-21]
- `Relayed WebSocket failed … hostname could not be found` and a 1006
  close from API Explorer: its deliberate `wss://example.invalid` probe at
  worker start.[^task-21]
- `Keep-alive armed … 1 native host(s) connected` with no native host: a
  relayed WebSocket counts.[^task-21]
- WebKit's `Unable to find "background/offscreen/vendor/semver.js"` for
  1Password's offscreen page: long-standing and harmless.[^notes-1password]
- `SWServerRegistration::clear` followed by `removeContextConnection`: an
  ordinary unload.[^notes-itp]
- A flat 20 `[SW …]` lines per second: that is the polyfill-side bridge
  limit (20 per second after a burst of 50), so the real rate is at least
  that, and the flatness says nothing about the extension.[^task-17]

## 4. Tools when the table does not have it

- **Trace one API.** A temporary module in `ExtensionAPIPolyfill` that
  wraps the suspect call (for example `runtime.sendMessage`) and adds a
  raw listener, logging through the console bridge, found the empty-reply
  bug in one deploy cycle. Remove it before committing.[^notes-1password]
- **Read the extension's code.** Installed extensions are unpacked under
  `<data directory>/Extensions/<id>/`. Minified sources are still
  greppable: search for the error string, then for the handler name next
  to it.[^notes-1password]
- **Read WebKit's code.** Dispatch and unload rules are in the
  `WebExtensionContext*` sources;
  [WebKit source lookup](../platform/webkit-source-lookup.md) says how to
  fetch them.
- **Ask the polyfill.** `__detourPolyfillDiag` records which
  implementation is in force for the APIs Detour overrides (for example
  `apis.offscreenInstall`), and a worker logs
  `[Detour polyfill] chrome.offscreen implementation: …` once per
  start.[^task-71]
- **Reproduce in a test.** A real context with a probe worker
  (`ExtensionPolyfillProfileWiringTests`) plus a fake native host
  reproduced worker replacement and host leaks without the real
  extension.[^task-67]

# Traps

- **Fixing the symptom's layer.** The keep-alive was blamed for an unload
  that tracking prevention caused, and an offscreen document's close was
  suspected for the same kill.[^task-68][^task-71]
- **Trusting an absent log line.** Info-level lines vanish; "no
  `connectNative` line" only means something if you were streaming at
  info level. WebKit always calls the delegate for `connectNative`, so
  with a live stream, no line means the extension never called it.[^notes-itp]
- **Assuming the profile's store.** Before the Private profile got its
  own non-persistent store for extension pages, they ran in WebKit's
  default store, and tracking prevention applied to them there.[^task-90]
- **Quoting payloads.** Native-messaging payloads can hold key material.
  Detour logs type and size only; do not add logging that prints them,
  and do not paste them into tasks or pages.[^task-1]

# Related

- [Reading runtime logs](./reading-runtime-logs.md) — how to get the lines this page refers to.
- [WebKit helper diagnostics](./webkit-helper-diagnostics.md) — attributing helper CPU.
- [Signed-build verification](./signed-build-verification.md) — checks that need the real app.
- [Seeding extensions](./seeding-extensions.md) — a controlled reproduction.
- [Extensions overview](../extensions/overview.md) — what WebKit provides and what Detour adds.
- [1Password integration](../extensions/1password-integration.md) — the extension most of these were found with.
- [Testing extensions](../extensions/testing-extensions.md) — turning a diagnosis into a test.

[^task-1]: TASK-1
[^task-3]: TASK-3
[^task-4]: TASK-4
[^task-15]: TASK-15
[^task-17]: TASK-17
[^task-21]: TASK-21
[^task-50]: TASK-50
[^task-55]: TASK-55
[^task-67]: TASK-67
[^task-68]: TASK-68
[^task-70]: TASK-70
[^task-71]: TASK-71
[^task-73]: TASK-73
[^task-74]: TASK-74
[^task-75]: TASK-75
[^task-80]: TASK-80
[^task-81]: TASK-81
[^task-90]: TASK-90
[^task-99]: TASK-99
[^task-100]: TASK-100
[^task-101]: TASK-101
[^task-104]: TASK-104
[^notes-1password]: Session notes on the 1Password integration
[^notes-seeding]: Session notes on seeding extensions for runtime checks
[^notes-updates]: Session notes on extension updates and options entry points
[^notes-itp]: Session notes on the extension data store and ITP
[^runtime-check]: Runtime check of the side panel with the real Claude extension, signed out
