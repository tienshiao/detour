---
type: Overview
title: Web Extension support
description: How Detour runs Chrome MV3 extensions — WebKit's native WKWebExtension runtime, Detour's polyfill layer for the APIs WebKit lacks, and the host integration around them — with a file map and the known gaps.
tags: [extensions, webkit, polyfill, overview]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T08:18:18Z }
sources:
  - id: docs-extensions
    resource: ../../docs/extensions.md
    title: docs/extensions.md (long-form description)
  - id: extensions-dir
    resource: ../../Detour/Extensions
    title: Detour/Extensions
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (extension controller, context load and unload)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift
  - id: notes-spike
    resource: "Agent session notes, 2026-07 (not in the repository)"
    title: WKWebExtension spike and migration — file map and known API gaps
  - id: task-99
    resource: backlog:TASK-99
    title: Give each context a stable base URL so extension storage survives a relaunch
  - id: task-81
    resource: backlog:TASK-81
    title: windows.getCurrent from a background worker reports "Window not found" with no key window
  - id: task-132-21
    resource: backlog:TASK-132.21
    title: A window with nothing selected reports no tabs to extensions
  - id: task-132-22
    resource: backlog:TASK-132.22
    title: Tell WebKit when a browser window opens or closes
---

Detour runs Chrome Manifest V3 extensions on WebKit's own `WKWebExtension`
runtime and fills what WebKit lacks with a JavaScript polyfill backed by native
handlers. Most of what is hard here is not Detour's code but WebKit's
behaviour: what its API wrappers allow, when it unloads a worker, what it
tells the host and what it does not. This page is the map; each part has its
own page.

# Summary

Three layers:

1. **WebKit's runtime** — `WKWebExtension` (the parsed extension),
   `WKWebExtensionContext` (one loaded instance of it) and
   `WKWebExtensionController` (the per-profile container). It injects content
   scripts, runs the background worker or page, and implements most of
   `chrome.runtime`, `tabs`, `windows`, `storage`, `scripting`, `action`,
   `alarms`, `commands`, `contextMenus`, `permissions`, `i18n` and
   `webNavigation`.
2. **Detour's polyfill layer** — one JavaScript bundle evaluated in every
   extension context, plus a native handler per [profile](../architecture/profiles-and-spaces.md).
   It adds missing namespaces, patches a few native members, and replaces
   WebKit's `runtime.onInstalled` with one that follows Chrome's rules.
3. **Host integration** — the controller delegate, the tab and window
   conformances, install and update, permissions, and the UI.

The deployment target is macOS 15.4 (`project.yml`), which
[docs/extensions.md](../../docs/extensions.md) gives as what `WKWebExtension`
requires. Only MV3 manifests install
(`ExtensionInstaller.InstallerError.notMV3`); an MV3 manifest may still use a
background *page* (`background.scripts` / `background.page`), which WebKit runs
and the polyfill handles.

The decision to build on WebKit's runtime, and what it replaced, is in
[native WebExtension with polyfills](../decisions/native-webextension-with-polyfills.md).

# Parts

