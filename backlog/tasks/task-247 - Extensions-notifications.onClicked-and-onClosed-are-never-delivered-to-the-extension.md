---
id: TASK-247
title: >-
  Extensions: notifications.onClicked and onClosed are never delivered to the
  extension
status: To Do
assignee: []
created_date: '2026-11-03T08:18:00Z'
labels:
  - extensions
dependencies:
  - TASK-238
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 291000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-238. The polyfill has __extensionDispatchNotificationClicked/Closed hooks, but nothing native calls them: there is no push channel into an extension context (wiki polyfill-layer.md, Gotchas). ExtensionNotificationManager.handleResponse resolves a click or close to its (profile, extension, notification id) owner since TASK-238, and nothing consumes that. Extensions that act on a click (open a tab, focus a conversation) do nothing in Detour. Design sketched in TASK-238: the background polyfill parks a notifications.awaitEvent request per worker incarnation (like runtime.awaitUpdateAvailable, only from a sender passing senderIsBackgroundContext); the manager keeps parked replies per owner and answers with {kind, notificationId, byUser}; events while nothing is parked go to a bounded per-owner backlog drained on the next park; a newer incarnation supersedes the old park. Open: whether a pending reply keeps the worker alive (WebKit 30 s unload timer, 2-minute background-post activity rule).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Clicking a notification fires notifications.onClicked with its id in the creating profile's extension, and only there
- [ ] #2 Closing or dismissing it fires onClosed with byUser set correctly
- [ ] #3 An event that arrives while the worker is unloaded is delivered once it starts again, or the task records why it is dropped
- [ ] #4 Real-extension-context tests cover delivery, profile isolation and a worker restart
<!-- AC:END -->
