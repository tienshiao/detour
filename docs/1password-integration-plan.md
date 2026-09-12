# 1Password Integration Plan

**Status (2026-09-11):** A Developer ID–signed build of HEAD (`7cb6843`) was deployed to
`/Applications/Detour.app` and tested end-to-end. 1Password trusts the app, native messaging works,
accounts unlock, and sessions are issued. The extension then becomes unusable about two minutes
after launch because WebKit terminates the idle service worker and every restart attempt hangs.
That restart failure is the single blocker for day-to-day use; everything else in this document is
secondary to it.

See also: [extensions.md](extensions.md), [chrome-runtime-patching.md](chrome-runtime-patching.md).

## Summary

The WKWebExtension migration plus the polyfill layer cover almost everything 1Password's manifest
requests. Native messaging (`connectNative` + `sendNativeMessage`, Chrome-compatible host-manifest
discovery, length-prefixed stdio framing) is implemented and verified working against
`1Password-BrowserSupport`. 1Password's trust grant is recorded in its `settings.json` under
`browsers.other-trusted-apps`, keyed by bundle ID with the `/Applications/Detour.app` path.

What remains, in priority order:

1. Make the background service worker survive (or correctly restart after) idle termination.
2. Close a small set of cheap API gaps (`privacy`, `webRequest.onAuthRequired`,
   `management.setEnabled`).
3. Real frame enumeration for iframe autofill.

## Reference data

- Extension: 1Password v8.12.26.40, ID `aeblfdkhhhdcdjpifhhbdiojplfjncoa`, installed unpacked at
  `~/Library/Application Support/Detour/Extensions/aeblfdkhhhdcdjpifhhbdiojplfjncoa/`.
- Manifest: MV3, ES-module service worker (`background/background.js`), `minimum_chrome_version:
  128`, `host_permissions: <all_urls>`, WASM (`'wasm-unsafe-eval'`).
- Permissions declared: `alarms`, `contextMenus`, `downloads`, `idle`, `management`,
  `nativeMessaging`, `notifications`, `offscreen`, `privacy`, `scripting`, `storage`, `tabs`,
  `webNavigation`, `webRequest`, `webRequestAuthProvider`, `declarativeNetRequestWithHostAccess`
  (static ruleset `rules_1.json`, a single `modifyHeaders` rule for DNS-over-HTTPS probes).
- Native host binary:
  `/Applications/1Password.app/Contents/Library/LoginItems/1Password Browser Helper.app/Contents/MacOS/1Password-BrowserSupport`.
  Host manifest lives in Chrome's `NativeMessagingHosts` dir and lists our ID (we reuse Chrome's
  stable-channel extension ID, so no separate manifest is needed).
- **Native messaging is the only desktop-app channel.** The `http://127.0.0.1:<port>` entries in the
  CSP are the Kolide device-trust agent client scanning a fixed port list. They are irrelevant for
  personal use and need no work.
- BrowserSupport logs (one file per host process, grep for `Detour`):
  `~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs/BrowserSupport/`.

### What 1Password actually calls (from the shipped bundle)

Verified by grepping the minified sources, not the manifest:

- **Background only:** `privacy.services.{passwordSavingEnabled,autofillEnabled,
  autofillCreditCardEnabled,autofillAddressEnabled}`; `webNavigation.{getFrame,getAllFrames,
  onBeforeNavigate,onCommitted,onCreatedNavigationTarget,onDOMContentLoaded}`;
  `webRequest.{onAuthRequired,onBeforeRedirect,onHeadersReceived}`; `management.{getAll,getSelf,
  setEnabled}`; `permissions.{contains,addHostAccessRequest,removeHostAccessRequest}`;
  `offscreen.{createDocument,closeDocument}`; `runtime.{connectNative,sendNativeMessage}`;
  `scripting.{executeScript,insertCSS}` (isolated world only, never `world: "MAIN"`);
  `tabs.captureVisibleTab`; `downloads.{download,onChanged}`; `action.getUserSettings`;
  `storage.{local,session}`; `alarms`, `idle`, `notifications`, `contextMenus`, `commands`,
  `i18n.getUILanguage`, `extension.getViews`.
