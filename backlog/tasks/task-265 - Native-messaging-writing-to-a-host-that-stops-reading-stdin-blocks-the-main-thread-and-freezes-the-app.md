---
id: TASK-265
title: >-
  Native messaging: writing to a host that stops reading stdin blocks the main
  thread and freezes the app
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/NativeMessagingHost.swift
  - Detour/Extensions/Runtime/ExtensionManager.swift
  - wiki/extensions/native-messaging.md
priority: medium
type: bug
ordinal: 312000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`NativeMessagingHost.sendMessage` writes the framed message with a blocking `fileHandleForWriting.write(contentsOf:)` (NativeMessagingHost.swift ~290), called on the main actor from both the one-shot path and the port `messageHandler` (ExtensionManager.swift ~3216-3224). A host that is busy or wedged and stops draining stdin, plus an extension posting more than the pipe buffer (~64 KB, up to the 1 MB cap), blocks the main thread inside `write`: the UI freezes, and a normal quit hangs too because `applicationWillTerminate` cannot run (only the SIGTERM path still ends hosts). TASK-242 widened what reaches this path (any JSON value on ports).

Related: the port path uses `try?`, so `messageTooLarge` / `invalidMessage` are dropped without a word to the extension or the log. The browser-to-host cap is 1 MB "in both directions"; Chrome allows much larger browser-to-host messages (64 MiB in current docs). Decide whether to raise it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A host that never reads stdin while the extension posts several MB does not block the main thread: the UI stays responsive and a normal quit completes
- [ ] #2 Messages to one host keep their order
- [ ] #3 A port message that cannot be sent (too large, not encodable, host gone) is logged and the extension learns of it (port disconnect with an error, or Chrome's behaviour, recorded in the task)
- [ ] #4 The browser-to-host size limit is a deliberate value with its reason recorded in the wiki native-messaging page
- [ ] #5 Tests cover a non-reading fake host with a large message
<!-- AC:END -->
