---
id: TASK-66
title: >-
  Extensions: a top-level extension page navigated to the background document
  path can claim runtime.onInstalled
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 21:56'
updated_date: '2026-09-13 22:17'
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
- [x] #1 An extension page navigated (in a Detour-created tab, popup or options view) to the background document path cannot claim runtime.onInstalled: the claim is refused and logged, the ledger stays pending, and the real background page still receives the event afterwards
- [x] #2 Claims from the real background page (background.scripts and background.page shapes) and from a service worker keep working; RuntimeInstalledEventTests, ExtensionPolyfillTests and ExtensionPolyfillProfileWiringTests stay green
- [x] #3 Tests cover the refused navigated-page claim (negative) and the accepted background claims (positive), through the production web view path
- [x] #4 The TASK-64 doc comment on senderIsBackgroundContext no longer lists this as a known limit
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measured: the public WKWebExtensionContext API exposes no background web view (only webViewConfiguration, isLoaded, loadBackgroundContent), so the discriminator is the inverse: every web view Detour itself creates or presents for extension content is known (tab web views held by BrowserTab, including addExtensionTab's plain WKWebView; OffscreenDocumentHost's view; the popup web view ExtensionPopoverController presents), while WebKit's background page view is the one Detour never touches.
2. Add a weak registry (ExtensionPageHostRegistry, NSHashTable.weakObjects) that those three sites register into; PolyfillSender.frame gains isDetourHosted, set in userContentController(didReceive:) from message.webView (nil web view fails closed).
3. senderIsBackgroundContext refuses a frame claim from a Detour-hosted view even at the background path; the log names the reason. Polyfill-side path classification stays (native gate is the authority).
4. Tests: unit tests of the gate with isDetourHosted true/false; wiring test through the production path: TabStore.addExtensionTab navigated to /_generated_background_page.html claims and is refused, the ledger stays pending, the real background page then receives the install; existing background/worker claim tests stay green. Drop the known-limit sentence from the TASK-64 doc comment.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Implemented: ExtensionPageHostRegistry (weak NSHashTable) registered from BrowserTab (webView didSet plus both inits, since observers do not run in init; covers addExtensionTab's plain WKWebView), OffscreenDocumentHost.load, and ExtensionPopoverController.presentPopupWebView. PolyfillSender.frame gains isDetourHosted (nil message.webView fails closed); senderIsBackgroundContext refuses a hosted frame before the path check. Tests: unit test over 4 manifest shapes (unhosted accepted, hosted refused); wiring test through TabStore.addExtensionTab navigated to /_generated_background_page.html (claim rejected, tab dispatched nothing, exactly one install recorded across the extension's contexts, so WebKit's background page got it); registry test (extension tab, ordinary tab, offscreen view registered; a fresh WKWebView not). Mutation-checked: removing the guard fails both. 'Ledger still pending before the wake' cannot be asserted because creating any extension web view starts the real background page, whose legitimate claim races; the end state is pinned instead. Full suite: 1129 tests, 0 failures.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A tab, popup, options page or offscreen document navigated to the background document path can no longer claim runtime.onInstalled: Detour registers every web view it creates or presents in ExtensionPageHostRegistry, and the claim gate refuses a frame from a registered view before the path check, leaving WebKit's own background page (the one view Detour never touches) as the only accepted frame sender. Verified with a unit test over all manifest shapes, a production-path wiring test, and a registry test; existing background/worker claim tests unchanged.
<!-- SECTION:FINAL_SUMMARY:END -->
