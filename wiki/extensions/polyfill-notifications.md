---
type: Feature
title: chrome.notifications in the polyfill
description: How Detour's chrome.notifications applies unawaited calls in call order, reads the create signature, answers clear and update as Chrome does, and maps the options onto a macOS banner.
resource: ../../Detour/Extensions/Runtime/ExtensionNotificationManager.swift
tags: [extensions, polyfill, notifications]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: notification-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionNotificationManager.swift
    title: ExtensionNotificationManager.swift
  - id: handler
    resource: ../../Detour/Extensions/Runtime/ExtensionPolyfillHandler.swift
    title: ExtensionPolyfillHandler.swift
  - id: task-234
    resource: backlog:TASK-234
    title: notifications.clear issued while notifications.create is still adding the notification is lost
  - id: task-240
    resource: backlog:TASK-240
    title: "Extensions: notifications.clear and notifications.update diverge from Chrome"
  - id: task-254
    resource: backlog:TASK-254
    title: "Extensions: notifications.create(null, options) is treated as create(options) with empty options"
  - id: task-269
    resource: backlog:TASK-269
    title: "Extensions: notifications.create with an empty id keeps it instead of generating one"
  - id: task-271
    resource: backlog:TASK-271
    title: "Extensions: a notifications.update whose add fails also removes the notification it was updating"
  - id: task-276
    resource: backlog:TASK-276
    title: "Docs: fix the permission-scope and notification-ordering descriptions the review found wrong"
  - id: chrome-notifications-api
    resource: https://developer.chrome.com/docs/extensions/reference/api/notifications
    title: chrome.notifications API reference
  - id: notification-manager-tests
    resource: ../../DetourTests/ExtensionNotificationManagerTests.swift
    title: ExtensionNotificationManagerTests
  - id: notification-ordering-tests
    resource: ../../DetourTests/ExtensionNotificationOrderingTests.swift
    title: ExtensionNotificationOrderingTests
---
Detour's `chrome.notifications` is a polyfill backed by
`ExtensionNotificationManager`, which posts through `UNUserNotificationCenter`.
It is installed only when the manifest declares `notifications`
([request gates](./polyfill-request-gates.md)). This page covers what the
calls do; the related pages cover
[authorization](./polyfill-notification-authorization.md),
[click and close events](./polyfill-notification-events.md) and
[ownership per profile](./polyfill-notification-scope.md).

# Calls apply in the order they were made

`ExtensionNotificationManager` (one shared instance for every profile; each
profile's handler reaches it through `notificationManager`) records a notification when `create` is
called, before `UNUserNotificationCenter.add` returns. An extension that does
not await `create` before `clear` or `update` therefore gets what it asked
for:[^task-234]

| Calls, none awaited | Result |
|---|---|
| `create('x')`, `clear('x')` | The clear drops the entry at once and removes the notification; when the `add` returns, the manager removes it once more, because the clear's removal can reach the center before the notification does. `getAll` does not list it |
| `create('x')`, `update('x')` | The update finds the entry and re-creates it; `wasUpdated` is `true` and the update's content shows |
| `create('x')`, `clear('x')`, `create('x')` | The clear drops the entry with its UNNotification identifier, so the second `create` gets a new identifier. When the first `add` returns it finds no entry under its own identifier and removes only that identifier's notification; the second `add` shows the second one, which stands. A first create still waiting for authorization finds its entry gone and never adds.[^task-276] Generations decide `create('x')`, `create('x')` with no clear between: the second keeps the identifier, so the first `add` finds a newer generation, leaves the entry alone and lets the newer `add` replace what it showed |

`getAll` lists a notification whose `add` is still in flight. A failed `add`
of a `create` drops the entry only if no later `create` or `update` has
replaced it, and also removes any notification shown under that id, so
`getAll` and the screen agree. A failed `add` of an `update` answers
`wasUpdated: false` and puts back the entry the update replaced, so the
notification the create (or an earlier update) showed stays listed, shown and
merged into by the next update, as in Chrome.[^task-271] Each update entry
keeps the entries it replaced, newest first, as fallbacks; one whose `add`
fails, or is skipped because it was superseded during the authorization wait,
is dropped from them (nothing of it shows), and one whose `add` succeeds
discards the older ones, so the list lasts only while adds are in flight.
Before TASK-234 the entry was recorded only after `add` returned, so a clear issued
meanwhile found nothing and the notification came back.

Rejected: serializing the operations per notification id. It would also make
calls apply in order, but it needs a queue per id, makes `clear` wait for the
`add`, and still has to decide what `getAll` says in between.

# The center seam

The manager talks to the center through `ExtensionNotificationCenter` (`add`,
`removeNotifications`, `authorizationStatus`, `requestAuthorization`,
`deliveredIdentifiers`, `pendingIdentifiers`), a seam
for tests: `HeldNotificationCenter` holds every `add`, and optionally every
authorization prompt, until the test releases it.[^notification-manager]

# The create signature

`create(notificationId?, options, callback?)` follows Chrome's signature: a
`null` or `undefined` id counts as absent, so the options are used and an id is
generated. Only a non-null object in the first slot means the id was left out
(`typeof null` is `'object'`, which once made `create(null, options)` create
an empty notification).[^task-254]
An empty id is generated too, as Chrome's is for one "not set or empty":
`ExtensionNotificationManager.create` replaces `""` with a fresh UUID, so
`create('', …)` twice makes two notifications and `getAll` never lists `""`.
Before, the empty id was kept and every such create replaced the last.[^task-269]

# What clear and update answer

As in Chrome, whose `clear` "resolves to indicate whether a matching
notification existed"[^chrome-notifications-api] (Chromium's
`NotificationsClearFunction` answers the display helper's `Close`), `clear`
answers true only when the owner had the notification, one whose `create` is
still in flight included, and false for a missing, already cleared or refused
id and for another owner's. Before TASK-240 it always answered true.

`update` merges the given options into the notification's, as Chromium's
`NotificationsUpdateFunction` copies the existing notification and
`UpdateNotification` applies only the fields passed: an update that sets only
`message` keeps the title. The entry keeps the merged options, so updates
compose, one made while the `create` is in flight included; a `null` field
counts as not given. Before TASK-240 the update replaced the whole options
object.[^task-240]

# What a notification shows

The content follows Chrome's macOS bridge (`CreateMacNotificationContext`
returns `context_message` for a notification that needs no origin attribution):

