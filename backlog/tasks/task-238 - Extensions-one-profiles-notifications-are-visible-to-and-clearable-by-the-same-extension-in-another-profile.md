---
id: TASK-238
title: >-
  Extensions: one profile's notifications are visible to and clearable by the
  same extension in another profile
status: Done
assignee:
  - '@claude'
created_date: '2026-11-03T07:58:00Z'
updated_date: '2026-11-03T16:32:00Z'
labels:
  - extensions
  - privacy
dependencies: []
references:
  - Detour/Extensions/Runtime/ExtensionNotificationManager.swift
priority: medium
type: bug
ordinal: 282000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in review during TASK-234 (pre-existing). ExtensionNotificationManager keys notifications by extension ID and notification ID only, and every profile shares one manager. The same extension installed in two profiles (including the Private profile) therefore sees, through notifications.getAll, the IDs and contents of notifications created in the other profile, and can clear or update them. Private-profile isolation is a product promise; a normal-profile extension must not learn what the Private copy did, and vice versa. Clicks on a notification must also be routed back to the profile that created it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 getAll, clear and update in one profile never see or affect a notification created by the same extension in another profile, including Private
- [x] #2 A click or close on a notification resolves only to the (profile, extension, id) that created it, and a close drops only that profile's entry (delivery of onClicked/onClosed to extension contexts is not implemented today; tracked separately)
- [x] #3 Real-extension-context tests cover two persistent profiles and a persistent plus the Private profile, from both transports
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Find how a request's profile is known: each Profile builds its own ExtensionPolyfillHandler (weak profile); both transports reach it (page via the profile's userContentController, worker via ExtensionManager -> Profile.profile(owning:) -> polyfillHandler).
2. ExtensionNotificationManager (still one shared instance; the UN center has one delegate) keys every entry by Owner(profileID, extensionID); UNNotification identifier detour-ext-notification.v2|<profile UUID>|<percent-encoded ext id>|<notification id>, injective. Legacy <ext>:<id> identifiers match no entry and are ignored.
3. Handler builds the Owner from its own profile; refuses when the profile is gone. notificationManager becomes notificationManagerOverride (test seam, resettable) + private computed accessor.
4. handleResponse resolves a click/close to the exact owner and returns it; a close drops only that entry. Delivery to onClicked/onClosed is out of scope (no push channel); AC #2 narrowed accordingly.
5. Tests: manager-level isolation tests; real-context tests in ExtensionNotificationOrderingTests for two persistent profiles and persistent + built-in Private profile, both transports, both directions, sharing one manager; response resolution from real contexts. Mutation check against unscoped keys.
6. Wiki (polyfill-layer, testing-extensions, private-profile-extensions, log), /code-review --fix, /verify, suites.

7. Review findings in scope: opaque identifiers (detour-ext-notification.v3|<random UUID>, manager-side map; v2 embedded the profile UUID, the Private one a well-known constant, and usernoted stores identifiers); removeAll(for:)/removeAll(profileID:) hooked into Profile.unloadExtension, TabStore.deleteProfile, the Private session's end (endPrivateSessionIfUnused, now the single place that also discards Private site settings) and start (startPrivateSessionIfNeeded), and quit (applicationWillTerminate).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
AC #2 narrowed (agreed with the coordinator): notifications.onClicked/onButtonClicked/onClosed never fire today. The polyfill's __extensionDispatchNotification* hooks have no native caller, because WebKit offers no push channel into a context (wiki polyfill-layer, Gotchas). So no click or close is delivered to any profile's context, and the original wording could not be met without building delivery. The AC now asks for what this task guarantees: the manager resolves a response to the exact (profile, extension, id) owner, and a close drops only that entry. Delivery is tracked separately by the coordinator.

Second pass (privacy findings from the first review): identifiers are opaque and only the manager maps them back; content carries no threadIdentifier/userInfo. An owner's notifications go with its scope: extension unloaded from the profile (disable, uninstall, update, background-recovery reload), profile deleted, Private session ended or started (a worker can create one between sessions, since Private contexts stay loaded), and at quit (best effort). A clear for an id the owner does not have now asks the center for nothing.

Private real-context fixture cleanup checked: tearDown removes any Private window space it opened (which ends the session through the production path), unloads the Private contexts, deletes the extension rows (cascading the Private profileExtension rows) and resets the handler override after the unloads. The Private profile row it saves is one the app saves itself in ensureIncognitoProfile.

Second /code-review --fix: fixed quit removal (new removePrivateProfileNotifications, called from applicationWillTerminate), a stale doc symbol, the owner built from one profile-id source, a misnamed unit test. I then added clearing at session start for notifications created between Private sessions. Not fixed, follow-ups: (a) notifications from an earlier launch are orphaned in Notification Center (clicks ignored, clear/create no longer reach them; the pre-238 fixed identifier reached them by accident) - a startup sweep of our prefixes needs getDelivered on the center seam; (b) background-recovery reload now drops the extension's notifications (by design: unload drops them).

Tests (all pass, load ~7): ExtensionNotificationManagerTests 30, ExtensionNotificationOrderingTests 10, ExtensionPolyfillTests 180, ExtensionPolyfillProfileWiringTests 62 (13 skipped), TabStoreTests 40, QuickDetourTests 27, QuickDetourProfileSwitchTests 23, QuickDetourExtensionTests 18, ProfileDeletionUndoTests 13, ProfileDataRemovalTests 25, ExtensionEnabledStateTests 8, MoveTabToSpaceTests 31: 467 run, 0 failures. Mutation check: disabling the three lifecycle hooks fails the Private-session, Quick Detour, profile-deletion and unload tests.

/verify (DEBUG launch harness, removed afterwards; API Explorer seeded in Default, Second and Private): A creates from page and worker; B's getAll (page and worker) lists none, B's update answers false, B's clears leave A's; same id in B is a second delivered notification; every v3 identifier delivered this run is prefix + UUID with no profile UUID, extension id or notification id in it; a Private notification is delivered under an opaque identifier, and closing the Private window's space removes it from getAll and from the delivered list while A's stay. The one harness FAIL was its own filter: the delivered list also held two v2 identifiers left by earlier test-host runs (ExtensionPolyfillTests posts real notifications under the same bundle id). Not verified: clicking a real banner; the quit removal reaching usernoted before exit.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
chrome.notifications is scoped by profile. One shared manager keys entries by Owner (handler's profile + verified extension id); getAll, clear and update see only the caller's own, so the same extension in two profiles, Private included, never sees or touches the other's. UNNotification identifiers are opaque (detour-ext-notification.v3|<random UUID>), mapped back to (owner, id) by the manager only, so nothing usernoted stores names the profile; earlier v2/legacy identifiers are ignored. handleResponse resolves a click or close to its exact owner and a close drops only that entry (delivery to onClicked/onClosed is TASK-247). An owner's notifications are removed, from getAll and the screen, when its extension is unloaded from the profile, when the profile is deleted, when a Private session ends or starts, and at quit. Tests: manager-level ordering, isolation, opaque-identifier, removeAll and TabStore lifecycle tests; real-context tests for two persistent profiles and persistent + Private from both transports, the Private session ending, and an extension unload. Follow-ups: sweep orphaned notifications from earlier launches at startup; the test host posts real notifications to the dev Notification Center.
<!-- SECTION:FINAL_SUMMARY:END -->
