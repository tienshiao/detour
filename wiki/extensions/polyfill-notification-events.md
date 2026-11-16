---
type: Feature
title: Notification events
description: How notifications.onClicked and onClosed reach the creating extension's background through a parked request, what fires for a click, a dismissal or a clear, and how the manager stays in step with Notification Center.
tags: [extensions, polyfill, notifications, events]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: notification-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionNotificationManager.swift
    title: ExtensionNotificationManager.swift
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: task-247
    resource: backlog:TASK-247
    title: "Extensions: notifications.onClicked and onClosed are never delivered to the extension"
  - id: task-264
    resource: backlog:TASK-264
    title: "Extensions: a Private-profile extension stops receiving notifications.onClicked and onClosed once a Private session starts or ends"
  - id: task-270
    resource: backlog:TASK-270
    title: "Extensions: revoking the notifications permission leaves the extension's notifications and event wait in place"
  - id: task-272
    resource: backlog:TASK-272
    title: "Extensions: notification entries outlive the banner when macOS takes it away without a dismiss"
  - id: task-298
    resource: backlog:TASK-298
    title: TASK-298 (the Private profile is reset when a Private session ends)
  - id: task-310
    resource: backlog:TASK-310
    title: TASK-310 (the Private-worker notification test across a session end)
  - id: chromium-mac-notification-service
    resource: https://source.chromium.org/chromium/chromium/src/+/main:chrome/services/mac_notifications/mac_notification_service_un.mm
    title: "Chromium: mac_notification_service_un.mm (shouldPreventNotificationDismissalAfterDefaultAction, SynchronizeNotifications), chrome/browser/notifications/mac/notification_utils.cc (by_user)"
  - id: chromium-notifications-clear
    resource: https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/extensions/api/notifications/
    title: "Chromium: notifications_api.cc (clear), extension_notification_handler.cc (OnClose), notification_ui_manager_impl.cc (CancelById)"
  - id: notification-event-tests
    resource: ../../DetourTests/ExtensionNotificationEventTests.swift
    title: ExtensionNotificationEventTests.swift (ExtensionNotificationEventManagerTests, ExtensionNotificationEventDeliveryTests)
