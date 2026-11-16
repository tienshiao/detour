---
type: Feature
title: chrome.management in the polyfill
description: The permission-free management methods Detour implements — getSelf, uninstallSelf (with its confirmation dialog and the cooldown after a Cancel) and getPermissionWarningsByManifest — the active permissions getSelf and getAll list, and where they differ from Chrome.
tags: [extensions, polyfill, management]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T10:06:25Z }
sources:
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift (polyfill file injection, sendMessage delegate)
  - id: task-251
    resource: backlog:TASK-251
    title: "Extensions: the history and management namespaces exist for extensions without the permission"
  - id: task-257
    resource: backlog:TASK-257
    title: "Extensions: management.uninstallSelf and management.getPermissionWarningsByManifest are missing"
  - id: task-267
    resource: backlog:TASK-267
    title: "Extensions: management.uninstallSelf with showConfirmDialog can show its app-modal alert again and again with no user action"
  - id: chromium-management-api
    resource: https://source.chromium.org/chromium/chromium/src/+/main:extensions/browser/api/management/management_api.cc
    title: "Chromium: management_api.cc (Uninstall, GetPermissionWarningsByManifest) and management_api_constants.h"
  - id: chromium-api-features
    resource: https://github.com/chromium/chromium/blob/main/extensions/common/api/_api_features.json
    title: "Chromium, extensions/common/api/_api_features.json (management.getSelf etc. have no dependency)"
  - id: task-261
    resource: backlog:TASK-261
    title: "Extensions: management.getSelf and getAll leave out permissions granted at runtime"
  - id: management-self-tests
    resource: ../../DetourTests/ExtensionManagementSelfTests.swift
    title: ExtensionManagementSelfTests
