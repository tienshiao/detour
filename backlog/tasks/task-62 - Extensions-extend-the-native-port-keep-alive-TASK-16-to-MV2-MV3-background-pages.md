---
id: TASK-62
title: >-
  Extensions: extend the native-port keep-alive (TASK-16) to MV2/MV3 background
  pages
status: In Progress
assignee:
  - '@claude'
created_date: '2026-09-13 19:25'
updated_date: '2026-09-13 22:03'
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

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Measure in ExtensionPolyfillProfileWiringTests with a background.scripts extension declaring nativeMessaging, a fake native host (the NativeMessagingEnforcementTests fixture: DETOUR_NATIVE_MESSAGING_HOSTS_DIR + a script that execs sleep), and the TASK-43 localStorage loads counter: (a) idle non-persistent background page with no port: is it unloaded after WebKit's 30 s idle rule; (b) with an open native port and no traffic: unloaded on the 2-minute inactive-ports rule; (c) with the keep-alive pings on the detourPolyfill port (shortened interval via __detourKeepAlivePingIntervalMs): does the page stay loaded past the point (b) unloaded. Record the numbers.
2. Based on the measurement, relax the nativePortKeepAliveJS gate from ServiceWorkerGlobalScope to 'worker or non-persistent background page' using g.__detourContextKind === 'background-page' and the manifest (an MV2 page with persistent !== false is skipped, installDetail 'persistent-background-page'; a non-background page stays 'not-a-worker' → rename the detail to 'not-a-background-context'). If the pings do not defer a page unload, keep the gate and record why in installDetail and the task.
3. Tests: wiring tests for the install decision per context kind (worker, non-persistent scripts page, persistent MV2 page, ordinary page); API Explorer's keep-alive probe reports contextKind alongside installMode/installDetail.
4. Update the doc comment above nativePortKeepAliveJS and docs/1password-integration-plan.md's TASK-16 notes with the page measurement.
<!-- SECTION:PLAN:END -->
