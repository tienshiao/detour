---
id: TASK-231.8
title: >-
  Memory safety: audit raw-pointer code and untrusted-byte parsing with strict
  memory safety checking
status: To Do
assignee: []
created_date: '2026-11-03T00:08:00Z'
labels:
  - concurrency
dependencies: []
references:
  - Detour/Extensions/Installer/CRX3Verifier.swift
  - Detour/Extensions/Installer/CRXUnpacker.swift
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
parent_task_id: TASK-231
priority: low
type: chore
ordinal: 275000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Independent of the concurrency work. Swift 6.2 added opt-in strict memory safety checking (SE-0458), which flags unsafe constructs. Ten files use raw pointers or unsafe casts. Two of them parse bytes from outside the app: CRX3Verifier / CRXUnpacker (extension packages downloaded from the store) and NativeMessagingHost (length-prefixed frames from another process). The others are AppDelegate, BrowserTab, TabStore, WebKitStorageScope, ExtensionOriginInteractionKeeper, WebInspectorControl and DevMode.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The strict memory safety warning count for the Detour target is measured and recorded
- [ ] #2 CRX parsing and native-messaging framing have no unchecked unsafe uses left: each is replaced by a bounds-checked equivalent or marked `unsafe` with a comment saying why it is in bounds
- [ ] #3 Tests cover malformed input on both paths: a CRX whose header lengths exceed the file, and a native message whose length prefix exceeds the data received
- [ ] #4 The task records whether the checking stays on for the whole target or was a one-time audit, and why
<!-- AC:END -->
