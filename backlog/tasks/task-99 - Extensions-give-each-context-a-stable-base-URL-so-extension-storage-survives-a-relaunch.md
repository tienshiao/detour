---
id: TASK-99
title: >-
  Extensions: give each context a stable base URL so extension storage survives
  a relaunch
status: To Do
assignee: []
created_date: '2026-09-20 18:51'
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
- [ ] #1 Every persistent profile's extension context loads with the same base URL across launches and across reload/recovery within a launch; a test asserts stability and per-(profile, extension) uniqueness
- [ ] #2 A probe extension's IndexedDB and localStorage values written in one context load are readable after unload + load (test), and 1Password's item cache is warm on restart in the signed build
- [ ] #3 Reload, background-load recovery, enable/disable and uninstall still work with a stable origin: open extension pages keep working or are retargeted as designed, the offscreen document, favicon permission, site-access grants and sender verification behave as before (existing suites plus new cases)
- [ ] #4 The Private profile's extension storage does not persist across private sessions (decision recorded; coordinated with TASK-73)
- [ ] #5 Extension-origin data orphaned by earlier launches is removed from the profile stores and the default store, and uninstall with removeData clears the stable origin's data
<!-- AC:END -->
