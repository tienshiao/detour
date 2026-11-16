---
type: Concept
title: Polyfill request gates
description: The checks the polyfill bundle and its native handler apply to a request after the sender is verified — which namespaces exist without a permission, which requests the handler refuses, and which profile or space a request acts in.
tags: [extensions, polyfill, permissions, security]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
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
  - id: history-scope-tests
    resource: ../../DetourTests/ExtensionHistoryScopeTests.swift
    title: ExtensionHistoryScopeTests
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
  permission listed only under `optional_permissions`. Chrome adds a granted
  namespace to running contexts; installing ours on a later event would leave
  a restarted worker's top-level code without it.[^task-250]

# Requests the handler refuses

`history.search`, `management.getAll`, `management.setEnabled` and every
`notifications.*` request are refused unless the permission is active for the
extension in the handler's profile (`permissionRefusal`, built on
`ExtensionPolyfillHandler.permissionIsActive`), checked before anything else
the request is answered with.[^task-239] Active means declared and not denied
in the profile's context, and, for a permission listed only under
`optional_permissions`, granted there: the handler refuses each call until the
context holds the grant, and again after a revocation.[^task-250] The rule,
its three refusal texts and the WebKit behaviour behind it are in
[Permissions](./permissions.md#permissions-the-polyfill-gates). Before
TASK-250 the check read the manifest alone, so a grant made at runtime
through `optional_permissions` was ignored.

`runtime.getURL('/_favicon/…')` is not a handler request at all: the polyfill
rewrites it to `detour-favicon://`, and the scheme handler gates it on
`favicon` and on the profile; see [favicons](./polyfill-favicons.md).

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
  profile's first). See [opening a tab](./tab-and-window-bridge.md#opening-a-tab).
  `sessions.restore` answers with `tab.id.hashValue`, not the id WebKit uses
  for that tab.

# Related

- [Polyfill layer](./polyfill-layer.md) — the request path these gates sit on.
- [Permissions](./permissions.md) — the active-permission rule, prompts and Settings switches.
- [Tab and window bridge](./tab-and-window-bridge.md) — the space rule `sessions.restore` and `search.query` share with `tabs.create`.

[^task-3]: Polyfill stubs for privacy, onAuthRequired, management.setEnabled, getUserSettings
[^task-239]: Extensions: the notifications API is available without the notifications permission
[^task-251]: Extensions: the history and management namespaces exist for extensions without the permission
[^task-250]: Extensions: notifications, history and management ignore permissions granted at runtime through optional_permissions
