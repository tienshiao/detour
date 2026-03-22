# Extension System

Detour supports Chrome-compatible browser extensions using the Manifest V3 format. The implementation covers content scripts (including MAIN world), background service workers, popup UI, context menus, offscreen documents, port-based messaging, and a broad subset of `chrome.*` APIs — enough to run real-world extensions like Dark Reader. Extensions are loaded from unpacked directories and managed through `ExtensionManager`, which coordinates injection, background hosting, messaging, toolbar integration, and command shortcuts.

## Architecture

```
ExtensionManager.shared (singleton)
  ├── extensions: [WebExtension]         loaded extension models
  ├── injector: ContentScriptInjector    injects scripts into webviews
  ├── backgroundHosts: [ID: BackgroundHost]  one per enabled extension
  ├── offscreenHosts: [ID: OffscreenDocumentHost]  on-demand per extension
  ├── tabIDMap: ExtensionTabIDMap        UUID ↔ chrome int (tabs)
  ├── spaceIDMap: ExtensionTabIDMap      UUID ↔ chrome int (windows)
  ├── tabObserver: ExtensionTabObserver  forwards TabStore events
  ├── popupWebViews: [ID: WeakWebView]  open popup webviews for message routing
  ├── badgeText/badgeBackgroundColor/customIcons/actionTitle  per-extension action state
  ├── uninstallURLs: [ID: URL]          set via runtime.setUninstallURL
  ├── contextMenuItems: [ID: [ContextMenuItem]]
  └── commandMonitor: NSEvent monitor   keyboard shortcuts from manifest commands

ExtensionMessageBridge.shared (WKScriptMessageHandler)
  └── routes all extension ↔ native messages

ExtensionDatabase.shared (SQLite via GRDB)
  ├── extension          metadata + manifest blob
  └── extensionStorage   key/value per extension (local + sync namespaces)

ExtensionToolbarManager          creates NSToolbarItems with badge support
ExtensionPopoverController       hosts popup.html in NSPopover (load-before-show)
ExtensionInstaller               validates, copies, persists new extensions
```

## Directory Layout

```
Detour/Extensions/
├── Installer/
│   └── ExtensionInstaller.swift          validate + copy + persist
├── Model/
│   ├── WebExtension.swift                runtime model (icon, contentWorld, matchers)
│   ├── ExtensionManifest.swift           Codable MV3 manifest (incl. commands, world)
│   ├── ExtensionPermissionChecker.swift  API + host permission checks
│   └── ContentScriptMatcher.swift        match-pattern → URL/JS guard logic
├── Runtime/
│   ├── ExtensionManager.swift            singleton lifecycle coordinator
│   ├── BackgroundHost.swift              hidden WKWebView for service worker
│   ├── OffscreenDocumentHost.swift       hidden WKWebView for offscreen documents
│   ├── ContentScriptInjector.swift       WKUserScript registration + MAIN world + event relay
│   ├── ExtensionMessageBridge.swift      WKScriptMessageHandler message router
│   ├── ExtensionTabObserver.swift        TabStoreObserver → chrome.tabs events
│   ├── ExtensionTabIDMap.swift           UUID ↔ integer ID mapping
│   ├── ExtensionI18n.swift               i18n message loading and resolution
│   └── ChromeAPI/
│       ├── ChromeAPIBundle.swift         combines all 16 polyfills into one bundle
│       ├── ChromeRuntimeAPI.swift        runtime.sendMessage, onMessage, onInstalled, onStartup, connect, setUninstallURL
│       ├── ChromeStorageAPI.swift        storage.local + storage.sync + storage.session
│       ├── ChromeTabsAPI.swift           tabs.query/create/update/remove/get/sendMessage/detectLanguage
│       ├── ChromeScriptingAPI.swift      scripting.executeScript/insertCSS
│       ├── ChromeWebNavigationAPI.swift  event emitters wired to WKNavigationDelegate
│       ├── ChromeWebRequestAPI.swift     stub event emitters (no WebKit support)
│       ├── ChromeI18nAPI.swift           i18n.getMessage/getUILanguage
│       ├── ChromeContextMenusAPI.swift   contextMenus create/update/remove/onClicked
│       ├── ChromeOffscreenAPI.swift      offscreen.createDocument/closeDocument/hasDocument
│       ├── ChromeAlarmsAPI.swift         alarms via setTimeout/setInterval (pure JS)
│       ├── ChromeActionAPI.swift         action.setIcon/setBadgeText/setBadgeBackgroundColor/setTitle
│       ├── ChromeCommandsAPI.swift       commands.getAll/onCommand
│       ├── ChromeWindowsAPI.swift        windows.getAll/get/create/update/getCurrent
│       ├── ChromeFontSettingsAPI.swift   fontSettings.getFontList
│       ├── ChromePermissionsAPI.swift    permissions.contains/getAll
│       └── ChromeResourceInterceptor.swift  XHR/fetch interception for extension:// URLs
├── Storage/
│   └── ExtensionDatabase.swift           GRDB database for extensions + storage API
└── UI/
    ├── ExtensionToolbarManager.swift     toolbar button factory with badge compositing
    └── ExtensionPopoverController.swift  popup.html in NSPopover (load-before-show)
```