- **Content scripts:** `runtime.{getURL,id,onMessage,sendMessage}`, `tabs.sendMessage`,
  `dom.openOrClosedShadowRoot` (in `inline/injected.js`).
- **Not used at all:** `declarativeNetRequest` JS API (static ruleset only), `cookies`, `identity`,
  `userScripts`, `sidePanel`, `webAuthenticationProxy`, `runtime.getBrowserInfo`.
- `chrome.privacy.services.*` is dereferenced **without** a `chrome.privacy` existence check in two
  functions (the "make 1Password the default password manager" setter and its getter). Both throw
  a `TypeError` today; the service worker keeps running regardless.
- `webRequest.onAuthRequired.addListener(fn, {urls: ["<all_urls>"]}, ["asyncBlocking"])` is
  registered unguarded in the same block as the `webNavigation` listeners.
- `management.setEnabled` is only ever used to disable *other* 1Password channel builds. A no-op is
  correct.
- `permissions.addHostAccessRequest` and `action.getUserSettings` are feature-detected.
- The only MAIN-world code is the manifest entry for `inline/injected/webauthn-listeners.js`.
- The offscreen document (`background/offscreen.html`) is used once for a localStorage migration.
  Its module imports `./vendor/semver.js` and `./vendor/just-pick.js` relative to
  `background/offscreen/`, where no `vendor/` directory exists. The resulting "Unable to find …
  in the extension's resources" errors are 1Password's bug and are benign.

## Findings from the 2026-09-11 test session

Timeline from the unified log (`native-messaging`, `extension-polyfill`, `EXT-LOAD` categories) and
WebKit's `ServiceWorker` category:

| Time     | Event |
|----------|-------|
| 14:56:44 | New build launches. BrowserSupport verifies `/Applications/Detour.app/Contents/MacOS/Detour` and connects. |
| 14:58–14:59 | `NmRequestAccounts`, unlock, `NmRequestDelegatedSession` all succeed. Trust grant written to 1Password's `settings.json`. |
| 14:58:59 | Service worker logs `[Tabs] Could not collect all frames that were initially found.` |
| 15:01:14 | WebKit terminates the idle service worker (~2 min after last activity). Its three native ports close; Detour SIGTERMs the three BrowserSupport processes. |
| 15:01:44 onward | Once per minute WebKit re-registers the service worker in a fresh WebContent process. Registration never progresses past `addRegistration`. ~30 s later the context reports `The background content failed to load due to an error.` |
| 15:12+   | Still failing. No further service-worker output for the rest of the session. |

Conclusions:

- **Trust and native messaging are done.** Do not spend more time there.
- **The service worker restart is the blocker.** Chrome also terminates idle workers and 1Password
  reconnects on wake, so the goal is a working restart, not preventing termination.
- **Frame enumeration is a real functional gap**, confirmed by the `[Tabs]` log line.
- **`chrome.privacy` is not a hard blocker.** Stub it because it is cheap, not because it is urgent.
- **MAIN-world injection appears to work.** A `[Webauthn] _handleGetCredential` line fired during
  the session, and the manifest entry is the only MAIN-world path. Needs one confirmation on a
  passkey site.
- **Diagnostics gaps found:** the service-worker console bridge serializes `Error` objects as
  `{}`, so every "Caught exception" line from 1Password arrived without its message; and the
  `errorsDidUpdate` observer in `Profile.swift` re-logs the whole accumulated error array on every
  update, which made the failure look like dozens of distinct errors.

### Security note

`NativeMessagingHost.swift` logged 500-byte previews of every native message payload at notice level
with public privacy. During this session the unified log store therefore contained the account
Secret Key, unlock-key material, and session keys in plaintext. The previews have been removed
(payloads must never be logged on this channel), and the existing log store should be purged:

```
sudo log erase --all
```

## Plan

### Phase 0 — Hygiene (before the next deploy)

