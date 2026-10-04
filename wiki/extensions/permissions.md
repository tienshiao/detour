---
type: Concept
title: Extension permissions
description: How permission decisions are stored, prompted for and re-applied to every loaded context, the order that makes the restore deterministic, how nativeMessaging is enforced, and what WebKit does with overlapping grants and denials.
tags: [extensions, permissions, security, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (loadExtensionContext, applySavedHostAccessDecisions)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (prompt delegates, setPermissionDecision, nativeHostAccess)
  - id: record
    resource: ../../Detour/Extensions/Storage/Models/ExtensionPermissionRecord.swift
    title: ExtensionPermissionRecord.swift
  - id: web-extension
    resource: ../../Detour/Extensions/Model/WebExtension.swift
    title: WebExtension.swift (askablePermissions, askableMatchPatterns)
  - id: tab-conformance
    resource: ../../Detour/Extensions/Runtime/WKExtensionTabConformance.swift
    title: WKExtensionTabConformance.swift
  - id: task-11
    resource: backlog:TASK-11
    title: Re-apply URL-keyed site-access grants when a context is reloaded
  - id: task-19
    resource: backlog:TASK-19
    title: Restore optional-permission decisions and an all_urls denial when a context is reloaded
  - id: task-25
    resource: backlog:TASK-25
    title: Settings rows for optional host permissions, and enforce the saved nativeMessaging decision
  - id: task-44
    resource: backlog:TASK-44
    title: nativeMessaging denials saved before TASK-25 become enforced on upgrade
  - id: task-63
    resource: backlog:TASK-63
    title: Reinstalling or updating an extension overwrites a saved nativeMessaging denial
  - id: task-75
    resource: backlog:TASK-75
    title: Origin patterns with a port make chrome.permissions calls throw in WebKit
  - id: restore-tests
    resource: ../../DetourTests/ExtensionPermissionRestoreTests.swift
    title: ExtensionPermissionRestoreTests
  - id: permission-tests
    resource: ../../DetourTests/ExtensionPermissionTests.swift
    title: ExtensionPermissionTests
  - id: nm-tests
    resource: ../../DetourTests/NativeMessagingEnforcementTests.swift
    title: NativeMessagingEnforcementTests
---

A `WKWebExtensionContext` forgets every permission status when it is unloaded,
and Detour reloads contexts at every launch, on enable, on update and on
background recovery. So permission state lives in Detour's database and is
re-applied on each load. The hard part is that WebKit's grant and denial sets
interact, which makes the order of the restore part of the contract.

# Summary

- Decisions are rows in `extensionPermission`, keyed by
  (extension id, key, type). They are global to the extension, not per
  [profile](../architecture/profiles-and-spaces.md).
- Three row types (`ExtensionPermissionType`):

| Type | Key | Applied with |
|---|---|---|
| `.apiPermission` | The permission name (`history`, `tabs`, …) | `setPermissionStatus(_:for: Permission)` |
| `.matchPattern` | The pattern string, exactly as WebKit reported it | `setPermissionStatus(_:for: MatchPattern)` |
| `.url` | A URL's `absoluteString`, from the site-access prompt | `setPermissionStatus(_:for: URL)` |

- Status is granted or denied. An unreadable status reads as **denied** (fail
  closed) in every reader.
- A `.url` key can be the same string as a `.matchPattern` key, so the types
  are never merged into one dictionary (`statusByKey(type:)`).

# Rules

## Who writes

| Writer | Call | Effect on an existing row |
|---|---|---|
| Install, reinstall, update | `recordDeclaredPermissions` — every manifest `permissions` and `host_permissions` entry as granted | Left alone (insert-or-ignore) |
| A prompt answer, a Settings toggle | `savePermission(s)` | Overwritten |

The first row is why a denial made in Settings survives an update, while a
permission an update newly declares is recorded as granted.[^task-63]
Rows are never purged when a manifest drops a permission; they go inert
instead (below).

## Prompts

WebKit asks through three delegate callbacks (API permissions, URLs, match
patterns). `handlePermissionPrompt` shows an Allow / Deny alert, saves a row
per item, and returns the granted set or an empty one.

One short circuit: a URL or pattern request from an extension holding
`activeTab` is granted without a prompt or a saved row when the tab has an
active user gesture, or when there is no tab (a worker acting on a user
action). API permission prompts are never short-circuited.

`BrowserTab.shouldGrantPermissionsOnUserGesture(for:)` returns `true`. WebKit's
default is `false`, which silently blocks every `activeTab` grant.

## Restore order

`Profile.loadExtensionContext` applies state in this order, before
`controller.load`:

1. `nativeMessaging` is granted explicitly, always (see below).
2. With `activeTab` in the manifest, each content-script match pattern is
   granted. Chrome lets such an extension use tab APIs on pages its content
   scripts run on; WebKit does not grant that implicitly. This comes *before*
   the saved decisions so a saved denial wins.
3. Saved `.apiPermission` rows, for keys in `askablePermissions` (the
   manifest's `permissions` ∪ `optional_permissions` as WebKit parsed them),
   skipping `nativeMessaging`.
4. `applySavedHostAccessDecisions`: saved `.matchPattern` rows, then saved
   `.url` rows — within each, **all grants first, then all denials**.

Undecided permissions are left for WebKit to prompt about.

## The manifest gate

A saved host row is applied only if some requested or optional manifest
pattern *matches* it (`askableMatchPatterns`). The walk is over the saved
rows, not over the manifest:

- `permissions.request({origins})` makes WebKit prompt with the caller's own
  pattern verbatim (`https://mail.example/*` under an optional `<all_urls>`),
  and the answer is saved under that string, which is in neither manifest
  list. An exact-membership check silently dropped every such decision.[^task-19]
- A row outside every manifest pattern stays inert. Re-applying a grant the
  current manifest no longer asks for would widen the extension's access.
  This also closed a hole: an older, ungated `<all_urls>` branch restored a
  stale all-sites grant.[^task-19]

Settings lists exactly what the restore would apply (`canAskForAccess(to:)`,
`savedSubPatternDecisionKeys`), so a switch never claims an access the next
launch drops.

## nativeMessaging

- The context always holds `nativeMessaging`. The polyfill's worker transport
  is `runtime.sendNativeMessage`, and the built-in `detourPolyfill` and
  `detourWebSocketRelay` hosts need it. The saved row is never applied to a
  context.
- A real host is gated at dispatch by `ExtensionManager.nativeHostAccess`:
  built-in host names are decided first and ignore everything else; otherwise
  the manifest must declare `nativeMessaging` (`.denied` if not) and the saved
  decision must not be a denial (`.deniedByUser`). No row means allowed.
- A refusal happens before any host object exists; nothing is looked up or
  spawned. The error is Chrome's "Access to the specified native messaging
  host is forbidden."
- Turning the permission off in Settings also kills the hosts already
  running (`disconnectRealNativeHosts`).
- Migration v13 deleted the denials saved before enforcement existed. The old
  switch wrote the row but nothing read it at dispatch, so honouring those rows
  on upgrade would have silently broken the 1Password unlock.[^task-44]

## Settings toggles

`ExtensionManager.setPermissionDecision` is the single entry point. It saves
the row and applies it to every loaded context in every profile at once. For a
host row it does not set the one key: it clears the key from the context and
re-runs `applySavedHostAccessDecisions`, so the live state is exactly what the
next launch would restore.

## Updates

An update or unpacked reload that adds permissions installs disabled until the
user accepts them; that policy is in [Updates](./updates.md).

# WebKit behaviour the rules depend on

All measured against real contexts and pinned in
[ExtensionPermissionRestoreTests](../../DetourTests/ExtensionPermissionRestoreTests.swift).

- Granted and denied match patterns live in two dictionaries. Writing a
  pattern that is not all-hosts **removes** whatever the opposite dictionary
  holds that the new pattern subsumes. Deny `https://sub.example.com/*`, then
  grant `*://*.example.com/*`, and the denial is gone; the reverse order keeps
  it. Hence denials last.[^task-19]
- `<all_urls>` is matched by equality only. An all-hosts grant and an
  all-hosts denial can both be present, and the denial wins at query time.
  Neither a grant nor `.unknown` removes an existing `<all_urls>` denial, so
  `setPermissionDecision` filters a pattern key out of both dictionaries
  directly (`testWebKitAllHostsGrantDoesNotEraseAllHostsDenial`).[^task-25]
- WebKit reports `<all_urls>` verbatim in whichever manifest list declares
  it, never expanded per scheme; listed in both, it appears only as
  requested.[^task-19]
- A URL grant is widened to an origin pattern, `*://*.host/*`. A per-URL
  denial beats a granted `<all_urls>`, and a denied pattern beats a URL grant
  inside it.[^task-11] The widening is why `.url` rows survive the base URL
  changing on every load, and why two rows on one origin overlap.
- `WKWebExtension` drops permission names it does not implement from
  `optionalPermissions` (`bookmarks` was dropped, `cookies` kept), so such a
  row is never applied and never prompted for.[^task-19]
- `permissions.contains` answers from granted patterns only: an explicit
  denial under a granted `<all_urls>` still answers `true`.[^task-75]

## Origin patterns with a port

Chrome's match patterns take a port (`http://127.0.0.1:8471/*`); WebKit's
parser accepts `scheme://host/path` only. `permissions.contains` with a ported
origin **throws synchronously** — not a rejected promise — so a caller with
only `.catch()` fails at the call site. 1Password checks every page's origin
this way, so on any site served from a non-default port its inline menu
appeared on no form at all.[^task-75]

`permissionsOriginPortJS` wraps `contains`, `request` and `remove` and drops
the port from each `details.origins` string before forwarding. WebKit's grants
are per host, so the rewritten question is the one it can answer. A known
divergence from Chrome: `request` and `remove` of a ported pattern act on the
whole host, where Chrome treats `host:8080` as narrower.

A ported pattern in a manifest's `host_permissions` is dropped by WebKit from
`requestedPermissionMatchPatterns`, so a saved row for it is inert either way
(`testPortedHostPermissionNeverBecomesAnAskablePattern`).

# Gaps

- The polyfill's own gates (`history`, `management`) check that the manifest
  *declares* the permission (`hasPermission`), not the user's saved decision.
- A legacy full-URL row saved as `.matchPattern` before `.url` existed is
  applied as an exact-path pattern when the manifest covers it, which is
  narrower than the origin-wide grant a `.url` row gives. No migration was
  written: the heuristic would also have widened wildcard-free manifest
  patterns.[^task-11]

# Where it lives

- [Profile.swift](../../Detour/Browser/Profile.swift) — the restore.
- [ExtensionManager.swift](../../Detour/Extensions/Runtime/ExtensionManager.swift) — prompts, Settings toggles, `nativeHostAccess`.
- [ExtensionPermissionRecord.swift](../../Detour/Extensions/Storage/Models/ExtensionPermissionRecord.swift) and `AppDatabase` — storage.
- `ExtensionsSettingsViewController` — the rows: required, `Optional:`, `Requested sites:`, `Site access:` ([Settings](../features/settings.md)).
- Tests: `ExtensionPermissionRestoreTests` (context level), `ExtensionPermissionTests` (database level), `NativeMessagingEnforcementTests` (real fake-host spawns).

# Related

- [ExtensionManager](./extension-manager.md) — where a context load sits in the lifecycle.
- [Native messaging](./native-messaging.md) — what `.allowed` leads to.
- [Chrome runtime patching](./chrome-runtime-patching.md) — how the `permissions` wrappers stay in place.
- [Private profile extensions](./private-profile-extensions.md) — `hasAccessToPrivateData`, a different gate.

[^task-11]: Re-apply URL-keyed site-access grants when a context is reloaded
[^task-19]: Restore optional-permission decisions and an all_urls denial when a context is reloaded
[^task-25]: Settings rows for optional host permissions, and enforce the saved nativeMessaging decision
[^task-44]: nativeMessaging denials saved before TASK-25 become enforced on upgrade
[^task-63]: Reinstalling or updating an extension overwrites a saved nativeMessaging denial
[^task-75]: Origin patterns with a port make chrome.permissions calls throw in WebKit
