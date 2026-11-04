---
type: Investigation
title: Extension data store and tracking prevention
description: Why WebKit's tracking prevention kept deleting extension storage and killing 1Password's worker, which data store extension pages really run in, the reconnect loop that was the same bug in the Private profile, and the interaction keeper that fixed it.
tags: [extensions, webkit, itp, data-store, service-worker, 1password]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:09:03Z }
stale_after: 2027-01-01T00:00:00Z
sources:
  - id: keeper
    resource: ../../Detour/Extensions/Runtime/ExtensionOriginInteractionKeeper.swift
    title: ExtensionOriginInteractionKeeper.swift
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (extensionController, loadExtensionContext)
  - id: itp-tests
    resource: ../../DetourTests/ExtensionOriginTrackingPreventionTests.swift
    title: ExtensionOriginTrackingPreventionTests.swift
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan (Tracking prevention purges the extension origin)
  - id: task-68
    resource: backlog:TASK-68
    title: The armed keep-alive does not stop WebKit unloading a worker (production)
  - id: task-70
    resource: backlog:TASK-70
    title: Tracking prevention deletes an extension origin's script-written storage
  - id: task-72
    resource: backlog:TASK-72
    title: Keep disabled extensions' origins inside ITP's interaction window too
  - id: task-90
    resource: backlog:TASK-90
    title: 1Password worker stuck in a reconnect loop pins the Networking process
  - id: task-99
    resource: backlog:TASK-99
    title: Give each context a stable base URL so extension storage survives a relaunch
  - id: notes-itp
    resource: "Agent session notes, 2026-09-13 to 2026-09-20 (not in the repository)"
    title: Session notes on the extension data store and the ITP purge
---

# Symptom

Two incidents, a week apart, that looked unrelated:

1. **A worker that dies one second after launch** (2026-09-13). One of
   1Password's workers answered the first
   [keep-alive](./native-port-keep-alive.md) ping and nothing after it. Its
   hidden background page stayed loaded, every port stayed open, alarms were
   lost, and WebKit unloaded the page about 150–175 s after start.[^task-68]
2. **A "desktop-app reconnect loop"** (2026-09-18 to 09-20). The WebKit
   Networking process sat at about 88% CPU and a service-worker process at
   about 20%. 1Password's worker logged a flat 20 errors per second for
   hours; its own diagnostics repeated `Desktop app connection attempt
   failed: PortClosed`.[^task-90]

# Root cause

**WebKit's tracking prevention (ITP) deletes the script-written storage of an
extension origin that has no recorded user interaction, and a service-worker
registration is script-written storage.**

The mechanism, from WebKit's `ResourceLoadStatisticsStore`:

- With the default removal mode (`AllButCookies`), every *observed* domain
  whose record has no unexpired user interaction is scheduled for removal of
  service-worker registrations, IndexedDB and localStorage. A record with
  `hadUserInteraction == false` qualifies at once.
- An extension origin is `webkit-extension://<uuid>/`. Its registrable domain
  is the uuid host, which is the key the deletion runs on.
- WebKit mints a **fresh uuid for every context load**. The extension's own
  pages put the new origin into the statistics table (a fingerprinting-API
  access or a third-party script load is enough), and the merge that inserts
  it runs a processing pass *synchronously*. The registration is cleared
  within about 10 ms, roughly a second after the worker starts.
- Popup clicks do log an interaction for the origin, but minutes too late.

Three further facts turned that mechanism into the two incidents:

| Fact | Consequence |
|---|---|
| The shipped WebKit builds the controller's `webViewConfiguration` as a plain configuration and never copies `defaultWebsiteDataStore` into it (WebKit `main` does). Every extension web view is a copy of that configuration | All profiles' extension pages, registrations and IndexedDB lived in WebKit's **default** data store, shared across profiles. A first fix that logged the interaction into the profile's store did nothing[^task-70] |
| The Private profile's extension pages were deliberately left on the default store for a week (see [private profile extensions](./private-profile-extensions.md)), and the keeper skipped the profile *because it was incognito* | That one origin was never protected. ITP deleted its IndexedDB files under the running worker after every start[^task-90] |
| 1Password cannot cope with IndexedDB vanishing under it | Every transaction aborted, its logger wrote each failure to the same database and failed again, and its backend re-initialised in a loop. `PortClosed` was its *own* local `disconnect()` during re-init, not Detour refusing a port |