- Redact native messaging payload logging (done as part of this revision).
- Purge the unified log store.
- Serialize `Error` objects in the polyfill console bridge as `name: message` plus stack so
  1Password's own exception messages survive the bridge (done, TASK-1; errors nested in
  objects serialize as `{name, message, stack}`).
- Log only newly added errors in the `errorsDidUpdate` observer (done, TASK-1; the line now
  carries `domain=` / `code=`).

### Phase 1 — Service worker restart after idle termination

Goal: after WebKit terminates the idle background service worker, the next wake must succeed and
1Password must reconnect its native ports.

**Status (2026-09-11 evening, TASK-2, done):** root cause found by sampling the production process
(a WebSocket deadlock in the worker, below), three-layer fix implemented, verified in the isolated
harness and then in production: with the fixed build deployed at 18:50, the worker and all three
native-messaging helpers were still alive after 15 idle minutes; the build without the WebSocket
guard lost them at 2.5 minutes.

#### How WebKit runs an extension service worker (from WebKit source, `WebExtensionContextCocoa.mm`)

- The "background" is a hidden `WKWebView` that loads a one-line page calling
  `navigator.serviceWorker.register(url)`. The load is reported successful when that promise
  settles (`willSettleRegistrationPromise` → `didFinishServiceWorkerPageRegistration`).
- 30 s after a load or wake, `unloadBackgroundContentIfPossible` closes the hidden page. If the page
  has open ports (native or runtime), the unload is deferred until 2 minutes after the last message
  the background posted on any port (`delayForInactivePorts`). Closing the hidden page fails any
  still-pending load with `WKWebExtensionContextError.backgroundContentFailedToLoad` (code 6).
- Closing the hidden page normally makes the network process's `SWServer` clear the registration
  and terminate the worker (`SWServerRegistration::clear`), so the next wake registers afresh,
  fetches the script and creates a new worker.

#### What production does instead

Captured live at 17:53 on the 14:56 build: every wake creates a new hidden page, `register()`
resolves instantly as `SWServerJobQueue::runRegisterJob: Found directly reusable registration 36`
with `active=50, state=4 (activated)`, the network process still believes worker 50 lives in the
*original* content process from 14:56 (still alive, silent), no script is fetched, no worker is
created, and 30 s later code 6 is recorded. The network process logged nothing but "reusable
registration" for over an hour. So the registration created at the first load was never torn down
when the background unloaded at 15:01, and every wake reuses it. Upstream WebKit reworked exactly
this area on 2026-08-31 (commit 4ce58a7ff7, "Extension service worker loses clients when it is
unloaded and reloaded"), which is not in the shipped WebKit.

#### Harness experiments (Debug build, isolated `DETOUR_DATA_DIR` profiles, 1-minute alarm as wake)

| Case | Result |
|------|--------|
| classic worker probe, api-explorer | unload at +30 s, registration cleared, alarm restarts a fresh worker every minute for 8 min |
| module-type worker probe | identical → module type is not the cause |
| classic worker + never-closed offscreen document | identical → a lingering offscreen client alone is not the cause |
| classic worker holding a native port to a silent fake host | 2-minute inactive-ports path taken, then clean unload and restart |
| 1Password itself (native messaging untrusted, ports close at once) | restarts cleanly every minute with fresh registrations |

None reproduce the stuck registration. The trigger was found by sampling the production process.

#### Root cause: the worker deadlocks on `new WebSocket()`

`sample` of the hidden page's content process on the redeployed build (18:45) showed its **main
thread** parked in `WorkerThreadableWebSocketChannel`'s constructor, reached from 1Password's worker
JS calling `new WebSocket()` (its `@1password/web-api` server push notifier). WebKit runs an
extension's background service worker on the main thread of its content process
(`WorkerMainRunLoop`), and the worker WebSocket channel blocks the calling thread on a semaphore
until the main thread creates the channel. On a main-thread worker that wait can never end.

Everything observed follows from the frozen process: the worker's event loop stops (no keep-alive
pings, no more native-messaging traffic), WebKit's 2-minute inactive-ports unload closes the hidden
page but the process never handles the close, so the page's service worker client is never
unregistered and the registration is never cleared; the worker and its process linger silently
(hours in the 14:56 session); and every wake reuses the registration with no worker, failing
loudly (code 6) when the new hidden page lands in the frozen process and silently when it gets a
new process. The harness never reproduced because without a desktop-app session 1Password never
reaches the notifier code. Upstream WebKit `main` still has the synchronous wait
(`WorkerThreadableWebSocketChannel.cpp`), so this is worth a WebKit bug report.

