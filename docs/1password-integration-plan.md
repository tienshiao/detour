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
- **Decision (TASK-25, 2026-09-12): a saved `nativeMessaging` denial blocks real native hosts.**
  Turning the extension's "Communicate with native applications" switch off in Settings writes a
  denied `nativeMessaging` row, and that row is enforced where a host is dispatched —
  `ExtensionManager.nativeHostAccess`, consulted by both `WKWebExtensionControllerDelegate` paths
  that can spawn a `NativeMessagingHost` (`sendMessage(toApplicationWithIdentifier:)` for
  `sendNativeMessage`, `connectUsing:` for `connectNative`). A denied host is refused before a host
  object exists, so nothing is looked up or spawned: `sendNativeMessage` rejects and
  `connectNative`'s port disconnects with `port.error`, both carrying Chrome's "Access to the
  specified native messaging host is forbidden." The denial takes effect on the loaded context with
  no relaunch, and hosts already running are torn down at once (process killed, port disconnected,
  keep-alive released, a pending one-shot reply rejected). No saved row, or a grant, means allowed
  (install records a declared permission as granted only where no decision is saved yet, TASK-63).
  Rationale: the switch has been in Settings since native messaging landed and read as a real
  control; persisting the decision while ignoring it (the state TASK-19 left) was worse than either
  enforcing it or removing the row.
  - **Detour's built-in hosts are exempt, by design.** `detourPolyfill` (the service-worker polyfill
    bridge and the keep-alive port) and `detourWebSocketRelay` (TASK-8) are Detour's own transport,
    not the user-facing capability, and are decided by host name before the saved decision is read.
    For the same reason `Profile.loadExtensionContext` still grants `nativeMessaging` on every
    context unconditionally and never applies the saved row to it.
  - **Denying it breaks 1Password, by design.** 1Password's only channel to the desktop app is its
    native host (`1Password-BrowserSupport`, above), so with the switch off the extension cannot unlock,
    fill or save (and the keep-alive has no host to arm for). Turning the switch back on lifts the
    block immediately; the extension reconnects on its next attempt.
- **Decision (TASK-44, 2026-09-13): nativeMessaging denials saved before TASK-25 are cleared once by
  migration v13; only denials made after that are enforced.** Before TASK-25 the switch was not
  inert: flipping it off saved the denied row, and the Settings row then read OFF on every relaunch
  (`apiPermissionIsOn` shows the nativeMessaging switch ON unless a denial is saved) while the
  toggle also pushed `.deniedExplicitly` for the key onto every loaded `WKWebExtensionContext`,
  breaking that extension's `chrome.*` polyfill bridge for the rest of the session — until the next
  launch, where `loadExtensionContext` re-granted `nativeMessaging` unconditionally and skipped the
  saved row. What the row never did was reach native-host dispatch: `nativeHostAccess` consulted
  only the manifest, so the user never lost a native host by it and the row cannot be read as a
  decision to give one up. Honouring those rows on upgrade would silently refuse every real host
  (1Password's desktop-app unlock first of all) with no prompt, so migration v13 deletes every saved
  `nativeMessaging` API-permission decision that is not a grant (a status the enum does not define
  reads as a denial, so it goes too). A denial saved after the upgrade was made against enforcement
  and blocks real hosts exactly as above. Since TASK-63 it also survives: reinstalling or updating
  the extension no longer resets it, because install only records declared permissions for keys
  with no saved decision.
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

### Which `chrome.offscreen` is in force (TASK-71)

Detour's polyfill, in production as well as in tests. The shipped WebKit (framework
21624.5.1.11.3, the safari-7624 branch) has no `chrome.offscreen` at all — the
`WK_WEB_EXTENSIONS_OFFSCREEN` feature, its `WebExtensionOffscreenEnabled` preference and the IDL
attribute exist only on WebKit main — so `createDocument`/`closeDocument`/`hasDocument` route
through `__detourPolyfillRequest` to `OffscreenDocumentHost`, which hosts the document in a
WKWebView of Detour's own (with the AudioContext shim) rather than as a page inside the worker's
process.

That is deliberate, and it stays that way if WebKit grows a native implementation: Detour's is the
one with the tested lifecycle, so `offscreenJS` shadows a native namespace instead of deferring to
it. It must not do so silently. `globalThis.__detourOffscreenInstall` — surfaced as
`_polyfillDiag.apis.offscreenInstall`, which the popup reads — records, once per context,
`polyfill` (nothing was there), `polyfill-over-native` (a native namespace was shadowed),
`polyfill-over-foreign` (a non-native object was), or `error: …` when the define did not take, which
also logs `console.error('[Detour polyfill] chrome.offscreen override failed: …')`.

In a production run the line to look for, once per background start, is:

```
[Detour polyfill] chrome.offscreen implementation: polyfill
```