| Option | Shown as |
|---|---|
| `title` | title |
| `message` | body |
| `contextMessage` | subtitle |
| `iconUrl` | nothing: the banner shows Detour's icon. An attachment would need the extension-relative URL loaded into a file first. Before TASK-240 the URL itself was the subtitle |
| `imageUrl`, `buttons`, `items`, `progress`, `priority`, `eventTime`, `requireInteraction`, `silent` | nothing (no sound is ever set, so `silent` holds by default) |

A click or a dismissal is resolved by `handleResponse` and delivered to the
owner's background as `onClicked` / `onClosed`; see
[notification events](./polyfill-notification-events.md). `onButtonClicked`
never fires, since buttons are not shown.

# Tests

| Suite | Proves |
|---|---|
| [ExtensionNotificationManagerTests](../../DetourTests/ExtensionNotificationManagerTests.swift) | The call orderings above against `HeldNotificationCenter`: clear or update while the `add` is in flight, create–clear–create, an `add` answering out of order or failing, another extension's clear; the [ownership](./polyfill-notification-scope.md) rules: the same extension in another profile (getAll, clear, update, click and close resolution, legacy identifiers), opaque identifiers, `removeAll` and its hooks (Private session end in a `TabStore` of its own, profile deletion), a Private session boundary leaving a parked wait standing |
| [ExtensionNotificationOrderingTests](../../DetourTests/ExtensionNotificationOrderingTests.swift) | The same orderings from an extension page and its worker through the production wiring, with the profile's handler on a held center; one extension in two persistent profiles, and in a persistent profile plus the built-in Private profile, sharing one manager, from both transports and in both directions; the Private session ending in the shared store, and unloading the extension from one profile |

Authorization and events have their own suites, listed on their pages.

# Related

- [Notification authorization](./polyfill-notification-authorization.md) — what a `create` waits for before its `add`.
- [Notification events](./polyfill-notification-events.md) — `onClicked` / `onClosed`, and synchronization with Notification Center.
- [Notification ownership](./polyfill-notification-scope.md) — owners, opaque identifiers, when notifications are taken away.
- [Testing extensions](./testing-extensions.md) — `HeldNotificationCenter` and the fake center's controls.
- [Polyfill layer](./polyfill-layer.md) — the request path.

[^task-234]: notifications.clear issued while notifications.create is still adding the notification is lost
[^task-276]: Docs: fix the permission-scope and notification-ordering descriptions the review found wrong
[^task-271]: Extensions: a notifications.update whose add fails also removes the notification it was updating
[^notification-manager]: ExtensionNotificationManager.swift
[^task-254]: Extensions: notifications.create(null, options) is treated as create(options) with empty options
[^task-269]: Extensions: notifications.create with an empty id keeps it instead of generating one
[^chrome-notifications-api]: chrome.notifications API reference
[^task-240]: Extensions: notifications.clear and notifications.update diverge from Chrome