## Extension Lifecycle

### Installation

Extensions can be installed from the Chrome Web Store or from a local unpacked directory. Both paths show a permission confirmation prompt before installing.

**Chrome Web Store:** When the user clicks "Add to Chrome" on the Chrome Web Store, `BrowserWindowController` intercepts the CRX download response (via `isCRXResponse` in `decidePolicyFor navigationResponse`). The CRX file is downloaded with a Chrome User-Agent, unpacked by `CRXUnpacker.unpack(data:)`, and the manifest is parsed to show the permission prompt.

**Local unpacked:** The user picks a directory via `NSOpenPanel` (Debug menu → Load Unpacked Extension). The manifest is parsed directly from the selected directory.

Both paths then show an `NSAlert` with the extension name and a bulleted list of requested permissions (generated by `ExtensionPermissionChecker.permissionSummary(for:)`). The user must click "Install" to proceed.

After confirmation:

1. `ExtensionInstaller.install(from:)` validates `manifest.json` and checks for MV3.
2. The directory is copied to `~/Library/Application Support/Detour/Extensions/{UUID}/`.
3. i18n placeholders in the extension name are resolved via `ExtensionI18n`.
4. An `ExtensionRecord` is saved to `ExtensionDatabase`.
5. `ExtensionManager` adds the `WebExtension` to its array, starts a `BackgroundHost` (with `isFirstRun: true`), and injects content scripts into all existing tabs.
6. The background host fires `runtime.onInstalled` with `reason: 'install'` and `runtime.onStartup`.
7. A toolbar update notification triggers `BrowserWindowController` to add the extension's toolbar button.
8. Command shortcuts from the manifest are registered via `NSEvent.addLocalMonitorForEvents`.

### Browser Restart

On restart, `ExtensionManager.initialize()` loads extensions from the database and starts background hosts with `isFirstRun: false`. This means `runtime.onInstalled` does NOT fire again — only `runtime.onStartup` fires. This matches Chrome behavior and prevents extensions from re-running first-install logic (like opening help pages) on every restart.

### Enable / Disable

`ExtensionManager.setEnabled(id:enabled:)` toggles the DB flag, starts or stops the background host, and posts `extensionsDidChangeNotification`. Toolbar buttons and content script injection update accordingly.

### Uninstall

`ExtensionManager.uninstall(id:)` opens the uninstall URL if one was set via `runtime.setUninstallURL`, stops the background host, cleans up all per-extension state (badge, icons, action title, context menus), removes the extension from the in-memory array, deletes the DB record (cascading to storage), and removes the copied files from disk.

## Content Script Injection

Content scripts run in an isolated `WKContentWorld` per extension, preventing interference between extensions and page scripts.

### New webviews

`ContentScriptInjector.addContentScripts(to:)` is called during `Space.makeWebViewConfiguration()`. For each enabled extension it calls `registerContentScripts(for:on:)` which:

