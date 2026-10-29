---
type: Component
title: Extension storage
description: Where an extension's data lives in Detour — WebKit's chrome.storage areas keyed by profile and extension id, the polyfilled storage.managed, and the origin-keyed storage (IndexedDB, localStorage) that WebKit moves to each context load's new base URL, so it survives relaunches.
tags: [extensions, storage, webkit, persistence]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T02:08:40Z }
sources:
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (extensionController, loadExtensionContext, unloadExtension)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (storageManagedJS)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (extensionStorage table and accessors)
  - id: task-80
    resource: backlog:TASK-80
    title: Polyfill chrome.storage.managed
  - id: task-99
    resource: backlog:TASK-99
    title: Give each context a stable base URL so extension storage survives a relaunch
  - id: webkit-context
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/Extensions/Cocoa/WebExtensionContextCocoa.mm
    title: WebKit WebExtensionContextCocoa.mm (LastSeenBaseURL, moveLocalStorageIfNeeded, removeStaleExtensionWebsiteData)
  - id: itp-tests
    resource: ../../DetourTests/ExtensionOriginTrackingPreventionTests.swift
    title: ExtensionOriginTrackingPreventionTests (testIndexedDBAndLocalStorageSurviveAnUnloadAndLoad)
  - id: task-32
    resource: backlog:TASK-32
    title: Deleting a profile must remove its website data store and extension controller data on disk
  - id: task-20
    resource: backlog:TASK-20
    title: Un-skip the WKExtensionIntegrationTests runtime messaging tests
  - id: task-22
    resource: backlog:TASK-22
    title: Verify runtime.onInstalled is delivered in the app, or emit it ourselves
  - id: integration-tests
    resource: ../../DetourTests/ExtensionPolyfillIntegrationTests.swift
    title: ExtensionPolyfillIntegrationTests
---

An extension has two kinds of storage and they behave differently in Detour.
`chrome.storage` is WebKit's and is keyed by the extension's id, so it
persists. Everything keyed by *origin* — IndexedDB, `localStorage`, Cache
Storage, the service worker registration — is keyed by a base URL that changes
on every context load. WebKit moves IndexedDB and `localStorage` to the new
origin at each load, so those persist too; Cache Storage and the service
worker registration do not.

# Role

| Storage | Implemented by | Keyed by | Survives a relaunch |
|---|---|---|---|
| `chrome.storage.local`, `sync` | WebKit | Controller (profile) and the context's `uniqueIdentifier` | Yes: neither key changes |
| `chrome.storage.session` | WebKit, in memory | — | No, by design |
| `chrome.storage.managed` | Detour's polyfill | — | Always empty |
| IndexedDB, `localStorage` | WebKit, in the profile's website data store | The context's `webkit-extension://<UUID>` origin, renamed to the new one at every load | Yes |
| Cache Storage, service worker registration | WebKit, in the profile's website data store | The context's origin | **No**: left on the old origin |

Storage is per [profile](../architecture/profiles-and-spaces.md): each
profile has its own controller and its own data store, so the same extension
in two profiles shares nothing. That is also why an options page has to be
opened in a named profile ([popup and options UI](./popup-and-options-ui.md)).

# How it works

## `chrome.storage`

`Profile.loadExtensionContext` sets `context.uniqueIdentifier = ext.id`, and
the controller is created with
`WKWebExtensionController.Configuration(identifier:)` from the profile's
storage identifier. WebKit keeps the data at:

```
~/Library/WebKit/<bundle id>/WebExtensions/<CONTROLLER UUID>/<uniqueIdentifier>/
    LocalStorage.db
    State.plist
```

measured while building profile deletion.[^task-32] `State.plist` also holds
the `LastSeenVersion` WebKit uses for its own install-reason logic.[^task-22]
A value written by one worker instance is there for the next.[^task-20]

The Private profile's controller is `.nonPersistent()`, so nothing is written
to disk there ([private profile extensions](./private-profile-extensions.md)).

The polyfill writes one key of its own into every extension's
`storage.local`: `_polyfillDiag`, the bundle's diagnostics
([Polyfill layer](./polyfill-layer.md)).

## Removal

- **Uninstall** — `Profile.unloadExtension(id:removeData: true)` fetches the
  context's data record and calls `removeData(ofTypes:from:)` for every
  extension data type.
- **Profile deletion** — handled separately, because WebKit's website-data
  removal does not touch the `WebExtensions/` directory
  ([profile data removal](../architecture/profile-data-removal.md)).

## `storage.managed`

WebKit's `chrome.storage` has no `managed` area. 1Password 8.12.37 added a
managed-policy monitor that calls `browser.storage.managed.onChanged.addListener`
and `storage.managed.get` synchronously inside its background initialisation,
before connecting to the desktop app. With no `managed`, the `TypeError`
rejected the whole initialisation: no native host was ever started and the
popup showed a spinner forever.[^task-80]

