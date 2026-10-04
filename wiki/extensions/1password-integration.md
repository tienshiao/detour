---
type: Overview
title: 1Password integration
description: What the 1Password extension needs from a browser, which Detour mechanism meets each need, how the desktop app's trust check works, and the gaps that remain.
tags: [extensions, 1password, native-messaging, service-worker, overview]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:48:49Z }
sources:
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan
  - id: host
    resource: ../../Detour/Extensions/Runtime/NativeMessagingHost.swift
    title: NativeMessagingHost.swift
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: deploy
    resource: ../../scripts/deploy-1password-test.sh
    title: deploy-1password-test.sh
  - id: task-2
    resource: backlog:TASK-2
    title: Service worker restart after idle termination
  - id: task-3
    resource: backlog:TASK-3
    title: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
  - id: task-4
    resource: backlog:TASK-4
    title: Iframe autofill — frame kinds on a real login page
  - id: task-5
    resource: backlog:TASK-5
    title: Verify passkeys, downloads and captureVisibleTab
  - id: task-6
    resource: backlog:TASK-6
    title: Is a Developer ID Debug build trusted by BrowserSupport
  - id: task-7
    resource: backlog:TASK-7
    title: Dev-only native messaging bridge app for Debug builds
  - id: task-15
    resource: backlog:TASK-15
    title: The polyfill must not replace the chrome/browser globals
  - id: task-21
    resource: backlog:TASK-21
    title: Signed-build verification of the keep-alive and the WebSocket relay
  - id: task-75
    resource: backlog:TASK-75
    title: Origin patterns with a port make chrome.permissions calls throw
  - id: task-80
    resource: backlog:TASK-80
    title: Polyfill chrome.storage.managed
  - id: task-81
    resource: backlog:TASK-81
    title: windows.getCurrent from a background worker reports Window not found
  - id: task-100
    resource: backlog:TASK-100
    title: Inject content scripts into srcdoc and about:blank frames
  - id: task-101
    resource: backlog:TASK-101
    title: The inline menu does not open from a form inside a cross-origin iframe
  - id: task-102
    resource: backlog:TASK-102
    title: The Private worker throws on a.providers
  - id: notes-1password
    resource: "Agent session notes, 2026-09-11 to 2026-09-21 (not in the repository)"
    title: Session notes on the 1Password integration
---

# Summary

1Password is the extension that drove most of Detour's extension work beyond
what WebKit provides. It is an MV3 extension with an ES-module service
worker, `<all_urls>` host access and WASM, and it talks to the desktop app
only through native messaging. With the mechanisms below it unlocks, fills,
receives live vault changes and keeps its workers up while the desktop app is
connected, in normal and (when allowed) Private windows. Last verified in the
signed build on 2026-09-21 with extension 8.12.26.40: three workers held for
19 to 23 minutes with every keep-alive ping answered.[^task-21]

Each profile where the extension is enabled runs its own worker with its own
native host process, so three profiles mean three of each.

[docs/1password-integration-plan.md](../../docs/1password-integration-plan.md)
is the long-form record with timelines and log excerpts. Its opening status
paragraph and summary date from 2026-09-11 and describe a blocker that has
since been fixed; read it for evidence, not for current state.

# What it needs, and what provides it