1. Generates chrome API polyfills via `ChromeAPIBundle` (with `isContentScript: true`) and registers them in the extension's content world.
2. Registers the message bridge in the extension's content world.
3. If the extension has MAIN world content scripts, installs a **cross-world event relay** (see below).
4. For each content script group, reads CSS/JS files and registers them as `WKUserScript` entries at the appropriate injection time and in the correct world.

### Content script worlds

The manifest `content_scripts[].world` field controls where scripts execute:

- **`"ISOLATED"` (default)** — Scripts run in the extension's `WKContentWorld`. They can access the DOM but not page JS variables.
- **`"MAIN"`** — Scripts run in the page's JS context. They're injected via `<script>` element creation from the content world (not as bare WKUserScripts), which ensures `document.currentScript` is available. MAIN world scripts do NOT get chrome API polyfills.

### Cross-world event relay

WKWebKit content worlds have separate JS namespaces — `CustomEvent`s dispatched in one world's `Document` wrapper don't reach listeners in another world. Chrome doesn't have this limitation. To bridge this gap, when an extension has MAIN world scripts:

1. A **page-world collector** wraps `document.addEventListener` to track which event types have listeners registered (stored in `window.__detourRelayEvents`).
2. A **content-world relay** wraps `document.dispatchEvent`. When a `CustomEvent` is dispatched, it creates an inline `<script>` element that checks `__detourRelayEvents` and re-dispatches matching events in the page world.

This is needed for extensions like Dark Reader, where the ISOLATED world content script dispatches configuration events that the MAIN world proxy script must receive.

### Existing tabs

When an extension is installed or enabled after tabs are already open, `ContentScriptInjector.injectIntoExistingTab(_:for:)`:

1. Registers persistent `WKUserScript` entries on the tab's content controller (so future navigations get scripts).
2. Calls `webView.evaluateJavaScript()` to immediately inject into the current page (if the URL matches).

## Background Service Workers

`BackgroundHost` creates a hidden, off-screen `WKWebView` with a non-persistent data store. The background script is loaded by:

1. Generating chrome API polyfills via `ChromeAPIBundle` (with `isContentScript: false`).
2. Building a synthetic HTML page that inlines the polyfill bundle and the extension's service worker script in `<script>` tags.
3. Loading the HTML via `loadHTMLString` with a `baseURL` of `extension://{id}/`. Scripts run in `.page` world.

The `start(isFirstRun:)` method controls whether `runtime.onInstalled` fires. `runtime.onStartup` always fires. Both use `setTimeout(0)` so synchronous listener registrations complete first.

Events are dispatched to background scripts via `BackgroundHost.dispatchEvent(_:data:)`, which calls `evaluateJavaScript` with the event name and JSON payload. The `ExtensionTabObserver` uses this to forward `chrome.tabs.onCreated`, `onRemoved`, `onUpdated`, and `onActivated`.

## Message Bridge

`ExtensionMessageBridge` implements `WKScriptMessageHandler` under the handler name `"extensionMessage"`. It is registered on every content controller — in `.page` world for background/popup webviews and in the extension's content world for content scripts.

### Message flow

```
Content script / Popup           Native bridge                    Background host
     │                                │                                 │
     ├─ runtime.sendMessage ─────────►│                                 │
     │   {type, extensionID,          │── evaluateJavaScript ──────────►│
     │    callbackID, data}           │   __extensionDispatchMessage()  │
     │                                │                                 │
     │                                │◄── runtime.sendResponse ────────┤
     │◄── __extensionDeliverResponse──│    {callbackID, response}       │
     │                                │                                 │
```

Messages from `runtime.sendMessage` are broadcast to all extension contexts (background, offscreen, popup) except the sender. Popup webViews are tracked via `ExtensionManager.popupWebViews` so the bridge can include them as broadcast targets.

### Sender object

The `sender` object passed to `onMessage` listeners includes:
- `id` — extension ID
- `origin` — `"content-script"` or `"extension"`
- `url` — the sender webView's URL (needed by extensions like Dark Reader that verify popup origin)
- `tab` — full tab info object (only for content script messages, includes `id`, `windowId`, `url`, etc.)
- `frameId` — frame ID (only for content script messages, currently always `0`)

