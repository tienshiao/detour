---
type: Concept
title: Extensions in the Private profile
description: The rules for extensions in Private windows — off unless allowed per extension, pages in the profile's own non-persistent store, and the WebKit private-data gate that silently stops events without hasAccessToPrivateData.
tags: [extensions, privacy, incognito, webkit, data-store]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:48:49Z }
sources:
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (extensionController, loadExtensionContext)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (extensionEnabledByDefault and the enabled-state readers)
  - id: settings
    resource: ../../Detour/Browser/Settings/ExtensionsSettingsViewController.swift
    title: ExtensionsSettingsViewController.swift (Allow in Private switch)
  - id: store-tests
    resource: ../../DetourTests/ExtensionPrivateStoreTests.swift
    title: ExtensionPrivateStoreTests.swift
  - id: default-tests
    resource: ../../DetourTests/ExtensionPrivateDefaultTests.swift
    title: ExtensionPrivateDefaultTests.swift
  - id: plan
    resource: ../../docs/1password-integration-plan.md
    title: 1Password integration plan (TASK-73 and TASK-74 sections)
  - id: webkit-context
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/WebExtensionContext.cpp
    title: WebKit WebExtensionContext.cpp (processes(), read 2026-10-04)
  - id: task-70
    resource: backlog:TASK-70
    title: Tracking prevention deletes an extension origin's script-written storage
  - id: task-73
    resource: backlog:TASK-73
    title: The Private profile's extension worker stalls in an ephemeral data store
  - id: task-74
    resource: backlog:TASK-74
    title: Do not load extensions in the Private profile unless the user allows each one
  - id: task-102
    resource: backlog:TASK-102
    title: 1Password's Private worker throws on a.providers
  - id: notes-private
    resource: "Agent session notes, 2026-09-20 (not in the repository)"
    title: Session notes on Private-profile extensions
---

# Summary

Three things hold for extensions in the built-in Private (incognito) profile:

1. **Off unless allowed.** An extension does not load there until the user
   turns on "Allow in Private" for it. See the
   [decision](../decisions/private-extensions-opt-in.md).
2. **Its pages run in the profile's own non-persistent data store.** Nothing
   an extension writes in Private reaches the disk.
3. **Its context has `hasAccessToPrivateData`.** Without that flag WebKit
   delivers no events to a context whose pages are in an ephemeral session,
   and says nothing about it.

The third point cost a week of misdiagnosis and is the one to remember.

# Rules

| Rule | Where |
|---|---|
| A missing `profileExtension` row means **off** for `TabStore.incognitoProfileID` and on for every other profile | `AppDatabase.extensionEnabledByDefault(inProfile:)` |
| All enabled-state readers share that default | `isExtensionEnabled`, `isExtensionEnabledByProfile`, `enabledExtensionIDs(for:)` |
| Pinning an extension in Private inserts a row carrying the default, so a pin does not allow it | `toggleExtensionPinned` |
| "Allow in Private" writes only the Private profile's row and loads or unloads the context at once; a disable closes its extension pages | `ExtensionsSettingsViewController.allowInPrivateToggled`, `ExtensionManager.setEnabled(id:profileID:enabled:)` |
| The switch is disabled while the extension is globally off, but keeps the saved choice | same |
| Install, update and global re-enable write no per-profile row, so they never change the Private state | `ExtensionPrivateDefaultTests` |
| Every context loaded into an incognito profile gets `hasAccessToPrivateData = true` | `Profile.loadExtensionContext` |
| The incognito controller is `.nonPersistent()` and its `webViewConfiguration.websiteDataStore` is the profile's `dataStore` | `Profile.extensionController` |
| The Private profile's worker never receives `runtime.onInstalled` | [runtime.onInstalled](./runtime-installed-event.md) |

Consequences worth knowing:

- **Uninstall forgets the allow.** The row is removed by a foreign-key
  cascade, so a reinstall starts off. Chrome remembers; Detour does not.
- **The rule is keyed on the profile id, not on `isIncognito`.** Only one
  incognito profile exists in production.
- **Private state lives until quit, not until the window closes.** The
  profile, its store and its loaded contexts are created once and kept, like
  its browsing cookies. An allowed extension's Private context also loads at
  every launch, before any Private window exists.
- **First-run setup never happens in Private.** Storage there is empty after
  every launch and `onInstalled` is never delivered, so an extension that
  seeds `storage.local` only from that event must cope with missing state.
- **No migration was needed** when the default flipped: the database had no
  Private rows, so extensions had been on there only through "missing row =
  enabled".[^task-74]

# The private-data gate

WebKit decides which processes receive an extension event or port message in
`WebExtensionContext::processes()`. Each candidate page is skipped when

```
!hasAccessToPrivateData() && page->sessionID().isEphemeral()
```

