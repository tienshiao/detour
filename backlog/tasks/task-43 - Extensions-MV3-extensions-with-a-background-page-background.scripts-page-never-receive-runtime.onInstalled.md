---
id: TASK-43
title: >-
  Extensions: MV3 extensions with a background page (background.scripts/page)
  never receive runtime.onInstalled
status: To Do
assignee: []
created_date: '2026-09-13 05:14'
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
- [ ] #1 An MV3 extension whose manifest declares background.scripts or background.page (no service_worker) receives exactly one runtime.onInstalled install in its background context on first run in a profile, and update after a version change, with a test in RuntimeInstalledEventTests / ExtensionPolyfillTests
- [ ] #2 Extension pages (popup, options) still get mode 'suppressed' as TASK-29 measured
- [ ] #3 Or, if MV3 background pages are declared unsupported, ExtensionInstaller rejects such a manifest with a logged reason and a test covers it
<!-- AC:END -->