---
Detour's `chrome.management` is a polyfill: WebKit vends no `management`
namespace. `getSelf`, `uninstallSelf` and `getPermissionWarningsByManifest`
are in it with or without the `management` permission, as in
Chrome;[^task-257] Chromium's `_api_features.json` gives those three empty
dependencies.[^chromium-api-features] `getAll` and `setEnabled` (a no-op) need
the permission, and the handler refuses them without it; when the namespace
is installed is on [request gates](./polyfill-request-gates.md#namespaces-the-bundle-leaves-out).[^task-251]

# ExtensionInfo lists the active set

`management.getSelf` / `getAll` build each `ExtensionInfo` from the asking
profile's context for that extension, not from the manifest. Chromium's
`CreateExtensionInfo` (`extensions/browser/api/management/management_api.cc`)
lists `active_permissions().GetAPIsAsStrings()` and
`active_permissions().explicit_hosts()`, so runtime grants appear and
revocations go:

- `permissions`: the manifest's `permissions` then `optional_permissions`,
  each kept iff `permissionIsActive`
  ([the active-permission rule](./polyfill-request-gates.md#the-active-permission-rule);
  so a required one switched off goes
  too). MV2 origin entries in those lists are left out; Chromium lists origins
  only under `hostPermissions`.
- `hostPermissions`: the context's unexpired granted match patterns that some
  manifest host pattern covers (`askableMatchPatterns`, the
  [manifest gate](./permissions.md#the-manifest-gate)), minus any an
  unexpired denial covers (WebKit keeps a narrower grant under a denied
  `<all_urls>`), sorted. The content-script patterns the restore grants for
  `activeTab` are left out, both by the coverage check and, when a manifest
  host pattern covers them, by name (`implicitContentScriptPatterns`), as
  Chromium's `explicit_hosts()` leaves out scriptable hosts. With no context
  in the profile, the required hosts as declared, which treats them as
  `permissionIsActive` treats required API permissions.[^task-261]

# uninstallSelf

`uninstallSelf(options?, callback?)` goes to
`ExtensionManager.uninstallSelf`, which ends in `uninstall(id:)`, the path
Settings' Uninstall button takes. It acts only on the verified caller.

| Rule | Detail |
|---|---|
| Scope | Every profile. Detour installs an extension once and each profile only turns it on or off, so an uninstall cannot be per profile. Chrome's profiles install separately, so Chrome removes it from the calling profile only |
| `showConfirmDialog: true` | An `NSAlert` in the Settings style: "Uninstall "X"?", saying the extension asked, Uninstall / Cancel. Tests answer it through `uninstallSelfConfirmationAnswerOverride` |
| Cancel | Rejects with Chromium's `kUninstallCanceledError`: `Extension <id> uninstall canceled by user.` |
| Order | The reply goes first (the handler answers `true`; the polyfill resolves `undefined`), and the uninstall runs on the next main-actor turn. The uninstall unloads the caller's worker and closes its pages, so the reply may still never arrive. Chrome uninstalls first and then answers |
| Arguments | `options` absent, null or an object; `showConfirmDialog` absent, null or a boolean. Anything else is refused (`management.uninstallSelf: options must be an object`) |
| A second dialog | Refused at once, with the cancel text, while the extension's alert is up. The claim is taken before the alert's task runs, because WebKit can hand two messages over in one batch. A call without a dialog is not affected |
| After a Cancel | For 10 minutes from the Cancel (`ExtensionManager.uninstallSelfCancelCooldown`), the extension's requests for the dialog are refused at once with the cancel text and no alert. Per extension; a call without a dialog is not affected; the clock is `ExtensionManager.now`, a test seam; a time before the Cancel (clock set back) does not refuse; `uninstall(id:)` forgets the Cancel[^task-267] |
| Not carried over | Chrome refuses a dialog without a user gesture (`kGestureNeededForUninstallError`). The polyfill has no gesture signal, so Detour shows the dialog anyway, and the cooldown above stands in for the gesture check |

Without the cooldown a worker that called again after every Cancel kept the
app-modal alert up, naming itself with its manifest's name at a moment it
chose. Chrome's gesture check still lets a user retry at once; a block for the
whole session would refuse a deliberate retry until relaunch. Ten minutes caps
a looping worker at one alert per period, which leaves time to remove or turn
off the extension in Settings. `permissions.request` prompts for `history` and
`management` cannot loop this way: a denial is saved, and later requests are
refused without asking.[^task-267]

# getPermissionWarningsByManifest

`getPermissionWarningsByManifest(manifestStr)` returns the lines Detour's
install prompt shows for the manifest: its required permissions, each by its
description (an unknown one by its manifest name, where the window shows the
name made legible, TASK-339), then its `host_permissions`
(`<all_urls>` reads "All websites"). It leaves out `optional_permissions`, as
Chrome does. `ExtensionPermissionDescriptions.warnings` builds the list, and
the prompt's `formatForAlert` uses the same host wording.

This is not Chrome's list. Chrome leaves out permissions that carry no warning
(`storage`, `alarms`), merges hosts and adds content-script matches. Detour's
prompt names every permission it is asked for, so this list does too. Errors
use Chromium's `management_api_constants.h` texts:[^chromium-management-api]

| Input | Error |
|---|---|
| Malformed JSON, or JSON that is not an object | `Failed to parse manifest.` Chrome uses its JSON parser's message for malformed JSON. Detour does not reproduce that message |
| An object `ExtensionManifest` cannot decode (no `name`, `version` or `manifest_version`) | `Failed to create extension from manifest.` |
| Not a string | `management.getPermissionWarningsByManifest: manifestStr must be a string` |

# Tests

Both methods are tested from a page and a worker, in the promise and the
callback form, in
[ExtensionManagementSelfTests](../../DetourTests/ExtensionManagementSelfTests.swift).

# Related

- [Polyfill layer](./polyfill-layer.md) — the request path.
- [Request gates](./polyfill-request-gates.md) — when `chrome.management` is installed whole.
- [Permissions](./permissions.md) — the install prompt whose lines `getPermissionWarningsByManifest` returns, and the grants and denials `ExtensionInfo` reads.
- [Updates](./updates.md) — the other path that removes or replaces an installed extension.

[^task-257]: Extensions: management.uninstallSelf and management.getPermissionWarningsByManifest are missing
[^chromium-api-features]: Chromium, extensions/common/api/_api_features.json (management.getSelf etc. have no dependency)
[^task-251]: Extensions: the history and management namespaces exist for extensions without the permission
[^task-267]: Extensions: management.uninstallSelf with showConfirmDialog can show its app-modal alert again and again with no user action
[^chromium-management-api]: Chromium: management_api.cc (Uninstall, GetPermissionWarningsByManifest) and management_api_constants.h
[^task-261]: Extensions: management.getSelf and getAll leave out permissions granted at runtime