WebKit `main` adds an exception for a page whose session is the controller's
`defaultWebsiteDataStore`; the WebKit shipped with macOS 26 had no such
exception when this was investigated.[^task-73]
`WebExtensionContext::websiteDataStore(sessionID)` fails the same test.

What a context without the flag experiences:

- Private windows and their tabs are invisible to it.
- No content scripts are injected into pages on a non-persistent store.
- If its **own background** lives in an ephemeral session, nothing reaches
  it: `runtime.sendMessage` to the worker comes back empty with no
  `lastError`, and native port messages are never delivered.

The last case is indistinguishable, from outside, from a worker that has
stalled.

# How the gate was misread as a storage problem

| Date | What happened |
|---|---|
| Before 2026-09-13 | Every profile's extension pages ran in WebKit's *default* data store, because the shipped WebKit never copies `defaultWebsiteDataStore` into the configuration extension web views are built from. See [data store and ITP](./data-store-and-itp.md) |
| 2026-09-13, signed build | Extension pages were moved to each profile's own store. In Private, 1Password's worker then never answered keep-alive ping #1; WebKit unloaded it about 40 s after start and re-registered it every 60 s[^task-70] |
| Same day | Mitigation: the explicit store was applied to persistent profiles only. Private stayed on the shared default store, which is persistent and on disk, so extension data written in Private outlived the session |
| 2026-09-20 | Default-off landed, closing that leak for anyone who does not opt in; its review added `hasAccessToPrivateData` so an allowed extension can see Private tabs at all[^task-74] |
| 2026-09-20 | The stall was traced to the gate from WebKit's source: the worker was never stalling, it was never being spoken to. With the flag in place the ephemeral store works[^task-73] |

The suspects listed before the source was read were IndexedDB in a
non-persistent session, WebKit's origin-rename migration, and the relay or
native port setup. None was involved.

# Evidence

- **Control pair** (`ExtensionPrivateStoreTests`): the same probe worker in
  the same ephemeral store, with the context loaded by hand so the only
  variable is the flag. With it the worker answers; without it the callback
  fires with no reply and no `lastError` for 20 s of retries.[^task-73] If
  this pair ever flips, the explanation above has to be reopened.
- **Idle unload inside the ephemeral store**: over a 90 s leg the worker was
  idle-unloaded and woken by the next message with its `chrome.storage.local`
  counter intact.[^task-73]
- **Signed build, 2026-09-21, real 1Password allowed in Private**: pings #1
  to #15 answered in 0–1 ms over 7 minutes, one keep-alive port for the whole
  run, no registration clear and no re-register. A byte scan (UTF-8 and
  UTF-16LE) of the app's whole WebKit directory for the Private context's
  base-URL host found no file while the session was live; the two persistent
  profiles' hosts were found in 7 and 6 files as a positive control.[^task-73]

# Open questions

- **`a.providers` rejections.** 1Password's Private worker logged eight
  `TypeError: undefined is not an object (evaluating 'a.providers')`
  rejections in its first 20 s on 2026-09-21. Whether that is specific to
  Private or to the site being browsed is not known.[^task-102]
- **Per-tab-isolation profiles.** Each tab there gets its own
  `.nonPersistent()` store while contexts are loaded without the flag, so by
  the same gate those tabs are probably invisible to extensions. Suspected
  from the source, not tested.[^notes-private]
- **Leftovers.** Extension data written to the default store by Private
  extension pages in builds before 2026-09-20 is not cleaned up.
- **Teardown.** Nothing unloads the Private contexts or discards the store
  when the last Private window closes.

# Tests

- `ExtensionPrivateDefaultTests` — the default, the three readers agreeing,
  install/update/global toggle leaving Private untouched, pinning, and live
  load/unload on allow.
- `ExtensionPrivateStoreTests` — store wiring for both profile kinds, the
  positive leg (longer with `TEST_RUNNER_DETOUR_MEASURE_PRIVATE_WORKER=1`),
  and the control pair.
- `ExtensionOriginTrackingPreventionTests.testIncognitoProfilesPagesRunInItsEphemeralStoreSoNothingIsLogged`
  — the ITP keeper has nothing to do there.

# Related

- [Private extensions opt-in](../decisions/private-extensions-opt-in.md) — the decision and its alternatives
- [Data store and ITP](./data-store-and-itp.md) — which store extension pages run in, and why it mattered
- [Incognito](../architecture/incognito.md) — the Private profile itself
- [Permissions](./permissions.md) — the other per-extension switches in Settings
- [Extension manager](./extension-manager.md) — per-profile enable and load
- [Native port keep-alive](./native-port-keep-alive.md) — the pings that exposed the gate

[^task-70]: Tracking prevention deletes an extension origin's script-written storage
[^task-73]: The Private profile's extension worker stalls in an ephemeral data store
[^task-74]: Do not load extensions in the Private profile unless the user allows each one
[^task-102]: 1Password's Private worker throws on a.providers
[^notes-private]: Session notes on Private-profile extensions
