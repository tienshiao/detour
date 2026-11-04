---
id: TASK-247
title: >-
  Extensions: notifications.onClicked and onClosed are never delivered to the
  extension
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T08:18:00Z'
updated_date: '2026-11-03T23:43:00Z'
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
- [x] #1 Clicking a notification fires notifications.onClicked with its id in the creating profile's extension, and only there
- [x] #2 Closing or dismissing it fires onClosed with byUser set correctly
- [x] #3 An event that arrives while the worker is unloaded is delivered once it starts again, or the task records why it is dropped
- [x] #4 Real-extension-context tests cover delivery, profile isolation and a worker restart
- [x] #5 A banner the user dismisses reaches the manager (a dismiss-action category is registered), so its entry is dropped: clear and update answer false and getAll no longer lists it
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Manager: per-owner event channel (parked reply + instance order, bounded backlog of seq-numbered events kept until acked); awaitEvent(owner, instance, ack); handleResponse and clear deliver {kind, notificationId, byUser}; a newer incarnation supersedes the old park and the old one can no longer park; removeAll drops channels; wake the owner's background (loadBackgroundContent) on an event once it has listened.
2. Dismiss category with .customDismissAction registered by the system center; content carries its identifier.
3. Handler: notifications.awaitEvent, gated on the permission and senderIsBackgroundContext.
4. Polyfill: onClicked/onClosed addListener parks, dispatches events in order, re-parks with ack.
5. Tests: manager-level (bound, supersession, ack, wake, clear/dismiss byUser) and real-context (click only in creating profile, close/dismiss byUser, backlog before park, runtime.reload restart, gated real-unload leg).
6. Wiki (polyfill-layer, unload rules), API Explorer note, review, verify, suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Design as built: the manager keeps one event channel per owner (profile, extension): the parked awaitEvent reply, a backlog of seq-numbered events (max 32, oldest dropped) kept until a park acknowledges them (ack = last seq), the incarnation tokens seen (a new token supersedes the park; an older token is refused for good, so an old worker beside its replacement cannot ping-pong), and whether it ever listened. An event wakes the background (loadBackgroundContent) once the owner has listened. Reply shape {events: [{seq, kind, notificationId, byUser?}]} instead of one event, so a backlog drains in one answer.
Open question answered: the parked request does NOT keep the worker alive (a pending runtime.sendNativeMessage is not a port or a permission request). Measured in the gated leg testAClickAfterTheWorkerUnloadsWakesItAndIsDelivered (TEST_RUNNER_NOTIFICATION_UNLOAD_LEG=1, passed: new incarnation within 45 s) and in the /verify harness (unloaded within 50 s idle). So parking for every listening extension leaves worker lifetime unchanged; parking only while notifications are live was not needed.
Chrome: clear fires onClosed(byUser false), traced on the message-center path (notifications_api.cc Clear -> ExtensionNotificationDisplayHelper::Close -> NotificationUIManagerImpl::CancelById -> MessageCenter::RemoveNotification(by_user false) -> ExtensionNotificationHandler::OnClose). Chrome's native macOS bridge was not traced.
Pages: decided background only. A page park would need a slot per page instance and nothing tells the manager a page closed, so dead pages' replies would pile up; the handler refuses awaitEvent from senders failing senderIsBackgroundContext. Recorded in the polyfill-layer wiki.
Dismiss: every notification carries category detour-ext-notification with .customDismissAction, registered by SystemExtensionNotificationCenter merged with existing categories. No delegate method added or changed, so no WebKitDelegateReachabilityTests row.
/verify: DEBUG harness (docs/harness/task247-harness.patch, not committed to Detour/) installs a fake center as shared, installs the API Explorer, and calls handleResponse with delivered identifiers. Isolated run: worker parked at 3.7 s; click -> [SW] onClicked h-click; dismiss -> onClosed h-dismiss true, getAll no longer lists it; clear -> onClosed h-clear false; each acknowledged (backlog empty, same instance re-parked). After 50 s idle a click woke the unloaded worker and a new incarnation got onClicked within 0.5 s. Not verified: a real banner click/dismiss in Notification Center and the real category registration (the user's Notification Center must not be touched).

/code-review --fix (high): fixed (1) a wait refused for an optional notifications permission now re-parks at the next create/update/clear/getAll after the grant (it never re-parked before, and nothing woke it); (2) removed a dead generation counter in the polyfill; (3) the dismiss category registration is awaited before the first authorization check, so no banner precedes its category; (4) notifications.awaitEvent added to the permission-refusal and profile-gone refusal loops, plus a real-context test that a page's awaitEvent is refused and the worker's park stays; (5) a stale comment. Skipped: instance history of 8 (9+ restarts with the old worker alive), at-least-once double dispatch across a runtime.reload overlap (by design), a park made before an optional permission is revoked still receives events, every event wakes a listening background, parkingEmitter duplicating the runtime.onUpdateAvailable wrapper. The permission re-park path has no dedicated test: it needs the optional-grant fixture of ExtensionNotificationOrderingTests plus a listener; listed as a follow-up.

Tests after review: ExtensionNotificationEventManagerTests 9, ExtensionNotificationEventDeliveryTests 6 (unload leg gated/skipped in the batch; run once alone: passed), ExtensionNotificationManagerTests 49, ExtensionNotificationOrderingTests, ExtensionPolyfillProfileWiringTests, ExtensionPolyfillTests, WebKitDelegateReachabilityTests: 346 executed, 14 skipped, 0 failures. /verify harness re-run after the review fixes: same results (click, dismiss byUser true, clear byUser false all acknowledged; late click after 50 s idle reached a new incarnation). AC #5 is verified through handleResponse with UNNotificationDismissActionIdentifier and the category on every request; a real banner dismissal in Notification Center was not exercised (the user's Notification Center must not be touched).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
notifications.onClicked and onClosed now reach the creating owner's background context. The background polyfill parks a notifications.awaitEvent request (background senders only, notifications permission required); ExtensionNotificationManager keeps a per-owner channel with seq-numbered events held until the next park acknowledges them (max 32), wakes a listening background with loadBackgroundContent on each event, and lets a newer incarnation supersede the park for good. A click fires onClicked; a dismissal (now reported through a .customDismissAction category) fires onClosed(byUser true) and drops the entry; the extension's clear fires onClosed(byUser false) as Chrome's message-center path does. The parked request does not keep the worker alive (measured). Pages do not get the events (recorded why). Follow-ups: a test for the optional-permission re-park path; a signed/production check of a real banner click and dismissal.
<!-- SECTION:FINAL_SUMMARY:END -->
