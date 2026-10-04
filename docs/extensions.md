# Extension System

Detour supports Chrome-compatible browser extensions using Manifest V3, built on WebKit's native `WKWebExtension` APIs (requires macOS 15.4+). Content scripts, background service workers, popup UI, context menus, messaging, storage, and tab/window management are all handled natively by WebKit. Detour adds polyfills for Chrome APIs that WebKit doesn't implement (idle, notifications, history, offscreen documents, etc.) and provides the native integrations (pinned extension buttons, permission prompts, installation and updates) that wire everything together.

## Architecture

```
ExtensionManager.shared (singleton, WKWebExtensionControllerDelegate)
  ├── extensions: [WebExtension]             loaded extension models
  ├── tabObserver: ExtensionTabObserver      loads extensions into a profile added mid-session
  ├── activePopovers: [ID: ExtensionPopoverController]   popups opened by action.openPopup()
  ├── activeMessagingHosts: [ObjectIdentifier: OneShotNativeRequest]   sendNativeMessage calls in flight
  └── liveNativeHosts, keepAlivePorts, webSocketRelays   connectNative hosts, keep-alive ports and
                                             relayed WebSockets, per (controller, extension)

Profile (one per browsing profile)
  ├── extensionController: WKWebExtensionController     WebKit's native controller
  ├── extensionContexts: [ID: WKWebExtensionContext]    loaded per-profile contexts
  ├── polyfillHandler: ExtensionPolyfillHandler          native handler for polyfill APIs
  └── originInteractionKeeper                            keeps extension origins out of WebKit's
                                                         tracking-prevention purge

AppDatabase.shared (SQLite via GRDB)
  ├── extension                metadata + manifest blob, source and update URL
  ├── extensionPermission      saved permission decisions (API, match pattern, URL)
  ├── profileExtension         per-profile enabled and pinned state
  ├── extensionInstalledEvent  runtime.onInstalled ledger, per profile
  └── extensionStorage         unused (see Storage)

ExtensionTabLifecycle          the one seam for tab open/close/activate/change notifications
FauxAddressBar                 pinned extension buttons (icon + badge from ExtensionManager.iconImage)
ExtensionPopoverController     hosts popup.html in NSPopover (measures content, resize observer)
ExtensionInstaller             validates, copies, persists new extensions
CRXUnpacker / CRX3Verifier     extracts CRX3 files; verifies the signature of an update
ExtensionUpdater               polls update URLs, verifies, installs or stages updates
```

## Directory Layout