Anything other than `polyfill` there means the environment changed under us — `polyfill-over-native`
says a WebKit update has shipped its own offscreen API and this decision needs revisiting; `error: …`
says the extension is running against an implementation Detour did not install.

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
   - While armed, **Detour** sends `{type: "keepalive-ping", seq}` on that port — immediately on
     arming and then every `ExtensionManager.keepAlivePingInterval` (30 s) from a
     `DispatchSourceTimer` — and the background (a worker, or since TASK-62 a non-persistent
     background page) answers each one at once with `{type: "keepalive", seq}`. The *reply* is the
     background post WebKit counts. The background ran that interval itself until TASK-68; it does
     not any more, because a worker whose timers stop firing looks exactly like a healthy one from
     the outside (see below). If Detour drops the port the background reconnects with a capped
     backoff (1 s, doubling, 30 s max), disarmed, and Detour re-arms — and starts pinging — the new
     port from `portOpened` if hosts are still connected, so the background never has to remember
     anything.
   - Every round trip is in the log (category `extension-manager`, TASK-68): `Keep-alive
     'keepalive-start' delivered to <ext>`, `Keep-alive ping #n sent to <ext>`, `Keep-alive reply #n
     from <ext> (N ms)`, and — the watchdog line — `Keep-alive for <ext>: ping #n sent N s ago has
     no reply (worker stalled, its timers suspended, or the port is dead); sending #n+1` when a ping
     is still unanswered at the next tick. A production log can now say whether the pings flow,
     which the 2026-09-13 run could not.

   Why this works, measured: WebKit unloads the background 30 s after a load/wake, but while the
   background has open ports the unload is deferred until 2 minutes after the last message the
   *background* posted on any of them (`delayForInactivePorts`). Posting on the Detour port is such
   a message: the TASK-2 harness (2026-09-11 18:14) held a native port for 3 minutes with pings
   flowing and saw no unload, then an idle unload 30 s after release and a clean restart on the
   next alarm.

   **Background pages, measured 2026-09-13 (TASK-62).** A non-persistent `background.scripts` page
   follows the same two timers, so the keep-alive now installs there too (a persistent MV2 page is
   never unloaded and is skipped: `installDetail: 'persistent-background-page'`). Observed from an
   ordinary extension page reading a 0.5 s heartbeat the background page writes to the shared
   `localStorage` (so nothing messages, and wakes, the page), in
   `ExtensionPolyfillProfileWiringTests` with `DETOUR_MEASURE_BACKGROUND_PAGE_UNLOAD=1`:

   | Leg | Result |
   |-----|--------|
   | (a) idle page, no port (no `nativeMessaging`, so no keep-alive port either) | last heartbeat +29.7 s; the next message started a second page (`loads` 1 → 2) |
   | (b) page holds one real native port to a silent fake host, polyfill port suppressed | survived the 30 s idle unload; unloaded at +120.0 s (2 minutes after load, nothing ever posted), the port closed and Detour killed the host |
   | (c) as (b) with the real keep-alive installed and armed by that host, pings every 15 s | still running at +300.9 s, host connected, 21 pings received |

   Side observation from the first run of leg (a): a page that declares `nativeMessaging` but has no
   host holds the keep-alive's idle port, and that alone moved it off the 30 s unload onto the
   2-minute path (unloaded at ~120 s) — the cost the permission gate exists to avoid.

   **Production, 2026-09-13 (TASK-21, signed build, 1Password 8.12.26.40, macOS 26.6.2, three
   profiles): partial.** All three workers logged `Keep-alive armed ... 1 native host(s) connected`
   at 18:15:49, one second after their background pages were created. Personal and Work then held
   with no restart until the user locked 1Password at 18:37:28 (21+ minutes, AC #1 of TASK-16 in
   production) — but both also had a relayed WebSocket open (below). Private, which opened no
   socket, was unloaded by WebKit at 18:18:42 (`WebPageProxy::close`, 174 s after creation) with
   the keep-alive armed the whole time and nothing in Detour's or WebKit's log in the preceding
   3 s; the next background load failed with code 6 and the recovery reload fixed it. After the
   lock closed every relayed socket, workers started at hh:mm:49 were closed about 170 s later and
   restarted by 1Password's one-minute alarm, so the three profiles cycled about once a minute
   between them. 170 s is 120 s past the second 45-second ping, which says the first two pings
   were counted and later ones never arrived — Detour did not log pings, so production could not
   tell whether the worker stopped posting or WebKit stopped counting. Filed as TASK-68 (per-ping
   logging, a harness reproduction, and Detour-driven pings whose replies Detour can observe).
   Quitting the desktop app (18:38:41) also exposed TASK-67: 1Password's workers were replaced at
   18:38:49 without WebKit reporting their ports' disconnection, so the old BrowserSupport hosts
   stayed registered, the armed count read 2 and then 3 for one profile, and `ps` showed 10 host
   processes for three workers at 18:44. The lock/quit path never brings the host count to zero
   (BrowserSupport stays connected through a lock, and quitting relaunches the app), so AC #2 of
   TASK-16 — unload after the last host exits — remains covered only by the harness.

   **A replaced background context takes its native hosts with it (TASK-67, fixed 2026-09-14).**
   WebKit's `WebExtensionContext::unload()` clears `m_nativePortMap` without ever calling
   `reportDisconnection`, and `chrome.runtime.reload()` *is* `unload()` + `load()`, so a background
   context that reloads itself — or that WebKit restarts in place — leaves every native port Detour
   holds for it (real hosts, relayed sockets, the keep-alive port) with no disconnect callback at
   all. Detour's own cleanup runs only through `Profile.unloadExtension` → `closeExtensionPorts`,
   which a WebKit-internal reload never goes through, so the host processes stay alive as Detour's
   children and keep counting towards the keep-alive. Reproduced in
   `ExtensionPolyfillProfileWiringTests` with a worker probe that holds one (and two) ports to a
   fake host and then calls `chrome.runtime.reload()`: WebKit fired no disconnect handler for any
   of them, the old `sleep` processes were still running, and the state read `connectedHosts: 4`
   for a worker with two hosts — one second after the replacement started, and the same signature
   as production's `Keep-alive armed … 2 native host(s) connected` at 18:38:49. The one signal
   Detour does get is the replacement's keep-alive port superseding the old one, and the polyfill
   opens that port before any extension code runs, so everything registered under that
   (controller, extension) key at that moment belongs to the context that went away. The supersede
   path now tears all of it down — host processes killed and their ports disconnected, relayed
   sockets ended, the keep-alive reset with `contextUnloaded` so the count restarts at zero —
   through the same helper `closeExtensionPorts` uses, and logs `Replaced background context of
   <ext>: tore down N stale native host(s) and M relayed WebSocket(s)`.

   **Detour drives the pings now, and logs every round trip (TASK-68, 2026-09-14).** The 170 s
   unloads above are consistent with exactly one thing: the background's own `setInterval` stopped
   firing (or never fired) after the first ping or two, and nothing on either side could see it —
   WebKit's rule counts only what the *background* posts, so once its timer stops, the 2-minute
   clock runs out unopposed. Rather than trust a timer inside a context WebKit is free to suspend,
   Detour now owns the interval: while a key is armed, `ExtensionManager` sends
   `{type: "keepalive-ping", seq}` on the keep-alive port (immediately, then every 30 s from a
   `DispatchSourceTimer` on the main queue) and the polyfill answers `{type: "keepalive", seq}` on
   the same port at once. The reply is the background post WebKit counts, `keepalive-start` /
   `keepalive-stop` survive only as the worker's diagnostic `armed` flag, and every send, reply and
   missing reply is in the log.

   Harness result — `ExtensionPolyfillProfileWiringTests` with `DETOUR_MEASURE_WORKER_UNLOAD=1`
   (`DETOUR_MEASURE_WORKER_UNLOAD_SECONDS`, default 300), a *worker* declaring `nativeMessaging`
   whose only port is the keep-alive and whose only traffic on it is answering Detour, armed by
   `simulateNativeHostForTesting` so no real host adds traffic, at the production 30 s interval:

   | Phase | Result |
   |-------|--------|
   | armed, observed 300 s | port open the whole time (300.9 s); 11 pings sent, 11 replies, round trips 0–3 ms; never a ping awaiting a reply at the next tick; one keep-alive port opened, i.e. one worker start |
   | released (`connected: false`) | `keepalive-stop` delivered, and WebKit closed the port 149.4 s later — the inactive-ports path (2 min after the last reply, evaluated on WebKit's 30 s timer), so the disarmed behaviour is unchanged |

   That is well past the ~170 s at which production's worker-driven pings stopped counting, on the
   same machine and the same WebKit. What production still has to confirm is the same worker
   surviving 15+ minutes in the signed build (AC #3 of TASK-68) — with the new lines
   (`Keep-alive ping #n sent to <ext>`, `Keep-alive reply #n from <ext> (N ms)`, and the watchdog
   error line) the next run can say so directly instead of being inferred from unload times.

   **What actually kills the worker: WebKit's tracking prevention purges the extension origin's
   script-written storage, registration included (TASK-68 → TASK-70; production run 2, 2026-09-13
   20:04, signed build at 3b8d8f4).** With the per-round-trip logging in place the next production
   run answered the question outright, and the answer was not the pings. All three workers armed at
   20:04:22 with one host each and answered Detour in 0–20 ms. One of them answered ping #1 and
   nothing after it, and the Networking process's log says why: at 20:04:22.578 it ran
   `NetworkProcess::deleteAndRestrictWebsiteDataForRegistrableDomains ... session 1 with candidate
   domains - 9 domainsToDeleteAllCookiesFor, 0 domainsToDeleteAllButHttpOnlyCookiesFor, 706
   domainsToDeleteAllScriptWrittenStorageFor`, and one millisecond later `SWServerRegistration::clear
   31` followed by the worker's content process logging `SWContextManager::terminateWorker 36`. The
   run of the day before has the identical pair (`deleteAndRestrict... session 1 ... 702
   domainsToDeleteAllScriptWrittenStorageFor` → `clear 33` → `terminateWorker 40`, at 18:15:49).
   Service-worker registrations are script-written storage, and so are the extension's IndexedDB
   and localStorage; the `webkit-extension://` origin never earns first-party user interaction (ITP
   only records that for HTTP(S) documents), so once it has aged past ITP's no-interaction window
   its storage is purged on every pass. Only session 1 (Personal, the profile with the oldest
   statistics) was in the list in both runs; session 2's pass at 20:04:26 cleared nothing. In the
   63 minutes after launch there was exactly one pass, so it is a launch-time event plus whatever
   reprocessing ITP schedules later. A page of 1Password's offscreen document happened to close 14 ms
   before the clear in both runs and was the first suspect; the harness later showed that neither a
   Detour-hosted offscreen close nor an ordinary page close touches the worker, and the Networking
   log settled it.

   The hidden background page (476) was **not** closed. It stayed loaded around a dead worker: the
   keep-alive port stayed open and armed, Detour logged `ping #2 sent 30 s ago has no reply` every
   30 s, and the 20:05:22 and 20:06:22 alarms were simply lost — until WebKit unloaded the page at
   20:06:52 (120 s after the worker's last counted post, on the 30 s tick), after which the next
   alarm started a worker that reconnected and answered every ping for the rest of the session.
   The Private worker of the day before (hidden page 56 closed 174 s after the clear) is the same
   signature. The 170 s cycling *after* a lock was a second, separate fault — the background's own
   `setInterval` pings stopped flowing while the worker was alive — and that one the Detour-driven
   pings fixed: in this run the two untouched workers answered replies #1–#33 from 20:04:22 to
   20:20:23 with no error, no unload and no restart (16 min, AC #3 of TASK-68 in the signed build),
   and the restarted third answered #1–#27 over 13 min, with no relayed WebSocket open in any of
   them. Prevention — keeping the extension origin out of ITP's purge list — is TASK-70.

   **Harness (TASK-68 AC #2), `ExtensionPolyfillProfileWiringTests`.** The production trigger (an
   ITP pass purging the origin) is not driven here; the legs rule out the page-close suspects and
   reproduce the state the production worker was left in, and what Detour now does about it:

   | Leg | Result |
   |-----|--------|
   | `testADetourHostedOffscreenDocumentDoesNotKillTheWorker` — Detour-hosted offscreen document created and closed | the worker never notices; pings keep round-tripping, one keep-alive port, no restart |
   | `testAnOrdinaryExtensionPageClosingDoesNotKillTheWorker` — an extension page opened and released while another stays open | the worker survives (it may cost one missed ping while the page tears down) |
   | `testAWorkerTerminatedUnderItsLiveBackgroundPageIsRestarted` — the worker clears its own registration (`registration.unregister()`), reaching WebKit's teardown from the other end | `SWServerRegistration::clear 6` + `SWContextManager::terminateWorker 7` (2026-09-13 20:42:20.614/.615), the hidden background page and its port untouched, `portOpen`/`armed` still true, and the pings simply stop coming back — the production state exactly |
   | …and the recovery on that same leg | ping #3 unanswered at 20:42:24.4, `no reply to pings #3–#4 for 4 s; treating the background as dead and restarting it` at 20:42:26.5, ports and hosts torn down there; WebKit closed the now portless zombie page at 20:42:50.6 (its own 30 s tick); `loadBackgroundContent` at 20:43:01.5 (`keepAliveRestartDelay`, 35 s) → `WebPageProxy::loadServiceWorker`, a second keep-alive port, and a background answering every ping again |

   The symptom first appeared in the harness by accident on 2026-09-13, when a website-data deletion
   cleared another test's registration and left Detour pinging a worker that had been terminated
   under a page that was still loaded — the same three log lines, in the same order.

   **The recovery (`ExtensionManager.restartUnresponsiveBackground`).** Nothing Detour can do
   prevents WebKit from terminating the worker, so the pings are also the detector. A ping that is
   still unanswered when the next one goes out is logged (`ping #n sent N s ago has no reply …`);
   `keepAliveMissedReplyLimit` (2) of those in a row — the background silent for at least
   2 × `keepAlivePingInterval`, 60 s in production, still inside WebKit's 2-minute window — is
   treated as death:

   1. one error line, `Keep-alive for <ext>: no reply to pings #n–#m for N s; treating the
      background as dead and restarting it`;
   2. the same teardown a replaced context gets (TASK-67) — host processes killed and their ports
      disconnected with `Detour restarted an unresponsive background context.`, relayed sockets
      ended, the keep-alive reset through `contextUnloaded` — plus the keep-alive port itself,
      removed from the registry first so its own disconnect handler is a no-op. With no open ports
      left, WebKit's next 30 s `unloadBackgroundContentIfPossible` tick closes the zombie page
      instead of waiting out the 2-minute inactive-ports window;
   3. `keepAliveRestartDelay` (35 s, longer than that tick) later, `loadBackgroundContent` on the
      context — found through the controller held weakly per keep-alive key — and the outcome
      logged. Not an unload/reload of the context: that would take the extension's popup, options
      and other pages with it. If a keep-alive port turned up in the meantime (an alarm woke the
      background on its own) the load is skipped, and if the page is somehow still there the load
      is a harmless no-op.

   The threshold and the delay are instance properties so tests can shorten them; a restart in
   flight is tracked per key so a second cannot start on top of it, and the delayed load re-checks
   the port, the controller, the profile and the context before it runs.

   What production still has to confirm is a worker surviving 15+ minutes in the signed build with
   an offscreen document in play (AC #3 of TASK-68) — now with the restart as the safety net rather
   than a two-minute hole.

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

#### Tracking prevention purges the extension origin (TASK-70)

**The mechanism.** WebKit's Intelligent Tracking Prevention keeps a statistics record per
*registrable domain* and, at every processing pass, decides what to delete from
`ResourceLoadStatisticsStore::registrableDomainsToDeleteOrRestrictWebsiteDataFor()`. With the
default `FirstPartyWebsiteDataRemovalMode::AllButCookies`, `shouldRemoveAllButCookiesFor()` returns
true for *every* observed domain that has no unexpired user interaction — a record with
`hadUserInteraction == false` qualifies on the spot, no prevalence needed — and that domain's
**script-written storage** goes on the removal list: service worker registration, IndexedDB,
localStorage, DOM cache. An extension origin is spelled `webkit-extension://<uuid>/`, its
`RegistrableDomain` is that uuid host, and that is exactly the key
`NetworkProcess::deleteAndRestrictWebsiteDataForRegistrableDomains` deletes by
(`ensureSWServer()->clear(origin)` for the registration, `storageManager().deleteDataForRegistrableDomains`
for the rest). The origin enters the statistics table on its own as soon as a page loads one of the
extension's cross-host resources — a content-script iframe, a `chrome.runtime.getURL` fetch — which
for 1Password is every page with a login form.

**Why nothing the user did saved it.** Two things, found in production on 2026-09-13 after the first
version of the fix (interaction logged into `profile.dataStore`) changed nothing:

1. *The extension pages were not in the profile's store at all.* The shipped WebKit
   (`WebExtensionControllerConfigurationCocoa.mm`, safari-7624 branch) builds the controller's
   `webViewConfiguration` as a plain `WKWebViewConfiguration()` and never copies
   `defaultWebsiteDataStore` into it (main does). Every extension web view — background page and
   worker, popup, options, offscreen — is a copy of that configuration, so all profiles' extension
   pages, their service-worker registrations and their IndexedDB lived in the **default** data store
   (`~/Library/WebKit/com.detourbrowser.mac/WebsiteData/`, ITP "session 1"), shared across profiles.
   The purge always hit session 1; the interaction logged into the profile store's session was a
   no-op. `Profile` now sets `config.webViewConfiguration.websiteDataStore = dataStore` itself.
2. *Every launch is a brand-new origin.* WebKit mints a fresh `webkit-extension://<uuid>/` base URL at
   every context load (Detour does not persist one), and migrates IndexedDB/localStorage onto it from
   the last-seen origin. The service worker registers afresh on the new origin, whose statistics
   record does not exist yet. The extension's own pages then create it — a fingerprinting-API access
   (`navigator.*`, canvas) or a third-party script load is logged for the page's own top-frame
   domain — and `resourceLoadStatisticsUpdated` runs a processing pass *synchronously* after that
   merge: `merge: sessionID=1` → `deleteAndRestrictWebsiteDataForRegistrableDomains` →
   `SWServerRegistration::clear` within 10 ms, about a second after the worker started. Popup clicks
   do log an interaction for the origin (the default store held `hadUserInteraction = 1` rows for
   earlier launches' uuids), but they come minutes later, for an origin that dies at the next launch
   anyway.

So the record is `hadUserInteraction == false` at the only moment that matters, and the interaction
has to be logged into the store the extension pages run in, before the background content starts.
Two guards delay the purge and neither helps: the whole script-written-storage list is dropped unless
an hour has passed since the oldest recorded interaction in the database, and interaction windows
are counted in *operating days* (days the browser ran), 7 or 30.

**The fix — `Detour/Extensions/Runtime/ExtensionOriginInteractionKeeper.swift`.** Detour logs the
interaction itself, through the private `-[WKWebsiteDataStore _logUserInteraction:completionHandler:]`
(macOS 10.15.4+; `WebsiteDataStore::logUserInteraction` rejects only `about:` and empty URLs, so an
extension base URL is accepted and sets `hadUserInteraction` / `mostRecentUserInteractionTime` for
its registrable domain). It fires:

- at context load — `Profile.loadExtensionContext` calls `originInteractionKeeper.contextDidLoad`
  right after `extensionController.load(context)` succeeds and before the background content is
  started, with `context.baseURL`, into the store of the controller's `webViewConfiguration` — the
  one the extension's pages run in. WebKit mints a fresh origin for every load, so a reload needs
  its own claim; the TASK-68 background recovery
  reloads through the same method and is covered by the same call;
- every 24 hours after that, per profile (`Timer`, 1 h tolerance, main run loop), re-logging every
  loaded context so a long-running process never ages out of the window. The timer is stopped in
  `unloadAllExtensions` — which `TabStore.deleteProfile` runs — and self-invalidates if the profile
  is gone.

Incognito profiles are skipped (non-persistent store, no statistics database, nothing to preserve),
and so is any store whose `isPersistent` is false. If the private selector ever disappears, the
keeper logs one error per process and does nothing else.

**How to verify in the signed build.** Every call logs one line at `.notice`, category `EXT-ITP`:

```
ITP: logged user interaction for <extension id> origin <uuid>
```

A healthy run then shows, in the Networking process, `deleteAndRestrictWebsiteDataForRegistrableDomains
... N domainsToDeleteAllScriptWrittenStorageFor` with **no** `SWServerRegistration::clear` and no
`SWContextManager::terminateWorker` for the extension's worker afterwards, and no
`Keep-alive ping #n sent to <ext> ... has no reply` error from Detour in the minutes that follow.
The ITP decision itself can be read directly by turning on `_setResourceLoadStatisticsDebugMode`,
which logs `About to remove data records for <domain>(all but cookies), ...` on the
`com.apple.WebKit:ITPDebug` channel (info level — `log show` needs `--info`).

**Tests — `DetourTests/ExtensionOriginTrackingPreventionTests`.** Three unit tests cover the wiring
(one interaction per loaded context, for that context's own base URL; the daily refresh re-logs
every loaded context and no unloaded one; a non-persistent store and an incognito profile log
nothing), and `testTrackingPreventionPassSparesOriginsWithALoggedInteraction` drives a real pass:
two identical http origins write localStorage, one of them is handed to the keeper's own
`logInteraction`, both are marked prevalent, the ITP clock is advanced a day (the hour-old guard,
and WebKit's testing clock only steps in whole days), and the pass empties the uninteracted one
while sparing the logged one — with a loaded probe extension coming through the same pass with its
IndexedDB and worker intact. `fetchDataRecords` never reports `webkit-extension://` origins, not
even after `_allowWebsiteDataRecordsForAllOrigins`, so the extension side of the decision is only
directly visible in the ITPDebug log; during development it read `About to remove data records for
... itp-control.example(all but cookies), <uuid of the extension whose statistics had been
cleared>(all but cookies)` with the extension whose interaction had been logged absent from the
list.

**The TASK-68 recovery stays.** Keeping the origin out of the purge list removes the cause that was
actually observed; the keep-alive watchdog and the `loadBackgroundContent` restart remain the safety
net for any other way a worker can stop answering, and the context reload on
`backgroundContentFailedToLoad` remains the escape from a stale registration.

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

**Production, 2026-09-13 (TASK-21): the relay works against 1Password's notifier.** At 18:15:50
two profiles logged `Relaying a WebSocket for aeblfdkhhhdcdjpifhhbdiojplfjncoa` followed by `Relayed
WebSocket open`; the reloaded Private worker opened a third at 18:18:50 (open at 18:18:50.991). All
three stayed open until the user locked 1Password at 18:37:28, when each closed with `code 1005,
clean true`. Whether a vault change made elsewhere is pushed live, and the API Explorer echo probe
against `wss://echo.websocket.org`, were not exercised in that run (still open in TASK-21). The
sockets also looked at the time like what held the Personal and Work workers up, since the workers
without one were unloaded at ~170 s despite the armed keep-alive; run 2 traced that to the
background's own ping timer and to a `chrome.offscreen` document's close terminating the worker
(TASK-68, above), and Detour now drives the pings and restarts a background that stops answering.

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
- `chrome.storage.managed` (TASK-80, added 2026-09-14 for 1Password 8.12.37): an empty, read-only
  managed `StorageArea` patched onto WebKit's native `chrome.storage` when it lacks one (`get` →
  `{}` or the caller's defaults, `getBytesInUse` → 0, `getKeys` → [], `set`/`remove`/`clear` reject
  with "This is a read-only store.", `onChanged` never fires), rooted with `__detourHoldWrapper`;
  `_polyfillDiag.apis.storageManaged` records the path.

  **Why it matters.** 8.12.37 added a Credential Intelligence managed-policy monitor whose
  `initialize()` calls `browser.storage.managed.onChanged.addListener` synchronously inside the
  background's async `initialize`, before `initializeNativeAppConnection`. WebKit (macOS 26 and 27)
  has no `storage.managed`, so the TypeError rejected the whole initialize: "Finished initializing
  1Password" never ran, the native host was never started, and every popup open logged
  `[Sls] Not attempting to connect to desktop app: initialization hasn't finished` while the popup
  showed only its spinner. The symptom looks like a macOS or WebKit regression but depends only on
  the extension version: 8.12.37.1 has the monitor, 8.10.80.23 has no `storage.managed` use at all, and
  the machine where 1Password kept working ran 8.12.26.40 (not inspected). Worker console evidence, with
  `ExtensionConsoleLogPublic` set:

  ```
  [unhandled rejection] TypeError: undefined is not an object (evaluating 'browser.storage.managed.onChanged')
  [Sls] Not attempting to connect to desktop app: initialization hasn't finished
  ```

  The `WASM is not initialized, unable to make core call.` rejection logged at the same time is a
  startup race inside 1Password (a core call before `instantiate` finishes; WASM then logs
  "Initializing" normally), not the cause.

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

**Frame kinds as WebKit reports them (TASK-4, 2026-09-13)**

Measured by `ExtensionPolyfillIntegrationTests.testFrameKindsAsReportedByNativeGetAllFrames`: a
login page on one loopback server with three login-form iframes — a cross-origin http one (a second
loopback server; a different port is a different origin), a `srcdoc` one, and an `about:blank` one
the parent fills by script after load — registered as a real extension tab, with a `<all_urls>` /
`all_frames: true` content script that says hello to the worker from every frame it lands in. The
two frames WebKit reports with an empty URL are told apart by removing one `<iframe>` element at a
time and diffing the enumeration. Taken on macOS 26.6.2 (build 25G83), WebKit.framework
21624, Safari 26.6.2.

| frame kind | URL WebKit reports (`getAllFrames`) | Chrome's URL for the same frame | content script injected (hello) | `tabs.sendMessage` with that frameId reached it |
| --- | --- | --- | --- | --- |
| top document (http) | `http://127.0.0.1:<portA>/` | same | yes, `frameId` 0 | yes (`pong`) |
| cross-origin http iframe | `http://127.0.0.1:<portB>/login` | same | yes, `frameId` 30064771073 | yes (`pong`) |
| `srcdoc` iframe | `""` (empty string) | `about:srcdoc` | no | no |
| `about:blank` iframe, filled by the parent | `""` (empty string) | `about:blank` | no | no |

All four frames *are* enumerated, each with a distinct `frameId`, `parentFrameId` 0 (the top frame
reports -1), a `documentId`, and `errorOccurred: 0`; `getFrame({tabId, frameId})` resolves all four,
returning the same empty `url` for the last two. The fan-out to the two empty-URL frames fails
silently: the `tabs.sendMessage` callback fires with `undefined` and **no** `chrome.runtime.lastError`,
so a caller cannot tell "no receiver" from "the receiver answered nothing".

This supports the hypothesis. WebKit hands 1Password two frames per such page that it counts in
`getAllFrames` but that its URL filter cannot classify (empty string rather than `about:srcdoc` /
`about:blank`) and that have no content script to answer the fan-out — exactly the shape of
"[Tabs] Could not collect all frames that were initially found". Note the two halves are separable:
Chrome only injects into `about:blank` / `about:srcdoc` frames when the content script declares
`match_about_blank` (matching against the parent's URL), so a script without it is uninjected in
Chrome too — but Chrome still gives those frames a URL the filter can match. Candidates for the
follow-up decision, smallest first: (a) report `about:srcdoc` / `about:blank` instead of `""` in
`tabs` and `webNavigation` results, which fixes the classification and costs nothing else; or
(b) also inject content scripts into those frames per `match_about_blank` semantics, which is what
actually lets the fan-out land. (a) alone may be enough to stop the complaint if 1Password skips
frames it cannot fill; (b) is needed if a login form really does live in a `srcdoc`/`about:blank`
frame. Deciding between them needs the second half of TASK-4 — real 1Password on the signed build.

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

### runtime.onInstalled (TASK-22)

Question: does WebKit deliver `chrome.runtime.onInstalled` to the background service worker in the
app? TASK-20 had measured that it never arrives in the test process. 1Password, like most
extensions, does its first-run setup (and opens its welcome page) from that event.

#### Measurement (2026-09-12)

macOS 26.6.2 (25G83), WebKit 21624.5.1.11.3, Debug build, isolated `DETOUR_DATA_DIR`. A temporary
env-gated AppDelegate harness drove `ExtensionManager.install(from:)` (API Explorer with a manifest
`key`, so every install shares one id), `Profile.recoverFromBackgroundLoadFailure`, and
`setEnabled` globally and per profile, then woke the worker. The API Explorer worker records every
delivery (`reason`, `previousVersion`, version, ms after worker start) in
`storage.local.onInstalledEvents` and logs it, and logs the stored history each time it starts, so
the log shows both the event and what storage holds (`-ExtensionConsoleLogPublic YES`, `log show`
filtered by the harness PID).

| Scenario | WebKit delivers | Evidence |
|----------|-----------------|----------|
| First install into a profile that has never loaded an extension (even 21 s after launch) | **nothing**; `runtime.onStartup` instead | `worker start v3.0.0, onInstalled history: []` → `runtime.onStartup` |
| Install while the profile already has an extension loaded (installed 10 s earlier) | `install` | `runtime.onInstalled {"reason":"install","version":"3.0.0"}` |
| Update 3.0.0 → 3.0.1, Default profile | `update`, `previousVersion: "3.0.0"` | `{"reason":"update","previousVersion":"3.0.0","version":"3.0.1"}` |
| Update 3.0.1 → 3.0.2, Private profile (non-persistent controller) | `install`, no previousVersion | `{"reason":"install","version":"3.0.2"}` |
| Background-recovery reload, same version | **`install`** (spurious) | `{"reason":"install","version":"3.0.1"}`, history already held the update |
| Global disable → enable; per-profile disable → enable | **`install`** (spurious) | `{"reason":"install","version":"3.0.1"}` / `"3.0.2"` |
| Reinstall of the same version | `install` | `{"reason":"install","version":"3.0.1","msAfterWorkerStart":12}` |
| Relaunch (Default and Private) | nothing; `onStartup` | two `runtime.onStartup`, no `runtime.onInstalled` |

WebKit's source explains every row (`WebExtensionContext::determineInstallReasonDuringLoad`,
`WebExtensionController.cpp`): the reason is chosen per context *load*. A version (or bundle hash)
different from `LastSeenVersion` in the context's `State.plist` is an update. Otherwise, if the
controller is still "freshly created" — a 5-second window that, judging by the first row, starts at
the controller's first load — there is no install reason and `onStartup` fires; after the window,
every load is an install. The non-persistent Private controller has no stored state, so it never
sees a previous version. The test process loads its context straight into a new controller, inside
the window, which is why `testRuntimeOnInstalledIsNotDelivered` sees nothing (its doc comment now
says so).

#### Decision: Detour delivers the event itself

WebKit's event is wrong in both directions — the first extension a user installs never gets it, and
every background-recovery reload or re-enable replays `install` (for 1Password: its welcome page
again). It cannot be fixed from outside WebKit's rule, so Detour suppresses it and emits its own:

- **Rule** (`RuntimeInstalledEvent.pending`, pure): Detour keeps, per (profile, extension), the
  version the event was last delivered for (table `extensionInstalledEvent`). No row → `install`;
  a different version → `update` with that version as `previousVersion`; the same version →
  nothing. So: exactly once per install or version change, per profile; never on a reload,
  relaunch or enable; never `chrome_update`. A profile where the extension was disabled during an
  update gets the `update` when it next runs there (Chrome defers a pending dispatch the same way).
  A same-version reinstall is nothing (Chrome reports `update` for reloading an unpacked extension;
  a version ledger cannot tell that from a reload, and a spurious event is the worse error).
  *Superseded by TASK-29: a reinstall now delivers `update`, see below.*
- **Per profile, Private included.** Each profile runs its own worker with its own storage, so each
  gets the event once. The Private profile's storage is non-persistent, but the ledger is not, so
  it is not replayed at relaunch — the same as Chrome never re-firing at startup.
  *Superseded by TASK-29: the Private profile never gets the event, see below.*
- **Upgrade:** migration v9 seeds the ledger with every installed extension's version in every
  saved profile, so updating Detour does not deliver `install` to everything already installed.
  Uninstall deletes the rows.
- **Suppression** (`ExtensionAPIPolyfill.runtimeOnInstalledJS`, service workers only; extension
  pages too since TASK-29): the worker
  polyfill shadows `addListener`/`removeListener`/`hasListener`/`hasListeners` on the native
  `runtime.onInstalled` object and keeps the listeners itself, so WebKit's dispatch finds no
  listener. It holds a strong reference to the event wrapper (WebKit caches wrappers weakly, and
  `onInstalled` is `[MainWorldOnly]` so it cannot be pinned on `runtime`), verifies a second read
  returns the patched object, and otherwise restores the object and leaves the event to WebKit.
  `chrome`, `browser` and `chrome.runtime` are never replaced (TASK-15).
- **Delivery:** on every worker start, one task after the script ran, the polyfill sends
  `runtime.claimInstalledEvent`; the handler decides and advances the ledger in one transaction and
  replies with the details, which the polyfill dispatches. A second claim gets `{}`, so a restarted
  or racing worker cannot deliver twice; a worker that dies between claim and dispatch loses the
  event (at-most-once, like Chrome clearing its pending pref at dispatch).
- **Waking:** `ExtensionManager.wakeForPendingInstalledEvent` starts the worker after install,
  update, enable and at launch when the ledger says an event is owed.
- **Limits:** extension pages (popup, options) still get WebKit's event if one is open and
  listening across an install or reload (*closed by TASK-29, below*). A module worker that `await`s before registering its
  listener can miss the claim, as it would miss Chrome's dispatch. WebKit's spurious
  `runtime.onStartup` on a profile's first-ever install is left alone.

Verified in the same harness with the fix: first install into a fresh profile → one `install`;
update → one `update` (`previousVersion 3.0.0`); recovery reload, disable → enable and same-version
reinstall → nothing, with the worker's stored history ending at exactly those two entries
(`[Detour polyfill] runtime.onInstalled mode: detour` at every worker start). After a relaunch, the
Private profile (created after the first install) got its one `install`, and an update to 3.0.2
delivered one `update` in each profile; a per-profile disable → enable then delivered nothing.
Tests: `RuntimeInstalledEventTests` (rule, ledger, migration), the `runtime.onInstalled` section of
`ExtensionPolyfillTests` (suppression, claim-once dispatch, worker-only, fallback). API Explorer's
popup shows the recorded deliveries and the worker's polyfill mode.

#### Follow-up: extension pages, reinstall, Private (TASK-29)

TASK-22 left three gaps open. Each one is now decided and closed, and the bullets above that
contradict them are superseded:

- **Extension pages no longer see WebKit's event.** The same shadowing now runs in every non-worker
  context the polyfill reaches that has `runtime.onInstalled` (popup, options, extension tabs,
  offscreen documents). There it runs in mode `suppressed`: listeners are kept but never called, and
  the page never claims. Detour's event goes to the worker only. Chrome does deliver to pages that
  are open when the event fires, but a page opened later never sees it. In a page, WebKit's event is
  exactly the spurious `install` from a recovery reload or a disable → enable. So no page event at
  all is the closer and safer behaviour.

  This was measured before relying on it, in the test process (macOS 26.6.2), with
  `ExtensionPolyfillProfileWiringTests.testRealExtensionPageDoesNotSeeWebKitsRuntimeOnInstalled`.
  The test loads a throwaway context first and the extension 5.5 s later, so WebKit is past its
  freshly-created window and really fires `install`. A real extension page from the context listens
  twice: through `chrome.runtime.onInstalled`, and, as a control, through WebKit's own prototype
  `addListener`. Results:
  - The control received `{reason: "install"}`.
  - The shadowed listener received nothing.
  - After heap churn, a fresh read still returned the patched wrapper.
  - The worker got exactly one `install`, from Detour's claim.

  `chrome`, `browser` and `chrome.runtime` are still never replaced.
- **A same-version reinstall delivers `update`.** Migration v10 adds
  `extensionInstalledEvent.reinstallPending`. When `ExtensionManager.install` replaces an installed
  extension that has the same id, it sets the flag on every row for that id
  (`AppDatabase.markRuntimeInstalledEventReinstalled`) before the replacement loads. The rule reads a
  flagged row as `update`, with `previousVersion` set to the delivered version. For a same-version
  reinstall, that is the current version. The claim that delivers the event clears the flag, so it
  arrives exactly once per profile. A profile that never had the event still gets `install`. Only an
  explicit install sets the flag. The background-recovery reload (TASK-2), enable and relaunch never
  go through `install`, so they still deliver nothing. This matches Chrome, which reports `update`
  when an unpacked extension is reloaded.
- **The Private profile never receives `runtime.onInstalled`.** Four pieces enforce this:
  - The rule returns nothing for it.
  - The claim handler answers `{}` and writes no ledger row (`profile.isIncognito`).
  - `wakeForPendingInstalledEvent` never wakes a worker there.
  - v10 deletes the Private rows that v9 had seeded.

  This matches Chrome's default "spanning" incognito mode: the incognito side shares the regular
  profile's background and never gets an `onInstalled` of its own. It also keeps onboarding pages,
  such as 1Password's welcome page, from opening in Private windows.

  **Caveat:** the Private context's extension storage is non-persistent, and first-run setup is
  never re-run there. An extension that seeds `storage.local` only from `onInstalled` will find it
  empty in Private windows after every launch, and has to cope with the missing state itself.

Tests:
- `RuntimeInstalledEventTests`: the reinstall rule and ledger, a reinstall through
  `ExtensionManager.install`, a reload after a delivered reinstall, Private across relaunches, and
  the v10 migration.
- `ExtensionPolyfillTests`: page suppression, and a Private claim through the native bridge.
- `ExtensionPolyfillProfileWiringTests`: the real-page measurement above, and no wake in Private.

API Explorer's popup readout now also shows the popup's own polyfill mode, and that its listener
received nothing.

## Recommendation

Phase 0 and Phase 1 first, in that order. Phase 1 is the whole game: until the worker survives past
its first idle termination, no other fix is observable for more than a couple of minutes. Phase 2
can ride along in the same deploys. Phase 3 is the largest remaining functional win once the worker
is stable.
