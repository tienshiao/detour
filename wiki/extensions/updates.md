---
type: Feature
title: Extension updates
description: How installed extensions move to newer versions — the update2 poll, the verification gate, the added-permissions hold, deferring an update while the extension is busy, runtime.onUpdateAvailable, and why runtime.reload has to be recognised natively.
tags: [extensions, updates, crx, polyfill]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: updater
    resource: ../../Detour/Extensions/Updates/ExtensionUpdater.swift
    title: ExtensionUpdater.swift
  - id: policy
    resource: ../../Detour/Extensions/Updates/ExtensionUpdatePolicy.swift
    title: ExtensionUpdatePolicy.swift
  - id: deferral
    resource: ../../Detour/Extensions/Updates/ExtensionUpdateDeferral.swift
    title: ExtensionUpdateDeferral.swift
  - id: staged
    resource: ../../Detour/Extensions/Updates/StagedExtensionUpdate.swift
    title: StagedExtensionUpdate.swift
  - id: manager-updates
    resource: ../../Detour/Extensions/Runtime/ExtensionManager+Updates.swift
    title: ExtensionManager+Updates.swift
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (runtimeUpdateCheckJS)
  - id: task-113
    resource: backlog:TASK-113
    title: Check for and install extension updates
  - id: task-123
    resource: backlog:TASK-123
    title: Defer an update while the extension is busy and fire runtime.onUpdateAvailable
  - id: notes-updates
    resource: "Agent session notes, 2026-09-26 (not in the repository)"
    title: Extension updates — design decisions
  - id: docs-extensions
    resource: ../../docs/extensions.md
    title: docs/extensions.md, "Updates"
---

A CRX-installed extension is polled for newer versions and replaced in place;
an unpacked one is reloaded from its folder on request. An update is never
installed under an extension that is in the middle of something: it is staged
and applied when the extension goes idle. The awkward part is Chrome's
`runtime.onUpdateAvailable` / `runtime.reload()` handshake, because WebKit
gives the host neither a way to push an event into a worker nor a way to see a
reload.

# What it does

- Checks every CRX install against its update URL about 30 s after launch if
  the last full check is more than 5 hours old, and then whenever 5 hours have
  passed (a timer looks every 15 minutes). Never in the unit-test host.
- On demand: Settings → Extensions → Check for Updates, Extensions → Check for
  Extension Updates, and `chrome.runtime.requestUpdateCheck`.
- Unpacked extensions get Reload in Settings and the Develop menu
  (`reloadUnpacked`). Any version is accepted and the id is kept.
- An update that adds permissions installs **disabled** until the user accepts
  them.
- A verified update for a busy extension waits on disk; Settings shows it with
  **Install Now**.

# How it works

## The check (`ExtensionUpdater.performCheck`)

1. Build the update2 request (`UpdateManifest.requestURL`):
   `response=updatecheck`, `acceptformat=crx3`, `prodversion`, and an `x`
   parameter holding `id=…&v=…&uc` with its inner `=` and `&` percent-encoded.
   The store does not split a raw one.
2. Parse the `<gupdate>` answer. An `<app status>` other than `ok`, or an
   `<updatecheck status>` other than `ok` / `noupdate`, is a failure.
   Self-hosted manifests are the same document.
3. Stop unless the announced version is strictly newer.
4. Download the CRX and run the gate below.
5. Either stage it or call `ExtensionManager.applyUpdate`.

A second check for the same extension while one is running joins it.

## The gate

A candidate is taken only if all hold:

| Check | Where |
|---|---|
| The download matches the announced SHA-256, when one is announced | `ExtensionUpdatePolicy.validateSHA256` |
| Every CRX3 signature verifies and one key hashes to the header's `crx_id` | `CRX3Verifier` ([Installer and CRX](./installer-and-crx.md)) |
| That key derives the *installed* extension id | `validateCandidate` |
| The version is strictly newer | `ExtensionVersion.isNewer` |

`ExtensionVersion` orders versions as Chrome does: one to four dot-separated
non-negative integers, missing trailing components read as 0 (`1.2 == 1.2.0`,
`1.10 > 1.9`). A version that does not parse can never count as newer.

`applyUpdate` re-reads the installed extension and re-checks id and version,
because the extension may have changed while the download ran. The replacement
goes through the ordinary `install` path, which already keeps per-profile
enablement and saved permission decisions, moves open
[extension pages](./extension-pages.md) to the new origin, and owes
[`runtime.onInstalled`](./runtime-installed-event.md) its `update`.

## Added permissions

`ExtensionUpdatePolicy.addedPermissions(from:to:)` compares manifests:

- API permissions the old manifest lacked, except those in
  `warningFreePermissions` (a deliberately short list of permissions Chrome
  shows no install warning for);
- host access — `host_permissions` plus content script `matches` — not already
  covered by a pattern the old manifest had
  (`WKWebExtension.MatchPattern.matches`). A candidate pattern that does not
  parse counts as new;
- optional permissions are not counted: they are asked for at use.

A non-empty delta installs the new version with the global flag off and a
`pendingPermissionApproval` (version and delta) saved as JSON on the
`extension` row. A later update's additions merge into a pending approval
rather than replacing it. `approvePendingPermissions` clears it and enables
the extension; Settings shows a banner with "Accept and Enable", and turning
the Enabled switch on asks the same question.

## Deferral

