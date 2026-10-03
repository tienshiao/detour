---
id: TASK-132.1
title: >-
  Extensions spike: can WebKit's native sidePanel be used
  (WebExtensionSidebarEnabled + _WKWebExtensionSidebar)?
status: To Do
assignee: []
created_date: '2026-10-03 23:07'
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
- [ ] #1 A test extension with the sidePanel permission reports whether chrome.sidePanel exists in its service worker and in an extension page, with the preference on and off
- [ ] #2 With the preference on, sidePanel.setOptions({tabId, path}) then sidePanel.open({tabId}) either reaches Detour's delegate with a sidebar whose web view loads the path, or the failure is recorded with its error text
- [ ] #3 The sidebar web view is confirmed to carry the Detour polyfill and the profile's data store, or the gap is recorded
- [ ] #4 The task records a decision (native SPI or polyfill) with the evidence, including behaviour on the oldest supported macOS that has WKWebExtension
<!-- AC:END -->
