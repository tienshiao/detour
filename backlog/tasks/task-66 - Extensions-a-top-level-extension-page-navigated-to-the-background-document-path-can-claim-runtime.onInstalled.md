---
id: TASK-66
title: >-
  Extensions: a top-level extension page navigated to the background document
  path can claim runtime.onInstalled
status: To Do
assignee: []
created_date: '2026-09-13 21:56'
labels:
  - extensions
  - security
dependencies: []
priority: low
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-64 review. Both gates that decide whether a context is the background context identify it by URL path only: the polyfill's contextKind decision (ExtensionAPIPolyfill preambleJS, isBackgroundPage) classifies a top-level document at the background path as 'background-page' and auto-claims, and the native gate added in TASK-64 (ExtensionPolyfillHandler.senderIsBackgroundContext) accepts a main-frame sender at that path. So an ordinary extension page that navigates itself to the background path (location.href = '/bg.html', or chrome.tabs.create({url: chrome.runtime.getURL('_generated_background_page.html')})) becomes indistinguishable from the real background page in both places and can consume its own extension's install/update event, so the background context WebKit started never gets it. Pre-existing since TASK-43 for the polyfill side; TASK-64 narrowed the native gate to the same path rule but could not do better because WKScriptMessage.frameInfo carries only the frame's URL. Intra-extension only (a page can only take its own extension's event) and no known extension does it.

Fix shape: the native side needs a discriminator other than the path. Candidates: (a) a registry of the web views Detour (or WebKit, via the context) created for background content, so a claim is accepted only from a frame whose WKWebView is the context's background view — check whether WKWebExtensionContext exposes the background web view (private in current SDKs; measure) or whether Profile can observe its creation; (b) refuse a claim from any frame hosted in a WKWebView Detour created for a tab/popup/options/offscreen page (Detour knows every web view it creates for those), so only a view it did not create — WebKit's own background view — can claim. (b) needs no private API and covers tabs.create; measure whether a background page's WKScriptMessage.webView is the same object across the claim. Keep the polyfill's path-based classification as is unless the native change makes a JS-side check redundant.

Related: TASK-43 (background page claims), TASK-64 (sender gate, records this and the sendNativeMessage bypass for service_worker manifests as accepted limits).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An extension page navigated (in a Detour-created tab, popup or options view) to the background document path cannot claim runtime.onInstalled: the claim is refused and logged, the ledger stays pending, and the real background page still receives the event afterwards
- [ ] #2 Claims from the real background page (background.scripts and background.page shapes) and from a service worker keep working; RuntimeInstalledEventTests, ExtensionPolyfillTests and ExtensionPolyfillProfileWiringTests stay green
- [ ] #3 Tests cover the refused navigated-page claim (negative) and the accepted background claims (positive), through the production web view path
- [ ] #4 The TASK-64 doc comment on senderIsBackgroundContext no longer lists this as a known limit
<!-- AC:END -->
