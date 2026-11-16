---
type: Feature
title: Notification authorization
description: When Detour asks macOS for notification authorization on an extension's behalf, how creates and updates wait for the answer, and the bounded wait that keeps an ignored prompt from stalling every profile.
tags: [extensions, polyfill, notifications, macos]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T04:58:04Z }
sources:
  - id: notification-manager
    resource: ../../Detour/Extensions/Runtime/ExtensionNotificationManager.swift
    title: ExtensionNotificationManager.swift
  - id: task-253
    resource: backlog:TASK-253
    title: "Extensions: Detour never requests notification permission, so extension notifications may never be shown"
  - id: task-271
    resource: backlog:TASK-271
    title: "Extensions: a notifications.update whose add fails also removes the notification it was updating"
  - id: task-273
    resource: backlog:TASK-273
    title: "Extensions: an unanswered notification authorization prompt stalls notifications.create in every profile"
---
Detour asks for notification authorization the first time any extension calls
`notifications.create` (a product decision; at install or from Settings were
the alternatives), and that create waits for the user's answer. Before
TASK-253 nothing asked, so on a fresh install `create` reported success and
nothing appeared.[^task-253]

- Every create and update asks the center for the status first, so a change
  the user makes in System Settings applies to the next call. `provisional`
  counts as allowed (`ephemeral` is unavailable on macOS).
- One check at a time: creates and updates arriving while the status query or
  the prompt is in flight wait on that check, so one prompt answers them all.
  They resume in call order (a list of continuations; awaiting a shared
  `Task`'s `value` resumed four waiters in reverse order, which reorders the
  adds).
- The entry is recorded before the wait, as before the `add`, so a `clear`
  during the wait answers true and an `update` merges into the waiting
  create. A create cleared or superseded during the wait never calls `add`:
  the superseding update or create adds its own, and skipping the stale one
  keeps it from landing after the newer content.
- Not allowed (declined now or earlier): `create` answers its id, as Chrome
  does when the OS blocks notifications, but nothing is shown and the entry
  goes, so `getAll` does not list it and `clear` and `update` answer false
  for it. A notification shown earlier under that identifier is taken away,
  since the extension no longer has it.
- The prompt is a banner ("“Detour” Notifications", Allow / Don't Allow). The
  unified log shows it as a NotificationCenter record with
  `app:"com.apple.notificationcenter.askpermissions" req:"com.detourbrowser.mac"`.
  On the development Mac the bundle id was still not determined in the TASK-253
  run, which is why earlier runs saw `add` succeed with nothing on screen.
  A Debug build shares `com.detourbrowser.mac` with the installed app, so
  answering a Debug build's prompt sets the installed app's permission too.
- The wait for the answer is bounded (TASK-273). Once the prompt has been up
  for `authorizationAnswerTimeout` (5 s), every create and update waiting on
  it is answered, a create with its id and an update with true,
  and one joining that check later is answered at once. Each stays recorded
  (listed, clearable, updatable) and is shown when the user allows
  notifications, or dropped as above if they decline. Before, a prompt the
  user ignored into Notification Center left every `await create(...)` in
  every profile hanging.[^task-273]
  - Why answer rather than refuse: Chrome's `create` answers once the
    notification is handed to its display service and never waits on the OS
    permission, so answering is the closest match. The 5 s still lets a user
    who answers the prompt at once give the real answer, and it is well inside
    WebKit's 30 s unload timer for a worker whose reply is pending.
  - The timeout is scheduled only when the status is not determined, right
    before the prompt, through the `scheduleAuthorizationTimeout` seam, so
    tests fire it by hand. A check that only reads the status (every create
    once allowed) schedules none. A timeout that fires after its check
    finished does nothing (checks are numbered).
- While the prompt is up, at most `authorizationWaitLimit` (32) of one
  owner's creates and updates wait on it; another owner's are counted
  separately, and a burst joining a status-only check is never limited.
  Shows cleared or superseded while waiting still count, as each still holds
  a waiting task. One more is
  settled as a failed `add` would be: a create answers its id but is neither
  listed nor added, and an update answers false and puts back the entry it
  replaced (the TASK-271 fallback; see
  [failed adds](./polyfill-notifications.md#calls-apply-in-the-order-they-were-made)). Without the limit an extension creating in
  a loop, which the early answers make fast, would pile up waiting tasks and
  update fallbacks until the user answered.[^task-273]

# Tests

[ExtensionNotificationManagerTests](../../DetourTests/ExtensionNotificationManagerTests.swift)
tests the prompt, the shared check, clears and updates during the wait, a
decline, the bounded wait and the per-owner limit against
`HeldNotificationCenter`, which can hold every authorization prompt until the
test answers it.
[ExtensionNotificationOrderingTests](../../DetourTests/ExtensionNotificationOrderingTests.swift)
checks, through the production wiring, that an unanswered prompt answers a
create and an update from both transports.
The fake center's controls are described on
[testing extensions](./testing-extensions.md).

# Related

- [chrome.notifications](./polyfill-notifications.md) — the calls that wait here.
- [Notification events](./polyfill-notification-events.md) — what a shown notification reports back.
- [Service worker unload rules](../platform/service-worker-unload-rules.md) — the 30 s timer the 5 s answer stays inside.

[^task-253]: Extensions: Detour never requests notification permission, so extension notifications may never be shown
[^task-273]: Extensions: an unanswered notification authorization prompt stalls notifications.create in every profile
