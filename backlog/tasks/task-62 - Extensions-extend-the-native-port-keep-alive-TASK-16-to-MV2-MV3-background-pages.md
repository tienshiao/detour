---
id: TASK-62
title: >-
  Extensions: extend the native-port keep-alive (TASK-16) to MV2/MV3 background
  pages
status: To Do
assignee: []
created_date: '2026-09-13 19:25'
labels: []
dependencies: []
ordinal: 62000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
TASK-43 made the polyfill recognise a background page (MV2, or MV3 background.scripts/page) as the extension's background context (g.__detourContextKind === 'background-page'), and the content-script bridge now installs there. nativePortKeepAliveJS still gates on ServiceWorkerGlobalScope, so a background-page extension with nativeMessaging gets no keep-alive and WebKit unloads its non-persistent page like the bug TASK-16 fixed for workers. The keep-alive premise (WebKit counts the worker's pings as background activity that defers the unload) was measured for workers only, and a persistent MV2 page needs no keep-alive at all — so this needs measurement before the gate is relaxed. Found in the review of e912d33..1e26a52.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Measured: whether WebKit unloads a non-persistent background page with an open native port, and whether the keep-alive pings defer it
- [ ] #2 nativePortKeepAliveJS installs in a non-persistent background page with nativeMessaging permission (and records why not otherwise) based on the measurement; a persistent MV2 page is skipped
- [ ] #3 ExtensionPolyfillProfileWiringTests cover the background-page install decision; the API Explorer shows the keep-alive status for its context kind
<!-- AC:END -->
