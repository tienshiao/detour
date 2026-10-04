---
type: Component
title: Offscreen documents
description: Detour's implementation of chrome.offscreen — a hidden web view per extension and profile, the rule that every createDocument settles exactly once, the AudioContext bridge, and why Detour's implementation shadows a native one.
resource: ../../Detour/Extensions/Runtime/OffscreenDocumentHost.swift
tags: [extensions, offscreen, polyfill, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: host
    resource: ../../Detour/Extensions/Runtime/OffscreenDocumentHost.swift
    title: OffscreenDocumentHost.swift
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (offscreen.* cases, offscreenLoadCompletion)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (offscreenJS)
  - id: plan-doc
    resource: ../../docs/1password-integration-plan.md
    title: docs/1password-integration-plan.md, "Which chrome.offscreen is in force"
  - id: task-12
    resource: backlog:TASK-12
    title: Fail an in-flight offscreen.createDocument when its context unloads
  - id: task-13
    resource: backlog:TASK-13
    title: Give ExtensionPolyfillHandler a profile back-reference
  - id: task-18
    resource: backlog:TASK-18
    title: offscreen.createDocument must reply and unregister its host when the page fails to load
  - id: task-71
    resource: backlog:TASK-71
    title: Which chrome.offscreen runs in the signed build, and make it observable
  - id: task-14
    resource: backlog:TASK-14
    title: Reload or close open extension pages when their context is reloaded
  - id: wiring-tests
    resource: ../../DetourTests/ExtensionPolyfillProfileWiringTests.swift
    title: ExtensionPolyfillProfileWiringTests
---

`chrome.offscreen` lets an MV3 worker open one hidden page for work a worker
cannot do (DOM parsing, audio, `localStorage`). The shipped WebKit has no such
API, so Detour provides it: the polyfill forwards the three calls to the
profile's `ExtensionPolyfillHandler`, which keeps one `OffscreenDocumentHost`
per extension, each owning a hidden `WKWebView`.

# How it works

## Calls

| Call | Native behaviour |
|---|---|
| `createDocument({url, …})` | Builds a host and loads `<context.baseURL>/<url>` from the context's own `webViewConfiguration`, so the page has `chrome.*`. Replies when the load settles. |
| `closeDocument()` | `closeOffscreenDocument(for:)`: unregister, then `stop()` |
| `hasDocument()` | True only for a registered host whose load has settled |

`reasons` and `justification` are accepted and ignored.

Hosts are keyed by extension id in `offscreenHosts` on the handler, which is
per profile. The context is resolved only through
`profile.extensionContext(for:)`. An earlier version used
`ExtensionManager.context(for:)`, which prefers the last-active space's
profile, so an extension enabled in two profiles could get its document built
in the wrong profile's controller and data store.[^task-13]

## Every create settles exactly once

A load ends one of three ways: `didFinish`, a real navigation failure, or
`stop()`. `OffscreenDocumentHost.settleLoad` drains the pending completions on
all three, clearing them before invoking so a completion that closes the
document cannot re-enter.

The handler's completion (`offscreenLoadCompletion`) first checks that its
host is **still the registered one**, by identity. By the time a load settles
the slot may hold a second host built by a later `createDocument`, and neither
a success nor a failure belonging to the dead host may touch it.

| Outcome | Reply | Host |
|---|---|---|
| Loaded, still registered | `true` | Kept |
| Navigation failed, still registered | The error text | Unregistered and stopped, so `hasDocument` is false and a retry loads again |
| Closed or replaced before it settled | `Offscreen document was closed before it finished loading` | Already gone |

Related rules:

- A `createDocument` arriving while the first is still loading **joins** that
  load (`addLoadCompletion`) rather than short-circuiting with success. It may
  still fail, and both waiters must then fail with it.
- `closeOffscreenDocument` unregisters *before* it stops. `stop()` fails the
  pending completions, and they must see that the host is no longer
  registered.
- A cancelled navigation (`isSupersededNavigationError`) is not the end of the
  load: a page that navigates itself before its first load finishes fails the
  first navigation and finishes the second.
- `Profile.unloadExtension` closes the document. It belongs to the old
  context's origin; a reloaded context has a new one.

Before these rules a 404 left the promise pending forever, the dead host
stayed registered, and every later `createDocument` answered success for a
document that never loaded.[^task-18]

## Which implementation is in force

Detour's, in the signed build as well as in tests. The shipped WebKit
(framework 21624.5.1.11.3, the safari-7624 branch) has no `chrome.offscreen`:
the `WK_WEB_EXTENSIONS_OFFSCREEN` feature and its IDL attribute exist only on
WebKit main.[^task-71]

`offscreenJS` deliberately **shadows** a native namespace if one ever appears,
because Detour's is the implementation with the tested lifecycle and the audio
bridge. It must not do so silently, so it classifies what was there before
defining anything and records the outcome once per context in
`__detourOffscreenInstall` (`_polyfillDiag.apis.offscreenInstall`):

| Marker | Meaning |
|---|---|
| `polyfill` | Nothing was there |
| `polyfill-over-native` | A native namespace was shadowed: a WebKit update has shipped its own, and this decision needs revisiting |
| `polyfill-over-foreign` | Another script's object was shadowed |
| `polyfill-over-unreadable` | The namespace's getter threw |
| `error: …` | The define threw or did not take; also `console.error` |

`__detourDefine` only warns on failure, so the module re-reads
`chrome.offscreen` and checks for its own `_detourPolyfill` tag. Each
background start logs one line through the
[console bridge](./console-bridge.md):

```
[Detour polyfill] chrome.offscreen implementation: polyfill
```

## AudioContext bridge

WebKit's `AudioContext` does not play in a hidden web view without a user
gesture. After the document loads, the host evaluates a shim that replaces
`window.AudioContext`:

1. `decodeAudioData` base64-encodes the buffer (in 8 KB chunks) instead of
   decoding it;
2. `createBufferSource().start()` posts the base64 audio to the
   `detourAudioBridge` message handler;
3. Swift plays it with `AVAudioPlayer`;
4. when playback finishes, Swift calls the source node's `onended`.

Only that path is covered: `decodeAudioData`, `createBufferSource`, `start`,
`stop`, `onended`. There is no audio graph.

# Invariants

- At most one host per (profile, extension).
- A `createDocument` request is answered exactly once, and never reports a
  document that is gone.
- The offscreen web view is registered in `ExtensionPageHostRegistry`, so even
  when loaded from the background document's path it cannot pass for the
  background page ([runtime.onInstalled](./runtime-installed-event.md)).

# Gotchas

- The shim is injected in `didFinish`, not as a user script, because the
  extension configuration's `userContentController` is shared with the
  extension's other contexts. So it arrives **after** the page's own scripts
  have run: an `AudioContext` constructed during load is WebKit's real one.
- That shared `userContentController` also means the `detourAudioBridge`
  handler name is registered once per profile: `load` removes any existing
  handler of that name before adding its own. Two extensions with offscreen
  documents in one profile would contend for it. This follows from the code
  and has not been tested.
- A missing page under `webkit-extension://` produces a genuine
  `didFailProvisionalNavigation` (`NSURLErrorDomain` -1100), so the failure
  tests drive the real navigation path.[^task-18]
- The error reply names the extension-relative path the extension asked for,
  not the resolved URL: polyfill error strings are logged publicly.
- 1Password's offscreen document imports two vendor modules from a directory
  that does not exist in its bundle. The resulting "Unable to find … in the
  extension's resources" errors are its own bug and benign.
- The `createDocument` log line is info level and is not persisted, which once
  made it look as if a native implementation had served the call.[^task-71]

# Tests

[ExtensionPolyfillProfileWiringTests](../../DetourTests/ExtensionPolyfillProfileWiringTests.swift),
through `handleNativeMessage` and real `Profile` wiring:

- `testOffscreenCreateDocumentFailsAndUnregistersWhenPageIsMissing`
- `testLateOffscreenLoadFailureDoesNotUnregisterANewerHost`
- `testPendingOffscreenCreateDocumentFailsWhenTheDocumentIsClosed`
- `testConcurrentOffscreenCreateDocumentJoinsTheLoadInFlight`
- `testCancelledOffscreenNavigationKeepsTheCreateDocumentPending`
- the document is created in the sender's profile, with the same extension loaded in two.

`ExtensionPolyfillTests` covers the install marker, including simulated native
and non-configurable namespaces.

# Related

- [Polyfill layer](./polyfill-layer.md) — the request path and callback form.
- [Chrome runtime patching](./chrome-runtime-patching.md) — replacing a whole namespace.
- [ExtensionManager](./extension-manager.md) — context unload, which closes the document.
- [1Password integration](./1password-integration.md) — its one use of an offscreen document.

[^task-13]: Give ExtensionPolyfillHandler a profile back-reference
[^task-18]: offscreen.createDocument must reply and unregister its host when the page fails to load
[^task-71]: Which chrome.offscreen runs in the signed build, and make it observable