#### Fix

0. **WebSocket guard** (`ExtensionAPIPolyfill.webSocketGuardJS`): in service worker contexts,
   `WebSocket` is replaced by a stand-in that fails the connection asynchronously (`error`, then
   `close` with code 1006), the path extensions already handle for an unreachable server. The real
   constructor stays available as `__detourNativeWebSocket`. 1Password loses only live vault-change
   notifications until a real WebSocket relay exists (candidate follow-up: relay sockets through
   Detour with `URLSessionWebSocketTask` over the polyfill port). Verified with a worker probe that
   opens a socket at startup: it gets `error` and `close`, stays alive, and restarts on every alarm.

   **Status (2026-09-12, TASK-8, done):** that follow-up shipped, and the module is now
   `ExtensionAPIPolyfill.webSocketRelayJS`: worker sockets are *relayed* through Detour rather than
   failed, so 1Password's notifier gets a working socket again (see "WebSocket relay (TASK-8)"
   below). The guard survives as the module's fallback for any context that cannot reach the relay
   host, and what this all avoids is unchanged: nothing ever constructs WebKit's worker WebSocket.
1. **Prevention, Chrome parity — Detour drives the keep-alive** (TASK-16;
   `ExtensionAPIPolyfill.nativePortKeepAliveJS`, `NativeHostKeepAliveState`,
   `ExtensionManager.webExtensionController(_:connectUsing:…)`): Chrome keeps a service worker
   alive while it holds a native messaging port. The worker cannot detect its own native ports in
   WebKit (see the TASK-15 history below), but Detour knows natively, from
   `NativeMessagingHost.connect()` / its exit, exactly when a real host is connected, so the
   decision lives on the native side and the worker only obeys:

   - At startup the worker opens **one idle port** to Detour's own `detourPolyfill` host with a
     plain `chrome.runtime.connectNative('detourPolyfill')` — nothing is wrapped, and the
     `chrome`/`browser` globals and `runtime.connectNative` are never touched. ExtensionManager
     accepts the port without spawning a process and holds it (one per extension per controller).
     Only in extensions whose manifest declares `nativeMessaging`: nothing else can ever have a
     host, and an idle port would still move that worker off WebKit's 30 s idle unload onto the
     2-minute inactive-ports path (and retain a port in Detour) for nothing.
   - `NativeHostKeepAliveState` (pure, unit-tested in `NativeHostKeepAliveTests`) tracks, per
     (controller, extension), how many real hosts are connected and whether the worker's port is
     open. On the first host with the port open it answers `.sendStart` and Detour posts
     `{type: "keepalive-start"}` on the port; when the last host exits it answers `.sendStop`
     (`{type: "keepalive-stop"}`). One-shot `sendNativeMessage` hosts never count; live hosts are
     held in a per-(controller, extension) registry, so a host is released exactly once whether its
     process exit or the port's disconnect comes first, and a late release from a host whose
     extension has since been reloaded cannot disarm a keep-alive a *new* host is holding up. A
     control message that fails to send clears `armed` and is retried a second later while it is
     still wanted (`controlSendFailed` / `reconcile`).
   - While armed the worker posts `{type: "keepalive"}` on that port immediately and then every
     45 s. If Detour drops the port the worker reconnects with a capped backoff (1 s, doubling, 30 s
     max), disarmed, and Detour re-arms the new port from `portOpened` if hosts are still connected,
     so the worker never has to remember anything.

   Why this works, measured: WebKit unloads the background 30 s after a load/wake, but while the
   background has open ports the unload is deferred until 2 minutes after the last message the
   *background* posted on any of them (`delayForInactivePorts`). Posting on the Detour port is such
   a message: the TASK-2 harness (2026-09-11 18:14) held a native port for 3 minutes with pings
   flowing and saw no unload, then an idle unload 30 s after release and a clean restart on the
   next alarm.

   **History — 2026-09-11 22:40 (TASK-15): the worker-side detection this replaces was inert, and
   its first version broke the popup.** The original design wrapped `runtime.connectNative` in the
   worker to count real ports itself. WebKit re-materializes that property on every read
   (assignment and `defineProperty` complete, the read-back is always a fresh native function), so
   the wrap never took (`installMode: 'none' (patch-rejected)`). Its fallback shadowed the
   `chrome`/`browser` globals with proxies; WebKit's message dispatcher unwraps those globals to
   find the worker's `onMessage` listeners, cannot unwrap a proxy, and answered every
   `runtime.sendMessage` to the worker with the empty default reply — which is why 1Password's
   popup showed "Oops, something went wrong while loading" (`get-popup-config` got no reply). Both
   the wrap and the fallback are gone; see `docs/chrome-runtime-patching.md` "Level 3".
