# Overviews

* [1Password integration](1password-integration.md) - What the 1Password extension needs from a browser, which Detour mechanism meets each need, how the desktop app's trust check works, and the gaps that remain.
* [Claude extension epic](claude-extension-epic.md) - The in-flight epic to make Anthropic's Claude extension install, sign in and drive pages in Detour — what the extension needs, the sub-task map, and the decisions and measurements so far. None of this code is on main. *(draft)*
* [Web Extension support](overview.md) - How Detour runs Chrome MV3 extensions — WebKit's native WKWebExtension runtime, Detour's polyfill layer for the APIs WebKit lacks, and the host integration around them — with a file map and the known gaps.

# Concepts

* [Extension pages in tabs](extension-pages.md) - A tab showing a webkit-extension:// page is tied to one loaded context's origin, which dies on every context reload and every relaunch; how such tabs, pinned tiles, favourites and closed-tab records are rehomed, restored, refused or closed.
* [Extension permissions](permissions.md) - How permission decisions are stored, prompted for and re-applied to every loaded context, the order that makes the restore deterministic, how nativeMessaging is enforced, and what WebKit does with overlapping grants and denials.
* [Extensions in the Private profile](private-profile-extensions.md) - The rules for extensions in Private windows — off unless allowed per extension, pages in the profile's own non-persistent store, and the WebKit private-data gate that silently stops events without hasAccessToPrivateData.
* [Frames and content scripts](frames-and-content-scripts.md) - What WebKit does with frames in an extension context — native getAllFrames with its own frame ids, empty URLs and no content scripts for srcdoc and about:blank frames, the limits seen in cross-origin iframes — and what Detour adds for content scripts.

# Components

* [Extension console bridge](console-bridge.md) - How console output and uncaught errors from extension contexts reach the unified log, why the text is private by default, and the two rate limiters that keep an extension's error loop from flooding the log.
* [Extension installer and CRX handling](installer-and-crx.md) - How an extension gets from a Chrome Web Store download or an unpacked folder into Detour's data directory — CRX3 unpacking, signature verification, Chrome-compatible id derivation, and what the installer records.
* [Extension popup, menu and options page](popup-and-options-ui.md) - The browser-side entry points to an extension — the pinned sidebar buttons, the Extensions menu, the action popup popover and how it takes the popup's size, and the options page — and the rule that nothing but an explicit present may read an action's popupWebView.
* [Extension storage](storage.md) - Where an extension's data lives in Detour — WebKit's chrome.storage areas keyed by profile and extension id, the polyfilled storage.managed, and the origin-keyed storage (IndexedDB, localStorage) that WebKit moves to each context load's new base URL, so it survives relaunches.
* [ExtensionManager](extension-manager.md) - The singleton that installs, loads, enables and uninstalls extensions across profiles and is the delegate of every profile's WKWebExtensionController; with the Profile half that owns the contexts.
* [Native messaging](native-messaging.md) - How Detour runs Chrome native messaging hosts for extensions — host discovery, the access gate at dispatch, the one-shot and port paths, exactly-once teardown, and what may and may not be logged.
* [Native port keep-alive](native-port-keep-alive.md) - How Detour keeps an extension's background alive while it holds a native messaging host or relayed WebSocket, why the native side drives it, how a dead background is detected and restarted, and the cases it does not cover.
* [Offscreen documents](offscreen-documents.md) - Detour's implementation of chrome.offscreen — a hidden web view per extension and profile, the rule that every createDocument settles exactly once, the AudioContext bridge, and why Detour's implementation shadows a native one.
* [Polyfill layer](polyfill-layer.md) - The JavaScript bundle Detour evaluates in every extension context and the native handler behind it — how it is injected, how a request reaches Swift, how the sender is verified, and how callback-style calls get runtime.lastError.
* [runtime.onInstalled](runtime-installed-event.md) - Why Detour suppresses WebKit's runtime.onInstalled and emits its own from a per-profile version ledger, how the background context claims the event at start-up, and how the claim is restricted to the real background context.
* [Tab and window bridge](tab-and-window-bridge.md) - How Detour's tabs and windows are presented to WebKit's extension runtime — the WKWebExtensionTab and Window conformances, the rule for when a tab is reported open, closed, moved or active, and what a window lists.
* [WebSocket relay](websocket-relay.md) - Why a WebSocket opened in an extension service worker deadlocks WebKit, and how Detour replaces it with a socket relayed through a native port to URLSessionWebSocketTask — protocol, lifetime, cookies and deliberate gaps.

# Features

* [Extension updates](updates.md) - How installed extensions move to newer versions — the update2 poll, the verification gate, the added-permissions hold, deferring an update while the extension is busy, runtime.onUpdateAvailable, and why runtime.reload has to be recognised natively.

# Investigations

* [Extension data store and tracking prevention](data-store-and-itp.md) - Why WebKit's tracking prevention kept deleting extension storage and killing 1Password's worker, which data store extension pages really run in, the reconnect loop that was the same bug in the Private profile, and the interaction keeper that fixed it.

# Platform quirks

* [Patching WebKit's chrome.* wrappers](chrome-runtime-patching.md) - WebKit vends chrome.* objects from a weak wrapper cache and serves many members through class callbacks, so a JavaScript patch can vanish at the next garbage collection or never take at all; which members can be patched, how to keep a patch alive, and what must be done natively instead.

# Playbooks

* [Testing extensions](testing-extensions.md) - Which kind of extension test proves what — pure rules, the polyfill in a bare web view, a real WebKit extension context, the production Profile wiring, a runtime check with API Explorer, and the signed build — with the fixtures and the traps.