```
Detour/Extensions/
├── Installer/
│   ├── ExtensionInstaller.swift          validate + copy + persist
│   ├── CRXUnpacker.swift                 CRX3 extraction
│   └── CRX3Verifier.swift                CRX3 signature verification (updates)
├── Model/
│   ├── WebExtension.swift                runtime model (icon, i18n, WKWebExtension ref)
│   ├── ExtensionManifest.swift           Codable MV3 manifest
│   ├── ExtensionSource.swift             webStore / crx / unpacked
│   ├── ExtensionVersion.swift            version comparison
│   └── ExtensionPermissionDescriptions.swift  permission text for prompts and Settings
├── Runtime/
│   ├── ExtensionManager.swift            singleton lifecycle + WKWebExtensionControllerDelegate
│   ├── ExtensionManager+Updates.swift    applying, staging and deferring updates
│   ├── ExtensionManager+OptionsPage.swift  options page entry points
│   ├── ExtensionAPIPolyfill.swift        JS polyfill bundle for non-native chrome.* APIs
│   ├── ExtensionPolyfillHandler.swift    native handler for polyfill messages
│   ├── ExtensionTabLifecycle.swift       tab open/close/activate/change → WKWebExtensionContext
│   ├── ExtensionTabObserver.swift        TabStoreObserver: a new profile gets its extensions
│   ├── ExtensionActiveTab.swift          which tab a window reports as active (Peek-aware)
│   ├── ExtensionPageURL.swift            webkit-extension:// pages open in tabs
│   ├── ExtensionPageHostRegistry.swift   web views Detour hosts (tells pages from the background)
│   ├── RuntimeInstalledEvent.swift       Detour's runtime.onInstalled rule
│   ├── ExtensionOriginInteractionKeeper.swift  tracking-prevention guard for extension origins
│   ├── ExtensionNotificationManager.swift  UNUserNotificationCenter bridge
│   ├── IdleMonitor.swift                 system idle state via CGEventSource
│   ├── FaviconSchemeHandler.swift        detour-favicon:// for runtime.getURL('/_favicon/…')
│   ├── NativeMessagingHost.swift         native messaging process launcher
│   ├── NativeHostKeepAlive.swift         keep-alive state for a worker with a native host
│   ├── NativeConnectLogLimiter.swift     rate limit for native-connect log lines
│   ├── WebSocketRelay.swift              WebSocket for service workers, relayed natively
│   ├── ConsoleBridgeLimiter.swift        rate limit for forwarded worker console output
│   ├── OffscreenDocumentHost.swift       hidden WKWebView + AudioContext shim
│   ├── ModuleBundler.swift               bundles a module worker into one script (unused: useModuleBundler is false)
│   ├── WKExtensionTabConformance.swift   BrowserTab: WKWebExtensionTab
│   └── WKExtensionWindowConformance.swift BrowserWindowController: WKWebExtensionWindow
├── Storage/Models/
│   ├── ExtensionRecord.swift             GRDB record for installed extensions
│   ├── ExtensionPermissionRecord.swift   saved permission decisions
│   ├── ExtensionInstalledEventRecord.swift  runtime.onInstalled ledger
│   ├── ExtensionStorageRecord.swift      GRDB record for the unused extensionStorage table
│   └── ProfileExtensionRecord.swift      per-profile enabled and pinned state
├── UI/
│   ├── ExtensionPopoverController.swift  popup.html in NSPopover with dynamic sizing
│   ├── ExtensionMenuPopupDecision.swift  whether an Extensions-menu item opens a popup, without loading it
│   └── ExtensionOptionsPageEntry.swift   whether and where an options page opens
└── Updates/
    ├── ExtensionUpdater.swift            update checks, download, verification
    ├── UpdateManifest.swift              update2 response parsing
    ├── ExtensionUpdatePolicy.swift       added-permissions policy
    ├── ExtensionUpdateDeferral.swift     when an update waits for the extension to be idle
    └── StagedExtensionUpdate.swift       a verified update kept on disk until it installs
```

## What WebKit Provides vs. What Detour Adds

WebKit's `WKWebExtension` system handles the core extension runtime natively:

| Feature | Provider |
|---------|----------|
| Content script injection (isolated + MAIN world) | WebKit native |
| Service worker lifecycle | WebKit native |
| `chrome.runtime` messaging (sendMessage, connect, ports) | WebKit native |
| `chrome.storage.local/sync/session` | WebKit native |
| `chrome.tabs` (query, create, update, remove, sendMessage) | WebKit native |
| `chrome.scripting` (executeScript, insertCSS, removeCSS) | WebKit native |
| `chrome.i18n` (getMessage, getUILanguage, detectLanguage) | WebKit native |
| `chrome.action` (icon, badge, popup, title) | WebKit native |
| `chrome.commands` (keyboard shortcuts) | WebKit native |
| `chrome.windows` (getAll, get, create, update) | WebKit native |
| `chrome.permissions` (contains, getAll, request, remove) | WebKit native; `contains`/`request`/`remove` are wrapped to drop a port from origin patterns, which WebKit's parser rejects |
| `chrome.webNavigation` | WebKit native (`getAllFrames`/`getFrame` included); the polyfill fills in missing events and adds `onHistoryStateUpdated`/`onReferenceFragmentUpdated` from the content polyfill |
| `chrome.contextMenus` | WebKit native |
| `chrome.alarms` | WebKit native |
| `chrome.idle` | **Polyfill** → `IdleMonitor` (CGEventSource) |
| `chrome.notifications` | **Polyfill** → `ExtensionNotificationManager` (UNUserNotificationCenter) |
| `chrome.history.search` | **Polyfill** → `HistoryDatabase` |
| `chrome.management` (getSelf, getAll; `setEnabled` is a no-op) | **Polyfill** → `ExtensionManager` |
| `chrome.runtime.requestUpdateCheck`, `onUpdateAvailable` | **Polyfill** → `ExtensionUpdater` / staged updates (`onUpdateAvailable` fires in the background context when an update is deferred; `reload()` stays WebKit's — a reload that follows the event installs the staged copy) |
| `chrome.fontSettings.getFontList` | **Polyfill** → `NSFontManager` (filtered to system fonts) |
| `chrome.sessions.restore` | **Polyfill** → `TabStore.reopenClosedTab` |
| `chrome.search.query` | **Polyfill** → profile's search engine |
| `chrome.offscreen` | **Polyfill** → `OffscreenDocumentHost` |
| `chrome.webRequest` | **Polyfill** (no-op stubs, only with the `webRequest` permission; WebKit has no request interception) |
| `chrome.privacy` | **Polyfill** (stubs, only with the `privacy` permission) |
| `chrome.storage.managed` | **Polyfill** (empty, read-only) |
| `chrome.action.getUserSettings` | **Polyfill** (`{isOnToolbar: true}`) |
| `chrome.runtime.onInstalled` | **Detour** — WebKit's event is suppressed and Detour delivers its own (`RuntimeInstalledEvent`) |
| `WebSocket` in a service worker | **Polyfill** → `WebSocketRelaySession` (WebKit's worker WebSocket deadlocks an extension worker) |

## Polyfill Injection

The polyfill JS (`ExtensionAPIPolyfill.polyfillJS`) only reaches extension-owned contexts, not web pages. Content scripts get a separate, much smaller script (`ExtensionAPIPolyfill.contentPolyfillJS`):

| Context | Injection method | World | Communication channel |
|---------|-----------------|-------|----------------------|
| Service worker | `importScripts('_detour_polyfill.js')` prepended to the SW file on disk (a module worker gets `import './_detour_polyfill_module.js'` instead) | Extension (SW global scope) | `browser.runtime.sendNativeMessage('detourPolyfill', msg)` |
| Background page (`background.scripts` / `background.page`) | `WKUserScript` on extension controller's `userContentController` | Extension (page) | `webkit.messageHandlers.detourPolyfill.postMessage(msg)` |
| Popup / Options | `WKUserScript` on extension controller's `userContentController` | Extension (page) | `webkit.messageHandlers.detourPolyfill.postMessage(msg)` |
| Offscreen document | Inherited via `context.webViewConfiguration` (same `userContentController`) | Extension (page) | `webkit.messageHandlers.detourPolyfill.postMessage(msg)` |
| Content scripts | `_detour_content_polyfill.js` written into the installed copy and inserted first in each manifest `content_scripts[].js` | Isolated | `chrome.runtime.sendMessage` to the background context, which forwards to the native handler |

The service worker path exists because `WKUserScript` injection doesn't work in WebKit's opaque service worker process. `ExtensionManager.injectServiceWorkerPolyfill(into:)` writes `_detour_polyfill.js` next to the manifest's `background.service_worker` file and prepends `importScripts(...)` to it before `WKWebExtension` initialization. `writeContentPolyfill(into:)` does the same for content scripts by editing the installed copy's `manifest.json`. The content polyfill patches `chrome.i18n.detectLanguage` and reports `pushState`/`replaceState`/`hashchange` navigations; both round-trip through the background context.

All polyfill messages are handled by `ExtensionPolyfillHandler`, which implements `WKScriptMessageHandlerWithReply`. It has two entry points:

1. **Web view contexts** (popup, options, offscreen): `userContentController(_:didReceive:replyHandler:)` — called directly by WebKit.
2. **Service worker**: `handleNativeMessage(_:verifiedExtensionID:replyHandler:)` — called via `ExtensionManager`'s `sendMessage` delegate when `appID == "detourPolyfill"`. The extension id comes from the sending context, never from the message body.

## Extension Lifecycle

### Installation

Extensions can be installed from the Chrome Web Store or from a local unpacked directory. Both paths ask for confirmation before installing; the Web Store and Settings paths list the permissions the manifest requests.

**Chrome Web Store:** `BrowserWindowController` intercepts CRX download responses (`isCRXResponse` in `decidePolicyFor navigationResponse`). The CRX is downloaded with a Chrome User-Agent, unpacked by `CRXUnpacker.unpack(data:)`, and the manifest is parsed to show the permission prompt.

**Local unpacked:** The user picks a directory via `NSOpenPanel` (Settings → Extensions → Add Extension… → Load Unpacked Extension…, or Develop → Load Unpacked Extension…).

After confirmation:

1. `ExtensionInstaller.install(from:publicKey:options:)` validates `manifest.json` (MV3 required).
2. Extension ID is derived from CRX3 public key (SHA256 → a-p encoding), manifest `key` field, or UUID fallback.
3. Files are copied to `~/Library/Application Support/Detour/Extensions/{extensionID}/` (the data directory is `detourDataDirectory()`, so `DETOUR_DATA_DIR` moves it).
4. An `ExtensionRecord` is saved to `AppDatabase`, and the manifest's declared permissions and host permissions are recorded as granted where no decision is saved yet.
5. `ExtensionManager` injects the service worker and content polyfills, loads `WKWebExtension`, and loads a context into the `WKWebExtensionController` of each profile where the extension is enabled. It starts the background content only to deliver `runtime.onInstalled` (`wakeForPendingInstalledEvent`); otherwise WebKit starts it on demand.
6. `extensionsDidChangeNotification` triggers the pinned-button, menu and Settings updates.

### Browser Restart

`ExtensionManager.initialize()` installs any update staged at the last quit, loads extensions from the database, injects polyfills, loads `WKWebExtension` resources in parallel, and loads contexts into each profile. Background content is not started at launch: WebKit loads it on demand (an event, a message, an alarm). Detour calls `loadBackgroundContent` itself in three cases only — a `runtime.onInstalled` event is still owed (`wakeForPendingInstalledEvent`), a context was reloaded after its background failed to load (`Profile.recoverFromBackgroundLoadFailure`), or the keep-alive restarted a background that stopped answering (`restartUnresponsiveBackground`).

### Enable / Disable

Extensions can be toggled globally (`AppDatabase.setEnabled`) or per-profile (`AppDatabase.setProfileExtensionEnabled`), through `ExtensionManager.setEnabled(id:enabled:)` and `setEnabled(id:profileID:enabled:)`. An extension runs in a profile when the global flag is on and the profile's own answer is on; with no per-profile row that answer is the profile's default — on, except in the built-in Private profile, where an extension is off until the user allows it. Toggling loads/unloads the extension context from the relevant profile's controller, tells a newly loaded context about the profile's tabs, and closes an unloaded context's open pages.

### Uninstall

`ExtensionManager.uninstall(id:)` unloads the extension from all profiles (removing WebKit's stored data for it), closes its open pages, deletes the DB record (cascading to its permission and per-profile rows, and clearing its `runtime.onInstalled` ledger), removes the extension files from disk, and discards any staged update. `runtime.setUninstallURL` is not acted on: no uninstall URL is opened.

### Updates

Every installed extension records its **source** (`ExtensionSource`): `webStore` (a CRX downloaded from a Chrome Web Store host), `crx` (any other CRX), or `unpacked` (a folder loaded with Develop → Load Unpacked Extension, whose path is kept as `sourcePath`). CRX installs also record an `updateURL`: the manifest's `update_url` (HTTPS only), or the Web Store's update2 endpoint for store downloads that declare none. A non-store CRX without `update_url` never updates.

**Checking.** `ExtensionUpdater` polls each CRX install's update URL with an update2 (`x=id=…&v=…`) request. It runs ~30 s after launch when the last full check is older than 5 hours, then on the same 5-hour cadence while the app runs, and on demand from Settings → Extensions → Check for Updates, Extensions → Check for Extension Updates, and `chrome.runtime.requestUpdateCheck` (throttled to one real check per extension per 5 minutes; answers `throttled` / `no_update` / `update_available`).

**Verification.** A candidate CRX must match the response's SHA-256 (when given), pass CRX3 signature verification (`CRX3Verifier`), and its signing key must derive the installed extension id; its manifest version must be strictly newer (`ExtensionVersion`). `ExtensionManager.applyUpdate` re-checks id and version before installing over the old copy through the normal `install` path (per-profile enablement, saved permission decisions and open extension pages are kept; `runtime.onInstalled` gets `update`).

**Added permissions.** If the new manifest adds API permissions that carry a Chrome install warning, or new host permissions (`ExtensionUpdatePolicy.addedPermissions`), the update is installed **disabled** with a `pendingPermissionApproval`. Settings shows a banner listing them with "Accept and Enable"; turning the Enabled switch on asks the same question. A later update's additions merge into a pending approval rather than replacing it.

**Unpacked reload.** Unpacked extensions are never polled. Settings → Reload and Develop → Reload "<name>" reinstall from `sourcePath` keeping the id (`reloadUnpacked`); any version is accepted, and added permissions are held for approval the same way.

**Deferral (TASK-123).** A verified update is not installed while the extension is busy, because replacing a running context tears its pages down and restarts its worker. `ExtensionUpdateDeferral.shouldDefer` holds it when any of these is true (`ExtensionManager.activity(for:)`): one of the extension's pages is open in a tab, pinned tile, favorite or peek in any profile; its action popup is showing after `action.openPopup()` (`isPopupOpen` reads `activePopovers`, which only that delegate path fills — a popup the user opened from a pinned button or the Extensions menu is not counted); a native messaging host is connected on its behalf; or its background context made a polyfill request in the last 60 s (`noteBackgroundActivity`, recorded for every background-context request). The check then reports `.deferred(version:)` ("Version X is downloaded and installs when the extension is idle") and the unpacked, verified copy is **staged** on disk at `<data>/Extensions/<id>.staged/` with its version, signing key and time (`StagedExtensionUpdate`), so it survives a relaunch. A newer update replaces an older staged one.

A staged update is applied by whichever comes first:
- `chrome.runtime.reload()` in response to the event — WebKit's `reload` is a read-only static of the runtime wrapper and cannot be shadowed by the polyfill, and a reload keeps the context's base URL, so Detour recognises it by its only trace: the background context restarting within 15 s of an `onUpdateAvailable` delivery made to an *earlier incarnation* of it (`ExtensionManager.backgroundContextDidStart`, called from the polyfill's start-up `runtime.claimInstalledEvent`; the polyfill mints a `__detourContextInstance` token per evaluation and stamps it on both the wait and the claim, since a listener added at script evaluation is answered before the claim runs and that answer must not pass for the delivery a reload followed). That installs the staged copy at once, whatever the extension has open, which is Chrome's documented pattern. A reload made for any other reason is indistinguishable from an event waking the worker and leaves the copy for the idle poll;
- the idle poll — `ExtensionUpdater.applyStagedUpdatesIfIdle()` every 30 s while the app runs, installing any staged update whose extension is now idle (and posting `didFinishCheckNotification` so Settings and the menu summary update);
- the next launch — `applyStagedUpdatesBeforeLoad()` installs every staged copy through the installer before extension records are read;
- Settings → Extensions → **Install Now**, shown under the update row with the staged version while one is waiting.

Every path re-validates id and version (a staged copy the extension has since overtaken is discarded) and goes through the same added-permissions policy: an update that adds permissions still installs disabled pending approval. `requestUpdateCheck` reports a deferred update as `update_available` with its version.

**`runtime.onUpdateAvailable`** fires with `{version}` when an update is staged. WebKit has no push channel into a worker, so the first `addListener` in the background context parks a `runtime.awaitUpdateAvailable` request with Detour (`ExtensionManager.awaitUpdateAvailable`, one per profile and extension; a newer one supersedes the old). `stageUpdate` answers it (`notifyUpdateAvailable`) — at once if an update is already staged when the listener is added, unless that version was delivered to the same context in the last 15 s, which is the reloaded worker re-adding its listener — the listeners run, and the request is parked again. Only the background context may park one: requests from popups, options pages, tabs or iframes are refused, quietly, so the event exists there but never fires. As in Chrome, an extension that ignores the event gets the update when it next goes idle.

## WebKit Integration

### WKWebExtensionControllerDelegate

`ExtensionManager` implements the delegate for all profile controllers:

| Delegate method | Behavior |
|-----------------|----------|
| `openWindowsFor` | Returns `BrowserWindowController`s matching the profile |
| `focusedWindowFor` | Returns the key window when it shows a space of the profile |
| `openNewTabUsing` | Creates a tab via `TabStore` |
| `openNewWindowUsing` | Opens a new browser window (Private when asked) with the requested URLs |
| `openOptionsPageFor` | Opens extension's options page in a tab, reusing one that already shows it |
| `presentActionPopup` | Shows popup via `ExtensionPopoverController` (extension-initiated `action.openPopup()`; a user click presents the popup directly) |
| `promptForPermissions` | Shows an Allow / Deny `NSAlert` and saves the answer (`extensionPermission`) |
| `promptForPermissionToAccess` | Same alert for URL access; auto-granted without a prompt when the extension has `activeTab` and the request follows a user gesture in the tab (or comes from the background with no tab) |
| `promptForPermissionMatchPatterns` | Same alert for match patterns, with the same `activeTab` auto-grant |
| `didUpdate` | Notifies of action state changes (icon, badge, title) |
| `sendMessage` | Routes native messaging: polyfill calls to `ExtensionPolyfillHandler`, other appIDs to `NativeMessagingHost` (only when the manifest declares `nativeMessaging` and the user has not denied it) |
| `connectUsing` | Spawns `NativeMessagingHost` for port-based native messaging under the same rule; Detour's own `detourPolyfill` (keep-alive) and `detourWebSocketRelay` ports are accepted without spawning a process |

### Tab & Window Conformance

`BrowserTab` conforms to `WKWebExtensionTab`, exposing title, URL, loading state, audio state, and providing `activate()`, `loadURL()`, `reload()`, `close()` methods. The key method `webView(for:)` returns the tab's `WKWebView` only if its configuration matches the extension context.

`BrowserWindowController` conforms to `WKWebExtensionWindow`, exposing tabs, active tab, frame, screen, window state (normal/minimized/maximized/fullscreen), and focus/close actions.

### Tab Events

Tab lifecycle events reach the contexts through `ExtensionTabLifecycle` (`WKWebExtensionContext` calls). Opens follow the *placement rule* (TASK-52): a tab is reported the moment it enters a container the window enumeration reads (`Space.tabs`, `Space.pinnedEntries`, `Profile.favorites`, `BrowserTab.peekTab` — each has a `didSet` calling `didPlace`), and again when `wake()` builds a new web view. Closes come from `BrowserTab.teardown()`, the last moment the web view exists and the one point every kind of tab passes through; a few paths that end a registration without a teardown (a move to another profile, a parked or promoted Peek) call `ExtensionTabLifecycle.didClose` directly. `ExtensionTabObserver` reports no tab events: it only loads extensions into a profile added mid-session (`tabStoreDidAddProfile`). Activations are announced by the window that owns them, and property changes are observed on the tab itself:

- `didOpenTab()` / `didCloseTab()`
- `didChangeTabProperties()` (URL, title, loading state)
- `didActivateTab()`

## Offscreen Documents

`OffscreenDocumentHost` creates a hidden `WKWebView` for extensions that need off-screen DOM or audio processing. Created on demand via `chrome.offscreen.createDocument()`.

The offscreen webview is configured with the extension context's `WKWebViewConfiguration` (so it has `chrome.*` APIs) and loaded via the `webkit-extension://` URL scheme.

### AudioContext Bridge

WebKit's `AudioContext` doesn't work in hidden webviews without a user gesture. `OffscreenDocumentHost` injects a JavaScript shim (via `evaluateJavaScript` after page load) that replaces `AudioContext` with a bridge to native `AVAudioPlayer`:

1. `decodeAudioData()` converts `ArrayBuffer` → base64 (chunked encoding)
2. `createBufferSource().start()` sends base64 audio to Swift via `webkit.messageHandlers.detourAudioBridge`
3. Swift's `playAudioNatively(base64:)` plays via `AVAudioPlayer`
4. `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying` fires the JS `onended` callback

The shim is injected into the offscreen document only (not via `WKUserScript`, which would also reach the service worker through the shared `userContentController`).

## Popup / Toolbar UI

There is no window toolbar. Extensions the user pins in a profile (`profileExtension.isPinned`) get a button in the sidebar's `FauxAddressBar`; every enabled extension with an `action` is also listed in the popover behind that bar's settings button, and in the Extensions menu. `ExtensionManager.iconImage(for:ext:)` draws the icon, with badge text composited onto it as a rounded rectangle overlay.

### Popup Presentation

When an extension button or menu item is clicked, `ExtensionPopoverController` records the user gesture for `activeTab`, fires `action.onClicked` instead if the action has no popup, and otherwise:

1. Gets the popup `WKWebView` from `WKWebExtensionContext.action.popupWebView`.
2. Reloads the webview (popups are recreated each open, matching Chrome).
3. Waits 50ms for JS rendering, then measures content via `scrollWidth`/`scrollHeight`.
4. Presents an `NSPopover` at the measured size (clamped 100–800 wide, 100–600 tall).
5. Installs a `ResizeObserver` for dynamic size changes.

### Options Page Entry Points

An extension's options page (`options_page` or `options_ui.page`, see `ExtensionOptionsPageEntry.hasOptionsPage`) opens from three places, all through `ExtensionManager+OptionsPage.swift`:

- **`runtime.openOptionsPage()`** — the controller delegate opens it in the calling controller's profile.
- **Extensions menu** — each enabled extension is a submenu: "Show Popup" (still decided by `ExtensionMenuPopupDecision`, never reading `popupWebView`, TASK-55) and "Options…", enabled when the key window's profile has the extension loaded; it opens there.
- **Settings → Extensions → "Settings…"** — hidden without an options page. The pane is global, so `ExtensionOptionsPageEntry.resolveProfile` picks the profile: the main browser window's, then the last-active space's, then any profile with an open space — the first with the extension on. Private qualifies only when the main window is Private, so a background Private window never captures the click. Disabled (with a tooltip) when nothing resolves.

Options and extension storage are per profile: the page is loaded with that profile's context configuration, in one of its spaces. `optionsPageTab(for:in:preferring:)` reuses a tab already showing the page (same context origin and path, query/fragment ignored) instead of opening a duplicate; `openOptionsPage(for:in:)` then shows it in a window already on that space, else switches a normal window to it, else opens a new window (normal profiles only).

## Storage

Extension metadata and storage live in `AppDatabase` (the app's main SQLite database via GRDB), not a separate database.

### Schema

**`extension`** — installed extension metadata (id, name, version, manifestJSON, basePath, isEnabled, installedAt, source, updateURL, sourcePath, pendingPermissionApprovalJSON).

**`extensionStorage`** — unused. A key/value table (extensionID + key → JSON blob) left from before `chrome.storage` was WebKit's; the table and its `storageGet`/`storageSet` accessors are called only by tests.

**`extensionPermission`** — saved permission decisions (extensionID + key + type → granted/denied), for API permissions, match patterns and single URLs. Foreign key cascades deletes.

**`profileExtension`** — per-profile state (profileID + extensionID → isEnabled, isPinned). A missing row means the profile's default: enabled, except in the built-in Private profile, where it means disabled.

**`extensionInstalledEvent`** — the `runtime.onInstalled` ledger: the version the event was last delivered for, per extension and profile.

`chrome.storage.local`, `chrome.storage.sync` and `chrome.storage.session` are handled natively by WebKit, in the profile's extension controller storage, not in this database. `chrome.storage.session` is in-memory only.

## Native Messaging

`NativeMessagingHost` spawns native host processes using Chrome's length-prefixed JSON protocol (4-byte LE uint32 + UTF-8 JSON). It finds the host manifest in Chrome's `NativeMessagingHosts` directories (and Detour's own), checks the extension against its `allowed_origins`, and enforces a 1 MB message size limit. Used by extensions like 1Password that communicate with companion desktop apps.

## Test Extensions

Three test extensions live under `TestExtensions/` (a fourth directory, `1password/`, holds only a packed `1password.crx` that no test references):

- **hello-world** — Minimal extension with a content script, background service worker, popup, and storage permission. Verifies basic lifecycle and injection.
- **hello-world-module** — The same with a `type: "module"` service worker that imports other modules. Verifies module worker support.
- **api-explorer** — Comprehensive extension exercising all implemented APIs. Interactive popup sections for each API, background event logging to storage.

## Limitations

- **`chrome.webRequest`** — Stub-only event emitters; no listener ever fires. WebKit provides no pre-request interception API.
- **`chrome.webNavigation`** — `getAllFrames`/`getFrame` are WebKit's; `srcdoc` and `about:blank` frames are enumerated with an empty URL and get no content script. The synthesized `onHistoryStateUpdated`/`onReferenceFragmentUpdated` events report `frameId: 0` for the top frame and `-1` for any subframe, not WebKit's frame id.
- **`chrome.permissions.request()`** — Declared permissions and host permissions are granted at install time. A runtime request shows a plain Allow / Deny alert, with no per-site or time-limited choices.
- **`chrome.declarativeNetRequest`** — Detour adds nothing for it; an extension gets only what WebKit itself vends.
- **`chrome.tabs.detectLanguage`** — May not be implemented by WebKit in all versions.
- **Offscreen document AudioContext** — Shimmed to route through native `AVAudioPlayer`. The shim covers `decodeAudioData`/`createBufferSource`/`start`/`stop`/`onended` but not the full Web Audio API graph.