### Supported message types

| Type | Direction | Description |
|------|-----------|-------------|
| `runtime.sendMessage` | any → background/popup | Message passing between contexts |
| `runtime.sendResponse` | background → caller | Response routed back via callback ID |
| `runtime.connect` | content → background | Port-based messaging initiation |
| `runtime.openOptionsPage` | any → native | Open extension's options page |
| `runtime.setUninstallURL` | background → native | Set URL to open on uninstall |
| `port.postMessage` | any → any | Port message relay |
| `port.disconnect` | any → any | Port disconnection |
| `storage.get/set/remove/clear` | any → native | `chrome.storage.local` operations |
| `storage.sync.get/set/remove/clear` | any → native | `chrome.storage.sync` operations (key prefix `sync:`) |
| `tabs.query` | any → native | Query tabs with filters (active, currentWindow, lastFocusedWindow, url, title, windowId) |
| `tabs.create/update/remove/get` | any → native | Tab CRUD |
| `tabs.sendMessage` | background → content | Send message to a tab's content script |
| `tabs.detectLanguage` | any → native | Detect page language |
| `scripting.executeScript` | any → native | Inject JS (func+args or files) |
| `scripting.insertCSS` | any → native | Inject CSS (inline or files) |
| `contextMenus.create/update/remove/removeAll` | background → native | Context menu management |
| `offscreen.createDocument/closeDocument/hasDocument` | background → native | Offscreen document lifecycle |
| `action.setIcon/setBadgeText/setBadgeBackgroundColor/getBadgeText/setTitle/getTitle/setPopup` | background → native | Toolbar button state |
| `commands.getAll` | any → native | Return manifest commands |
| `windows.getAll/get/getCurrent/create/update` | any → native | Window/space queries |
| `fontSettings.getFontList` | any → native | System font enumeration |
| `permissions.contains` | any → native | Permission check |
| `resource.get` | content → native | Load extension resource files |

### Permission enforcement

Before dispatching any message, the bridge checks permissions via `ExtensionPermissionChecker`:

1. **API permission gate** — `requiredPermission(for:)` maps the message type prefix to a required manifest permission. APIs that require permissions: `storage`, `scripting`, `webNavigation`, `webRequest`, `contextMenus`, `offscreen`, `alarms`, `fontSettings`. APIs that are always allowed: `runtime`, `tabs`, `action`, `commands`, `windows`, `permissions`.
2. **Host permission gate** — `tabs.sendMessage`, `scripting.executeScript`, and `scripting.insertCSS` additionally check `hasHostPermission(for:extension:)` against the target tab's URL.
3. **URL field visibility** — Tab info objects include `url`, `title`, and `favIconUrl` only if the extension has the `"tabs"` permission OR has matching host permissions for the tab's URL. This matches Chrome's behavior.

## Chrome API Polyfills

`ChromeAPIBundle.generateBundle(for:isContentScript:)` concatenates all 16 polyfill generators into a single JavaScript string. The `isContentScript` flag controls world isolation: content scripts get polyfills injected into the extension's `WKContentWorld`, while background and popup scripts get them in `.page` world.

All bridge-backed APIs use `webkit.messageHandlers.extensionMessage.postMessage()` to communicate with native code. Some APIs (like `chrome.alarms`) are implemented entirely in JavaScript.