So the second incident was never a native-messaging problem. A 25-second
debug-level log stream of the app showed no `connectUsing` activity at all;
WebKit always calls the delegate for `connectNative`, so no log line meant
the extension was not calling it.[^task-90]

# Evidence

- **The pair of lines.** In both 2026-09-13 runs the Networking process
  logged `deleteAndRestrictWebsiteDataForRegistrableDomains … session 1 … 706
  domainsToDeleteAllScriptWrittenStorageFor`, then `SWServerRegistration::clear`
  one millisecond later, then the content process logged
  `SWContextManager::terminateWorker`.[^task-68]
- **A red herring.** A page of 1Password's offscreen document closed 14 ms
  before the clear in both runs and was blamed first. Tests then showed that
  neither a Detour-hosted offscreen close nor an ordinary extension page
  close affects the worker.[^task-68]
- **Unlinked but open files.** In the loop, `lsof` on the Networking process
  showed IndexedDB files under `WebsiteData/Default` that no longer existed
  on disk, with frozen WAL sizes. Killing the worker re-created them and they
  were unlinked again within about 60 s, three times out of three.[^task-90]
- **The CPU.** A sample of the Networking process was almost entirely
  `abortTransaction` → `takeNextRunnableTransaction`, which scans the pending
  list: each abort costs O(pending).[^task-90]
- **Not observed directly:** the Networking process's own deletion line for
  the 09-20 loop could not be captured. ITP is inferred there from the
  identical mechanism, the missing interaction, and the fix working.

# Fix

1. **Extension pages run in the profile's own store.**
   `Profile.extensionController` sets
   `config.webViewConfiguration.websiteDataStore = dataStore`, for persistent
   profiles and for the incognito profile. Only a deleted profile is
   excluded.
2. **`ExtensionOriginInteractionKeeper` logs the interaction itself**, through
   the private `-[WKWebsiteDataStore _logUserInteraction:completionHandler:]`,
   for each context's `baseURL`:
   - at context load, from `Profile.loadExtensionContext`, before background
     content starts (a background-recovery reload goes through the same
     method and gets its new origin logged);
   - every 24 hours while contexts are loaded, because the interaction window
     is counted in *operating days*.
3. **The store decides, never the profile kind.** `keptDataStore()` returns
   the store the pages actually use and skips it only when it is not
   persistent. The earlier `isIncognito` test was the bug behind the second
   incident.
4. **Safety nets stay**: the keep-alive watchdog restarts a background that
   stops answering, and `Profile.recoverFromBackgroundLoadFailure` reloads a
   context whose background load fails.

Tracking prevention is not disabled for any profile; that option was ruled
out from the start. What is logged is the extension's own origin, nothing
about what was browsed.

# Verification

Every keeper call logs one line at notice level, category `EXT-ITP`:
`ITP: logged user interaction for <extension id> origin <uuid>`.

| Date | Signed build result |
|---|---|
| 2026-09-13 | Persistent profiles: interaction logged at load, launch passes ran for their sessions with no registration clear; workers kept answering pings[^task-70] |
| 2026-09-14 | The periodic pass about an hour after launch: passes for three sessions, none followed by a clear[^task-70] |
| 2026-09-20 | Private profile's origin (then still on the default store): interaction logged a second before the pass, both databases intact four minutes later, no unlinked files, error stream gone, Networking at 0% CPU[^task-90] |

Not observed in production: the keeper's daily re-log.

# How to investigate this class of problem

