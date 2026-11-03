---
id: TASK-263
title: >-
  Extensions: the keep-alive port watch must not depend on WebKit firing a
  port's own onDisconnect
status: To Do
assignee: []
created_date: '2026-11-03T22:55:00Z'
labels:
  - extensions
  - native-messaging
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: medium
type: bug
ordinal: 307000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-256. The keep-alive port watch (watchPort / installPortWatch in ExtensionAPIPolyfill.swift) relies on WebKit firing a port's onDisconnect in the context that called port.disconnect() — a WebKit bug (WebExtensionAPIPort::disconnect calls fireDisconnectEventIfNeeded), fixed upstream 2026-10-30 (325256@main, bug 329433). Detour uses the system WebKit, so once a macOS update ships the fix, an already installed Detour stops re-anchoring when the background closes a runtime.connect / tabs.connect port itself; the closed port goes unseen until the next ping, bringing back the TASK-142 unload risk (1Password keep-alive). The watch should re-anchor after the caller's own disconnect whether or not WebKit fires the event, without double-anchoring today.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A port the background closes itself triggers a re-anchor both when WebKit fires the caller's onDisconnect (today) and when it does not (simulated: e.g. the watch wraps port.disconnect and the test suppresses the self-fired event), and re-anchoring stays idempotent (one anchor held)
- [ ] #2 The TASK-256 tests that pin the current WebKit behaviour stay, documented as expected to flip when the fix ships
- [ ] #3 NativeHostKeepAliveTests and the keep-alive legs of ExtensionPolyfillProfileWiringTests pass; the task records a signed-build 1Password check if behaviour changed
<!-- AC:END -->
