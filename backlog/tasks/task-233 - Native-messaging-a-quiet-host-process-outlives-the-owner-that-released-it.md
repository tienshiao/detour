---
id: TASK-233
title: 'Native messaging: a quiet host process outlives the owner that released it'
status: To Do
assignee: []
created_date: '2026-11-03T03:00:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
priority: low
type: bug
ordinal: 277000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-231.4 (pre-existing). NativeMessagingHost's stdout read loop runs `while let self, self.isConnected`, so it holds the host strongly for the whole iteration, including the blocking readData(ofLength:). When the owner drops the host (a one-shot request settling and removing its activeMessagingHosts entry) while the host process is alive and silent, deinit does not run, disconnect() is never called, and the host keeps running as a child of Detour until it exits on its own. Owners must call disconnect() explicitly today; the isolated deinit only covers the case where the read loop is not blocked.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Releasing a host whose process is alive and silent terminates the process (or every owner provably calls disconnect first, with the deinit no longer relied on)
- [ ] #2 A test with a fake host that stays alive after answering shows the process gone after the owner releases it
- [ ] #3 The task records a signed-build check with 1Password after the change
<!-- AC:END -->
