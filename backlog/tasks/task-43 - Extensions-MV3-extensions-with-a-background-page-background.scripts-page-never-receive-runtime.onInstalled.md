---
id: TASK-43
title: >-
  Extensions: MV3 extensions with a background page (background.scripts/page)
  never receive runtime.onInstalled
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 05:14'
updated_date: '2026-09-13 19:36'
labels:
  - extensions
  - webkit
  - bug
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - Detour/Extensions/Model/ExtensionManifest.swift
priority: low
ordinal: 43000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the review of the TASK-22/TASK-29 commits. runtimeOnInstalledJS (ExtensionAPIPolyfill.swift) shadows chrome.runtime.onInstalled add/remove/hasListener in every extension context, and only a context where ServiceWorkerGlobalScope exists gets mode 'detour' and schedules a claim; every other context gets mode 'suppressed' and its captured listeners are never dispatched. ExtensionManager.installedEventOwingWake additionally requires manifest.background?.serviceWorker != nil, and ExtensionManifest.Background only decodes service_worker. ExtensionInstaller accepts any MV3 manifest, and WebKit runs an MV3 background.scripts / background.page (Safari-style, non-persistent) as a background page, so such an extension's background listener lands in the suppressed shadow, WebKit's own dispatch is hidden, and Detour never claims: the extension loses runtime.onInstalled entirely (before TASK-22 WebKit delivered it, if unreliably). Decide whether Detour supports MV3 background pages; if yes, treat 'has background content' (service worker OR scripts/page) as the claiming context both in the polyfill (identify the background page context, not just ServiceWorkerGlobalScope) and in installedEventOwingWake, decoding background.scripts/page in ExtensionManifest.Background; if no, have ExtensionInstaller reject or warn on such manifests so the silent loss cannot happen.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 An MV3 extension whose manifest declares background.scripts or background.page (no service_worker) receives exactly one runtime.onInstalled install in its background context on first run in a profile, and update after a version change, with a test in RuntimeInstalledEventTests / ExtensionPolyfillTests
- [x] #2 Extension pages (popup, options) still get mode 'suppressed' as TASK-29 measured
- [ ] #3 Or, if MV3 background pages are declared unsupported, ExtensionInstaller rejects such a manifest with a logged reason and a test covers it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Decision: Detour supports MV3 background pages (background.scripts / background.page). WebKit already runs them and ExtensionInstaller accepts them, so refusing would be a regression; the claiming context becomes "the background context" rather than "a service worker".
2. ExtensionManifest.Background decodes scripts ([String]?) and page (String?) alongside service_worker; add hasBackgroundContent (any of the three).
3. Polyfill runtimeOnInstalledJS: identify the background page context outside workers. Detour knows the manifest, so inject the background page path (manifest background.page, or WebKit generated page name for background.scripts — find the actual URL WebKit gives it by loading a test extension and logging location.href from the background) into the polyfill as a placeholder, and treat typeof ServiceWorkerGlobalScope !== undefined OR location.pathname == that path as the claiming context (mode detour). Ordinary extension pages stay suppressed.
4. ExtensionManager.installedEventOwingWake: require manifest.background?.hasBackgroundContent instead of serviceWorker != nil.
5. Tests: manifest decoding for scripts/page; a TestExtensions fixture with background.scripts whose listener records runtime.onInstalled into storage; an integration test (pattern: ExtensionPolyfillProfileWiringTests / RuntimeInstalledEvent tests) asserting the background page receives install once and an ordinary extension page does not; the API Explorer extension is unaffected (service worker).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision: MV3 background pages are supported. Measured: background.scripts runs at webkit-extension://<uuid>/_generated_background_page.html and background.page at its own path; hasBackgroundContent true, the polyfill user script reaches them, and before the fix they came up suppressed. Fix: ExtensionManifest.Background decodes scripts/page with hasBackgroundContent; the polyfill computes a shared context kind (worker / background-page / page) from the manifest and location, and runtime.onInstalled claims in a background page after DOMContentLoaded; installedEventOwingWake requires hasBackgroundContent. Review pass (ceda589): background.page resolved against the extension root so "./bg.html" matches; the content polyfill bridge also installs in a background page. Tests live in ExtensionPolyfillProfileWiringTests (the only suite loading a real context through Profile): install once per shape, update after a version change, iframe of the background path stays suppressed; ExtensionManifestTests decoding. AC #3 not applicable. Follow-ups not filed: the native claim handler checks only the sender origin, not that it is the background context; the WebSocket relay and native-port keep-alive remain worker-only (TASK-62 filed by the review for the keep-alive).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
MV3 extensions with background.scripts or background.page now receive runtime.onInstalled in their background page exactly once per install/update, and ordinary pages stay suppressed. Verified by ExtensionPolyfillProfileWiringTests, RuntimeInstalledEventTests and ExtensionManifestTests.
<!-- SECTION:FINAL_SUMMARY:END -->
