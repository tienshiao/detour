---
id: TASK-232
title: >-
  Native messaging: a host that writes its reply and exits at once can have the
  exit handled before the reply
status: To Do
assignee: []
created_date: '2026-11-03T03:00:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
priority: low
type: bug
ordinal: 276000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-231.4, not fixed there (pre-existing). NativeMessagingHost reports a host exit from Process.terminationHandler, on its own thread, with no ordering against the stdout read loop. A host that writes its response and exits with status 0 straight away (a one-shot runtime.sendNativeMessage host) can have handleDisconnect queued before the read loop has read the frame still in the pipe: onDisconnect fires first, the request settles with "Native host has exited", and the real reply is dropped or reaches onMessage after the request settled. On the port path, onMessage can call port.sendMessage after port.disconnect. Disconnects the read loop itself reports are already ordered after the messages it read (TASK-231.4). Any change here touches the 1Password host path and needs a signed-build check.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A reply the host wrote before exiting is delivered before the disconnect, for both one-shot sendNativeMessage and connectNative ports
- [ ] #2 A test with the fake native host that writes one reply and exits immediately fails before the change and passes after it
- [ ] #3 The task records a signed-build check with 1Password (connect, unlock, autofill) after the change
<!-- AC:END -->