| Part | Code | Page |
|---|---|---|
| Lifecycle singleton and controller delegate | `Runtime/ExtensionManager.swift`, `ExtensionManager+Updates.swift`, `ExtensionManager+OptionsPage.swift`; the per-profile half is in [Profile.swift](../../Detour/Browser/Profile.swift) | [ExtensionManager](./extension-manager.md) |
| Polyfill JS and its native handler | `Runtime/ExtensionAPIPolyfill.swift`, `Runtime/ExtensionPolyfillHandler.swift` | [Polyfill layer](./polyfill-layer.md), [Chrome runtime patching](./chrome-runtime-patching.md) |
| Permissions | `Storage/Models/ExtensionPermissionRecord.swift`, `Model/WebExtension.swift`, `Profile.applySavedHostAccessDecisions` | [Permissions](./permissions.md) |
| Install | `Installer/ExtensionInstaller.swift`, `CRXUnpacker.swift`, `CRX3Verifier.swift` | [Installer and CRX](./installer-and-crx.md) |
| Updates | `Updates/` (`ExtensionUpdater`, `ExtensionUpdatePolicy`, `ExtensionUpdateDeferral`, `StagedExtensionUpdate`, `UpdateManifest`) | [Updates](./updates.md) |
| Storage | WebKit's `chrome.storage`; `storageManagedJS` | [Storage](./storage.md) |
| Tabs and windows as WebKit sees them | `Runtime/WKExtensionTabConformance.swift`, `WKExtensionWindowConformance.swift`, `ExtensionTabLifecycle.swift`, `ExtensionTabObserver.swift`, `ExtensionActiveTab.swift` | [Tab and window bridge](./tab-and-window-bridge.md) |
| `runtime.onInstalled` | `Runtime/RuntimeInstalledEvent.swift`, `Storage/Models/ExtensionInstalledEventRecord.swift`, `ExtensionPageHostRegistry.swift` | [runtime.onInstalled](./runtime-installed-event.md) |
| Offscreen documents | `Runtime/OffscreenDocumentHost.swift` | [Offscreen documents](./offscreen-documents.md) |
| Popup, Extensions menu, options page | `UI/ExtensionPopoverController.swift`, `ExtensionMenuPopupDecision.swift`, `ExtensionOptionsPageEntry.swift` | [Popup and options UI](./popup-and-options-ui.md) |
| Extension pages open in tabs | `Runtime/ExtensionPageURL.swift`, `Profile.retargetExtensionPages` | [Extension pages](./extension-pages.md) |
| Frames and content scripts | `webNavigationJS`, `contentPolyfillJS` | [Frames and content scripts](./frames-and-content-scripts.md) |
| Native messaging hosts | `Runtime/NativeMessagingHost.swift`, `NativeConnectLogLimiter.swift` | [Native messaging](./native-messaging.md) |
| Keeping a worker alive | `Runtime/NativeHostKeepAlive.swift` | [Native port keep-alive](./native-port-keep-alive.md), [service worker unload rules](../platform/service-worker-unload-rules.md) |
| WebSocket in workers | `Runtime/WebSocketRelay.swift` | [WebSocket relay](./websocket-relay.md) |
| Worker console in the unified log | `consoleJS`, `Runtime/ConsoleBridgeLimiter.swift` | [Console bridge](./console-bridge.md) |
| Private profile | `hasAccessToPrivateData`, `profileExtension` default | [Private profile extensions](./private-profile-extensions.md) |
| Tracking prevention vs extension origins | `Runtime/ExtensionOriginInteractionKeeper.swift` | [Data store and ITP](./data-store-and-itp.md) |
| Small native backends | `Runtime/IdleMonitor.swift`, `ExtensionNotificationManager.swift`, `FaviconSchemeHandler.swift` | this page |
| Unused | `Runtime/ModuleBundler.swift` (`ExtensionManager.useModuleBundler` is `false`) | — |

Paths are relative to [Detour/Extensions](../../Detour/Extensions).

# What WebKit provides and what Detour adds

| API | Who | Notes |
|---|---|---|
| Content script injection, service worker / background page lifecycle | WebKit | |
| `runtime` messaging, ports, `sendNativeMessage`, `connectNative` | WebKit | Detour answers native messaging through the delegate |
| `tabs`, `windows`, `scripting`, `action`, `alarms`, `commands`, `contextMenus`, `i18n` | WebKit | Driven by Detour's [tab and window bridge](./tab-and-window-bridge.md) |
| `storage.local` / `sync` / `session` | WebKit | [Storage](./storage.md) |
| `storage.managed` | Polyfill | Always empty, read-only |
| `permissions` | WebKit, patched | `contains` / `request` / `remove` drop a port from origin patterns ([Permissions](./permissions.md)) |
| `webNavigation` | WebKit, patched | Missing events filled in; `getAllFrames` / `getFrame` are native and deliberately not polyfilled |
| `runtime.onInstalled` | Detour | WebKit's is suppressed ([runtime.onInstalled](./runtime-installed-event.md)) |
| `runtime.requestUpdateCheck`, `runtime.onUpdateAvailable` | Polyfill | [Updates](./updates.md) |
| `runtime.getURL('/_favicon/…')` | Polyfill | Rewritten to `detour-favicon://`, served by `FaviconSchemeHandler` to extensions with the `favicon` permission |
| `offscreen` | Polyfill | Shipped WebKit has none ([Offscreen documents](./offscreen-documents.md)) |
| `idle` | Polyfill | `IdleMonitor` |
| `notifications` | Polyfill | `ExtensionNotificationManager` (`UNUserNotificationCenter`) |
| `history` | Polyfill | Only `search` is real, and it reads the calling profile's history only ([polyfill layer](./polyfill-layer.md)); `getVisits` answers `[]`, the writes are no-ops |
| `management` | Polyfill | `getSelf`, `getAll`; `setEnabled` is a permission-gated no-op |
| `fontSettings.getFontList` | Polyfill | System font families only |
| `sessions` | Polyfill | `restore` reopens a closed tab; `getRecentlyClosed` and `getDevices` answer `[]` |
| `search.query` | Polyfill | Opens the profile's search engine in a new tab |
| `privacy` | Polyfill stub | Only with the `privacy` permission |
| `webRequest` | Polyfill stub | Only with the `webRequest` permission; **no listener ever fires** |
| `action.getUserSettings` | Polyfill | `{ isOnToolbar: true }` |
| `WebSocket` in a worker | Polyfill | [WebSocket relay](./websocket-relay.md) |

