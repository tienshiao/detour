---
id: TASK-132.1
title: >-
  Extensions spike: can WebKit's native sidePanel be used
  (WebExtensionSidebarEnabled + _WKWebExtensionSidebar)?
status: Done
assignee:
  - '@claude'
created_date: '2026-10-03 23:07'
updated_date: '2026-10-03 23:21'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: high
ordinal: 133000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Decide whether chrome.sidePanel comes from WebKit's private implementation or from a Detour polyfill. The installed WebKit has _WKWebExtensionSidebar and sidebarForTab:, and WebKit main gates the namespace on the WebExtensionSidebarEnabled preference (default false) and the sidePanel permission. Unknown: the shipped default, whether the preference can be set on the controller's webViewConfiguration and reaches the service worker, and whether the delegate's _webExtensionController:presentSidebar:forExtensionContext:completionHandler: fires. The shipped class has willOpenSidebar (no user-interaction argument) and no associatedWindow, so it is older than main. Fallback: define chrome.sidePanel as an own property and host sidepanel.html in a Detour web view built from the context configuration, as OffscreenDocumentHost does. Detour's minimum is macOS 14 and WKWebExtension needs 15.4, so availability on 15.4 matters too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A test extension with the sidePanel permission reports whether chrome.sidePanel exists in its service worker and in an extension page, with the preference on and off
- [x] #2 With the preference on, sidePanel.setOptions({tabId, path}) then sidePanel.open({tabId}) either reaches Detour's delegate with a sidebar whose web view loads the path, or the failure is recorded with its error text
- [x] #3 The sidebar web view is confirmed to carry the Detour polyfill and the profile's data store, or the gap is recorded
- [x] #4 The task records a decision (native SPI or polyfill) with the evidence, including behaviour on the oldest supported macOS that has WKWebExtension
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Standalone WebKit probe (no app build): load a test extension with the sidePanel permission into a WKWebExtensionController, look for the WebExtensionSidebarEnabled feature, read chrome.sidePanel in an extension page and the service worker, call sidebarForTab:.
2. Read WebKit source at the shipped-era revision and at main for how the namespace is gated.
3. Record the decision.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Probe: .claude/scratch/task132.1-sidepanel-spike.m (clang -fobjc-arc -framework AppKit -framework WebKit; run with the sandbox off). Run on macOS 26.7 (25G229), 2026-10-03.

Measured:
- WebExtensionSidebarEnabled is in none of +[WKPreferences _features] (599), _experimentalFeatures (220) or _internalDebugFeatures (143). There is no preference to turn on.
- WKWebExtension.requestedPermissions for a manifest asking for sidePanel, tabs, storage is {storage, tabs}: WebKit does not recognise the sidePanel permission. Granting it explicitly changes nothing.
- chrome.sidePanel and chrome.sidebarAction are undefined in an extension page and in the service worker, with and without a side_panel manifest key.
- -[WKWebExtensionContext sidebarForTab:] exists but returns nil before and after; the delegate's presentSidebar is never called.
- Also undefined in the worker, as the review predicted: chrome.tabGroups, chrome.debugger, chrome.identity, chrome.downloads, chrome.tabs.group, chrome.runtime.getContexts, chrome.runtime.ContextType.

Why (source): Source/WTF/wtf/PlatformEnableCocoa.h defines ENABLE_WK_WEB_EXTENSIONS_SIDEBAR as '0 && ENABLE_WK_WEB_EXTENSIONS', both at the pre-June-2026 revision (4a646799) and on main today. The preference, the IDL interfaces and the namespace members are all conditional on it, so the implementation is compiled out of every released WebKit; only the _WKWebExtensionSidebar wrapper class and the sidebarForTab: selector are left. That holds for macOS 15.4 too (the define dates from the 2024 stubs), so no supported OS has it. Apple is still working on it (main: per-tab sidebar rendering 2026-08-07, newer sidePanel features 2026-08-24), so re-run the probe on new macOS releases.

Polyfill route confirmed workable:
- Object.defineProperty(chrome, 'sidePanel', {value}) succeeds in the worker and in an extension page, survives allocation churn, and is visible as browser.sidePanel (chrome === browser there). WebKit vends nothing, so nothing shadows it (same situation as chrome.webRequest).
- A web view built from context.webViewConfiguration and loaded with an extension URL runs the user scripts added to the controller configuration (marker script seen), so a Detour-built panel web view gets the polyfill and the profile's data store the same way popups and the offscreen document do.

Not explained, not needed: in the bare probe runtime.sendMessage from the extension page to the worker came back empty (no lastError); the worker's results were read through chrome.storage.local instead. Detour's own integration tests do this round trip successfully.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Decision: polyfill. Released WebKit compiles the sidePanel/sidebarAction implementation out (ENABLE_WK_WEB_EXTENSIONS_SIDEBAR is 0 in PlatformEnableCocoa.h, at the shipped revision and on main), so there is no feature flag to enable, chrome.sidePanel is undefined in pages and workers, the sidePanel permission is unrecognised and sidebarForTab: returns nil — measured on macOS 26.7 with a standalone probe, and true by source for macOS 15.4. Detour will define chrome.sidePanel itself (the own property sticks in both contexts) and host the panel page in its own web view built from the context's configuration, which carries the polyfill and the profile's data store. No app code changed.
<!-- SECTION:FINAL_SUMMARY:END -->