| API | Support | Notes |
|-----|---------|-------|
| `chrome.runtime.id` | Full | Extension ID string |
| `chrome.runtime.getManifest()` | Full | Returns parsed manifest |
| `chrome.runtime.getURL(path)` | Full | Returns `extension://{id}/path` |
| `chrome.runtime.sendMessage()` | Full | Promise + callback, broadcast to all contexts |
| `chrome.runtime.onMessage` | Full | Event emitter with sender.tab/url/frameId |
| `chrome.runtime.onInstalled` | Full | Fires on first install only (not restarts) |
| `chrome.runtime.onStartup` | Full | Fires on every background host start |
| `chrome.runtime.connect/onConnect` | Full | Port-based messaging |
| `chrome.runtime.openOptionsPage()` | Full | Opens extension's options page |
| `chrome.runtime.setUninstallURL()` | Full | URL opened on uninstall |
| `chrome.runtime.getPlatformInfo()` | Full | Returns `{os: 'mac', arch: 'arm'}` |
| `chrome.runtime.lastError` | Stub | Always `null` |
| `chrome.storage.local` | Full | get/set/remove/clear with onChanged |
| `chrome.storage.sync` | Full | Separate namespace (prefixed keys), onChanged |
| `chrome.storage.session` | Full | In-memory only, cleared on restart |
| `chrome.tabs.query()` | Full | Supports active, currentWindow, lastFocusedWindow, url, title, windowId |
| `chrome.tabs.create/update/remove/get` | Full | Full CRUD on tabs |
| `chrome.tabs.sendMessage()` | Full | Background → content script messaging |
| `chrome.tabs.detectLanguage()` | Full | Via document.documentElement.lang |
| `chrome.tabs.onCreated/Removed/Updated/Activated` | Full | Fired via ExtensionTabObserver |
| `chrome.scripting.executeScript()` | Full | func + args or files |
| `chrome.scripting.insertCSS()` | Full | Inline css or files |
| `chrome.scripting.removeCSS()` | Full | Removes matching `<style>` elements by content |
| `chrome.webNavigation.*` | Full | All four events fire from WKNavigationDelegate |
| `chrome.webRequest.*` | Stub | No-op emitters; WebKit has no request interception |
| `chrome.i18n.getMessage()` | Full | With substitution support |
| `chrome.i18n.getUILanguage()` | Full | Returns system language |
| `chrome.contextMenus` | Full | create/update/remove/removeAll/onClicked |
| `chrome.offscreen` | Full | createDocument/closeDocument/hasDocument |
| `chrome.alarms` | Full | create/clear/clearAll/get/getAll/onAlarm (pure JS) |
| `chrome.action` | Full | setIcon/setBadgeText/setBadgeBackgroundColor/getBadgeText/setTitle |
| `chrome.commands` | Full | getAll/onCommand + keyboard shortcut dispatch |
| `chrome.windows` | Full | getAll/get/getCurrent/create/update |
| `chrome.fontSettings.getFontList()` | Full | Via NSFontManager |
| `chrome.permissions.contains()` | Full | Checks declared permissions |
| `chrome.permissions.getAll()` | Full | Returns manifest permissions/origins |
| `chrome.extension.isAllowedFileSchemeAccess()` | Stub | Always returns `false` |
| `chrome.extension.isAllowedIncognitoAccess()` | Stub | Always returns `false` |
| `chrome.extension.getBackgroundPage()` | Stub | Always returns `null` (MV3) |

## Popup / Toolbar UI

`ExtensionToolbarManager` generates `NSToolbarItem` identifiers for enabled extensions that declare an `action` in their manifest. Each toolbar item gets an `NSButton` with the extension's icon (scaled to 20x20). If the extension has set badge text via `chrome.action.setBadgeText`, the badge is composited onto the icon as a small rounded rectangle with white text.

The toolbar manager also handles dynamic updates: when `extensionActionDidChangeNotification` fires (triggered by `action.setBadgeText`, `action.setIcon`, `action.setTitle`), `updateToolbarButton(for:)` iterates all windows and updates matching toolbar items. Change guards prevent no-op notifications from triggering unnecessary redraws.

### Popup presentation

When the toolbar button is clicked, `BrowserWindowController` creates an `ExtensionPopoverController` which uses a **load-before-show** pattern:

1. Creates a `WKWebView` offscreen with chrome API polyfills injected.
2. Registers the webView with `ExtensionManager` so the message bridge can deliver messages during load.
3. Loads the extension's `popup.html` via the `extension://` scheme handler.
4. Waits for `didFinish` + 50ms for JS rendering.
5. Measures the DOM content size via `evaluateJavaScript`.
6. Creates and shows the `NSPopover` at the measured size (clamped to 800x600 max).

