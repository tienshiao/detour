---
type: Decision
title: chrome.sidePanel is a Detour polyfill, not WebKit's sidebar
description: Why Detour defines chrome.sidePanel itself and hosts the panel in its own web view — released WebKit compiles its side panel out, so there is no preference to enable, no permission and no sidebar object — and what that choice costs.
tags: [extensions, side-panel, webkit, polyfill, decision]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T18:50:00Z }
stale_after: 2027-04-01T00:00:00Z
sources:
  - id: task-132-1
    resource: backlog:TASK-132.1
    title: "Spike: can WebKit's native sidePanel be used (WebExtensionSidebarEnabled + _WKWebExtensionSidebar)"
  - id: task-132-8
    resource: backlog:TASK-132.8
    title: Host an extension's per-tab side panel beside the tab's content
  - id: commit-sidepanel
    resource: commit:208bbd8
    title: Epic-branch commit recording the TASK-132.1 spike result
  - id: webkit-enable
    resource: https://github.com/WebKit/WebKit/blob/main/Source/WTF/wtf/PlatformEnableCocoa.h
    title: WebKit, PlatformEnableCocoa.h (ENABLE_WK_WEB_EXTENSIONS_SIDEBAR)
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (sidePanelJS)
  - id: panel
    resource: ../../Detour/Extensions/Runtime/ExtensionSidePanel.swift
    title: ExtensionSidePanel.swift
---

Detour's [side panel](../extensions/side-panel.md) is a polyfilled API over a
web view Detour hosts. WebKit has side panel code, and the installed framework
even exports a sidebar class, so using it was the first thing to rule in or
out. A spike did that before any hosting work started.

# Context

The Claude extension stops with "Browser not supported" when `chrome.sidePanel`
is undefined ([Claude extension epic](../extensions/claude-extension-epic.md)).
Two ways to provide it were on the table:

- WebKit's own implementation. The installed WebKit has the class
  `_WKWebExtensionSidebar` and the selector `sidebarForTab:`, and WebKit `main`
  gates the namespace on a `WebExtensionSidebarEnabled` preference and the
  `sidePanel` permission.
- A polyfill, with the panel page in a Detour web view built from the
  context's configuration, as [offscreen documents](../extensions/offscreen-documents.md)
  already are.

What the spike measured, with a standalone WebKit probe on macOS 26.7 on
2026-10-03:[^task-132-1]

| Question | Result |
|---|---|
| Is there a `WebExtensionSidebarEnabled` feature to turn on? | No. It is in none of `WKPreferences`' feature lists (`_features`, `_experimentalFeatures`, `_internalDebugFeatures`) |
| Does WebKit recognise the `sidePanel` permission? | No. `WKWebExtension.requestedPermissions` for a manifest asking for `sidePanel`, `tabs`, `storage` is `{storage, tabs}`, and granting it explicitly changes nothing |
| Is `chrome.sidePanel` (or `chrome.sidebarAction`) defined? | No, in an extension page and in the service worker, with or without a `side_panel` manifest key |
| Does `sidebarForTab:` return a sidebar? | No. It answers nil, and the delegate's present-sidebar method is never called |

The cause is in WebKit's source: `ENABLE_WK_WEB_EXTENSIONS_SIDEBAR` is defined
as `0 && ENABLE_WK_WEB_EXTENSIONS` in `PlatformEnableCocoa.h`, both at the
revision of the shipped framework and on `main`. The preference, the IDL
interfaces and the namespace members are all conditional on it, so the
implementation is compiled out of every released WebKit. Only the wrapper
class and the selector are left. By the source this holds for macOS 15.4 too,
the oldest system that has `WKWebExtension`.[^task-132-1]

# Decision

Detour defines `chrome.sidePanel` itself and hosts the panel page in its own
`WKWebView`.

The spike confirmed both halves work:[^task-132-1]

- `Object.defineProperty(chrome, 'sidePanel', …)` succeeds in the worker and
  in an extension page, survives allocation churn, and is visible as
  `browser.sidePanel`. WebKit vends nothing under the name, so nothing shadows
  it, the same situation as `chrome.webRequest`
  ([chrome runtime patching](../extensions/chrome-runtime-patching.md)).
- A web view built from `context.webViewConfiguration` and loaded with an
  extension URL runs the user scripts on the controller's configuration, so a
  Detour-built panel gets the polyfill and the profile's data store the way
  popups and the offscreen document do.

# Alternatives rejected

- **WebKit's `_WKWebExtensionSidebar`.** Not available on any supported
  system: there is nothing to enable, and the leftover SPI answers nil. It is
  also private API. This was the only alternative the spike weighed.

# Consequences

- **The manifest is the permission gate.** WebKit does not know the
  permission, so the polyfill module and the native handler both check the
  manifest's `permissions` list.
- **WebKit knows nothing about the panel.** It will not grant `activeTab` on
  panel interaction and reports the panel nowhere.[^task-132-8] Detour
  therefore lists panels itself in
  [`runtime.getContexts`](../extensions/runtime-get-contexts.md), and patches
  `tabs.getCurrent` in the panel page, where WebKit answers `null` rather than
  Chrome's `undefined`.
- **Detour owns everything a browser owns here**: the options state, which
  window shows which panel, the divider, focus, and every closing path. That
  is the whole of the [side panel](../extensions/side-panel.md) page.
- **No user gesture is visible** from a worker's `sidePanel.open`, so `open`
  is not gated on one; Detour notes the gestures it can see (the toolbar
  click, a [command shortcut](../extensions/command-shortcuts.md)) and uses
  them only for keyboard focus.
- **Window ids cannot be bridged**, so a window is named by its active tab.
- **Re-run the probe on new macOS releases.** Apple is still developing the
  feature on WebKit `main` (per-tab sidebar rendering 2026-08-07, further
  `sidePanel` work 2026-08-24).[^task-132-1] The module leaves a namespace
  that is already there alone and reports `native`. From the code: if a future
  WebKit vends `chrome.sidePanel`, the polyfill steps aside, calls go to
  WebKit, and Detour implements no present-sidebar delegate method, so panels
  would stop appearing until the hosting is moved to WebKit's sidebar or the
  module is made to shadow the native one (as
  [offscreen](../extensions/offscreen-documents.md) does). The probe is not in
  the repository; its findings are in the task.

# Related

- [Side panel](../extensions/side-panel.md) — what was built.
- [Native WebExtension with polyfills](./native-webextension-with-polyfills.md) — the general rule this is an instance of.
- [Never replace chrome globals](./never-replace-chrome-globals.md) — the constraint the own-property route respects.
- [WebKit source lookup](../platform/webkit-source-lookup.md) — how the build flag was read.

[^task-132-1]: Spike: can WebKit's native sidePanel be used (WebExtensionSidebarEnabled + _WKWebExtensionSidebar)
[^task-132-8]: Host an extension's per-tab side panel beside the tab's content
