---
type: Component
title: ExtensionManager
description: The singleton that installs, loads, enables and uninstalls extensions across profiles and is the delegate of every profile's WKWebExtensionController; with the Profile half that owns the contexts.
resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
tags: [extensions, lifecycle, profiles, webkit]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-26T02:50:00Z }
sources:
  - id: extension-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionManager.swift
    title: ExtensionManager.swift
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (extensionController, loadExtensionContext, unloadExtension, recoverFromBackgroundLoadFailure)
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (extension, profileExtension, extensionPermission, extensionInstalledEvent)
  - id: task-26
    resource: backlog:TASK-26
    title: Global setEnabled ignores the per-profile enabled table
  - id: task-27
    resource: backlog:TASK-27
    title: Load extensions into a newly created profile
  - id: task-46
    resource: backlog:TASK-46
    title: Startup reads enabled state once per profile
  - id: task-14
    resource: backlog:TASK-14
    title: Reload or close open extension pages when their context is reloaded
  - id: task-2
    resource: backlog:TASK-2
    title: "1Password: service worker restart after idle termination"
  - id: enabled-tests
    resource: ../../DetourTests/ExtensionEnabledStateTests.swift
    title: ExtensionEnabledStateTests
  - id: new-profile-tests
    resource: ../../DetourTests/NewProfileExtensionLoadTests.swift
    title: NewProfileExtensionLoadTests
  - id: startup-tests
    resource: ../../DetourTests/ExtensionStartupEnabledReadsTests.swift
    title: ExtensionStartupEnabledReadsTests
---

`ExtensionManager.shared` holds the list of installed extensions and decides,
for every [profile](../architecture/profiles-and-spaces.md), whether each one
has a loaded context. It does not own the contexts: each `Profile` owns its
`WKWebExtensionController` and the `WKWebExtensionContext`s loaded in it. The
manager is the controller delegate for all profiles.

# Role

| Owner | Holds |
|---|---|
| `ExtensionManager` | `extensions: [WebExtension]` (the model the UI reads), the per-profile enabled-id cache, popovers opened by `action.openPopup()`, and the native messaging, [keep-alive](./native-port-keep-alive.md) and [WebSocket relay](./websocket-relay.md) state keyed by (controller, extension id) |
| `Profile` | `extensionController` (lazy), `extensionContexts: [id: context]`, `polyfillHandler`, `pendingExtensionOrigins`, the `errorsDidUpdate` observers, `originInteractionKeeper` |
| `WebExtension` | Manifest, install path, `isEnabled` (the global flag), source and update bookkeeping, and `wkExtension` — one `WKWebExtension` shared by all profiles |
| Session database | `extension`, `profileExtension`, `extensionPermission`, `extensionInstalledEvent` ([session database](../architecture/session-database.md)) |

# How it works

## The controller

`Profile.extensionController` is built on first use with
`WKWebExtensionController.Configuration(identifier:)` — non-persistent for the
Private profile and for a deleted one. While building it, the profile:

- sets `webViewConfiguration.websiteDataStore` to its own data store (shipped
  WebKit does not copy `defaultWebsiteDataStore` into extension web views; see
  [data store and ITP](./data-store-and-itp.md));
- registers a `FaviconSchemeHandler` that holds the profile (see [favicons](../features/favicons.md));
- installs the [polyfill](./polyfill-layer.md) user script and its message
  handler, creating the profile's `ExtensionPolyfillHandler`;
- records itself in a weak controller → profile map. `Profile.profile(owning:)`
  is how a web view, or a delegate callback, is traced back to its profile.
  Scanning `TabStore.profiles` instead would force-build every profile's lazy
  controller just to compare.

## Launch

`initialize()` starts an async task and returns, so **contexts always load
after `TabStore.restoreSession`** and after the first window exists. The task:

1. installs updates staged at the last quit (`applyStagedUpdatesBeforeLoad`, [Updates](./updates.md));
2. reads the `extension` rows; the manifest is parsed from the installed copy
   on disk, falling back to the row's `manifestJSON`;
3. rewrites the polyfill files into each installed copy (so a new Detour build
   updates them without a reinstall);