---
`notifications.onClicked` and `onClosed` fire in the background context of the
owner (profile and extension) whose notification it was, and nowhere
else.[^task-247] There is no push channel into a context (see the
[polyfill layer's gotchas](./polyfill-layer.md#gotchas)), so the
first `addListener` on either parks a `notifications.awaitEvent` request,
which the manager answers with the owner's unacknowledged events
`{events: [{seq, kind, notificationId, byUser?}]}`. The polyfill dispatches
them in order and parks again with `ack` = the last `seq`.

# What fires

| Event | Fires |
|---|---|
| Click on the banner (`UNNotificationDefaultActionIdentifier`) | `onClicked(id)`, then `onClosed(id, true)`, in one answer; the entry goes (macOS takes a clicked banner away) |
| User dismisses it (`UNNotificationDismissActionIdentifier`) | `onClosed(id, true)`; the entry goes, so `clear`/`update` answer false and `getAll` leaves it out |
| The center stops listing it without a report (Clear All?, system pruning) | `onClosed(id, true)` at the next synchronization; the entry goes |
| The extension's `clear` finds it | `onClosed(id, false)` |
| Unload of the extension, end of the profile or Private session, not-allowed or failed add | nothing |

- **Chrome's clear fires `onClosed(byUser false)`.** `notifications.clear` →
  `ExtensionNotificationDisplayHelper::Close` → the display service →
  `NotificationUIManagerImpl::CancelById` → `MessageCenter::RemoveNotification(id,
  /* by_user */ false)` → `ExtensionNotificationHandler::OnClose`, which sends
  `onClosed` with `by_user`.[^chromium-notifications-clear] That is the
  message-center path; Chrome's native macOS bridge was not traced.
- `onButtonClicked` still never fires: buttons are not shown.

# How the park works

- **Acknowledged, not answered.** An event stays in the per-owner backlog
  (at most 32, oldest dropped) until a park acknowledges it. A parked reply
  whose worker WebKit has unloaded goes nowhere and nothing says so; the next
  incarnation's first park acknowledges nothing and receives the events again.
  The polyfill skips a `seq` it has already dispatched.
- **The park keeps nothing alive.** It is a pending `runtime.sendNativeMessage`,
  not a port or a permission request, so WebKit's idle unload ignores it.
  Measured: a worker parked and left alone was replaced by a new incarnation
  within 45 s (the gated leg `testAClickAfterTheWorkerUnloadsWakesItAndIsDelivered`,
  `TEST_RUNNER_NOTIFICATION_UNLOAD_LEG=1`). So parking for every listening
  extension is safe, and parking only while it has live notifications was
  not needed.
- **An event wakes the background.** Once an owner has parked this launch, each
  event calls `loadBackgroundContent` on its context (a no-op while it is
  loaded), as Chrome starts a worker for an event it listens to. The new
  worker's top-level `addListener` parks and drains the backlog. An owner
  that never parked is never woken; its events wait in the backlog.
- **A newer incarnation supersedes.** The park carries `__detourContextInstance`.
  A token not seen before settles the parked request with "superseded" and
  takes its place; from then on an older token is refused, so an old worker
  still running beside its replacement (`runtime.reload()`) cannot take the
  park back and ping-pong.
- **Background only.** The handler refuses `awaitEvent` from any sender that
  fails `senderIsBackgroundContext`. Chrome fires these events in every
  context with a listener; Detour does not deliver them to popups, options
  pages or extension tabs. A page's park would need its own slot per page
  instance and nothing tells the manager a page closed, so dead pages'
  replies would pile up; extensions handle clicks in the background in
  practice. Rejected for now, not ruled out.
- **A refused wait stops, with one exception.** A refusal for "not the
  background", "superseded", "unloaded" or "profile gone" is final for that
  context. A refusal for the permission (an optional `notifications` not yet
  granted) is retried at the next `create`/`update`/`clear`/`getAll` while a
  listener exists, so the grant does not leave the worker deaf until restart.

# When the owner's scope changes

- **A Private session starting leaves the park standing.** The Private
  profile's contexts stay loaded when a session starts, so the start
  (`removeSession(profileID:)`) takes the notifications and the events
  queued for them but keeps each owner's park, incarnation history and
  "listens" flag. A session *ending* does that too, then (since TASK-298)
  resets the Private profile: each context is unloaded through
  `Profile.unloadExtension`, whose `removeAll(for:)` answers the old
  worker's park "unloaded" and forgets its channel, its data is cleared,
  and those still allowed in Private are loaded again on a fresh origin.
  The reloaded worker, a new incarnation, parks afresh, so later events
  reach it
  (`ExtensionNotificationEventDeliveryTests.testAPrivateWorkerHearsEventsAfterTheSessionStartsAndInItsReloadAfterItEnds`;
  TASK-310 found the test still expecting one incarnation across the
  end).[^task-298] [^task-310] Only unloading the extension
  (`removeAll(for:)`, the path that reset takes) and deleting the profile
  (`removeAll(profileID:)`) answer the park "unloaded" and forget the
  channel. Before TASK-264 both boundaries used `removeAll(profileID:)`:
  the live worker took "unloaded" as final, never parked again, and every
  later click and close waited unheard in the backlog until WebKit
  restarted it.[^task-264]
- **Losing the permission answers the park with the refusal.** When
  `notifications` stops being active for an extension in a profile (the
  Settings switch off, a prompt answered Deny, or the extension's own
  `permissions.remove` of the optional permission), its notifications there
  go, with their queued events, and the park is answered with the handler's
  permission refusal ("denied by the user" or "is optional and has not been
  granted"), which the polyfill retries after a later grant. "Unloaded" would
  have stopped the worker for good. The incarnation history stays, so the
  same worker's re-park is accepted. Before TASK-270 nothing happened: the
  banners stayed, a click on one still fired `onClicked` through the park
  admitted before the revocation, and the extension could not `clear` them
  (refused for the permission). No `onClosed` fires for the notifications
  taken away: the extension no longer holds the permission whose events those
  are.[^task-270]

What else takes an owner's notifications away, and from where, is in the
lifetime table on [notification ownership](./polyfill-notification-scope.md#an-owners-notifications-go-with-its-scope).

# Keeping in step with Notification Center

- **Dismissals need a category.** Every notification carries the
  `detour-ext-notification` category with `.customDismissAction`
  (`ExtensionNotificationManager.dismissCategory`); without it macOS never
  reports a dismissal. The system center registers it alongside any other
  category (`setNotificationCategories` replaces the set). The registration
  is awaited before the first authorization check, so no banner is shown
  before its category exists.
- **The banner going ends the notification.** macOS removes a banner when
  its default action is clicked; Chrome keeps its own only by setting the
  private `shouldPreventNotificationDismissalAfterDefaultAction` on the
  content,[^chromium-mac-notification-service] which Detour does not. Before
  TASK-272 a click kept the entry, so an extension using `create(null, …)`
  that never cleared grew the entries all session, `getAll` listed banners
  no longer shown, and a later `update` brought the banner back. A click now
  drops the entry, asks the center to remove the identifier too (should
  macOS ever keep the banner, nothing could clear it otherwise), and fires
  `onClicked` then `onClosed(byUser true)`: what
  Chrome reports when a notification leaves Notification Center without a
  dismissal (its `SynchronizeNotifications` turns every such one into a
  close, and every macOS close reaches the extension with `by_user`
  true).[^task-272] An update whose `add` is in flight when the click comes
  finds no entry when it lands and takes the banner it re-showed away, as
  after a clear during the `add`; it still answers `wasUpdated: true`.
- **Synchronization catches the rest.** `synchronizeWithCenter()` lists the
  center's delivered and pending identifiers and closes (`onClosed(byUser
  true)`, entry dropped, identifier removed from the center in case the
  listing missed it) every entry it does not list, like Chrome's
  `SynchronizeNotifications`. Pending is listed before delivered: a request
  only moves from pending to delivered, so one moving between the two calls
  is still seen. It runs at every `create` (coalesced, and at most once per
  5 s, so an extension that never clears cannot outgrow what is on screen
  and one re-creating a progress notification does not list usernoted at
  every call) and every 10 minutes (Chrome's `kSynchronizationInterval`)
  while there are entries.
  Only entries whose own `add` succeeded at least 5 s ago are checked: the
  center may list a notification a moment after `add` answers, and an entry
  with an `add` in flight (an update over a banner the center lost) shows
  it again, as Chrome skips pending content. An entry cleared, clicked,
  replaced or removed with its owner while the listing was in flight is
  skipped, so a revoked owner gets no `onClosed`. The clock is injectable
  (`now`).
- **What "Clear All" reports was not measured.** Producing a real banner
  from a Debug build needs notification authorization for
  `com.detourbrowser.mac`, which on the development Mac was still
  undetermined (no usernoted records for it); answering that prompt also
  sets the installed app's permission, which is the user's decision, and
  Clear All would have to be driven in the Notification Center the running
  production Detour shares. The design holds either way: a reported
  dismissal closes through `handleResponse`, an unreported one at the next
  synchronization. Chrome polling at all suggests some removals go
  unreported.

# Tests

The manager-level behaviour is in `ExtensionNotificationEventManagerTests`, the
real-worker behaviour (profile isolation, byUser, backlog before the park,
`runtime.reload()` superseding, a Private worker hearing events across session
boundaries, the Settings switch and `permissions.remove` taking the
notifications and the wait) in `ExtensionNotificationEventDeliveryTests`.
Both classes are in
[ExtensionNotificationEventTests.swift](../../DetourTests/ExtensionNotificationEventTests.swift).

# Related

- [chrome.notifications](./polyfill-notifications.md) — the calls whose notifications these events report on.
- [Notification ownership](./polyfill-notification-scope.md) — owners and the identifiers `handleResponse` resolves.
- [Updates](./updates.md) — `onUpdateAvailable`, the other event delivered through a parked request.
- [Service worker unload rules](../platform/service-worker-unload-rules.md) — why a pending native message keeps nothing alive.
- [Permissions](./permissions.md#permissions-the-polyfill-gates) — the refusal a park is answered with when the permission goes.

[^task-247]: Extensions: notifications.onClicked and onClosed are never delivered to the extension
[^chromium-notifications-clear]: Chromium: notifications_api.cc (clear), extension_notification_handler.cc (OnClose), notification_ui_manager_impl.cc (CancelById)
[^task-298]: TASK-298 (the Private profile is reset when a Private session ends)
[^task-310]: TASK-310 (the Private-worker notification test across a session end)
[^task-264]: Extensions: a Private-profile extension stops receiving notifications.onClicked and onClosed once a Private session starts or ends
[^task-270]: Extensions: revoking the notifications permission leaves the extension's notifications and event wait in place
[^chromium-mac-notification-service]: Chromium: mac_notification_service_un.mm (shouldPreventNotificationDismissalAfterDefaultAction, SynchronizeNotifications), chrome/browser/notifications/mac/notification_utils.cc (by_user)
[^task-272]: Extensions: notification entries outlive the banner when macOS takes it away without a dismiss
