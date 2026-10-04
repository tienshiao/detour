---
id: TASK-146
title: >-
  Extensions: polyfilled idle, notifications and history events accept listeners
  but never fire
status: To Do
assignee: []
created_date: '2026-10-04 02:29'
labels: []
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
  - Detour/Extensions/Runtime/IdleMonitor.swift
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - wiki/extensions/polyfill-layer.md
priority: medium
ordinal: 169000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The polyfill (Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift) defines dispatch hooks __extensionDispatchIdleStateChanged, __extensionDispatchNotificationClicked, __extensionDispatchNotificationClosed, __extensionDispatchNotificationButtonClicked and __extensionDispatchHistoryEvent, and exposes chrome.idle.onStateChanged, chrome.notifications.onClicked / onClosed / onButtonClicked and chrome.history.on* with addListener. No Swift code calls any of those hooks: IdleMonitor.dispatchStateChanged only logs (its comment assumes WebKit dispatches the event), and ExtensionNotificationManager's UNUserNotificationCenter delegate only logs clicks and closes. chrome.management.on* likewise accepts listeners with nothing behind it. An extension that relies on these events registers successfully and then waits for ever, with no error.

Read from the code while writing wiki/extensions/polyfill-layer.md; not observed from extension JS. Check first whether WebKit dispatches any of them natively (the IdleMonitor comment suggests that was the hope).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 For each of the events the task records whether WebKit delivers it natively; an event nobody delivers is either dispatched by Detour or not exposed, so no listener is silently dead
- [ ] #2 idle.onStateChanged fires on a state change for an extension that set a detection interval; notifications.onClicked, onClosed and onButtonClicked fire for the extension that created the notification and for no other
- [ ] #3 Tests in a real extension context cover delivery from the native side to a service worker listener, permission gating, and isolation between extensions and profiles, per the CLAUDE.md extension-API rules; history events are scoped to the profile (see TASK-138)
- [ ] #4 The API Explorer extension and wiki/extensions/polyfill-layer.md are updated
<!-- AC:END -->