4. creates each `WKWebExtension(resourceBaseURL:)` in parallel;
5. sets `hasLoadedInstalledExtensions`, then calls `loadExtensionsIntoProfile`
   for every profile and posts `extensionsDidChangeNotification`.

`loadExtensionsIntoProfile` reads the profile's enabled set once
(`enabledExtensionIDs(for:)`, cached) and for every extension reconciles the
context, wakes its background if a `runtime.onInstalled` is owed, then resolves
pending [extension pages](./extension-pages.md) and announces the profile's
windows and tabs to the new contexts (`notifyExistingTabs`).

Detour does not start background content at launch. WebKit starts it on
demand; Detour calls `loadBackgroundContent` only to deliver a pending
[`runtime.onInstalled`](./runtime-installed-event.md), after a background-load
recovery, and when the keep-alive restarts an unresponsive worker.

## Loading a context (`Profile.loadExtensionContext`)

In order: create the context, set `uniqueIdentifier` to the extension id, set
`hasAccessToPrivateData` in the Private profile, grant `nativeMessaging`
unconditionally, grant content-script match patterns when the manifest has
`activeTab`, restore saved [permission](./permissions.md) decisions, then
`controller.load(context)`. After a successful load it observes
`errorsDidUpdateNotification` and claims a user interaction for the origin with
tracking prevention.

The Bool it returns means "has background content", not "loaded"; check
`extensionContexts[id]` for the latter.

## Enabled state

One rule, read by every path that loads a context and every per-profile list:

> enabled in a profile = the global flag is on **and** the profile's answer is
> on. With no `profileExtension` row the profile's answer is its default: on,
> except in the Private profile ([private extensions opt-in](../decisions/private-extensions-opt-in.md)).

- The two flags are stored independently and each toggle writes only its own.
  A global disable keeps the per-profile rows, so re-enabling restores them; a
  per-profile enable while globally off is saved but loads nothing.[^task-26]
- `reconcileExtensionContext` loads or unloads one profile's context to match
  the rule. It reads the saved flags at call time rather than applying a
  delta, so it is idempotent.
- `isEnabled(extensionID:inProfile:)` is deliberately not cache-backed. The
  `enabledIDsCache` is invalidated only at the end of each toggle, so a
  cache-backed read in the middle of one would be stale.[^task-46]
- After a toggle, a newly loaded context is told about windows and tabs alone
  (re-announcing to the others surfaces duplicate events), and an unloaded
  context's pages are closed in that profile only.

## Install, update, uninstall

`install(from:publicKey:options:)` is the single path for a first install, a
reinstall, an update and an unpacked reload:

1. `ExtensionInstaller.install` copies the files and writes the row
   ([Installer and CRX](./installer-and-crx.md)).
2. If the id was already installed: unload it in every profile, remember each
   old origin and register it as pending, and mark the `onInstalled` ledger as
   reinstalled.
3. Record declared permissions without overwriting saved decisions.
4. Write the polyfill files, then asynchronously create the `WKWebExtension`,
   reconcile every profile, move open pages from the old origin to the new one
   (or close them where no replacement context loaded), and announce tabs.

`extensionsDidChangeNotification` is posted twice: synchronously, before any
context exists, and again once contexts are loaded. UI that needs a loaded
context refreshes on the second.

`uninstall(id:)` unloads with `removeData: true` (WebKit's extension data
record), closes the extension's pages, deletes the row and the files, and
discards any staged update.

## A profile created mid-session

`TabStore` tells observers when it creates a profile, including the Private
and Default profiles created on demand. `ExtensionTabObserver` forwards that to
`profileWasAdded`, which runs `loadExtensionsIntoProfile` once the launch load
has reached its per-profile loop.[^task-27]

## Background-load recovery

`Profile.recoverFromBackgroundLoadFailure` unloads and reloads a context when
it reports `backgroundContentFailedToLoad`. The reason: after WebKit unloads an
idle worker, the worker's registration can survive in the network process bound
to the old content process; every later wake then finds it "directly reusable",
never starts a worker, and fails 30 s later, forever. The registration is keyed
by the context's base URL, and a new context object gets a new one, so a reload
sidesteps it.[^task-2] It is limited to 3 reloads per 10 minutes per
extension, and the reload moves open pages to the new origin before announcing
tabs.

