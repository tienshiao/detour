---
id: TASK-18
title: >-
  Extensions: offscreen.createDocument must reply and unregister its host when
  the offscreen page fails to load
status: To Do
assignee: []
created_date: '2026-09-12 07:32'
labels:
  - extensions
dependencies: []
priority: low
ordinal: 18000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
ExtensionPolyfillHandler registers the OffscreenDocumentHost in offscreenHosts before loading, and its replyHandler is only invoked from OffscreenDocumentHost's didFinish or stop(). didFail and didFailProvisionalNavigation only log, so when the offscreen page 404s or is blocked the extension's createDocument promise pends forever, every later createDocument short-circuits with success because the dead host is still registered, and offscreen.hasDocument reports true for a document that never loaded, until an explicit closeDocument. Found by the 2026-09-12 code review of TASK-13 (pre-existing).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A failed offscreen page load (404 or blocked navigation) rejects the createDocument request with an error
- [ ] #2 The failed host is removed from offscreenHosts so hasDocument returns false and a retry loads again
- [ ] #3 Tests cover the failure path through handleNativeMessage with a missing offscreen page, plus the existing success path
<!-- AC:END -->
