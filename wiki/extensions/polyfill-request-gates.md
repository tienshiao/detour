---
type: Concept
title: Polyfill request gates
description: The checks the polyfill bundle and its native handler apply to a request after the sender is verified — which namespaces exist without a permission, which requests the handler refuses and the active-permission rule behind the refusal, and which profile or space a request acts in.
tags: [extensions, polyfill, permissions, security]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:06:25Z }
sources:
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: task-3
    resource: backlog:TASK-3
    title: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
  - id: task-239
    resource: backlog:TASK-239
    title: "Extensions: the notifications API is available without the notifications permission"
  - id: task-250
    resource: backlog:TASK-250
    title: "Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions"
  - id: task-251
    resource: backlog:TASK-251
    title: "Extensions: the history and management namespaces exist for extensions without the permission"
  - id: task-257
    resource: backlog:TASK-257
    title: "Extensions: management.uninstallSelf and management.getPermissionWarningsByManifest are missing"
  - id: web-extension
    resource: ../../Detour/Extensions/Model/WebExtension.swift
    title: WebExtension.swift (polyfillGatedPermissions, polyfillGatedDeclaredPermissions)
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (revokeNotificationsWhereNotPermitted)
  - id: task-259
    resource: backlog:TASK-259
    title: "Extensions: a required notifications, history or management permission switched off in Settings still works"
  - id: task-260
    resource: backlog:TASK-260
    title: "Extensions: chrome.permissions.request, contains and remove do not work for history and management"
  - id: task-277
    resource: backlog:TASK-277
    title: "Tests: cover native host quit refusal and the SIGTERM path, keep the host sweep to the test's own hosts, and route the injected clock through the permission gates"
  - id: history-scope-tests
    resource: ../../DetourTests/ExtensionHistoryScopeTests.swift
    title: ExtensionHistoryScopeTests
  - id: notification-ordering-tests
    resource: ../../DetourTests/ExtensionNotificationOrderingTests.swift
    title: ExtensionNotificationOrderingTests
---

Once the [polyfill layer](./polyfill-layer.md#sender-verification) knows
which extension, in which profile, sent a request, it still has to decide
whether the extension may make it and where it acts. WebKit does not
permission-check APIs it does not implement, so the bundle and the handler
do. Both sides gate: the bundle gate is what the extension sees, the
handler's is what holds against a caller that goes straight to
`__detourPolyfillRequest`.

# Namespaces the bundle leaves out

Gap-filling namespaces that Chrome leaves undefined without a permission are
installed only when the manifest declares it, so feature detection stays
truthful.[^task-3]

| Namespace | Installed when |
|---|---|
| `privacy`, `webRequest` | the manifest's `permissions` lists it (`__detourManifestPermissions()`) |
| `notifications`, `history` | `permissions` or `optional_permissions` lists it (`__detourDeclaresPermission`) |
| `management` | whole when either list has `management`; otherwise holding only the permission-free `getSelf`, `uninstallSelf` and `getPermissionWarningsByManifest` |

- Before TASK-239 `notifications` was installed for every extension and the
  handler served it unchecked. Without the permission WebKit vends no
  `notifications` namespace of its own either (measured from a page and a
  worker in `ExtensionNotificationOrderingTests`).[^task-239]
- `history` and `management` were installed whole for every extension until
  TASK-251, gated only in the handler. Chromium's
  `extensions/common/api/_api_features.json` gives `management` the
  dependency `permission:management` but gives `getSelf`, `uninstallSelf` and
  `getPermissionWarningsByManifest` empty dependencies, and since TASK-257
  Detour implements all three ([chrome.management](./polyfill-management.md)).
  WebKit vends neither namespace (measured from a page and a worker in
  `ExtensionHistoryScopeTests`: with neither permission `chrome.history` is
  undefined and `chrome.management` has only Detour's permission-free
  methods).[^task-251] In a plain `WKWebView` (the `ExtensionPolyfillTests`
  harness) `browser` is a separate object from `chrome`, so the alias can only
  be checked in a real context.
- Since TASK-250 the three namespaces an extension may be granted at runtime
  (`notifications`, `history`, the full `management`) also install for a
  permission listed only under `optional_permissions`, for the reason
  below.[^task-250]

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

# Requests the handler refuses

`history.search`, `management.getAll`, `management.setEnabled` and every
`notifications.*` request are refused unless the permission is active for the
extension in the handler's profile (`permissionRefusal`, built on
`ExtensionPolyfillHandler.permissionIsActive`), checked before anything else
the request is answered with.[^task-239] Active means declared and not denied
in the profile's context, and, for a permission listed only under
`optional_permissions`, granted there: the handler refuses each call until the
context holds the grant, and again after a revocation.[^task-250] The rule,
its three refusal texts and the WebKit behaviour behind it follow. Before
TASK-250 the check read the manifest alone, so a grant made at runtime
through `optional_permissions` was ignored.