# How they connect

- **One controller per profile.** `Profile.extensionController` is lazy and
  owns the storage for that profile's extensions; every web view of the profile
  carries it (`Space.makeWebViewConfiguration`), which is what makes content
  scripts inject. `ExtensionManager.shared` is the delegate of all of them.
- **An extension has two identities.** Its *id* (32 letters a–p, derived from
  its key) is stable and is what Detour's database uses. Its *origin*
  (`webkit-extension://<UUID>/`) belongs to one loaded context and changes on
  every load. Sender verification, [extension page tabs](./extension-pages.md)
  and the favicon scheme all resolve origin → id through the owning profile;
  the origin is never assumed to equal the id.
- **Everything is announced.** WebKit only knows a web view is a tab once it is
  told. A web view built from a profile's configuration that nobody reported
  still runs content scripts, and their messages fail with "Tab not found".
- **The polyfill never replaces `chrome` or `browser`.** It patches members in
  place ([never replace chrome globals](../decisions/never-replace-chrome-globals.md)).

# Known gaps

- `chrome.webRequest` cannot observe or block anything. On `main` the
  polyfill adds nothing for `declarativeNetRequest`, `downloads`, `identity`,
  `sidePanel`, `tabGroups` or `chrome.debugger`: an extension gets whatever
  WebKit itself vends for those, if anything. Several are the subject of the
  [Claude extension epic](./claude-extension-epic.md).
- The polyfilled `idle`, `notifications`, `history` and `management` event
  objects accept listeners but never fire ([Polyfill layer](./polyfill-layer.md)).
- An extension's origin changes at every launch, so its IndexedDB,
  `localStorage` and service worker registration do not survive one; only
  `chrome.storage` does.[^task-99]
- `windows.getCurrent` from a background context has been seen failing with
  "Window not found"; the likely cause is that Detour reports a focused window
  only when the profile has the key window.[^task-81]
- A window is announced to WebKit only when a context loads or the window
  becomes key, and a window with nothing selected reports no tabs.[^task-132-22][^task-132-21]
- No content scripts in `srcdoc` / `about:blank` frames
  ([Frames and content scripts](./frames-and-content-scripts.md)).
- A CRX installed by hand is not signature-checked; only updates are
  ([Installer and CRX](./installer-and-crx.md)).

# Related

- [ExtensionManager](./extension-manager.md) — where to start reading the code.
- [1Password integration](./1password-integration.md) — the extension that drove most of this work.
- [Testing extensions](./testing-extensions.md) — which test suite proves what.
- [Diagnosing extension problems](../playbooks/diagnosing-extension-problems.md) — symptom to cause.
- [Seeding extensions](../playbooks/seeding-extensions.md) — getting an extension into an isolated profile for a runtime check.

[^task-99]: Give each context a stable base URL so extension storage survives a relaunch
[^task-81]: windows.getCurrent from a background worker reports "Window not found" with no key window
[^task-132-21]: A window with nothing selected reports no tabs to extensions
[^task-132-22]: Tell WebKit when a browser window opens or closes