2. **Recovery** (`Profile.recoverFromBackgroundLoadFailure`): when the context records code 6, unload
   and reload the context in that profile, re-associate its windows and tabs, and call
   `loadBackgroundContent`. The new context gets a new `webkit-extension://` base URL, so the stale
   registration (keyed by the old origin) is simply never consulted again. Rate-limited to three
   reloads per ten minutes per extension so a genuinely broken background script cannot loop.
   `unloadExtension` also stops the extension's offscreen document host, which belongs to the old
   origin. Verified in the harness with a worker that throws at top level: three reloads, then
   "keeps failing to load; giving up".

Diagnostics added on the way: the console bridge reports uncaught exceptions and unhandled
rejections from the worker (`[uncaught exception] (file:line:col) Name: message`), which is how the
harness cold-start failure was diagnosed in one run; and Debug builds honor
`DETOUR_NATIVE_MESSAGING_HOSTS_DIR` to point a host name at a stand-in binary.

#### Log filters

Detour side (the network process lines are the ones that say whether a registration was reused or
cleared; `log show` cannot run inside the Claude Code sandbox and debug-level lines are retained for
roughly an hour):

```
log show --last 30m --style compact --info --debug --predicate 'process == "Detour" AND (category == "native-messaging" OR category == "EXT-LOAD" OR (subsystem == "com.apple.WebKit" AND category == "ServiceWorker"))'
log show --last 30m --style compact --info --debug --predicate 'process == "com.apple.WebKit.Networking" AND category == "ServiceWorker" AND (eventMessage CONTAINS "runRegisterJob" OR eventMessage CONTAINS "clear" OR eventMessage CONTAINS "erminat")'
```

1Password's own service-worker console output (the `[SW <id>]` lines in the `extension-polyfill`
category) is logged **privately by default**, because it can contain native-messaging responses.
For a debugging session either launch with the argument `-ExtensionConsoleLogPublic YES` (argument
domain, nothing persisted) or opt in with defaults and revert afterwards:

```
defaults write com.detourbrowser.mac ExtensionConsoleLogPublic -bool YES
defaults delete com.detourbrowser.mac ExtensionConsoleLogPublic
```

Add `OR category == "extension-polyfill"` to the Detour predicate to include it. Purge the log store
again after such a session.

#### WebSocket relay (TASK-8)

A worker's `WebSocket` is `RelayedWebSocket` (`ExtensionAPIPolyfill.webSocketRelayJS`), a full
implementation of the interface that owns no socket at all: it opens a native messaging port to
Detour's own `detourWebSocketRelay` host and speaks JSON over it, while `WebSocketRelaySession`
(`Detour/Extensions/Runtime/WebSocketRelay.swift`) drives a real `URLSessionWebSocketTask` in the
app process. One socket = one port = one session; `ExtensionManager` keeps them per (controller,
extension) and `closeExtensionPorts(for:in:)` tears them down with the context.