| Need | Provided by | Page |
|---|---|---|
| The same extension id as in Chrome, because the desktop app's host manifest lists it in `allowed_origins` | Chrome-compatible id derivation from the CRX public key | [Installer and CRX](./installer-and-crx.md) |
| A native messaging channel to `com.1password.1password` | Host discovery in Chrome's `NativeMessagingHosts` directories, stdio framing | [Native messaging](./native-messaging.md) |
| A worker that lives as long as its native port, as in Chrome | Detour-driven pings on a built-in port | [Native port keep-alive](./native-port-keep-alive.md) |
| A `WebSocket` in the worker for the server push notifier (WebKit's deadlocks the worker) | Sockets relayed through `URLSessionWebSocketTask` | [WebSocket relay](./websocket-relay.md) |
| Its service-worker registration and IndexedDB not being purged | User interaction logged for the extension origin | [Data store and ITP](./data-store-and-itp.md) |
| Popup and content scripts reaching the worker with `runtime.sendMessage` | The polyfill never replaces `chrome` / `browser` | [Never replace chrome globals](../decisions/never-replace-chrome-globals.md) |
| `runtime.onInstalled` exactly once (it opens the welcome page) | Detour's own ledger and delivery | [runtime.onInstalled](./runtime-installed-event.md) |
| An offscreen document (used once, for a localStorage migration) | Detour's `chrome.offscreen`; WebKit ships none | [Offscreen documents](./offscreen-documents.md) |
| Every tab that runs its content script being a known tab, including favourites and Peeks | Registration at web view creation | [Tab and window bridge](./tab-and-window-bridge.md) |
| Not being asked to unlock at launch | The Extensions menu never loads a popup page | [Popup and options UI](./popup-and-options-ui.md) |
| Working in Private windows | Per-extension "Allow in Private" | [Private profile extensions](./private-profile-extensions.md) |
| Updates from the Chrome Web Store | Verified CRX updates | [Updates](./updates.md) |

## API gaps it hits

All in `ExtensionAPIPolyfill`, each installed only where WebKit leaves a gap
and recorded in the polyfill diagnostics (`_polyfillDiag.apis`):

| API | Why 1Password needs it | Detour's answer |
|---|---|---|
| `storage.managed` | 8.12.37 touches `storage.managed.onChanged` synchronously during init; the `TypeError` aborted init, no host was ever started and the popup showed only a spinner[^task-80] | Empty, read-only managed area |
| `permissions.contains` with a ported origin | It builds the origin pattern of every page; WebKit match patterns reject a port and **throw synchronously**, so no form on a `host:port` site got a control[^task-75] | The port is stripped before the call |
| `privacy.services.*` | Dereferenced without an existence check | No-op settings, `not_controllable`, only with the `privacy` permission |
| `webRequest.onAuthRequired` | Registered unguarded in the same block as its navigation listeners | Never-firing event, only with the `webRequest` permission |
| `management.setEnabled` | Disables other 1Password channel builds | No-op |
| `action.getUserSettings` | Feature-detected | `{isOnToolbar: true}` |

Natively provided and load-bearing: `alarms` (its wake source),
`webNavigation.getAllFrames` / `getFrame` with WebKit's own frame ids, and
MAIN-world injection of its WebAuthn listener script (it appears to run; not
confirmed on a real passkey flow). See
[frames and content scripts](./frames-and-content-scripts.md) and
[polyfill layer](./polyfill-layer.md).

# Trust

The desktop app's helper (`1Password-BrowserSupport`) verifies the process
that spawned it. Detour cannot influence this; it can only be a build the
helper accepts.

- The grant is per machine, made by the user in 1Password, and stored in
  1Password's settings under `browsers.other-trusted-apps`, keyed by bundle
  id with the `/Applications/Detour.app` path.[^plan]
- It behaves as a code-signing requirement plus that path, not a build hash:
  a rebuilt and re-signed app does not need re-approval.[^notes-1password]
- A Debug build running from DerivedData is **not** trusted, even though it
  is signed with the same identity. Whether the same build copied to
  `/Applications` would pass is untested.[^task-6]

| What 1Password reports | Meaning |
|---|---|
| `parent browser was not valid` / `UnsupportedBrowser` | The spawning build is not acceptable (wrong path or signature) |
| `BrowserVerificationFailed` / `Disconnected from Desktop app due to UnknownBrowser` | The build is fine but this machine has no trust grant for Detour yet |

In both cases Detour's own log shows a successful connect and frames being
sent; the refusal is visible only on 1Password's side. The helper's logs are
per host process in 1Password's group container
(`…/Data/logs/BrowserSupport/`; search for `Detour`).

The practical consequence: anything that needs a live desktop-app session
can only be checked in the signed build. `scripts/deploy-1password-test.sh`
builds Release, signs, copies to `/Applications` and relaunches. A dev-only
bridge app that would let a Debug build borrow a trusted parent is an
unbuilt idea.[^task-7]

# Behaviour worth knowing when testing

- **The desktop app must be running and unlocked first.** Otherwise each
  worker connects, gets no app, disconnects after 10 s and tries the absent
  1Password 7 host.[^task-21]
- **Locking does not disconnect the host; quitting gets undone**, because the
  extension relaunches the app. To bring the host count to zero, turn off
  "Integrate with 1Password app" in the extension's own settings in one
  profile and use the others as the control.[^task-21]
- **A remote vault change** shows as `[Syncer] Sync started … reason code: 7`
  in every worker within a fraction of a second.
- **Extension console text is `<private>`** unless the
  [console bridge](./console-bridge.md) is made public for the session.
- **The installed, unpacked extension is readable** under the data
  directory's `Extensions/<id>/`. Its sources are minified but error strings
  and message names can be searched for, which is how several of the gaps
  above were diagnosed.
- **It declares no options page** (8.12.37.1), so the "Settings…" entry
  points are hidden for it by design.[^notes-1password]

# Known gaps

| Gap | State |
|---|---|
| No control on login forms inside `srcdoc` or script-filled `about:blank` iframes: WebKit reports their URL as empty and injects no content script | Measured in tests and in the signed build[^task-100] |
| In a cross-origin iframe the control is drawn but clicking it opens no menu | Seen in the signed build, undiagnosed[^task-101] |
| `windows.getCurrent()` from the worker reports "Window not found" at every start, and 1Password's callback then throws on `A.id` | Not blocking; cause believed to be the focused-window lookup returning nothing for a profile without the key window[^task-81] |
| Rejections on `a.providers` in the Private worker | Unexplained; worker keeps running[^task-102] |
| Basic-auth fill | Unsupported: WebKit has no blocking request interception |
| Passkeys, export through `downloads`, QR scanning through `captureVisibleTab` | Not verified[^task-5] |
| Item cache is cold at every launch | Extension storage does not survive a relaunch; see [storage](./storage.md) |
| `[Tabs] Could not collect all frames that were initially found` | Seen occasionally; the empty-URL-frame explanation was tested and rejected[^task-4] |

Benign noise, not Detour's: `Unable to find "background/offscreen/vendor/semver.js"`
(the extension's offscreen page imports files its bundle does not contain), a
`WASM is not initialized` rejection at start (a race inside the extension),
and hourly `Received unknown message from b5x` in the helper's log.

# Lessons that generalise

- **Sample the production process.** Five harness experiments could not
  reproduce the worker deadlock, because the code path needs a real
  desktop-app session. One `sample` of the worker's WebContent process found
  it.[^task-2]
- **A symptom that follows the extension's version is not a platform
  regression.** The spinner-only popup looked like a macOS or WebKit change
  but depended only on the extension: 8.12.37.1 has the code path, and the
  machine where it kept working ran 8.12.26.40.[^task-80]
- **Silence from the worker has at least four causes** that look the same
  from outside: a deadlocked main thread, a proxied `chrome` global, a
  registration purged by tracking prevention, and WebKit's private-data gate.
  The [diagnosis playbook](../playbooks/diagnosing-extension-problems.md)
  tells them apart.
- **Never log native messaging payloads.** An early build logged payload
  previews and put account key material in the unified log.[^plan]

# Related

- [Extensions overview](./overview.md) — the system this sits on
- [Signed-build verification](../playbooks/signed-build-verification.md) — the session recipe
- [Service worker unload rules](../platform/service-worker-unload-rules.md) — the WebKit behaviour behind the lifetime work
- [Testing extensions](./testing-extensions.md) — what can and cannot be checked without the desktop app
- [Claude extension epic](./claude-extension-epic.md) — the next extension with needs beyond WebKit's

[^plan]: 1Password integration plan
[^task-2]: Service worker restart after idle termination
[^task-4]: Iframe autofill — frame kinds on a real login page
[^task-5]: Verify passkeys, downloads and captureVisibleTab
[^task-6]: Is a Developer ID Debug build trusted by BrowserSupport
[^task-7]: Dev-only native messaging bridge app for Debug builds
[^task-21]: Signed-build verification of the keep-alive and the WebSocket relay
[^task-75]: Origin patterns with a port make chrome.permissions calls throw
[^task-80]: Polyfill chrome.storage.managed
[^task-81]: windows.getCurrent from a background worker reports Window not found
[^task-100]: Inject content scripts into srcdoc and about:blank frames
[^task-101]: The inline menu does not open from a form inside a cross-origin iframe
[^task-102]: The Private worker throws on a.providers
[^notes-1password]: Session notes on the 1Password integration