`runtime.getURL('/_favicon/…')` is not a handler request at all: the polyfill
rewrites it to `detour-favicon://`, and the scheme handler gates it on
`favicon` and on the profile; see [favicons](./polyfill-favicons.md).

## The active-permission rule

`notifications`, `history` and `management` are implemented by Detour's
polyfill, which gates them itself (`WebExtension.polyfillGatedPermissions`),
reading the decisions [Permissions](./permissions.md) saves and restores.
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
  `notifications`, Detour's for the other two:
  [chrome.permissions for history and management](./polyfill-permissions.md)) and the restore at
  load put it there; `permissions.remove` and a switch turned off take it
  out, and the next call is refused.[^task-250]

A refused call says which state it is in (`permissionRefusal`): "<name>
permission not declared" (in neither list), "<name> permission denied by the
user" (an unexpired denial: the switch off, a prompt answered Deny, or that
saved denial restored), or "<name> permission is optional and has not been
granted".[^task-260] "Unexpired" is measured against the handler's `now`
clock (a test seam, `Date.init` in the app) at every gate: `permissionRefusal`,
`permissions.contains`, the `permissions.request` plan and `management`'s
`permissions` / `hostPermissions`. A test that moves that clock past a grant
or denial still held by WebKit, which reads the wall clock, sees it
expired.[^task-277] The notifications event wait in the polyfill matches all
three to decide whether to re-arm after a later grant. When `notifications`
stops being active in a profile, its notifications there go and the wait is
answered with this refusal (`ExtensionManager.revokeNotificationsWhereNotPermitted`,
after every saved-decision change and grant removal; see
[Notification ownership](./polyfill-notification-scope.md#an-owners-notifications-go-with-its-scope)).

## Why the grant dictionary is read

The grant dictionary is read, not `hasPermission(_:)`. WebKit's
`permissionState` answers `.unknown` for every name outside
`WebExtension::supportedPermissions()`, and `history` and `management` are
outside it (`notifications` is inside). `setPermissionStatus` still stores
such a name in the grant dictionary and fires `permissions.onAdded` /
`onRemoved` for it in the extension's contexts. WebKit also drops those names
from `requestedPermissions` and `optionalPermissions`, so the
[restore](./permissions.md#restore-order) adds
`polyfillGatedDeclaredPermissions` (the gated names in either manifest list)
to `askablePermissions` (`WebExtension.restorablePermissions` is the union).[^task-250] [^task-259] The
[removal rule](./permissions.md#the-extensions-own-permissionsremove)
(`savedGrantsRevoked`) reads the same set but still skips every required
key, so the row of a required permission is never deleted.

In the web process, `permissions.request` / `contains` / `remove` reject any
name outside that set ("'history' is not a valid permission") before Detour
sees the call; the polyfill's wrappers answer for `history` and
`management` instead ([chrome.permissions for history and management](./polyfill-permissions.md)).
`permissions.getAll` does no such check: it lists the grant
dictionary, so a restored `history` or `management` grant appears in it
(seen in the running app).[^task-250]

# The profile and space a request acts in

- `history.search` answers from the handler's own profile only; see
  [chrome.history](./polyfill-history.md).
- `notifications.*` belongs to an owner, the handler's profile plus the
  verified extension; see [notification ownership](./polyfill-notification-scope.md).
- `offscreen.*` uses only the handler's own profile's context.
- `sessions.restore` and `search.query` act in `targetSpace()`, which is
  `tabs.create`'s rule (`ExtensionManager.newTabSpace(for:)`): a normal
  profile's most recently used space, never another profile's (TASK-226;
  before, the global last active space when it was this profile's, else the
  profile's first). See [opening a tab](./opening-tabs-and-windows.md#opening-a-tab).
  `sessions.restore` answers with `tab.id.hashValue`, not the id WebKit uses
  for that tab.

# Related

- [Polyfill layer](./polyfill-layer.md) — the request path these gates sit on.
- [Permissions](./permissions.md) — the saved decisions, prompts, restore and Settings switches the active-permission rule reads.
- [chrome.permissions for history and management](./polyfill-permissions.md) — how `contains`, `request` and `remove` read and change the rule's state.
- [Opening tabs and windows](./opening-tabs-and-windows.md) — the space rule `sessions.restore` and `search.query` share with `tabs.create`.

[^task-3]: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
[^task-239]: Extensions: the notifications API is available without the notifications permission
[^task-251]: Extensions: the history and management namespaces exist for extensions without the permission
[^task-250]: Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions
[^task-259]: Extensions: a required notifications, history or management permission switched off in Settings still works
[^task-260]: Extensions: chrome.permissions.request, contains and remove do not work for history and management
[^task-277]: Tests: cover native host quit refusal and the SIGTERM path, keep the host sweep to the test's own hosts, and route the injected clock through the permission gates