`storageManagedJS` adds the area Chrome reports on an unmanaged machine:

| Member | Answer |
|---|---|
| `get(keys)` | `{}`, or the caller's defaults object |
| `getBytesInUse` | `0` |
| `getKeys` | `[]` |
| `set`, `remove`, `clear` | Reject with `This is a read-only store.` (`lastError` in callback form) |
| `onChanged` | Never fires |

It is installed only when `chrome.storage` exists and lacks `managed`.
`chrome.storage` itself is never created: without the `storage` permission its
absence is the correct answer. The patched wrapper is rooted with
`__detourHoldWrapper` and re-read to check the patch is visible
([Chrome runtime patching](./chrome-runtime-patching.md));
`testStorageManagedInRealExtensionContextSurvivesGarbageCollection` covers
the real context, and that `storage.local` stays native.

# Gotchas

## Origin-keyed storage moves to each new origin

`loadExtensionContext` never sets `context.baseURL`, so WebKit mints a fresh
`webkit-extension://<UUID>/` for every context load: each launch, each
enable, each update, each background recovery. WebKit compensates in
`WebExtensionContext::load`: it keeps the previous load's origin as
`LastSeenBaseURL` in the context's `State.plist`, writes the new one, and
before starting the background calls `moveLocalStorageIfNeeded`, which renames
the old origin's IndexedDB and `localStorage` to the new one
(`-[WKWebsiteDataStore _renameOrigin:to:forDataOfTypes:]` on the context's
web view data store).[^webkit-context] Cache Storage and the service worker
registration are not moved.

`testIndexedDBAndLocalStorageSurviveAnUnloadAndLoad` writes both in one load
and reads them back in the next, under a different origin.[^itp-tests] In
production (2026-10-28) each 1Password profile store held exactly one
extension origin, created the minute the app last launched and carrying
24–26 MB of IndexedDB, with `LastSeenBaseURL` naming it; 1Password keeps
nothing in Cache Storage.[^task-99]

The rename happens on the store the context's web views use. Before TASK-90
the pages were on the default store, and on 2026-09-20 each profile store was
found holding the previous launch's origin next to the current one, which is
why TASK-99 was filed believing the data was lost at every launch. Those
orphans are gone: WebKit's `removeStaleExtensionWebsiteData` removes every
`webkit-extension://` origin no loaded context owns, once per controller (the
`StaleExtensionOriginsCleared` file in the controller's storage directory
marks it done).[^webkit-context]

A stable base URL (setting `context.baseURL` per profile and extension) was
proposed in TASK-99 and closed as unnecessary on 2026-10-28 (the user's
decision): the rename already keeps the data, and a stable origin would
have to be threaded through the code that relies on a new one: page
retargeting, background-load recovery escaping a stale worker registration,
the offscreen teardown, and sender verification by base URL.[^task-99]

The fresh origin is still what
[tracking prevention](./data-store-and-itp.md) treats as a site with no user
interaction, and why open [extension pages](./extension-pages.md) need
rehoming.

## The `extensionStorage` table is dead

The session database still has an `extensionStorage` table with
`storageGet` / `storageSet` accessors on `AppDatabase`, apparently left from
the extension system that predates `WKWebExtension`. Nothing in the app calls
them; only database tests do.

# Tests

- `ExtensionPolyfillTests` — the `managed` stub, `lastError`, native left alone, absent without `chrome.storage`.
- [ExtensionPolyfillIntegrationTests](../../DetourTests/ExtensionPolyfillIntegrationTests.swift) — the real context.
- `ProfileDataRemovalTests` — extension controller storage on profile deletion.
- `ExtensionOriginTrackingPreventionTests.testIndexedDBAndLocalStorageSurviveAnUnloadAndLoad` — IndexedDB and `localStorage` carried to the next load's origin.

# Related

- [Data store and ITP](./data-store-and-itp.md) — which website data store extension pages use, and the purge.
- [Extension pages](./extension-pages.md) — the other consequence of a per-load origin.
- [runtime.onInstalled](./runtime-installed-event.md) — why first-run setup must not be repeated when storage is lost.
- [1Password integration](./1password-integration.md) — the `storage.managed` failure in context.

[^task-80]: Polyfill chrome.storage.managed
[^task-99]: Give each context a stable base URL so extension storage survives a relaunch
[^webkit-context]: WebKit WebExtensionContextCocoa.mm (LastSeenBaseURL, moveLocalStorageIfNeeded, removeStaleExtensionWebsiteData)
[^itp-tests]: ExtensionOriginTrackingPreventionTests (testIndexedDBAndLocalStorageSurviveAnUnloadAndLoad)
[^task-32]: Deleting a profile must remove its website data store and extension controller data on disk
[^task-20]: Un-skip the WKExtensionIntegrationTests runtime messaging tests
[^task-22]: Verify runtime.onInstalled is delivered in the app, or emit it ourselves
