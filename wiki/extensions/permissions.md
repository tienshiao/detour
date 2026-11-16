---
type: Concept
title: Extension permissions
description: How permission decisions are stored, prompted for and re-applied to every loaded context, the order that makes the restore deterministic, how nativeMessaging is enforced, and what WebKit does with overlapping grants and denials.
tags: [extensions, permissions, security, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:06:25Z }
sources:
  - id: task-339
    resource: backlog:TASK-339
    title: "Extensions settings: every permission has a readable name (no raw 'privacy' or 'favicon')"
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
  - id: task-250
    resource: backlog:TASK-250
    title: "Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions"
  - id: task-258
    resource: backlog:TASK-258
    title: "Extensions: permissions.remove is not saved, so the revoked permission comes back at the next launch"
  - id: task-259
    resource: backlog:TASK-259
    title: "Extensions: a required notifications, history or management permission switched off in Settings still works"
  - id: task-268
    resource: backlog:TASK-268
    title: "Extensions: clearing a grant the extension removed writes the full page URL to the system log as public"
  - id: task-276
    resource: backlog:TASK-276
    title: "Docs: fix the permission-scope and notification-ordering descriptions the review found wrong"
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
| The extension's own `permissions.remove` | `revokePermission`, from `contextDidLoseGrants` (or `removeOutsideWebKitPermissions` for `history` / `management`; see [chrome.permissions for history and management](./polyfill-permissions.md)) | A granted row is deleted |

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
3. Saved `.apiPermission` rows, for keys in `restorablePermissions`:
   `askablePermissions` (the manifest's `permissions` ∪
   `optional_permissions` as WebKit parsed them) plus
   `polyfillGatedDeclaredPermissions`, the
   [polyfill-gated](./polyfill-request-gates.md#why-the-grant-dictionary-is-read)
   names either list declares, since WebKit drops `history` and `management`
   from its lists; skipping `nativeMessaging`.[^task-250]
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
the row and applies it to every loaded context in every profile at once.
Every switch can be turned off, a required permission's too: the pane asks
"Revoke Permission?" first, then saves a denied row like any other.[^task-259] For a
host row it does not set the one key: it clears the key from the context and
re-runs `applySavedHostAccessDecisions`, so the live state is exactly what the
next launch would restore.

Each switch reads as `ExtensionPermissionDescriptions.describe`, as the
install and request prompts do: a sentence per permission ("Store data
locally"). Every permission Detour knows has one of its own: WebKit's
`WKWebExtension.Permission` constants, the ones the polyfill implements or
stands in for (`privacy`, `favicon` among them, which showed their raw names
until TASK-339) and `background`; `ExtensionPermissionDescriptionsTests`
walks that list. Any other reads as its name made legible ("tabGroups" is
"Tab groups", "system.display" "System display"), never the raw manifest
string. `management.getPermissionWarningsByManifest` keeps returning an
unknown permission's manifest name, as before (the window's legible form is
not API output).[^task-339]

## The extension's own permissions.remove

WebKit applies `permissions.remove` to the context only. Detour learns of it
from `WKWebExtensionContext.grantedPermissionsWereRemovedNotification` and
`grantedPermissionMatchPatternsWereRemovedNotification`, which
`ExtensionManager` observes for every context, and deletes the saved granted
rows the removal revoked (`savedGrantsRevoked`).[^task-258]

- **The row is deleted, not saved as denied.** A saved denial is restored as
  `deniedExplicitly`, and WebKit never prompts for an explicitly denied
  permission (`needsPermission` is false for it), so a later
  `permissions.request` would be refused without asking. With no row, Settings
  reads OFF and the next request prompts; the prompt saves the new answer.
  This is Chrome's state after a removal.
- **The rule is on state, not on who wrote.** WebKit posts these
  notifications for every write that takes a grant out, Detour's own
  included (a restored denial, a Settings clear-and-reapply), and posts them
  with `dispatch_async` to the main queue after the write. So a flag around
  Detour's writes would not cover them. Instead, at delivery a saved
  granted row whose key was removed is deleted only when the context neither
  grants it nor denies it, and no denied pattern covers it. Detour's own
  writes always leave the key granted, denied or covered by a denial.
- **That is an invariant every Detour write must keep.** The rule is right
  only while each write Detour makes to a context's grants and denials ends
  its main-actor turn with every key it touched granted, denied or covered by
  a denial, never plainly removed, unless the saved row is gone or meant to
  go. Today's writes do: the load restore only adds statuses, and a grant it
  takes out is one a later denial erases or covers; `applySavedDecisions`
  clears a host key and re-runs the restore before the notification is
  delivered, and writes `.unknown` only for a key with no row; the TASK-270
  notification revocation writes no permission. A future write that removed
  a grant from one profile's context alone (say, a Private-only rule) would
  be read as the extension's own removal and delete the saved grant, which
  is the extension's, for every profile. The invariant is stated in the code
  on `applySavedDecisions` and at the restore in
  `Profile.loadExtensionContext`.[^task-276]
  `permissionStatus(for:)` of a pattern under a broader denied pattern does
  not read as denied, which is why the covering-denial check is separate.
- Skipped: rows outside the restore's manifest gate (inert), required keys
  (WebKit refuses to remove a required permission or an origin a required
  pattern covers; a broader optional origin still sweeps a narrower required
  grant out of the context, and the row keeps the next load correct), and
  `nativeMessaging`.
- A removed origin also clears the `.url` rows it covers: WebKit removes
  every granted pattern the removed one matches, the URL's widened origin
  pattern included.
- The cleared rows are then applied to every loaded context of the
  extension, in every profile (`applySavedDecisions`, shared with
  `setPermissionDecision`), since the decision belongs to the extension. In
  the context that removed, the restore re-run puts back the required grants
  WebKit's sweep took. Those writes post again and end there, because the rows
  are already gone.
- A post that arrives after the context was unloaded (disable, update) still
  counts: the extension is found by the context's `uniqueIdentifier`, and
  unloading touches no permission.
- An open Settings pane follows (below).
- Grants are not observed: every grant WebKit makes from `permissions.request`
  comes from a prompt answer, which `handlePermissionPrompt` saves.

## The open Settings pane

Every write of a saved decision posts
`ExtensionManager.permissionDecisionsDidChangeNotification` with the
extension's ID: `setPermissionDecision`, a prompt answer
(`handlePermissionPrompt`) and a removal (`contextDidLoseGrants`). The
Extensions pane rebuilds its detail when the ID is the shown extension's, so a
switch never reads a row that has since changed. Its own toggle ends in the
same rebuild, and a switch that had keyboard focus hands it to the switch
rebuilt for the same row. Install's `recordDeclaredPermissions` does not post; install
posts `extensionsDidChangeNotification`, which reloads the whole
list.[^task-259]

## Updates

An update or unpacked reload that adds permissions installs disabled until the
user accepts them; that policy is in [Updates](./updates.md).

## Log privacy

A `.url` key is the full address the site-access prompt asked about, path and
query included, and a match-pattern key names the sites the user granted.
Both are browsing data, so a log line about a saved decision prints only the
key's scheme publicly and the whole key `.private`:
`ExtensionPermissionType.publicLogPart(ofKey:)` gives the public part (an API
permission name and `<all_urls>` whole, otherwise the scheme: the text before the first `:` when it is a plain scheme token or `*`, else `(no scheme)`), the rule
`logRejectedOrigin` follows for origins. The lines that use it are the
removal in `clearRemovedGrants` (`removed its grant of URL https
(<private>)`) and the two stale-row lines of `applySavedHostAccessDecisions`.
A test host run from Xcode or `xcodebuild` shows private values; a launch
outside Xcode reads `<private>`.[^task-268]

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
- Setting a match pattern the context already holds with the same status
  adds a second entry for the same string, so `permissions.getAll` lists the
  origin twice. The bridged Swift dictionary hides it (one key). So
  `applySavedHostAccessDecisions`, which Settings and a removal re-run on a
  loaded context, skips a pattern already held with its status. Measured in
  the running app and pinned through `getAll` in
  `testRemovedOptionalOriginStaysRevokedAfterReload`.[^task-258]
- `permissions.contains` answers from granted patterns only: an explicit
  denial under a granted `<all_urls>` still answers `true`.[^task-75]

## Permissions the polyfill gates

`notifications`, `history` and `management` are implemented by Detour's
polyfill, which gates them itself (`WebExtension.polyfillGatedPermissions`)
with the same saved decisions, restore and Settings switches as above. The
handler's rule (`permissionIsActive`), its refusal texts and the WebKit
behaviour behind it are in
[polyfill request gates](./polyfill-request-gates.md#the-active-permission-rule);
`permissions.request`, `contains` and `remove` of `history` and `management`
are in [chrome.permissions for history and management](./polyfill-permissions.md);
what `management.getSelf` / `getAll` list is in
[chrome.management](./polyfill-management.md#extensioninfo-lists-the-active-set).

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

- A legacy full-URL row saved as `.matchPattern` before `.url` existed is
  applied as an exact-path pattern when the manifest covers it, which is
  narrower than the origin-wide grant a `.url` row gives. No migration was
  written: the heuristic would also have widened wildcard-free manifest
  patterns.[^task-11]

# Where it lives

- [Profile.swift](../../Detour/Browser/Profile.swift) — the restore.
- [ExtensionManager.swift](../../Detour/Extensions/Runtime/ExtensionManager.swift) — prompts, Settings toggles, `nativeHostAccess`.
- [ExtensionPermissionRecord.swift](../../Detour/Extensions/Storage/Models/ExtensionPermissionRecord.swift) and `AppDatabase` — storage.
- `ExtensionsSettingsViewController` — the rows, in form sections since TASK-338: Permissions, Optional Permissions, Requested Sites, Site Access ([Settings](../features/settings.md)).
- Tests: `ExtensionPermissionRestoreTests` (context level, and `permissions.remove` from a real extension page), `ExtensionPermissionTests` (database level), `NativeMessagingEnforcementTests` (real fake-host spawns); optional polyfill-gated permissions in a real context in `ExtensionHistoryScopeTests` (with `permissions.request` / `contains` / `remove` of `history` and `management`, section 7) and `ExtensionNotificationOrderingTests`.

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
[^task-268]: Extensions: clearing a grant the extension removed writes the full page URL to the system log as public
[^task-258]: Extensions: permissions.remove is not saved, so the revoked permission comes back at the next launch
[^task-250]: Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions
[^task-259]: Extensions: a required notifications, history or management permission switched off in Settings still works
[^task-276]: Docs: fix the permission-scope and notification-ordering descriptions the review found wrong
[^task-339]: TASK-339
