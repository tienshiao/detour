# Extension System

Detour supports Chrome-compatible browser extensions using Manifest V3, built on WebKit's native `WKWebExtension` APIs (requires macOS 15.4+). Content scripts, background service workers, popup UI, context menus, messaging, storage, and tab/window management are all handled natively by WebKit. Detour adds polyfills for Chrome APIs that WebKit doesn't implement (idle, notifications, history, offscreen documents, etc.) and provides the native integrations (toolbar buttons, permission grants, installation flow) that wire everything together.

## Architecture

```
ExtensionManager.shared (singleton, WKWebExtensionControllerDelegate)
  ├── extensions: [WebExtension]             loaded extension models
  ├── contextMenuItems: [ID: [ContextMenuItem]]
  ├── uninstallURLs: [ID: URL]
  ├── tabObserver: ExtensionTabObserver      forwards TabStore events to contexts
  ├── activePopovers: [ID: ExtensionPopoverController]
  └── activeMessagingHosts: [ObjectIdentifier: NativeMessagingHost]

Profile (one per browsing profile)
  ├── extensionController: WKWebExtensionController     WebKit's native controller
  ├── extensionContexts: [ID: WKWebExtensionContext]    loaded per-profile contexts
  └── polyfillHandler: ExtensionPolyfillHandler          native handler for polyfill APIs

AppDatabase.shared (SQLite via GRDB)
  ├── extension             metadata + manifest blob
  ├── extensionStorage      key/value per extension (chrome.storage.local)
  └── profileExtension      per-profile enable/disable overrides

ExtensionToolbarManager        creates NSToolbarItems with badge support
ExtensionPopoverController     hosts popup.html in NSPopover (measures content, resize observer)
ExtensionInstaller             validates, copies, persists new extensions
CRXUnpacker                    extracts CRX3 files from Chrome Web Store
```

## Directory Layout

