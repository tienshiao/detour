---
type: Concept
title: Notification ownership
description: How extension notifications belong to a profile-and-extension owner, why their Notification Center identifiers are opaque, when an owner's notifications are taken away, and how a launch removes the ones an earlier launch left.
tags: [extensions, polyfill, notifications, profiles, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: notification-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionNotificationManager.swift
    title: ExtensionNotificationManager.swift
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (Private session start and end)
  - id: profile
    resource: ../../Detour/Browser/Profile.swift
    title: Profile.swift (unloadExtension, resetPrivateSession)
  - id: task-238
    resource: backlog:TASK-238
    title: "Extensions: one profile's notifications are visible to and clearable by the same extension in another profile"
  - id: task-248
    resource: backlog:TASK-248
    title: "Extensions: notifications left from an earlier launch stay in Notification Center and can no longer be cleared"
  - id: task-264
    resource: backlog:TASK-264
    title: "Extensions: a Private-profile extension stops receiving notifications.onClicked and onClosed once a Private session starts or ends"
  - id: task-270
    resource: backlog:TASK-270
    title: "Extensions: revoking the notifications permission leaves the extension's notifications and event wait in place"
  - id: task-298
    resource: backlog:TASK-298
    title: TASK-298 (the Private profile is reset when a Private session ends)
  - id: notification-manager-tests
    resource: ../../DetourTests/ExtensionNotificationManagerTests.swift
    title: ExtensionNotificationManagerTests
  - id: notification-ordering-tests
    resource: ../../DetourTests/ExtensionNotificationOrderingTests.swift
    title: ExtensionNotificationOrderingTests
---
Extension notifications belong to a profile as well as to an extension, so
the same extension in two profiles (the Private one included) never sees,
clears or hears about the other's, nothing Notification Center stores names
the profile, and an owner's notifications go when its scope does.

# One owner per profile and extension

The system center has one delegate, so one manager serves every profile, and
every notification belongs to an `Owner`: the handler's profile plus the
verified extension id, never anything from the request body. The same
extension installed in two profiles, the Private one included, is two owners.
Before TASK-238 the key was the extension id alone, so a normal-profile copy
listed, cleared and updated what its Private copy had created, and the reverse
also held.[^task-238]

| What | Scoped how |
|---|---|
| `getAll` | lists only the calling owner's entries |
| `clear`, `update` | find the owner's own notification; another profile's notification with the same id is untouched (both answer false and take nothing away) |
| The UNNotification identifier | opaque: `detour-ext-notification.v3\|<random UUID>`, one per notification, mapped back to (owner, id) by the manager only. Each owner's notification has its own, so one profile's `create` never replaces the other's banner and one profile's `clear` never takes it away. An `update` keeps the identifier (the center replaces the banner); a notification cleared and created again gets a new one |
| A click or close | `handleResponse` resolves the identifier to its owner and id and returns it; either drops only that entry (a click too, since TASK-272; see [notification events](./polyfill-notification-events.md)) |

The identifier is opaque because usernoted keeps delivered identifiers on
disk. The first TASK-238 draft used
`detour-ext-notification.v2|<profile UUID>|<extension id>|<id>`; for Private
the profile UUID is the well-known constant `TabStore.incognitoProfileID`, so
the system's store would have recorded which notifications came from Private,
and what the extension called them. The content handed to the center carries
only title, body and subtitle: no `threadIdentifier`, no `userInfo`.[^task-238]

Identifiers from earlier builds (`<extensionID>:<notificationID>` before
TASK-238, the v2 form) match no entry, so a click or close on one still on
screen is ignored. The map lives in memory only, so the same holds for a v3
identifier left over from an earlier launch. Since TASK-248 a launch removes
all of these ([below](#notifications-left-by-an-earlier-launch-are-removed-at-launch)),
so this matters only until that removal reaches them, or when it is
skipped.[^task-248]

# An owner's notifications go with its scope

Entries would otherwise outlive what created them, and the Private profile's
id is a constant, so a Private session's notifications would carry over into
the next one. They are taken away, from `getAll` and off screen (delivered
and pending), when:

| When | Called from | Manager call |
|---|---|---|
| The extension is unloaded from a profile: disabled there, uninstalled, updated, its context reloaded by background recovery, or the Private profile reset when a Private session ends (TASK-298) | `Profile.unloadExtension` → handler `removeNotifications(ofExtension:)` | `removeAll(for: owner)` |
| The profile is deleted | `TabStore.deleteProfile`, after `unloadAllExtensions` → handler `removeAllNotifications()` | `removeAll(profileID:)` |
| The Private session ends: the last Private window's space is removed, or the last Private Quick Detour closes or switches profile | `TabStore.endPrivateSessionIfUnused()`, the one place that also calls `siteSettings.discardPrivateSession()`; it then calls `Profile.resetPrivateSession()` | `removeSession(profileID: incognitoProfileID)` on the Private profile's handler (`removeSessionNotifications()`): the notifications and their queued events go, the workers' parks stand (TASK-264). The reset that follows unloads each context through the first row, which answers those parks "unloaded", and loads it again on a fresh origin, whose worker parks afresh (TASK-298; see [notification events](./polyfill-notification-events.md#when-the-owners-scope-changes)) |
| A Private session starts (a Private window's space or a Private Quick Detour, when none was live): the Private profile's contexts stay loaded between sessions, so a worker can create one while no Private page is open | `TabStore.startPrivateSessionIfNeeded()`, from `addIncognitoSpace` and `openQuickDetourTab` | the same |
| The app quits, which ends the Private session without closing its windows | `applicationWillTerminate` → `TabStore.removePrivateProfileNotifications()`; best effort, the request may not reach usernoted before exit | the same |
| `notifications` stops being active for the extension in the profile (`permissionIsActive`): a Settings switch or prompt answer, or the extension's `permissions.remove`. Decisions are per extension, so a removal in one profile clears the saved grant and every profile's context loses it | `ExtensionManager.applySavedDecisions` (from `setPermissionDecision` and `clearRemovedGrants`) and `contextDidLoseGrants` → `revokeNotificationsWhereNotPermitted` → each profile's handler `revokeNotificationsIfNotPermitted(ofExtension:)`, which does nothing while the permission is active | `revoke(for: owner, refusal:)`: the notifications and queued events go, the park is answered with the permission refusal, the channel stays (TASK-270) |

A notification whose `add` is still in flight when its owner goes is taken
away again when the `add` returns, as after a `clear`. The handler's removals
use the shared manager only if something created it this launch
(`sharedIfCreated`), so ending a session never sets up the system center.
A persistent profile's notifications still on screen when the app quits stay
there until dismissed or until the next launch removes them (next section).
That launch cannot map their identifiers back, so until the removal reaches
them, or when it is skipped, a click on one is ignored and `clear` or
`create` with the same id no longer reaches it (before TASK-238 the fixed
`<extensionID>:<id>` identifier did, by accident).

# Notifications left by an earlier launch are removed at launch

The manager's map from identifier to owner lives in memory only, so a
notification still in Notification Center after a relaunch belongs to nobody:
a click on it is ignored and the extension's `clear` cannot reach it. At
launch `AppDelegate` calls `removeLeftoverNotifications()`, which lists
delivered and pending identifiers and removes every one shaped like an
extension notification of any build:[^task-248]

| Form | Builds | Matched by |
|---|---|---|
| `detour-ext-notification.v3\|<UUID>` | since TASK-238's second pass | prefix |
| `detour-ext-notification.v2\|<profile>\|<ext>\|<id>` | TASK-238's first pass | prefix |
| `<extension id>:<id>` | before TASK-238 | the id must be 32 letters a–p (a CRX key's) or a UUID string (an unpacked extension with no key), anchored at the start |

- Nothing else in Detour posts a UNNotification today (downloads and the
  updater do not; Sparkle could only with gentle reminders, which Detour does
  not enable), but the legacy form is still anchored on the extension id's
  shape rather than "anything with a colon", so a later poster is safe unless
  its identifiers start with such an id and a colon.
- Identifiers this launch has an entry for are kept: the filter runs after the
  listing returns, so a create made while it was in flight survives. No need
  to run before the first extension loads.
- Not gated on authorization: listing never prompts.
- Skipped in the XCTest host (launch runs before the bundle installs its fake
  center) and whenever another process with Detour's bundle id is running:
  the production app and a `DETOUR_DATA_DIR` run share one Notification
  Center, and one would take the other's live notifications for leftovers.
  A run that skips it says so in a `notice` log line.

# Tests

[ExtensionNotificationManagerTests](../../DetourTests/ExtensionNotificationManagerTests.swift)
covers the owner rules against `HeldNotificationCenter` (getAll, clear,
update, click and close resolution for the same extension in another
profile, legacy and opaque identifiers, `removeAll` and its hooks, a Private
session boundary leaving a parked wait standing).
[ExtensionNotificationOrderingTests](../../DetourTests/ExtensionNotificationOrderingTests.swift)
covers them through the production wiring: one extension in two persistent
profiles, and in a persistent profile plus the built-in Private profile, from
both transports and in both directions; the Private session ending in the
shared store; unloading the extension from one profile.

# Related

- [chrome.notifications](./polyfill-notifications.md) — the calls the owner scopes.
- [Notification events](./polyfill-notification-events.md) — what a revocation or a Private session boundary does to the parked wait.
- [Private profile extensions](./private-profile-extensions.md) — the Private copy of an extension, and when a session starts and ends.
- [Permissions](./permissions.md#permissions-the-polyfill-gates) — `permissionIsActive`, which decides the revocation row.

[^task-238]: Extensions: one profile's notifications are visible to and clearable by the same extension in another profile
[^task-248]: Extensions: notifications left from an earlier launch stay in Notification Center and can no longer be cleared