Like the polyfill host, the relay host is accepted by `ExtensionManager.nativeHostAccess` *without*
the `nativeMessaging` manifest permission — a worker may open a WebSocket whether or not it declares
native messaging, and this port is now the only way it can. It spawns no process, and a one-shot
`sendNativeMessage` to it is refused ("port-only host") so it can never be mistaken for a real host.

| worker -> native | native -> worker |
|---|---|
| `{op:'open', url, protocols:[String]}` (once) | `{op:'open', protocol, extensions}` |
| `{op:'send', text}` | `{op:'message', text}` |
| `{op:'send', binary}` (base64) | `{op:'message', binary}` (base64) |
| `{op:'close', code, reason}` | `{op:'close', code, reason, wasClean}` — then the port is dropped |
| | `{op:'error', message}` — always followed by a close |

**An open relayed socket keeps the worker alive**, through the same
`NativeHostKeepAliveState` a native host feeds (`connectedHosts` counts both): `openWebSocketRelay`
applies `.hostConnected` and the port's disconnect chain applies `.hostDisconnected`, so
`keepalive-start` stands while any socket *or* host is live. Without it a quiet long-lived socket —
which is exactly what 1Password's notifier is — dies with the worker WebKit unloads after ~2.5
minutes idle, and the extension sees an `error` and a 1006 every few minutes. This is deliberately
broader than Chrome, which keeps a worker alive for a native *port* but only resets a worker's idle
timer on actual socket traffic: WebKit's inactive-ports rule counts messages the background *posts*,
so there is nothing to hook incoming frames onto, and an idle-but-open socket is precisely the case
that has to survive. The cost is one worker held up per open socket, which is what the extension
asked for by keeping the socket open.

The handshake carries **the owning profile's cookies** for the origin, as Chrome's does (a fresh
ephemeral `URLSession` sends none, so a credentialed socket to a site the user is signed into in
that profile would fail). `ExtensionManager` passes a provider over the profile's
`dataStore.httpCookieStore`; `WebSocketRelaySession` filters the jar down to what applies (domain,
path, `Secure`, expiry) and sets the `Cookie` header on the handshake request. Subprotocols travel
in the `Sec-WebSocket-Protocol` header, since a `URLRequest` handshake takes no protocols parameter.

The URL is validated natively (ws/wss, parseable, no fragment) and in JS (plus the browsers'
http/https -> ws/wss rewrite); a protocol violation (an op before `open`, a second `open`, an unknown
op) is answered with `error` + `close` 1006 and ends the session. A dropped port fails the socket as
1006 in the worker, which is what an extension already handles.

Gaps, all deliberate:

- **The extension's CSP `connect-src` is not applied.** WebKit enforces it on its own WebSocket
  channel, which the relay bypasses entirely; Detour does not re-implement CSP parsing.
- **No host-permission check**, matching Chrome: it does not CORS-restrict WebSockets opened from an
  extension worker either, so requiring host permissions here would break extensions that work
  everywhere else. The gate that remains is that only a loaded extension context can open the port.
- **Cookies are read at handshake time only.** The profile's jar is snapshotted for the `Cookie`
  header when the socket opens; nothing is written back, a `Set-Cookie` on the 101 response is not
  stored, and a cookie that changes later does not affect a socket already open.
- **Application close codes (3000-4999) go out on the wire as 1000.**
  `URLSessionWebSocketTask.CloseCode` models only the registered codes, so the frame carries a
  normal closure — the worker's own `CloseEvent` still reports the code it asked for.
- **Frames are base64 over the port and pass through the main thread**, so a very large binary
  message costs about 33% more bytes than the wire frame plus a main-thread hop each way. Fine for
  1Password's notifier traffic; not a transport for bulk data.
- The guard fallback stays for contexts with no reachable relay host (`__detourWebSocketRelay.mode`
  reports `relay` or `guard`; the polyfill diagnostics carry it as `apis.webSocket`, which is
  `native` in page contexts, where the module does not install at all).

