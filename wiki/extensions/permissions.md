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
  - id: task-250
    resource: backlog:TASK-250
    title: "Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions"
  - id: task-258
    resource: backlog:TASK-258
    title: "Extensions: permissions.remove is not saved, so the revoked permission comes back at the next launch"
  - id: task-259
    resource: backlog:TASK-259
    title: "Extensions: a required notifications, history or management permission switched off in Settings still works"
  - id: task-260
    resource: backlog:TASK-260
    title: "Extensions: chrome.permissions.request, contains and remove do not work for history and management"
  - id: task-261
    resource: backlog:TASK-261
    title: "Extensions: management.getSelf and getAll leave out permissions granted at runtime"
  - id: task-268
    resource: backlog:TASK-268
    title: "Extensions: clearing a grant the extension removed writes the full page URL to the system log as public"
  - id: polyfill-handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift (permissionIsActive)
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
| The extension's own `permissions.remove` | `revokePermission`, from `contextDidLoseGrants` (or `removeOutsideWebKitPermissions` for `history` / `management`) | A granted row is deleted |

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
the row and applies it to every loaded context in every profile at once.
Every switch can be turned off, a required permission's too: the pane asks
"Revoke Permission?" first, then saves a denied row like any other.[^task-259] For a
host row it does not set the one key: it clears the key from the context and
re-runs `applySavedHostAccessDecisions`, so the live state is exactly what the
next launch would restore.

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
  writes always leave the key granted or denied.
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
polyfill, which gates them itself (`WebExtension.polyfillGatedPermissions`).
The handler's rule is `ExtensionPolyfillHandler.permissionIsActive`, in
WebKit's own order for the APIs it implements
(`WebExtensionContext::permissionState`: denied, then granted, then
requested):

- an unexpired entry in the asking profile's context's `deniedPermissions`
  refuses, whichever list declares it. For a required permission that is the
  Settings switch turned off, or its saved denial restored at
  load.[^task-259]
- listed in the manifest's `permissions`: otherwise active, even with no
  decision. WebKit would leave an undecided required permission at
  "requested" and prompt, but it never prompts for `history` or
  `management`, and install saves every required permission as granted.
