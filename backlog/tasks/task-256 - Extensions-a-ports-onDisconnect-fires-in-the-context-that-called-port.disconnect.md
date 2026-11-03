---
id: TASK-256
title: >-
  Extensions: a port's onDisconnect fires in the context that called
  port.disconnect()
status: To Do
assignee: []
created_date: '2026-11-03T17:25:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: low
type: bug
ordinal: 300000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Noticed during TASK-241 runtime verification: an extension page that calls port.disconnect() on its connectNative port also gets that port's onDisconnect. In Chrome onDisconnect fires only on the other end, never for the caller's own disconnect. Whether this is Detour's polyfill/native port code or WebKit's runtime.Port is unknown. Extensions that reconnect in onDisconnect (common for native hosts) can loop.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Whether the event comes from Detour's code or WebKit's is recorded
- [ ] #2 If it is Detour's, a port that calls disconnect() itself no longer gets onDisconnect, for native ports and runtime.connect ports, with real-context tests; if WebKit's, the behaviour and any workaround are recorded
<!-- AC:END -->
