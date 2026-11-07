---
id: TASK-272
title: >-
  Extensions: notification entries outlive the banner when macOS takes it away
  without a dismiss
status: Done
assignee:
  - '@claude'
created_date: '2026-11-07T00:12:00Z'
updated_date: '2026-11-07T01:18:00Z'
labels:
  - extensions
  - notifications
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: low
type: bug
ordinal: 319000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in the adversarial review of 2b36883..HEAD (TASK-238..263 stream) on 2026-11-06.

`ExtensionNotificationManager.handleResponse` (~765-767) keeps the entry after a click, although macOS removes the banner. For an extension that uses create(null, ...) and never calls clear, `entries` grows for the whole session, `getAll` reports notifications that are no longer shown, and a later `update` brings the banner back. Not yet checked: whether Notification Center's "Clear All" reports a dismiss action.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 After a click removes a banner, getAll no longer lists it and update of its id answers false (or the Chrome behaviour, recorded)
- [ ] #2 The task records what Clear All reports, measured in the running app
- [x] #3 entries cannot grow without bound for an extension that never calls clear
- [x] #4 Tests cover the click case
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Chromium check (mac_notification_service_un.mm, notification_utils.cc): Chrome sets the private shouldPreventNotificationDismissalAfterDefaultAction so its click does not remove the banner; any delivered notification that vanishes without a dismiss is found by SynchronizeNotifications every 10 min and reported as a close with by_user=true.
2. handleResponse: a click drops the entry (macOS removes our banner; we do not set the private key) and delivers onClicked then onClosed(byUser true), the id carried by both.
3. Reconciliation: synchronizeWithCenter() lists delivered+pending; an entry whose current generation's add succeeded at least a grace ago (injected clock) and is in neither list is dropped and gets onClosed(byUser true). In-flight adds/updates (no shownAt) are skipped, as Chrome skips pending content; fallbacks keep shownAt. Run at every create (coalesced) and on a 10-min main timer while entries exist: bounds entries for an extension that never clears and covers Clear All / system pruning.
4. Tests: click case (getAll/update/clear, events), sync drops vanished, keeps fresh/in-flight/listed, skips removed owners; update existing click tests.
5. Runtime: try to measure Clear All; record why if not possible. Wiki + log.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision (Chrome check): Chromium's MacNotificationServiceUN sets the private UNMutableNotificationContent key shouldPreventNotificationDismissalAfterDefaultAction, so a Chrome click leaves the banner; any delivered notification that disappears without a reported dismissal is found by SynchronizeNotifications (kSynchronizationInterval = 10 min) and reported as kClose, which notification_utils.cc hands to the extension with by_user=true. Detour does not set the private key (private API, and it would change what users see after a click), so macOS takes a clicked banner away; we follow Chrome's handling of a vanished notification: a click drops the entry and delivers onClicked then onClosed(byUser true) in one park answer (both carry the id). getAll stops listing it; update/clear answer false (AC #1). An update whose add is in flight at the click finds no entry when it lands and removes the banner it re-showed (like clear during the add); it still answers true.
AC #3: synchronizeWithCenter() lists delivered+pending and closes (onClosed byUser true) every entry missing from both whose own add succeeded >= 5 s ago (injected clock 'now'); entries with an add in flight are skipped (Chrome skips pending content), entries cleared/clicked/replaced/revoked during the listing are skipped. Runs at every create (coalesced) and on a 10-min main-run-loop timer while entries exist. Entry/Fallback carry shownAt so a TASK-271 fallback restore keeps it.
AC #2 NOT measured: producing a real banner from the Debug build needs notification authorization for com.detourbrowser.mac; on this Mac it is undetermined as far as observable (usernoted db2 has an app row for the bundle but no delivered records; no authorization log lines in 7 days; TASK-253 also found it undetermined). The first create would show the system Allow prompt, and answering it also sets the installed production app's permission (shared bundle id) - the user's decision, and the user was unavailable. Clear All would also have to be driven in the Notification Center shared with the running production Detour. Either answer is handled: a reported dismissal closes via handleResponse, an unreported removal at the next synchronization.

Review: /code-review --fix (forked) found 10; applied: sync also removes the dropped identifiers from the center; click also removes its identifier from the center; listedIdentifiers() shared with removeLeftoverNotifications, pending listed before delivered; timer scheduled when a superseded generation's add shows; Response kind from events[0]. I then took three it skipped: create-triggered sync throttled to once per grace (lastListing), the in-flight flag replaced by an awaitable task, a DEBUG timer seam with a test of the periodic check, and testSynchronizingClosesWhatTheCenterNoLongerLists isolated from the create's own sync. Left: a click on the old banner during a create(sameId)'s add ends the new notification too (dismissals already did this before).
Tests: ExtensionNotificationEventManagerTests + ExtensionNotificationManagerTests + ExtensionNotificationEventDeliveryTests + ExtensionNotificationOrderingTests 107 run, 0 failures, 1 skipped (gated unload leg); ExtensionPolyfillIntegrationTests + ExtensionPolyfillTests + WebKitDelegateReachabilityTests 224 run, 0 failures.
Runtime (/verify): Debug build from .derived launched twice in isolated data dirs (DetourVerify272, DetourVerify272b; dylib mtime matched the build); launched cleanly, logged the expected 'Not removing leftover extension notifications: another Detour process is running'. Nothing more observable without a real banner. Defaults keys and data dirs removed afterwards.
Not verified: AC #2 (what Clear All reports; see the earlier note for why), that macOS removes a clicked banner from Notification Center for Detour's notifications (taken from Chromium's comment on the private key), and the 5 s grace against real usernoted timing.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
A click on an extension notification now ends it: macOS takes the clicked banner away (Chrome keeps its own only through the private shouldPreventNotificationDismissalAfterDefaultAction, which Detour does not set), so handleResponse drops the entry, removes the identifier from the center, and delivers onClicked then onClosed(byUser true), which is how Chrome reports a notification that left Notification Center unreported. getAll stops listing it and update/clear answer false, so an update no longer brings the banner back. New synchronizeWithCenter() mirrors Chrome's SynchronizeNotifications: entries shown at least 5 s ago that the center lists neither as pending nor as delivered are closed (onClosed byUser true). It runs at each create (coalesced, at most once per 5 s) and on a 10-minute timer while entries exist, so the entries of an extension that never clears stay bounded by what is on screen, and an unreported Clear All or system pruning is caught. In-flight adds and entries changed during the listing are skipped, which keeps the TASK-264/270/271 invariants. Tests: 107 + 224 run, 0 failures. Not measured: what Clear All reports (needs notification authorization for the shared bundle id; the user's decision). Either outcome is handled.
<!-- SECTION:FINAL_SUMMARY:END -->