## Delegate methods

| Callback | What Detour does |
|---|---|
| `openWindowsFor`, `focusedWindowFor` | Browser windows whose active space belongs to the controller's profile, and that profile's [Quick Detour](../features/quick-detour.md) windows (`extensionListedWindows()`); the key window only if it is one of them |
| `openNewTabUsing`, `openNewWindowUsing` | Create through `TabStore`; an extension URL gets `addExtensionTab` with the context's configuration; `detour://` and `javascript:` URLs are refused; a window opened for a Private context is always Private, a normal context's Private window is refused unless the extension is allowed in Private, and a normal window, like a new tab (`newTabSpace(for:)`), goes to the caller's profile's most recently used space ([opening a window](./tab-and-window-bridge.md#opening-a-window), [opening a tab](./tab-and-window-bridge.md#opening-a-tab)) |
| `openOptionsPageFor` | Reuses an open options tab ([popup and options UI](./popup-and-options-ui.md)) |
| `presentActionPopup` | `browser.action.openPopup()` only; a user click presents the popup directly |
| `promptForPermissions`, `…ToAccess`, `…MatchPatterns` | An alert, and the answer saved ([Permissions](./permissions.md)) |
| `didUpdate action` | Posts `extensionActionDidChangeNotification` |
| `sendMessage toApplicationWithIdentifier`, `connectUsing` | Polyfill bridge, relay, keep-alive port, or a real [native messaging](./native-messaging.md) host |

# Invariants

- A profile holds a context for an extension only while
  `isEnabled(extensionID:inProfile:)` is true; an enabled extension lacks one
  only when its load failed.
- `ExtensionManager` never loads a context except through
  `reconcileExtensionContext` or the recovery reload.
- Every unload goes through `Profile.unloadExtension`, which also closes the
  offscreen document, forgets the console rate limit, drops the keep-alive
  port and relays, and removes the error observer.
- New contexts are announced **after** pending pages are resolved, so each
  rehosted tab is announced once, on wake.

# Gotchas

- `context(for:)` answers for the *last-active space's* profile and falls back
  to any profile. Code that acts for a specific profile must use
  `profile.extensionContext(for:)`. The polyfill handler got this wrong once:
  an offscreen document was built in another profile's controller.
- `extensionIDFromContext` returns nil for a context its profile no longer
  lists (unloaded, or a message in flight across a reload). Callers reject
  rather than trust anything the message claims.
- The unit tests run inside the app, so `initialize()` has run there too.
  `loadsExtensionsIntoAddedProfiles` is switched off in `TestEnvironmentSetup`
  so the many tests that create profiles do not load every installed
  extension; tests of the new-profile path switch it back on.
- Disable and uninstall close extension page tabs with `undoable: false` and
  write no closed-tab record: the origin died with the context, so a restored
  tab could never load.[^task-14]

# Tests

- [ExtensionEnabledStateTests](../../DetourTests/ExtensionEnabledStateTests.swift) — toggle combinations against real profiles, per-profile page closing.
- [NewProfileExtensionLoadTests](../../DetourTests/NewProfileExtensionLoadTests.swift) — a new profile gets its extensions and one `install` event.
- [ExtensionStartupEnabledReadsTests](../../DetourTests/ExtensionStartupEnabledReadsTests.swift) — one enabled-state read per profile at startup.
- `ExtensionPageRehostTests` — recovery, disable and uninstall against real contexts.

# Related

- [Web Extension support](./overview.md) — the map of the area.
- [Tab and window bridge](./tab-and-window-bridge.md) — what `notifyExistingTabs` announces and why.
- [Extension pages](./extension-pages.md) — what happens to open pages when a context goes away.
- [Profile data removal](../architecture/profile-data-removal.md) — deleting a profile's extension controller storage.
- [Private profile extensions](./private-profile-extensions.md) — the Private default and WebKit's private-data gate.

[^task-26]: Global setEnabled ignores the per-profile enabled table
[^task-27]: Load extensions into a newly created profile
[^task-46]: Startup reads enabled state once per profile
[^task-14]: Reload or close open extension pages when their context is reloaded
[^task-2]: 1Password: service worker restart after idle termination