Tested at three levels: `WebSocketRelaySessionTests` (the session against a real loopback WebSocket
echo server, with a fake port), `ExtensionPolyfillTests` (the JS state machine against a fake
`connectNative`), and two real-worker round trips —
`ExtensionPolyfillIntegrationTests.testWorkerWebSocketIsRelayedToARealServer` and
`ExtensionPolyfillProfileWiringTests.testWorkerWebSocketIsRelayedAndReleasedThroughTheProductionWiring`
(the production Profile wiring, including that Detour holds exactly one session while the socket is
open and none after it closes).

### Phase 2 — Cheap, high-confidence stubs (parallelizable with Phase 1)

All small additions to `ExtensionAPIPolyfill.swift` / `ExtensionPolyfillHandler.swift`, each with
API Explorer and test coverage per project convention:

- `chrome.privacy.services.*` as `ChromeSetting`-shaped objects (`get`/`set`/`clear`/`onChange`)
  that no-op and report `levelOfControl: "not_controllable"`. Detour has no built-in password
  manager, so this is honest.
- `chrome.webRequest.onAuthRequired` as a no-op event emitter if WebKit does not provide it, so the
  unguarded `addListener` call cannot throw and abort the rest of 1Password's listener setup.
  Basic-auth fill stays unsupported; WebKit has no blocking request interception.
- `management.setEnabled` native dispatch case returning success without doing anything.
- Confirm `action.getUserSettings` is provided natively; stub `{isOnToolbar: true}` if not.

### Phase 3 — Real frame enumeration

1Password calls `getAllFrames({tabId})`, filters by URL, and fans messages out to every frame with
`tabs.sendMessage(tabId, msg, {frameId})`. It also calls `getFrame({tabId, frameId})` to obtain
`parentFrameId` and relay messages one level up. Consequences for the design:

- **Frame IDs must be WebKit's.** The IDs returned must match `sender.frameId`, the `frameId`
  option on `tabs.sendMessage`, and `frameIds` on `scripting.insertCSS`, or messages go to
  nonexistent frames. A home-grown numbering scheme is unusable.
- **The registry belongs in the service-worker polyfill, not native code.** A content script cannot
  learn its own frame ID, but the worker sees it as `sender.frameId` on any message. Have the
  content polyfill (already injected with `all_frames: true`) send a hello on injection and a
  goodbye on `pagehide`; the worker keeps a per-tab map of `frameId → {url, parentFrameId}`.
- **Parent IDs:** depth-one frames report `parentFrameId: 0` when `window.parent === window.top`.
  For deeper nesting, the worker replies to the hello with the frame's own ID; the content script
  posts it to `window.parent` via `postMessage`; the parent's content script forwards
  `{childFrameId}` to the worker, which now knows the parent of that child.
- **Cleanup:** drop entries on `tabs.onRemoved` and on `webNavigation.onCommitted` for the same
  frame ID (a navigation replaces the frame's document).
- **Before building any of it**, record in `_polyfillDiag` whether `chrome.webNavigation.getAllFrames`
  was already present natively. The polyfill only installs when WebKit lacks it, and the answer
  determines whether this phase is needed at all.

### Phase 4 — Verification and polish (optional)

- Passkeys: confirm the MAIN-world `webauthn-listeners.js` intercepts a real `navigator.credentials`
  call on a passkey-enabled site.
- `downloads` API (used for export flows only).
- `tabs.captureVisibleTab` (used for QR-code scanning).
- Test whether a Developer ID–signed **Debug** build in DerivedData is trusted by BrowserSupport.
  `project.yml` signs both configurations with the same identity; the only known difference is the
  path stored in 1Password's trust record. If it works, the Release build and `/Applications` copy
  can be dropped from the iteration loop. **Answer (2026-09-11): not trusted from DerivedData.**
  BrowserSupport logs `Verifying browser ".../DerivedData/.../Debug/Detour.app/..."` →
  `parent browser was not valid` → `UnsupportedBrowser`. Untested: the Debug configuration copied to
  `/Applications`. A dev-only bridge app is tracked as TASK-7.

## Recommendation

Phase 0 and Phase 1 first, in that order. Phase 1 is the whole game: until the worker survives past
its first idle termination, no other fix is observable for more than a couple of minutes. Phase 2
can ride along in the same deploys. Phase 3 is the largest remaining functional win once the worker
is stable.
