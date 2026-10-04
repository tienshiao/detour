---
type: Component
title: runtime.onInstalled
description: Why Detour suppresses WebKit's runtime.onInstalled and emits its own from a per-profile version ledger, how the background context claims the event at start-up, and how the claim is restricted to the real background context.
tags: [extensions, runtime, polyfill, security, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: rule
    resource: ../../Detour/Extensions/Runtime/RuntimeInstalledEvent.swift
    title: RuntimeInstalledEvent.swift
  - id: record
    resource: ../../Detour/Extensions/Storage/Models/ExtensionInstalledEventRecord.swift
    title: ExtensionInstalledEventRecord.swift
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (runtimeOnInstalledJS, preambleJS)
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (senderIsBackgroundContext, runtime.claimInstalledEvent)
  - id: registry
    resource: ../../Detour/Extensions/Runtime/ExtensionPageHostRegistry.swift
    title: ExtensionPageHostRegistry.swift
  - id: plan-doc
    resource: ../../docs/1password-integration-plan.md
    title: docs/1password-integration-plan.md, "runtime.onInstalled"
  - id: task-22
    resource: backlog:TASK-22
    title: Verify runtime.onInstalled is delivered in the app, or emit it ourselves
  - id: task-29
    resource: backlog:TASK-29
    title: runtime.onInstalled parity gaps left by TASK-22
  - id: task-43
    resource: backlog:TASK-43
    title: MV3 extensions with a background page never receive runtime.onInstalled
  - id: task-64
    resource: backlog:TASK-64
    title: The claim handler accepts a claim from any page of the extension
  - id: task-66
    resource: backlog:TASK-66
    title: A top-level extension page navigated to the background document path can claim
  - id: task-20
    resource: backlog:TASK-20
    title: Un-skip the WKExtensionIntegrationTests runtime messaging tests
  - id: ledger-tests
    resource: ../../DetourTests/RuntimeInstalledEventTests.swift
    title: RuntimeInstalledEventTests
---

Extensions do first-run setup in `runtime.onInstalled`: 1Password opens its
welcome page there. WebKit's own event fires at the wrong times, so Detour
keeps it away from the extension and delivers one of its own, decided from a
ledger of what each profile has already been told.

# Role

## What WebKit does

WebKit decides the reason per context *load*
(`WebExtensionContext::determineInstallReasonDuringLoad`): a version different
from the `LastSeenVersion` it stored is an update; otherwise a load into a
controller that is no longer "freshly created" (about 5 s after its first
load) is an install; any other load is none.

Measured in the app on 2026-09-12 (macOS 26.6.2, WebKit 21624.5.1.11.3) with
the API Explorer worker recording each event:[^task-22]

| Situation | WebKit delivers |
|---|---|
| First extension a profile's controller ever loads | Nothing (`onStartup` instead) |
| Install while the controller already had a context for more than 5 s | `install` |
| Update 3.0.0 → 3.0.1, persistent profile | `update`, `previousVersion: 3.0.0` |
| The same update in the Private profile | `install` |
| Background-load recovery reload | `install` — spurious |
| Disable → enable, global or per profile | `install` — spurious |
| Relaunch | Nothing |

So an extension would miss its real first install and repeat it at every
recovery or re-enable. The unit-test process always sits inside the 5 s
window, which is why `testRuntimeOnInstalledIsNotDelivered` sees nothing; that
test pins the measurement and will fail loudly if WebKit changes.[^task-20]

## What Detour delivers

Per profile: exactly once per install, reinstall or version change; never for
a reload, relaunch or re-enable; never `chrome_update`. A profile where the
extension was disabled during an update gets the `update` when it next runs
there. The Private profile never gets the event.

# How it works

## Suppressing WebKit's event (`runtimeOnInstalledJS`)

WebKit dispatches to listeners registered on its native event object, so the
only way to keep its event away is to keep the extension's listeners off that
object. The module defines own properties `addListener`, `removeListener`,
`hasListener` and `hasListeners` on the event wrapper, holding the listeners
itself. WebKit sees a context with no `onInstalled` listener and has nothing
to deliver.

`onInstalled` is `[MainWorldOnly]`, served by a property callback on every
read, and what the read returns comes from the weak wrapper cache
([Chrome runtime patching](./chrome-runtime-patching.md)). The module holds a
strong reference to the wrapper it patched and then re-reads to check the
shadow is visible. If it is not (`patch-not-visible`), it puts everything back
and leaves the event to WebKit rather than splitting listeners across two
lists. Nothing else is touched: not `chrome`, `browser` or `chrome.runtime`.

The shadowing applies in **every** context that has `runtime.onInstalled`:

| Context | Mode | Behaviour |
|---|---|---|
| Service worker, background page | `detour` | Claims once per start and dispatches what Detour answers |
| Popup, options, extension tab, offscreen document | `suppressed` | Listeners are kept and never called |

Pages are suppressed because WebKit's spurious `install` reaches any page that
is listening when a recovery reload or re-enable fires it. In Chrome a page
opened after the event never sees it either.[^task-29]

## The claim

Once per background-context start, on a later task, the context sends
`runtime.claimInstalledEvent`:

- a worker claims on the next task (a classic worker has registered its
  top-level listeners by then; a module worker that awaits before registering
  could miss it, and Chrome requires synchronous registration too);
- a background page claims on a task after `DOMContentLoaded`, because a timer
  alone can fire while the parser is still yielding.

`AppDatabase.claimRuntimeInstalledEvent` reads the ledger and advances it in
one transaction and answers `{reason, previousVersion?}` or `{}`. Of any
number of claims for one version exactly one gets the event. The ledger
advances *before* the context dispatches: a context that dies in between loses
the event rather than risking it twice.

Listeners registered after the claim settled get nothing, as in Chrome.

## The ledger

`extensionInstalledEvent` holds, per (extension, profile), the version the
event was last delivered for and a `reinstallPending` flag. The pure rule is
`RuntimeInstalledEvent.pending(ledger:currentVersion:isPrivateProfile:)`:

| Ledger | Owed |
|---|---|
| Private profile | Nothing, ever |
| No row | `install` |
| Row with a different version | `update` from the delivered version |
| Row with `reinstallPending` | `update` from the delivered version (the current one, for a same-version reinstall) |
| Otherwise | Nothing |

- Only `ExtensionManager.install` over an already-installed extension sets
  `reinstallPending`. Chrome reports `update` for reloading an unpacked
  extension; this is Detour's nearest equivalent. A recovery reload, relaunch
  or re-enable never sets it.
- Migration v9 seeded every (installed extension, saved profile) with the
  installed version, so upgrading Detour did not replay `install` everywhere.
  A profile created later has no row and gets `install` when the extension
  first runs there.
- The Private profile is excluded because Chrome's default "spanning"
  incognito mode never gives the incognito side its own event, and because
  delivering it would rerun first-run setup in windows whose extension storage
  does not survive a relaunch. No row is ever written for it.
- Rows are deleted with the extension, so a reinstall under the same id after
  an uninstall is a new install.

## Waking the background

A worker that nothing starts would get its event only when something else
woke it. `ExtensionManager.wakeForPendingInstalledEvent` calls
`loadBackgroundContent` after a launch load, an install and an enable, when
`installedEventOwingWake` says an event is owed. It requires background
content by both WebKit's parse and Detour's manifest, and skips the Private
profile.

## Who may claim

A claim advances the ledger, so a popup or options page calling
`__detourPolyfillRequest('runtime.claimInstalledEvent')` directly would
consume its own extension's install and the background would never get it.
Verified identity is not enough: every context of the extension has it. The
handler checks the *sender* (`ExtensionPolyfillHandler.senderIsBackgroundContext`):

| Sender | Accepted when |
|---|---|
| Native message (no frame) | The manifest's background may run as a service worker (`Background.mayRunAsServiceWorker`) |
| Frame | It is the main frame, at the background document's percent-encoded path, **and** its web view is not one Detour hosts |

The background document path is `background.page` resolved against the
extension root, or `/_generated_background_page.html` for a `background.scripts`
list. `preferred_environment` is honoured: a `scripts` list may be hosted in a
worker, a `service_worker` in the generated document.

The path alone is not enough: a tab navigated to the background path has that
path too. `WKWebExtensionContext` exposes no background web view, so the
discriminator is the inverse. `ExtensionPageHostRegistry` is a weak set of
every web view Detour creates or presents for extension content (tabs, the
popup, offscreen documents). WebKit's background page is the one view Detour
never touches, so *absence* from the registry identifies it. A message with no
web view fails closed as hosted.[^task-66]

A refused claim is logged, answered with an error, and returns before the
ledger call, so the event stays pending.

# Invariants

- No native `onInstalled` listener is ever registered by the polyfill.
- The claim is the only writer that marks an event delivered.
- `claimInstalledEvent` doubles as Detour's "a background context just
  started" signal; [Updates](./updates.md) depends on it.

# Gotchas

- **Accepted limit.** `runtime.sendNativeMessage` reaches the delegate with
  the context only, never the sending frame. For a service-worker manifest, an
  ordinary extension page that calls
  `chrome.runtime.sendNativeMessage('detourPolyfill', {type: 'runtime.claimInstalledEvent'})`
  directly is indistinguishable from the worker. It can only take its own
  extension's event, and no extension is known to do it.[^task-64]
- The polyfill's own `__detourContextKind` still classifies by path, so a tab
  navigated to the background path calls itself a background page and tries to
  claim. The native gate is what refuses it.
- Nothing reads `manifest_version`: MV2's background shapes in an MV3 manifest
  are treated the same way.
- WebKit's `onStartup` on a profile's first install is left alone.

# Tests

- [RuntimeInstalledEventTests](../../DetourTests/RuntimeInstalledEventTests.swift) — the pure rule, the ledger and its migrations.
- `ExtensionPolyfillTests` — the shadowing, modes, and `senderIsBackgroundContext` over manifest shapes.
- `ExtensionPolyfillProfileWiringTests` — real contexts: one `install` per background shape; `testRealExtensionPageDoesNotSeeWebKitsRuntimeOnInstalled` (a control listener on the native method receives WebKit's `install`, the shadowed one does not); `testAnOrdinaryExtensionPageCannotClaimTheInstalledEventThroughTheBridge`; a tab navigated to `/_generated_background_page.html` is refused.
- A wiring test cannot assert "the ledger is still pending right after a refusal": opening any extension web view also starts the real background page, whose legitimate claim races. The tests pin the end state.

# Related

- [Polyfill layer](./polyfill-layer.md) — sender verification in general.
- [ExtensionManager](./extension-manager.md) — where the wake is called.
- [Updates](./updates.md) — the `update` event and the reload heuristic.
- [1Password integration](./1password-integration.md) — the extension whose welcome page made this matter.

[^task-22]: Verify runtime.onInstalled is delivered in the app, or emit it ourselves
[^task-29]: runtime.onInstalled parity gaps left by TASK-22
[^task-64]: The claim handler accepts a claim from any page of the extension
[^task-66]: A top-level extension page navigated to the background document path can claim
[^task-20]: Un-skip the WKExtensionIntegrationTests runtime messaging tests
