---
id: TASK-99
title: >-
  Extensions: give each context a stable base URL so extension storage survives
  a relaunch
status: Done
assignee:
  - '@claude'
created_date: 2026-09-20 18:51
updated_date: '2026-10-29T01:03:00Z'
labels:
  - extensions
  - webkit
  - bug
dependencies:
  - TASK-70
references:
  - Detour/Browser/Profile.swift
  - Detour/Extensions/Runtime/ExtensionOriginInteractionKeeper.swift
priority: medium
ordinal: 99000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-09-20 while closing TASK-70/TASK-90. Profile.loadExtensionContext sets context.uniqueIdentifier (Profile.swift:367) but never context.baseURL, so WebKit mints a fresh webkit-extension://<uuid>/ origin for every context load - i.e. on every launch and every reload/recovery. Storage is keyed by origin, so an extension's IndexedDB, localStorage and service-worker registration never survive a relaunch: 1Password logs '[Cache] The item cache has not been initialized yet' at every start and rebuilds its item cache per profile per launch. Evidence on disk (2026-09-20, ~/Library/WebKit/com.detourbrowser.mac): store b0e91083 holds extension origin 7fac7a34 (created Sep 19 12:38, 14 MB, previous launch, orphaned) next to 45332632 (created Sep 20 11:39:31, today's launch); store ca8c2b61 holds 7001c112 (Sep 19, 13 MB, orphaned) next to b5412e6a (today); the default store holds the Private profile's 7e17b0c8 (today). Each launch abandons the previous origin's data until something purges it.

WKWebExtensionContext.baseURL is settable before the context is loaded (public API; must be unique per context in a controller). Proposal: derive a stable webkit-extension://<uuid>/ per (profile, extension) - e.g. a UUIDv5 of profile id + extension id, or a persisted random UUID - and set it before load.

Design pass needed BEFORE implementing (invariant-heavy, Fable-level): code that currently assumes a new origin per load - retargetExtensionPages(from:to:) callers (Profile.swift:785, :862, ExtensionManager.swift:1423), recoverFromBackgroundLoadFailure, closeOffscreenDocument on unload, FaviconSchemeHandler grant/revoke by host, URL-keyed site-access grants (TASK-11), polyfill sender verification by base URL (TASK-10), ExtensionOriginInteractionKeeper (a stable origin keeps its ITP interaction record, which makes TASK-70/72 easier, but check the launch-time synchronous pass). Open questions: can a context with the same baseURL be loaded right after the old one is unloaded in the same controller (reload / recovery paths) or does WebKit reject it; does a stale service-worker registration from the previous launch start cleanly against the new context (and does that remove or reintroduce TASK-68-style worker kills); the Private profile's pages share the DEFAULT store (TASK-73), so its stable origin would persist extension data across private sessions - Private should probably keep a fresh origin per launch and have the old one's data removed; uninstall / removeData must clear the stable origin's data; one-time cleanup of origins orphaned by earlier launches.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Whether origin-keyed extension storage (IndexedDB, localStorage) survives an unload + load and a relaunch is established with a test and the production stores
- [x] #2 The cause of the 2026-09-20 orphaned origins is explained and whether they still accumulate is checked
- [x] #3 The wiki pages that describe origin-keyed storage are corrected
- [x] #4 The stable base URL is decided with the user
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-28 investigation: the premise does not hold since TASK-90 (extension pages on the profile's own store).
- WebKit WebExtensionContext::load (WebExtensionContextCocoa.mm, main): reads LastSeenBaseURL from the context's State.plist, writes the new base URL, then moveLocalStorageIfNeeded(lastSeenBaseURL) calls -[WKWebsiteDataStore _renameOrigin:to:forDataOfTypes:] for IndexedDB + LocalStorage on webViewConfiguration().websiteDataStore before the background starts. Cache Storage and the service worker registration are not moved.
- New test ExtensionOriginTrackingPreventionTests.testIndexedDBAndLocalStorageSurviveAnUnloadAndLoad: probe writes an IndexedDB marker and a localStorage value, unload, load (origin 93a13be9… → c6aa1939…), both read back. Passes on macOS 26.7 (25G229).
- Production (2026-10-28): app launched 10-26 19:28; stores b0e91083 and ca8c2b61 each hold exactly one webkit-extension origin (81c12ef6 / 91e12e3e), created 10-26 19:28, 26 MB / 24 MB of IndexedDB (+ LocalStorage), and both 1Password State.plists name that origin as LastSeenBaseURL. 1Password uses no Cache Storage.
- The 09-20 orphans: pages were on the default store until ccde7e1 (Sep 20), so the rename ran on another store than the profile store's origin. They are gone: WebKit's removeStaleExtensionWebsiteData removes webkit-extension origins no loaded context owns, once per controller (StaleExtensionOriginsCleared sentinel present in the controller directory).
- 1Password's 'item cache has not been initialized yet' at start is therefore not storage loss.
User decision 2026-10-28: close; no stable base URL. Wiki corrected (extensions/storage, data-store-and-itp, extension-pages).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Closed without a code change. Extension IndexedDB and localStorage already survive reloads and relaunches: WebKit renames the last-seen origin's data to each new base URL at load, and has since TASK-90 done so on the store the pages use. A new test proves it (write, unload, load under a new origin, read back), and the production stores show one carried 1Password origin each. The orphans that prompted the task predate TASK-90 and were swept by WebKit's one-time stale-origin cleanup. Cache Storage and worker registrations are not carried (1Password uses neither). The user chose not to implement a stable base URL. Wiki pages corrected.
<!-- SECTION:FINAL_SUMMARY:END -->