```
Detour/Extensions/
├── Installer/
│   ├── ExtensionInstaller.swift          validate + copy + persist
│   └── CRXUnpacker.swift                 CRX3 extraction
├── Model/
│   ├── WebExtension.swift                runtime model (icon, i18n, WKWebExtension ref)
│   ├── ExtensionManifest.swift           Codable MV3 manifest
│   └── ContextMenuItem.swift             context menu item model
├── Runtime/
│   ├── ExtensionManager.swift            singleton lifecycle + WKWebExtensionControllerDelegate
│   ├── ExtensionAPIPolyfill.swift        JS polyfill bundle for non-native chrome.* APIs
│   ├── ExtensionPolyfillHandler.swift    native handler for polyfill messages
│   ├── ExtensionTabObserver.swift        TabStoreObserver → WKWebExtensionContext notifications
│   ├── ExtensionNotificationManager.swift  UNUserNotificationCenter bridge
│   ├── IdleMonitor.swift                 system idle state via CGEventSource
│   ├── NativeMessagingHost.swift         native messaging process launcher
│   ├── OffscreenDocumentHost.swift       hidden WKWebView + AudioContext shim
│   ├── WKExtensionTabConformance.swift   BrowserTab: WKWebExtensionTab
│   └── WKExtensionWindowConformance.swift BrowserWindowController: WKWebExtensionWindow
├── Storage/Models/
│   ├── ExtensionRecord.swift             GRDB record for installed extensions
│   ├── ExtensionStorageRecord.swift      GRDB record for chrome.storage.local
│   └── ProfileExtensionRecord.swift      per-profile enable/disable state
└── UI/
    ├── ExtensionToolbarManager.swift     toolbar button factory with badge compositing
    └── ExtensionPopoverController.swift  popup.html in NSPopover with dynamic sizing
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
| `chrome.permissions` (contains, getAll) | WebKit native |
| `chrome.webNavigation` events | WebKit native |
| `chrome.contextMenus` | WebKit native |
| `chrome.alarms` | WebKit native |
| `chrome.idle` | **Polyfill** → `IdleMonitor` (CGEventSource) |
| `chrome.notifications` | **Polyfill** → `ExtensionNotificationManager` (UNUserNotificationCenter) |
| `chrome.history.search` | **Polyfill** → `HistoryDatabase` |
| `chrome.management` (getSelf, getAll) | **Polyfill** → `ExtensionManager` |
| `chrome.fontSettings.getFontList` | **Polyfill** → `NSFontManager` (filtered to system fonts) |
| `chrome.sessions.restore` | **Polyfill** → `TabStore.reopenClosedTab` |
| `chrome.search.query` | **Polyfill** → profile's search engine |
| `chrome.offscreen` | **Polyfill** → `OffscreenDocumentHost` |
| `chrome.extension` (getBackgroundPage, etc.) | **Polyfill** (stubs) |
| `chrome.webRequest` | **Polyfill** (no-op stubs; WebKit has no request interception) |

## Polyfill Injection

The polyfill JS (`ExtensionAPIPolyfill.polyfillJS`) only reaches extension-owned contexts, not web pages:

| Context | Injection method | World | Communication channel |
|---------|-----------------|-------|----------------------|
| Service worker | `importScripts('_detour_polyfill.js')` prepended to SW file on disk | Extension (SW global scope) | `browser.runtime.sendNativeMessage('detourPolyfill', msg)` |
| Popup / Options | `WKUserScript` on extension controller's `userContentController` | Extension (page) | `webkit.messageHandlers.detourPolyfill.postMessage(msg)` |
| Offscreen document | Inherited via `context.webViewConfiguration` (same `userContentController`) | Extension (page) | `webkit.messageHandlers.detourPolyfill.postMessage(msg)` |
| Content scripts | `chrome.scripting.registerContentScripts` from SW polyfill | Isolated | N/A (stubs only, no native messaging) |

The service worker path exists because `WKUserScript` injection doesn't work in WebKit's opaque service worker process. `ExtensionManager.injectServiceWorkerPolyfill(into:)` writes `_detour_polyfill.js` to the extension directory and prepends `importScripts(...)` to the manifest's `background.service_worker` file before `WKWebExtension` initialization.

All polyfill messages are handled by `ExtensionPolyfillHandler`, which implements `WKScriptMessageHandlerWithReply`. It has two entry points:

1. **Web view contexts** (popup, options, offscreen): `userContentController(_:didReceive:replyHandler:)` — called directly by WebKit.
2. **Service worker**: `handleNativeMessage(_:replyHandler:)` — called via `ExtensionManager`'s `sendMessage` delegate when `appID == "detourPolyfill"`.

## Extension Lifecycle

### Installation

Extensions can be installed from the Chrome Web Store or from a local unpacked directory. Both paths show a permission confirmation prompt.

**Chrome Web Store:** `BrowserWindowController` intercepts CRX download responses (`isCRXResponse` in `decidePolicyFor navigationResponse`). The CRX is downloaded with a Chrome User-Agent, unpacked by `CRXUnpacker.unpack(data:)`, and the manifest is parsed to show the permission prompt.

**Local unpacked:** The user picks a directory via `NSOpenPanel` (Settings → Extensions → Add Extension).

After confirmation:

1. `ExtensionInstaller.install(from:publicKey:)` validates `manifest.json` (MV3 required).
2. Extension ID is derived from CRX3 public key (SHA256 → a-p encoding), manifest `key` field, or UUID fallback.
3. Files are copied to `~/Library/Application Support/Detour/Extensions/{extensionID}/`.
4. An `ExtensionRecord` is saved to `AppDatabase`.
5. `ExtensionManager` injects the service worker polyfill, loads `WKWebExtension`, creates contexts in each profile's `WKWebExtensionController`, and starts background content.
6. `extensionsDidChangeNotification` triggers toolbar and UI updates.

### Browser Restart

`ExtensionManager.initialize()` loads extensions from the database, injects polyfills, loads `WKWebExtension` resources in parallel, and loads contexts into each profile. Background content is started asynchronously with a 10-second timeout.

### Enable / Disable

Extensions can be toggled globally (`AppDatabase.setEnabled`) or per-profile (`AppDatabase.setProfileExtensionEnabled`). Toggling loads/unloads the extension context from the relevant profile's controller and notifies existing tabs.

### Uninstall

`ExtensionManager.uninstall(id:)` opens the uninstall URL if set, cancels background tasks, unloads from all profiles, deletes the DB record (cascading to storage), and removes extension files from disk.

## WebKit Integration

### WKWebExtensionControllerDelegate

`ExtensionManager` implements the delegate for all profile controllers:

| Delegate method | Behavior |
|-----------------|----------|
| `openWindowsFor` | Returns `BrowserWindowController`s matching the profile |
| `focusedWindowFor` | Returns the key window |
| `openNewTabUsing` | Creates a tab via `TabStore` |
| `openOptionsPageFor` | Opens extension's options page in a new tab |
| `presentActionPopup` | Shows popup via `ExtensionPopoverController` |
| `promptForPermissions` | Auto-grants all requested permissions |
| `promptForPermissionToAccess` | Auto-grants URL access |
| `promptForPermissionMatchPatterns` | Auto-grants match patterns |
| `didUpdate` | Notifies of action state changes (icon, badge, title) |
| `sendMessage` | Routes native messaging: polyfill calls to `ExtensionPolyfillHandler`, other appIDs to `NativeMessagingHost` |
| `connectUsing` | Spawns `NativeMessagingHost` for port-based native messaging |

### Tab & Window Conformance

`BrowserTab` conforms to `WKWebExtensionTab`, exposing title, URL, loading state, audio state, and providing `activate()`, `loadURL()`, `reload()`, `close()` methods. The key method `webView(for:)` returns the tab's `WKWebView` only if its configuration matches the extension context.

`BrowserWindowController` conforms to `WKWebExtensionWindow`, exposing tabs, active tab, frame, screen, window state (normal/minimized/maximized/fullscreen), and focus/close actions.

### Tab Events

`ExtensionTabObserver` implements `TabStoreObserver` and notifies all extension contexts of tab lifecycle events via `WKWebExtensionContext`:

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

`ExtensionToolbarManager` generates `NSToolbarItem`s for enabled extensions that declare an `action`. Badge text is composited onto the icon as a rounded rectangle overlay.

### Popup Presentation

When the toolbar button is clicked, `ExtensionPopoverController`:

1. Gets the popup `WKWebView` from `WKWebExtensionContext.action.popupWebView`.
2. Reloads the webview (popups are recreated each open, matching Chrome).
3. Waits 50ms for JS rendering, then measures content via `scrollWidth`/`scrollHeight`.
4. Presents an `NSPopover` at the measured size (clamped 100–800 wide, 100–600 tall).
5. Installs a `ResizeObserver` for dynamic size changes.

## Storage

Extension metadata and storage live in `AppDatabase` (the app's main SQLite database via GRDB), not a separate database.

### Schema

**`extension`** — installed extension metadata (id, name, version, manifestJSON, basePath, isEnabled, installedAt).

**`extensionStorage`** — `chrome.storage.local` key/value pairs (extensionID + key → JSON blob). Foreign key cascades deletes.

**`profileExtension`** — per-profile enable/disable overrides (profileID + extensionID → isEnabled). Missing row means the extension uses its global enabled state.

`chrome.storage.local` and `chrome.storage.sync` are handled natively by WebKit. `chrome.storage.session` is in-memory only.

## Native Messaging

`NativeMessagingHost` spawns native host processes using Chrome's length-prefixed JSON protocol (4-byte LE uint32 + UTF-8 JSON). It validates the host manifest location and enforces a 1 MB message size limit. Used by extensions like 1Password that communicate with companion desktop apps.

## Test Extensions

Two test extensions live under `TestExtensions/`:

- **hello-world** — Minimal extension with a content script, background service worker, popup, and storage permission. Verifies basic lifecycle and injection.
- **api-explorer** — Comprehensive extension exercising all implemented APIs. Interactive popup sections for each API, background event logging to storage.

## Limitations

- **`chrome.webRequest`** — Stub-only event emitters. WebKit provides no pre-request interception API.
- **`chrome.webNavigation`** — Events fire only for main-frame navigations (`frameId: 0`).
- **`chrome.permissions.request()`** — All permissions are auto-granted at install time. No runtime permission prompt UI.
- **`chrome.declarativeNetRequest`** — Not supported.
- **`chrome.tabs.detectLanguage`** — May not be implemented by WebKit in all versions.
- **Offscreen document AudioContext** — Shimmed to route through native `AVAudioPlayer`. The shim covers `decodeAudioData`/`createBufferSource`/`start`/`stop`/`onended` but not the full Web Audio API graph.