- listed only in `optional_permissions`: active while the context holds an
  unexpired entry in `grantedPermissions`. A Settings switch
  (`setPermissionDecision`), a `permissions.request` prompt (WebKit's for
  `notifications`, Detour's for the other two, below) and the restore at
  load put it there; `permissions.remove` and a switch turned off take it
  out, and the next call is refused.[^task-250]

A refused call says which state it is in (`permissionRefusal`): "<name>
permission not declared" (in neither list), "<name> permission denied by the
user" (an unexpired denial: the switch off, a prompt answered Deny, or that
saved denial restored), or "<name> permission is optional and has not been
granted".[^task-260] The notifications event wait in the polyfill matches all
three to decide whether to re-arm after a later grant. When `notifications`
stops being active in a profile, its notifications there go and the wait is
answered with this refusal (`ExtensionManager.revokeNotificationsWhereNotPermitted`,
after every saved-decision change and grant removal; see
[Polyfill layer](./polyfill-layer.md#an-owners-notifications-go-with-its-scope)).

The grant dictionary is read, not `hasPermission(_:)`. WebKit's
`permissionState` answers `.unknown` for every name outside
`WebExtension::supportedPermissions()`, and `history` and `management` are
outside it (`notifications` is inside). `setPermissionStatus` still stores
such a name in the grant dictionary and fires `permissions.onAdded` /
`onRemoved` for it in the extension's contexts. WebKit also drops those names
from `requestedPermissions` and `optionalPermissions`, so the restore adds
`polyfillGatedDeclaredPermissions` (the gated names in either manifest list)
to `askablePermissions`.[^task-250] [^task-259] The removal rule
(`savedGrantsRevoked`) reads the same set but still skips every required
key, so the row of a required permission is never deleted.

In the web process, `permissions.request` / `contains` / `remove` reject any
name outside that set ("'history' is not a valid permission") before Detour
sees the call. `permissions.getAll` does no such check: it lists the grant
dictionary, so a restored `history` or `management` grant appears in it
(seen in the running app).[^task-250]

### permissions.request, contains and remove for history and management

The polyfill's `chrome.permissions` / `browser.permissions` wrappers (the
same ones that strip origin ports, `permissionsOriginPortJS`) take `history`
and `management` (`WebExtension.permissionsOutsideWebKit`) out of
`details.permissions`; the handler answers for them and the rest of the call
still goes to WebKit.[^task-260]

- `contains` answers from `permissionIsActive`; an undeclared name answers
  false, as in Chrome.
- `request` follows Chrome's rule (`permissionRequestPlan`): a name in
  neither manifest list is refused ("Only permissions specified in the
  manifest may be requested."); a required one is held already; a denied
  one, or a required one switched off, answers false without a prompt, as
  WebKit answers for a permission it holds denied (only the Settings switch
  turns it back on); the rest get Detour's prompt, the same alert and
  wording as WebKit's (`promptUserForPermission`), answerable through
  `permissionPromptAnswerOverride`. The answer is saved through
  `setPermissionDecision`, so it reaches every loaded context, is restored at
  load and posts `permissionDecisionsDidChangeNotification`. A second request
  while the prompt is pending is refused ("A permissions request is already
  pending."), like `uninstallSelf`'s confirmation. Unlike that
  confirmation it needs no cooldown after a refusal: the saved denial already
  stops the next request from asking.
- `remove` refuses a required name ("You cannot remove required
  permissions.") or an undeclared one, then deletes the saved grant and
  re-applies, as for WebKit's own removals: the row is deleted, not saved as
  denied, so the next request prompts again.

**WebKit requires a user gesture for its own `permissions.request`**
("Invalid call to permissions.request(). Must be called during a user
gesture.", measured: refused from a service worker, and from a page once an
await has passed; `callAsyncJavaScript` counts as a gesture). So a mixed
request (`['history', 'notifications']`) calls WebKit first, synchronously
inside the caller's gesture, and asks Detour only after WebKit grants. If
Detour's prompt is then denied, the wrapper takes back with WebKit's
`remove` exactly what the request added (each WebKit item is asked about
with `contains` before the request), so the request is granted whole or not
at all, as in Chrome. The extension does see `onAdded` then `onRemoved` for
the taken-back items. Asking Detour first was rejected: WebKit's half then
always failed for want of a gesture. From a worker a mixed request is
refused by WebKit before anyone is asked.

Detour does not require a gesture for `history` / `management`: the handler
gets no gesture signal, a worker has none, and a check in the polyfill would
be the extension's own code to skip. The prompt is the guard.

The namespaces are built at injection, so the bundle installs them when the
permission is listed in either manifest list (`__detourDeclaresPermission`),
and the handler decides each call. Chrome does it differently: a grant
re-runs the bindings of every running context, pages and workers
(`Dispatcher::UpdatePermissions` → `UpdateBindingsForExtension`), so a granted
namespace appears without a reload. A revoked one is not deleted (a TODO in
`NativeExtensionBindingsSystem::UpdateBindingsForContext`) but its calls are
refused. Detour matches the after-grant and after-revocation behaviour. Its
one deviation is that an optional namespace is already present before the
first grant. Installing it later, on `permissions.onAdded` or after an async
`permissions.getAll`, was rejected: a restarted worker's top-level
`chrome.history.onVisited.addListener` would throw before the answer
arrived.[^task-250]

### ExtensionInfo lists the active set

`management.getSelf` / `getAll` build each `ExtensionInfo` from the asking
profile's context for that extension, not from the manifest. Chromium's
`CreateExtensionInfo` (`extensions/browser/api/management/management_api.cc`)
lists `active_permissions().GetAPIsAsStrings()` and
`active_permissions().explicit_hosts()`, so runtime grants appear and
revocations go:

- `permissions`: the manifest's `permissions` then `optional_permissions`,
  each kept iff `permissionIsActive` (so a required one switched off goes
  too). MV2 origin entries in those lists are left out; Chromium lists origins
  only under `hostPermissions`.
- `hostPermissions`: the context's unexpired granted match patterns that some
  manifest host pattern covers (`askableMatchPatterns`), minus any an
  unexpired denial covers (WebKit keeps a narrower grant under a denied
  `<all_urls>`), sorted. The content-script patterns the restore grants for
  `activeTab` are left out, both by the coverage check and, when a manifest
  host pattern covers them, by name (`implicitContentScriptPatterns`), as
  Chromium's `explicit_hosts()` leaves out scriptable hosts. With no context
  in the profile, the required hosts as declared, which treats them as
  `permissionIsActive` treats required API permissions.[^task-261]

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

- A request made past the wrapper, straight to WebKit's function (the
  `_detourNative` the wrapper keeps), still gets WebKit's "'history' is not a
  valid permission".
- A mixed request whose Detour half is denied fires `permissions.onAdded`
  and `onRemoved` for the WebKit items it took back.[^task-260]
- A mixed request whose Detour half will be answered false without a
  prompt (the name is denied, or required and switched off) still shows
  WebKit's prompt first, and takes that grant back afterwards. Knowing the
  Detour answer first takes a native round trip, which would spend the user
  gesture WebKit requires.[^task-260]
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
[^task-260]: Extensions: chrome.permissions.request, contains and remove do not work for history and management
[^task-261]: Extensions: management.getSelf and getAll leave out permissions granted at runtime
