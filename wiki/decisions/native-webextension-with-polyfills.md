---
type: Decision
title: Run extensions on WebKit's WKWebExtension and fill the gaps with polyfills
description: Detour replaced its own extension runtime with WebKit's native WKWebExtension and a thin polyfill layer; what that bought, the working rules it led to, and what it costs.
tags: [extensions, webkit, polyfill, decision]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-04T01:49:13Z }
sources:
  - id: notes-spike
    resource: "Agent session notes, 2026-07 (not in the repository)"
    title: WKWebExtension spike and migration — what replaced what, and the gaps that remained
  - id: commit-eb8510e
    resource: commit:eb8510e
    title: "\"Switch to WkWebExtension?\" (2026-03-28), the commit that removed the custom runtime"
  - id: docs-extensions
    resource: ../../docs/extensions.md
    title: docs/extensions.md
  - id: polyfill
    resource: ../../Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
    title: ExtensionAPIPolyfill.swift (module doc comments state the gap-filling rules)
  - id: task-4
    resource: backlog:TASK-4
    title: "1Password: iframe autofill investigation (getAllFrames is native)"
  - id: task-71
    resource: backlog:TASK-71
    title: Which chrome.offscreen runs in the signed build
  - id: task-22
    resource: backlog:TASK-22
    title: Verify runtime.onInstalled is delivered in the app, or emit it ourselves
  - id: task-64
    resource: backlog:TASK-64
    title: The onInstalled claim handler accepts a claim from any page of the extension
---

Detour's Web Extension support is WebKit's `WKWebExtension` runtime plus a
polyfill for the Chrome APIs WebKit does not implement. It was not always so.
This page records the choice and the rules of thumb that grew out of living
with it.

# Context

Before March 2026 Detour implemented extensions itself. The commit that
switched (`eb8510e`, 2026-03-28) deleted, among others: a content script
injector (~980 lines), a message bridge between pages, workers and native code
(~3,000 lines), a background host, an extension page scheme handler, a tab id
map, and one Swift file per `chrome.*` namespace — nearly thirty of them, from
`ChromeRuntimeAPI` and `ChromeTabsAPI` to `ChromeStorageAPI`.[^commit-eb8510e]
Every API an extension touched was Detour's to implement and keep
Chrome-compatible.

WebKit ships a runtime that already does the central parts: content script
injection in isolated and main worlds, the service worker lifecycle,
`runtime` messaging and ports, `storage`, `tabs`, `windows`, `scripting`,
`action`, `alarms`, `commands`, `contextMenus`, `permissions` and most of
`webNavigation`.

# Decision

Use `WKWebExtension` / `WKWebExtensionContext` / `WKWebExtensionController`
as the runtime, one controller per [profile](../architecture/profiles-and-spaces.md).
Detour implements only:

- the host side WebKit asks for: the controller delegate, the tab and window
  conformances, permission prompts, native messaging;
- a **polyfill layer** for what WebKit lacks, as JavaScript evaluated in the
  extension's contexts and backed by a native handler;
- install, update and UI.

The March 2026 spike led to the migration, which was complete by July
2026.[^notes-spike] The session notes and the commit record what was done and
what it replaced. They do not record a written comparison of alternatives, so
the section below is limited to what the sources show.

# Alternatives rejected

- **Keep the custom runtime.** This is what the migration removed. No written
  rationale survives; what the commit shows is the size of it. Each namespace
  was a hand-written bridge, and core behaviour (background hosting, content
  script injection, message dispatch) was implemented outside the engine.
- **Polyfill a native API "to be safe".** Rejected repeatedly in later work.
  `webNavigation.getAllFrames` is native and returns WebKit's own frame ids; a
  polyfilled fallback could only fabricate frame records, so the fallbacks
  were deleted and a regression is meant to fail loudly.[^task-4]
- **Defer to WebKit wherever it has an implementation.** Also not the rule.
  For `chrome.offscreen` Detour's implementation deliberately shadows a native
  one, because it is the one with the tested lifecycle; it records that it did
  so.[^task-71] For `runtime.onInstalled` WebKit's event is suppressed because
  its timing is wrong for Chrome extensions.[^task-22]

# Consequences

**The working rules** that the polyfill's module comments state:

- Fill a gap only when the member is absent; leave a native implementation
  alone, and record which path was taken (`__detourPolyfillDiag.apis`).
- Stay absent where Chrome would be absent. `chrome.privacy` and
  `chrome.webRequest` are installed only when the manifest declares the
  permission, so feature detection stays truthful.
- Do not fabricate. A stub that cannot do the real thing must not look as if
  it did: `webRequest` listeners never fire and the code says so;
  `storage.managed` answers what an unmanaged Chrome answers.
- Where Detour overrides or shadows WebKit, make it observable.

**What it costs:**

- Detour depends on undocumented WebKit behaviour, discovered by probing and
  by reading WebKit's source: which wrappers can be patched
  ([Chrome runtime patching](../extensions/chrome-runtime-patching.md)), when
  a worker is unloaded
  ([service worker unload rules](../platform/service-worker-unload-rules.md)),
  what tracking prevention does to an extension origin
  ([data store and ITP](../extensions/data-store-and-itp.md)).
- The shipped WebKit lags WebKit main. Features and fixes present on main
  (`chrome.offscreen`, copying `defaultWebsiteDataStore` into extension web
  views) are missing in the system framework, and Detour cannot ship its own.
- The host sees less than it would like. `runtime.sendNativeMessage` reaches
  the delegate with the context only, never the sending frame; there is no
  public handle on the background web view; there is no way to push an event
  into a worker.[^task-64] Several designs exist only to work around these
  ([runtime.onInstalled](../extensions/runtime-installed-event.md),
  [Updates](../extensions/updates.md)).
- Every context load gets a fresh `webkit-extension://<UUID>/` origin, which
  shapes sender verification, [extension page tabs](../extensions/extension-pages.md)
  and [storage](../extensions/storage.md).
- Unit tests of the JavaScript are not enough. They do not exercise WebKit's
  wrappers, the message bridge or sender verification, so every polyfilled API
  also needs tests in a real extension context
  ([testing extensions](../extensions/testing-extensions.md)).

**What it bought:** real Chrome extensions, 1Password among them, run with
their content scripts, workers and messaging handled by the engine, and
Detour's own extension code is the integration and the gaps rather than a
runtime.

# Related

- [Web Extension support](../extensions/overview.md) — the resulting architecture.
- [Polyfill layer](../extensions/polyfill-layer.md) — how the gaps are filled.
- [Never replace chrome globals](./never-replace-chrome-globals.md) — the hardest constraint the polyfill works under.
- [1Password integration](../extensions/1password-integration.md) — the extension that tested the decision hardest.

[^notes-spike]: WKWebExtension spike and migration — what replaced what, and the gaps that remained
[^commit-eb8510e]: "Switch to WkWebExtension?" (2026-03-28), the commit that removed the custom runtime
[^task-4]: 1Password: iframe autofill investigation (getAllFrames is native)
[^task-71]: Which chrome.offscreen runs in the signed build
[^task-22]: Verify runtime.onInstalled is delivered in the app, or emit it ourselves
[^task-64]: The onInstalled claim handler accepts a claim from any page of the extension