- **Check which store the pages use before theorising.** Per-store origin
  data is under `WebsiteDataStore/<id>/Origins/<hash>/<hash>/origin` (default
  store: `WebsiteData/Default/…`); `grep -la <uuid>` over the `origin` files
  finds an extension origin's store.[^notes-itp]
- **ITP session numbers.** Session 1 is the default store; identifier-backed
  stores are 2, 3, … in creation order. Match a session to a store by
  comparing the pass's candidate-domain count with the row count of
  `ObservedDomains` in that store's `ResourceLoadStatistics/observations.db`.[^notes-itp]
- **A clear is not always ITP.** `SWServerRegistration::clear` also follows an
  ordinary idle unload (with `removeContextConnection`). Only a clear
  immediately after the "started to delete" line is the purge; that line is
  logged before any registration is cleared.[^task-70]
- **Check for unlinked-but-open files first** when an IndexedDB abort storm
  appears.
- **The decision itself** can be read with `_setResourceLoadStatisticsDebugMode`,
  which logs `About to remove data records for …` on WebKit's `ITPDebug`
  channel at info level.

Step-by-step commands are in
[WebKit helper diagnostics](../playbooks/webkit-helper-diagnostics.md).

# Tests

`ExtensionOriginTrackingPreventionTests` covers the wiring (one interaction
per loaded context; nothing for a non-persistent store, the incognito
profile or a deleted profile; extension web views use the profile store) and
drives a real pass: two http origins write localStorage, one gets the
keeper's `logInteraction`, both are marked prevalent, the clock is advanced a
day, and the pass empties only the uninteracted one while a loaded probe
extension keeps its IndexedDB and its worker.

Traps met while writing it:[^task-70]

- `fetchDataRecords` never lists `webkit-extension://` origins, even after
  `_allowWebsiteDataRecordsForAllOrigins`. The extension side is asserted
  through the worker itself.
- `_setResourceLoadStatisticsTimeAdvanceForTesting` steps in whole days (a
  3-hour advance is a no-op) and cannot be reset, so the test uses its own
  profile's session.
- Interaction expiry needs 30 recorded operating days, so the control origin
  is marked prevalent instead.

# Open questions

- **Disabled extensions.** Only loaded contexts are kept. An extension left
  disabled longer than the window loses its last origin's storage.[^task-72]
- **Storage across relaunches** (resolved 2026-10-28). The keeper's header
  comment is right: WebKit renames the last-seen origin's IndexedDB and
  `localStorage` to the new base URL at every load, on the store the pages
  use. The orphans found on 2026-09-20 were left from before this fix moved
  the pages to the profile store, and WebKit's one-time stale-origin sweep
  has since removed them. See [storage](./storage.md).[^task-99]
- **One unexplained event.** Both of 1Password's hosts in one profile were
  terminated within half a second and respawned a second later on
  2026-09-19. Judged harmless, never explained.[^task-90]

# Related

- [Private profile extensions](./private-profile-extensions.md) — why Private was on the default store, and the gate that was the real problem there
- [Native port keep-alive](./native-port-keep-alive.md) — the pings that made the dead worker visible, and its restart
- [Console bridge](./console-bridge.md) — the flood cap added after the second incident
- [Service worker unload rules](../platform/service-worker-unload-rules.md) — telling an idle unload from a kill
- [Diagnosing extension problems](../playbooks/diagnosing-extension-problems.md) — symptom table
- [Profile data removal](../architecture/profile-data-removal.md) — the same WebKit storage directories from the deletion side

[^task-68]: The armed keep-alive does not stop WebKit unloading a worker (production)
[^task-70]: Tracking prevention deletes an extension origin's script-written storage
[^task-72]: Keep disabled extensions' origins inside ITP's interaction window too
[^task-90]: 1Password worker stuck in a reconnect loop pins the Networking process
[^task-99]: Give each context a stable base URL so extension storage survives a relaunch
[^notes-itp]: Session notes on the extension data store and the ITP purge
