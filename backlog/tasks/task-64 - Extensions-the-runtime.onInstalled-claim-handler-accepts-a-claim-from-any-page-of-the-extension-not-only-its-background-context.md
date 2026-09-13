---
id: TASK-64
title: >-
  Extensions: the runtime.onInstalled claim handler accepts a claim from any
  page of the extension, not only its background context
status: To Do
assignee: []
created_date: '2026-09-13 20:03'
labels:
  - extensions
  - security
dependencies: []
priority: low
ordinal: 64000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the TASK-43 work. The polyfill claims the pending runtime.onInstalled event with __detourPolyfillRequest("runtime.claimInstalledEvent") from the background context only (service worker or, since TASK-43, the background page). The native side, ExtensionPolyfillHandler case "runtime.claimInstalledEvent" (~line 519), verifies only that the sender belongs to the extension (its origin), not that the sender IS the background context. An extension page (popup, options, any webkit-extension:// document) could call __detourPolyfillRequest("runtime.claimInstalledEvent", {}) directly and consume its own extension event, so the background context never receives install/update. This is intra-extension only (a page can only claim its own extension event) and no extension is known to do it; the polyfill never did before TASK-43 either. Hardening: for a page sender, check message.frameInfo.request.url path against the manifest background path (background.page resolved against the extension root, or the WebKit generated page name _generated_background_page.html for background.scripts; see the TASK-43 comments in ExtensionAPIPolyfill.runtimeOnInstalledJS); for a worker sender there is no frame, which is the accepted case today. Decide whether a refused claim should log and leave the ledger pending (so the background context still gets the event) rather than error to the caller.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A claim sent from an ordinary extension page (popup/options) is refused, logged, and leaves the ledger pending; the background context still receives the event afterwards
- [ ] #2 Claims from a service worker and from an MV3 background page (both background.scripts and background.page shapes) keep working; the existing RuntimeInstalledEvent and ExtensionPolyfillProfileWiringTests suites stay green
- [ ] #3 Tests cover the refused page claim (negative) and the accepted background claims (positive)
<!-- AC:END -->
