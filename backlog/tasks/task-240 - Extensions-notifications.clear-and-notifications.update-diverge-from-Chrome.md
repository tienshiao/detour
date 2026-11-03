---
id: TASK-240
title: 'Extensions: notifications.clear and notifications.update diverge from Chrome'
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T17:08:00Z'
labels:
  - extensions
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 284000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-234. clear always answers true, while Chrome answers whether a notification with that ID existed. update replaces the whole options object, while Chrome merges the given fields into the existing notification (an update that changes only the message keeps the title and icon). Extensions that branch on clear's result or update one field at a time behave differently in Detour.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 clear answers true only when a notification with that ID existed for that extension (including one whose create is still in flight), false otherwise
- [x] #2 update merges the given options into the existing notification; fields not given are kept
- [x] #3 Tests at the manager level and in a real extension context, for both the promise and the callback forms
- [x] #4 The notification's subtitle is not set to its iconUrl (pre-existing: content.subtitle carries the icon URL), and iconUrl / contextMessage map to what Chrome shows, or the gap is recorded
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Manager: clear answers whether the owner had the id (in-flight counts); Entry keeps the shown options; update merges given fields (null = not given) into them; content: title/message/contextMessage -> title/body/subtitle, iconUrl not shown.
2. Tests: manager (missing/existing/in-flight/failed/other owner clear, merge, in-flight merge, content mapping); real context page+worker, promise+callback (ExtensionNotificationOrderingTests); flip the isolation asserts to false.
3. API Explorer: Update message + Clear answers buttons, contextMessage on create.
4. Wiki polyfill-layer + log; /code-review --fix; /verify worker probe; suites.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Chrome's behaviour (cited):
- clear: developer.chrome.com/docs/extensions/reference/api/notifications: clear 'Returns a Promise which resolves to indicate whether a matching notification existed.' Chromium notifications_api.cc NotificationsClearFunction answers GetDisplayHelper()->Close(id).
- update: the reference says only 'Updates an existing notification' / 'Contents of the notification to update to'. The merge is Chromium's: NotificationsUpdateFunction copies the existing notification ('Copy the existing notification to get a writable version of it') and UpdateNotification applies only the fields set in options; a missing id answers false.
- NotificationOptions: title 'Title of the notification', message 'Main notification content', contextMessage 'Alternate notification content with a lower-weight font', iconUrl 'A URL to the sender's avatar, app icon, or a thumbnail', plus buttons/items/progress/priority/eventTime/requireInteraction/silent/imageUrl (deprecated)/appIconMaskUrl (deprecated)/isClickable (ignored since 67). Chrome's macOS bridge (chrome/browser/notifications/mac/notification_utils.cc CreateMacNotificationContext) puts context_message in the subtitle when no origin attribution is needed.

Implementation: ExtensionNotificationManager.clear answers false when the owner has no such id (another owner's same id included), true otherwise (an in-flight create's entry counts). Entry now keeps the shown options (title/message/contextMessage only; a review fix, since iconUrl is often a large data: URL and entries outlive dismissed banners); update merges the given options into them (NSNull = not given) and re-shows. content(for:) maps title->title, message->body, contextMessage->subtitle; iconUrl is no longer the subtitle. Recorded gap: iconUrl (would need the extension-relative URL loaded into a file for a UNNotificationAttachment), imageUrl, buttons, items, progress, priority, eventTime, requireInteraction are not shown; silent holds by default (no sound is set). Handler unchanged.

Tests: ExtensionNotificationManagerTests +6 (clear missing/again, after a failed add, other owner vs own in-flight, update merge incl. null + composition, in-flight merge, content mapping); the two isolation clears now assert false deliberately. ExtensionNotificationOrderingTests +2 (callback clear while create in flight, page+worker; clear answers + update merge in promise and callback forms, page+worker, plus bad-argument cases added in review); assertIsolated now asserts the other profile's clear answers false and its own copy's true; testAnotherExtensionsClearDoesNotCancelTheCreate asserts false. ExtensionPolyfillTests.testNotificationsClear moved off the real system center onto a fake (review: its true depended on the host's notification permission).

Runs: ExtensionNotificationManagerTests 36/36, ExtensionNotificationOrderingTests 14/14, ExtensionPolyfillTests 185/185 (235 total, 0 failures), after the review fixes.

/code-review --fix: fixed testNotificationsClear on the real center, stored options trimmed to shown keys, create doc comment, bad-argument real-context tests, duplicate test helper. Skipped (follow-ups): a banner the user dismisses never reaches handleResponse (no dismiss category), so its entry stays and clear/update still answer true for it; chrome.notifications.create(null, options) takes null for the options-first form (typeof null === 'object') and creates an empty notification; native error text is wrapped differently per transport (WebKit's sendNativeMessage prefix, doubled in the worker's callback lastError).

/verify: Debug build (.derived), isolated DETOUR_DATA_DIR, API Explorer seeded with a probe appended to its worker, -ExtensionConsoleLogPublic YES. Worker logged: clear(missing) false, update(message only) true, getAll lists the id, clear true, clear again false, callback clear(missing) false with no lastError, callback clear of an in-flight create true, getAll empty after. Not verified at runtime: the banner content itself (Detour never requests notification authorization, so nothing is displayed; the mapping is covered by the manager and real-context tests via the fake center), and the API Explorer popup buttons (no UI driving). Data dir and defaults keys removed.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
notifications.clear now answers whether the calling owner had the notification (an in-flight create counts; another profile's or extension's id answers false), and notifications.update merges the given fields into the notification instead of replacing them, as Chromium does. The banner shows title/message/contextMessage as title/body/subtitle (Chrome's macOS mapping) and no longer puts iconUrl in the subtitle; the unshown options are recorded in the wiki. Manager and real-context tests (page and worker, promise and callback); API Explorer gains Update message and Clear answers. Follow-ups: dismissed banners keep their entries; create(null, options) misparses; per-transport error wording.
<!-- SECTION:FINAL_SUMMARY:END -->
