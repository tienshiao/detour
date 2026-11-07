---
id: TASK-264
title: >-
  Extensions: a Private-profile extension stops receiving
  notifications.onClicked and onClosed once a Private session starts or ends
status: To Do
assignee: []
created_date: '2026-11-07T00:12:00Z'
labels:
  - extensions
  - notifications
  - private
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
  - Detour/Browser/TabStore.swift
  - Detour/Extensions/Runtime/ExtensionAPIPolyfill.swift
priority: medium
type: bug
ordinal: 311000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`TabStore.startPrivateSessionIfNeeded` and `endPrivateSessionIfUnused` (TabStore.swift ~2584-2607) call `removePrivateProfileNotifications`, which reaches `ExtensionNotificationManager.removeAll(profileID:)`. That also runs `dropEventChannels`, answering the worker's parked `notifications.awaitEvent` with "notifications: the extension was unloaded" (ExtensionNotificationManager.swift ~547-550, ~718-724).

The Private profile's extension contexts stay loaded between sessions (the comment on `startPrivateSessionIfNeeded` says so), so the worker is still alive. The polyfill's park loop (ExtensionAPIPolyfill.swift ~2519-2524) only re-arms after a refusal that matches the permission regex; the "unloaded" text sets `stopped = 'final'`, so the worker never parks again. The channel is recreated with `listens = false`, so later clicks and closes pile up in the backlog unseen until WebKit restarts the worker.

Effect: an extension allowed in Private loses every click/close event from the first Private window it opens. `testRemovingTheOwnerDropsItsChannel` only covers `removeAll(profileID:)` as "the profile is gone"; nothing covers a session boundary with a live worker.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 After a Private session boundary (start or end) with the extension's worker still loaded, a click on a notification created afterwards reaches the worker's onClicked, and a dismiss reaches onClosed
- [ ] #2 The session boundary still removes every Private-profile notification (delivered and pending) and the events queued for them, as TASK-238 requires
- [ ] #3 Unloading the extension from the profile, and removing the profile, still answer the parked wait so the context stops waiting
- [ ] #4 Tests cover a session boundary with a parked worker against the fake notification center
<!-- AC:END -->