Replacing a running context tears its pages down and restarts its worker.
WebKit exposes no "background content is running" signal, so
`ExtensionManager.activity(for:)` reads what Detour can see, and
`ExtensionUpdateDeferral.shouldDefer` holds the update when any is true:

- a tab, pinned tile, favourite or peek in any profile shows one of the
  extension's pages;
- its popup is open;
- a real native messaging host is connected for it;
- its background context made a polyfill request in the last 60 s
  (`noteBackgroundActivity`, recorded for every background-context request).

The verified, unpacked copy is moved to `<data>/Extensions/<id>.staged/` with a
`detour-staged.json` holding the id, version, verified signing key and time
(`StagedExtensionUpdate`). A newer update replaces an older staged one. The
check reports `.deferred(version:)`.

A staged copy is applied by whichever comes first:

| Trigger | Code |
|---|---|
| The extension is idle at the 30 s poll | `applyStagedUpdatesIfIdle` |
| A check finds the copy and the extension idle | `performCheck` |
| The next launch, before extension rows are read | `applyStagedUpdatesBeforeLoad` (installer level: no context exists yet) |
| Settings → Install Now | `applyStagedUpdate` |
| The extension reloads in response to `onUpdateAvailable` | `backgroundContextDidStart` |

Every path re-validates id and version (a copy the extension has since
overtaken is discarded) and applies the added-permissions policy. The marker
file is removed from the installed copy, since the installer copies the
directory whole.

## `runtime.onUpdateAvailable`

WebKit implements neither this event nor `requestUpdateCheck`; the polyfill
fills in both when absent.

There is no push channel into a worker, so the event is a **parked request**:
the first `addListener` in the background context sends
`runtime.awaitUpdateAvailable`, and Detour holds the reply
(`awaitUpdateAvailable`, one waiter per profile and extension; a newer one
supersedes the old). `stageUpdate` answers it with `{version}`; the listeners
run and the request is parked again. If an update is already staged when the
listener is added it is answered at once. Requests from anything but the
background context are refused, so the event exists in a popup or options page
and never fires there.

## Recognising `runtime.reload()`

Chrome's documented pattern is to call `runtime.reload()` from the listener to
take the update. WebKit's `reload` cannot be intercepted from JavaScript
([Chrome runtime patching](./chrome-runtime-patching.md)), and its reload
keeps the context object and base URL and calls no delegate method. Its only
trace is the background context starting again, which Detour sees because
every background start sends `runtime.claimInstalledEvent`.

So `backgroundContextDidStart` installs the staged copy when a background
start comes within 15 s (`reloadAfterUpdateAvailableWindow`) of an
`onUpdateAvailable` delivery for that same staged version **to an earlier
incarnation of the context**. The incarnation is the polyfill's
`__detourContextInstance` token, stamped on both the wait and the claim.

The token exists because of a bug the review caught. An extension adds its
listener at script evaluation, which is answered at once when a copy is
staged, and the start-up claim runs on a later task. Without the token every
ordinary worker start looked like "a delivery, then a restart" and installed
the update, defeating the deferral.[^task-123]

For the same reason an immediate answer is withheld when that version was
delivered to this context in the last 15 s: that is the reloaded worker
re-adding its listener, and answering again would loop.

# Edge cases

- A reload made for any other reason is indistinguishable from an event waking
  the worker; it leaves the staged copy for the idle poll.
- An extension that keeps a native host connected (1Password with its desktop
  app running) is never idle, so its updates land only at launch or through
  Install Now.[^notes-updates]
- `requestUpdateCheck` is throttled to one real check per extension per 5
  minutes (in memory). It answers Chrome's single result object in both forms:
  `throttled`; `no_update` for up to date, not updatable *and a failed check*
  (Chrome reports no error for either); `update_available` with `version` for
  installed, held for approval, or deferred.
- The popup signal is narrower than it reads. `isPopupOpen` looks at
  `ExtensionManager.activePopovers`, which only `presentActionPopup`
  (`action.openPopup()`) fills; a popup the user opened from the sidebar button
  or the Extensions menu is retained elsewhere and is not counted.
- Uninstall discards the staged copy and the parked waits.
- A non-store CRX without an `https` `update_url` never updates.
- Not exercised in the running app: the Install Now row, and a real store
  update arriving while an extension is busy.[^task-123] The real 1Password
  store CRX was verified and a live `noupdate` check run against the
  store.[^task-113]

# Tests

`ExtensionUpdaterTests` (canned fetcher, injected clock), `ExtensionUpdatePolicyTests`,
`ExtensionUpdateDeferralTests`, `StagedExtensionUpdateTests`, `UpdateManifestTests`,
`ExtensionVersionTests`, `ExtensionUpdateMigrationTests`, and the polyfill side
in `ExtensionRuntimeUpdateCheckPolyfillTests` and
`ExtensionRuntimeUpdateAvailablePolyfillTests`.

# Related

- [Installer and CRX](./installer-and-crx.md) — sources, the verifier, the install step.
- [CRX verification gate](../decisions/crx-verification-gate.md) — the decision behind the gate.
- [runtime.onInstalled](./runtime-installed-event.md) — the claim that doubles as the "background started" signal.
- [Service worker unload rules](../platform/service-worker-unload-rules.md) — why 60 s of silence means idle.
- [Settings](../features/settings.md) — the Extensions pane rows.

[^task-113]: Check for and install extension updates
[^task-123]: Defer an update while the extension is busy and fire runtime.onUpdateAvailable
[^notes-updates]: Extension updates — design decisions