This eliminates the visible resize animation that would occur if the popover showed before content was measured.

## Storage

`ExtensionDatabase` is a separate SQLite database at `~/Library/Application Support/Detour/extensions.db`, managed via GRDB.

### Schema

**`extension`** table:

| Column | Type | Description |
|--------|------|-------------|
| `id` | TEXT PK | UUID string |
| `name` | TEXT | Extension name |
| `version` | TEXT | Version string |
| `manifestJSON` | BLOB | Encoded manifest |
| `basePath` | TEXT | File system path to extension files |
| `isEnabled` | BOOLEAN | Enabled flag |
| `installedAt` | DOUBLE | Unix timestamp |

**`extensionStorage`** table:

| Column | Type | Description |
|--------|------|-------------|
| `extensionID` | TEXT | FK to `extension.id` |
| `key` | TEXT | Storage key (sync keys prefixed with `sync:`) |
| `value` | BLOB | JSON-encoded value |

Primary key: (`extensionID`, `key`). Foreign key cascades deletes — removing an extension clears its storage.

`chrome.storage.sync` uses the same table with keys prefixed by `sync:` (e.g., `sync:settings`). `chrome.storage.session` is in-memory only (JS-side), not persisted to the database.

When `storage.get` is called with an object argument (e.g., `chrome.storage.local.get({key: defaultValue})`), the default values are merged client-side for missing keys, matching Chrome's behavior.

## Tab ID Mapping

Chrome APIs use integer IDs for tabs and windows. Detour uses UUIDs internally. `ExtensionTabIDMap` provides a session-scoped bidirectional mapping:

- `intID(for: UUID) -> Int` — returns existing mapping or auto-assigns the next integer (starting at 1).
- `uuid(for: Int) -> UUID?` — reverse lookup.
- Mappings are cleaned up when tabs/spaces are removed via `ExtensionTabObserver`.

Two instances exist: `ExtensionManager.tabIDMap` for tab IDs and `ExtensionManager.spaceIDMap` for window IDs.

## Command Shortcuts

Extensions can declare keyboard shortcuts in `manifest.commands`. On initialization, `ExtensionManager.registerCommandShortcuts()` parses these and installs an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` handler. When a registered shortcut is pressed, the corresponding `__extensionDispatchCommand(commandName)` function is called on the background host, firing `chrome.commands.onCommand` listeners.

Supported modifiers: `Ctrl`/`Control`/`MacCtrl`, `Alt`/`Option`, `Shift`, `Command`/`Cmd`. The `mac` key in `suggested_key` takes precedence over `default` on macOS.

## Test Extensions

Two test extensions live under `TestExtensions/`:

- **hello-world** — Minimal extension with a content script (runs on all URLs), background service worker, popup, and storage permission. Useful for verifying basic lifecycle and injection.
- **api-explorer** — Comprehensive extension exercising all implemented APIs. Declares alarms, fontSettings, storage, tabs, scripting, webNavigation, contextMenus, and offscreen permissions. The popup has interactive sections for each API. Background script logs events (tabs, webNavigation, storage.onChanged, alarms.onAlarm, commands.onCommand, runtime.onStartup) to a storage-backed event log. Version 3.0.0.

## Limitations

- **`chrome.webRequest`** — Stub-only event emitters. WebKit provides no pre-request interception API.
- **`chrome.webNavigation`** — All four events fire from `WKNavigationDelegate` methods, but only for main-frame navigations (`frameId: 0`). Sub-frame navigation events are not tracked.
- **`chrome.scripting.removeCSS`** — Removes `<style>` elements previously inserted by `insertCSS`, matched by content and extension ID attribute.
- **`chrome.permissions.request()`** — Stubbed to always deny. Install-time permissions are confirmed via an NSAlert prompt, but there is no UI for granting optional permissions at runtime.
- **`allFrames` and `matchAboutBlank`** — Parsed from manifest but not yet enforced by the content script injector. All scripts currently inject into all frames (`forMainFrameOnly: false`).
- **`tabs.sendMessage` options** — The `documentId` and `frameId` options in the third argument are accepted but not used for targeting.
