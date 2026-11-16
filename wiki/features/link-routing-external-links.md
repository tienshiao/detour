---
type: Feature
title: Links from other apps
description: "How Link Routes handle links other apps open in Detour: Detour's own Get URL Apple Event handler, reading the sending app from the event (what macOS 26.7 reports for each kind of sender, the int32Value trap), how multi-URL opens arrive, the link that launched Detour (its sender read at launch; an unknown one fails closed to Quarantine where a From app route to it cannot be ruled out), delivering test links without reaching the production app, and the runtime checks."
tags: [links, apple-events, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:20Z }
stale_after: 2027-01-31T00:00:00Z
sources:
  - id: appdelegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (handleGetURLEvent, application(_:open:), openExternalURLs)
  - id: sender
    resource: ../../Detour/Browser/LinkRouting/LinkSender.swift
    title: LinkSender.swift (linkSenderPID, linkSenderBundleID, linkURLs, LaunchLinkTracker)
  - id: resolver
    resource: ../../Detour/Browser/LinkRouting/LinkRouteResolver.swift
    title: LinkRouteResolver.swift (resolveExternalLinkRoute)
  - id: placement-tests
    resource: ../../DetourTests/LinkPlacementTests.swift
    title: LinkPlacementTests.swift
  - id: routing-tests
    resource: ../../DetourTests/ExternalLinkRoutingTests.swift
    title: ExternalLinkRoutingTests.swift
  - id: task-191-2
    resource: backlog:TASK-191.2
    title: "TASK-191.2: send links from other apps to the routed space"
  - id: task-304
    resource: backlog:TASK-304
    title: "Link Routes: a link that launches Detour has no known sending app, so From app routes can't match it"
  - id: harness-2
    resource: ../../docs/harness/task191-2-harness.patch
    title: TASK-191.2 runtime harness
---

A link another app opens in Detour (a click in Mail, `open URL`, a
`.webloc`) arrives as a Get URL Apple Event. Detour reads which app sent it,
runs the routes and the Default for an `.external(sourceApp:)` origin, and
places each URL by the [placement rule](./link-routing-placement.md). This
is the only origin From app routes and the Quick Detour and Default
Quarantine targets apply to (see the [resolver](./link-routing-resolver.md)).
Part of [Link Routes](./link-routing.md).

# How it works

Detour handles Get URL Apple Events itself since TASK-304:
`AppDelegate.handleGetURLEvent`, installed with
`NSAppleEventManager.setEventHandler` in `applicationWillFinishLaunching`,
reads the event's sender and URLs, then
`openExternalURLs(_:sourceApp:launchedDetour:)` takes each http/https URL
(scheme compared without case) on its own: `resolveExternalLinkRoute` (the
routes as `resolveLinkRoute` applies them to `.external(sourceApp:)`, plus
the launch rule [below](#the-link-that-launched-detour)), then
`AppDelegate.openLink(_:routedTo:)` and the pure `linkPlacement` with a
snapshot of the browser windows taken again for every URL.[^task-191-2][^task-304]

## The sender

`linkSenderPID(of:)` reads `keySenderPIDAttr`, else a `keyAddressAttr` that
is a process ID; `linkSenderBundleID` names it with
`NSRunningApplication(processIdentifier:)`, and treats Detour itself, a PID
of 0 and a process without a bundle ID as no sender. The handler reads it
when the event arrives, since the sender may exit before a launch link is
opened. What macOS reported on 2026-10-25 (macOS 26.7, logged by the
harness through `application(_:open:)`), and on 2026-11-08 with Detour's own
handler (TASK-304 spike, macOS 26.7):

| Sender | `keySenderPIDAttr` | Bundle ID |
|---|---|---|
| An app calling `NSWorkspace.open(_:withApplicationAt:)` (LaunchServices) on a running Detour | the calling app's PID (type `'magn'`); `keyAddressAttr` and `keyOriginalAddressAttr` the same PID | the app's (`com.detourbrowser.verify.sender-a`), so its source-app route matched |
| `open -a <app> URL` from a shell | the `open` process | none: no sender |
| A tool sending the event itself (`AESendMessage`) | the tool's PID | none, even when the binary sits inside an `.app` bundle but was not launched by LaunchServices: `NSRunningApplication` knows only LaunchServices-launched processes |
| A sender that has already exited | its PID | none (`NSRunningApplication` returns nil) |
| The URL that cold-launches Detour, under AppKit's own Get URL handling (before TASK-304) | no current Apple Event at all (`currentAppleEvent` is nil) in `application(_:open:)` for the first URL: AppKit queues the launch URLs and calls the delegate after `applicationDidFinishLaunching`; later URLs of the same open arrive as their own events, from the opener | none for the first URL |
| The URL that cold-launches Detour, with Detour's handler installed in `applicationWillFinishLaunching` (TASK-304) | the event reaches the handler **before** `applicationDidFinishLaunching`, from the opener: `'magn'` PID of the app calling `NSWorkspace.open` (new instance); `keyAddressAttr` and `keyOriginalAddressAttr` type `'psn '` (8 bytes, low word = the PID); `keyEventSourceAttr` 3 (local process); `keySenderAuditTokenAttr` the same PID. The next URL of the same open came 0.11 s after launch as its own event, same sender. `NSApplicationLaunchIsDefaultLaunchKey` is 0 | the app's when it was launched by LaunchServices (`com.detourbrowser.verify.sender304`); none for a bare tool or for `open -n` (the `open` process had already exited) |

Nothing named LaunchServices or Detour as the sender of a Get URL event.
So a source-app route matches links from running apps that open them
through LaunchServices, and since TASK-304 the link that launches Detour as
well. **Not verified**: Finder (opening a `.webloc` goes to the default
browser, and scripting Finder at the debug PID would need an Automation
grant), Mail, Slack and other real apps (not scripted, on purpose).

The raw-sender `int32Value` trap: a `typeKernelProcessID` descriptor reads
as 0 through `int32Value` (no numeric coercion), so `linkSenderPID` reads
its four bytes; `keySenderPIDAttr` cannot be set on an event built in
process (`setAttribute` ignores it), so only the address path is
unit-tested.

## How links arrive

Every URL of an `open -a` with several URLs, or of one `NSWorkspace.open`
with several, came as its own Get URL event. One event whose direct object
is a list of URLs (`linkURLs(in:)`) is still routed URL by URL. At a cold
launch the handler queues what arrives before `applicationDidFinishLaunching`
and opens it at the end of that method, once the session is restored and
the routes are loaded; at that point Detour was active with its restored
window key in every TASK-304 run, so a Most Recent Space link opened a tab
there rather than a second window. Open Documents events (an `.html` file
from Finder or the Dock) still reach `application(_:open:)`, which opens
only web URLs, so a file is ignored, as it was before.

Activation: `open -a` activated Detour before the event was handled (a key
window existed); `NSWorkspace.open` with `activates = false` and a raw Apple
Event do not, and then the placement only orders the window to the front of
Detour's own windows. (The default `NSWorkspace.open`, which activates, was
not observed.)

# The link that launched Detour

`LaunchLinkTracker` (pure, `LinkSender.swift`) tells which Get URL events
carry the links that launched Detour: every event handled before
`applicationDidFinishLaunching` finished, and an event from one of those
events' senders up to 10 s after it (the rest of the same open). Anything
later, or from another process, is a link while Detour runs.

`resolveExternalLinkRoute(url:sourceApp:launchedDetour:...)`:

| Link | Sender | Decision |
|---|---|---|
| Launched Detour | known | the routes and the Default, as while running: a From app route matches it |
| Launched Detour | unknown, and a From app route to Quarantine is reached whose URL condition holds | `.quarantine` |
| Launched Detour | unknown, otherwise | the routes and the Default, as before (a From app route cannot match an unknown sender) |
| While running | known or unknown | unchanged: the routes and the Default |

**Fail closed (user, 2026-11-08).** Before TASK-304 the launch link never
had a sender, so "links from Mail go to Quarantine" was skipped for exactly
the link that started Detour, which then opened in a normal space with the
user's cookies. With the sender read at launch that hole closes for apps
that open links themselves through LaunchServices; for a sender Detour
cannot name at launch (a command-line tool, a helper process
`NSRunningApplication` does not know, an opener that has exited), the link
goes to Quarantine wherever a Quarantine route could have matched it. The
user first chose "any route" (a URL-only route to Quarantine also triggered
it, and it beat routes listed before it), then the same day narrowed it to
routes that cannot be ruled out: a route whose URL condition fails is false
whatever the sender, a route behind one that matches is never reached, and a
URL-only route matches or not as usual. So in route order, a From app route
to Quarantine whose URL condition holds is taken as matching
(`senderMightMatchQuarantine` in the private resolver core); every other
route resolves as for a known sender no route names. While Detour runs, an
unknown sender (`open` from a shell) keeps the routes and the Default: those
links were never the hole.[^task-304]

**Not verified** (TASK-304): links clicked in Mail, Messages, Notes or Slack
(the user's production Detour is the default browser, so their links cannot
reach a Debug build), and macOS 15.4 (only macOS 26.7 was available).
Whether those apps send links from their own process (a known sender) or
from a helper inside their bundle (unknown, so the fail-closed path) is
open.

# Delivering test links safely

The Debug build shares the production bundle ID (`com.detourbrowser.mac`),
so anything that resolves the app by bundle ID (`open URL`, `open -a <debug
app> URL` without `-n`, `NSWorkspace.open` to a running instance) can hand
the link to the user's own `/Applications/Detour.app`. The TASK-191.2 runs
used only: an Apple Event addressed by PID that refuses any executable but
the `.derived` build and any send `AEDeterminePermissionToAutomateTarget`
(ask: false) does not allow; `open -n -a <debug app> --env ...`, which
always starts a new instance; and a copy of the Debug app with its own
bundle ID for every LaunchServices delivery to a running instance. The
permission probe returned `noErr` for the PID-addressed sender in two runs
and -1744 (would need consent) in another, also for sender apps launched by
LaunchServices; nothing was sent then. The recipe is in
[runtime verification](../playbooks/runtime-verification.md) and the
harness.[^harness-2]

# Runtime check: links from other apps

Harness `docs/harness/task191-2-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1912`, 2026-10-25.[^harness-2] With windows on
Home, Work and Personal (Personal in front) and Detour in the background:
`work.test` opened in the Work window and brought it to the front of
Detour's windows; `other.test` switched that (most recent) window to Other;
a `secret` link opened a new Private window, and a second one, with a normal
window in front, a tab in it; an unmatched link and a Most Recent Space
route with Detour inactive opened a new window each (the path from before
routes, no key window); with Detour active, a tab in the key window's space;
with the Default set to Personal, the Personal window. A list of four URLs
in one event went to four places (Work by switching the most recent window,
the Personal window, an Other window, the Private window). Through
LaunchServices on a renamed copy: an app-only route matched the app it
names and not another app, a URL route listed first won over it, and two
URLs from one open routed separately. `open -n` with three URLs
cold-launched the build and routed all three after launch. Captures (window
number) for phase 1; later LaunchServices steps ran into a screen lock and
have text logs only.

# Runtime check: the link that launched Detour

TASK-304, 2026-11-08, macOS 26.7, a temporary file-logging patch (not
committed).[^task-304] Senders: a bare swiftc tool and the same binary as an
LSUIElement app (`com.detourbrowser.verify.sender304`, started with `open
-n`) calling `NSWorkspace.open(_:withApplicationAt:)` on the worktree's
Debug build with `createsNewApplicationInstance` and
`environment = [DETOUR_DATA_DIR: …]` (the log's first line confirmed the
data directory), `open -n --env … -a <Debug app> URL`, and, for links while
running, a copy of the Debug app with its own bundle ID. Routes were seeded
with `sqlite3` after a first launch made the database. Results: the app
sender cold-launched Detour with a From app route for it to Private Window
and the link opened in a new Private window; the bare tool (no bundle ID)
with "links from Mail go to Quarantine" opened it in a quarantine window;
the bare tool with a Mail route to Private Window and no Quarantine route
opened a tab in the restored window (the Default); while running, the app
sender's link matched its route and the bare tool's went to the Default
although a Quarantine route existed.

# Tests

- `LinkPlacementTests` (the parts on this page): the sender's PID from the
  address, Detour itself, no PID or bundle ID; a Get URL event's URLs, one
  or a list; `LaunchLinkTracker`: while launching, the rest of the open
  within the window, other processes and later events.
- `ExternalLinkRoutingTests`: real windows in the test host driven through
  `application(_:open:)` and `openExternalURLs(_:sourceApp:launchedDetour:)`:
  the routed window comes forward, an unshown space switches the most recent
  normal window, never a Private one, Private reuse, source-app routes, the
  Default, Most Recent Space, a Quarantine route and Default opening a
  quarantine (TASK-194), multi-URL opens, non-web URLs ignored; TASK-304: a
  launch link with no known sender opens in a quarantine window when a From
  app route to Quarantine cannot be ruled out and in the Default when the
  only Quarantine route is a URL route it does not match, one from a known
  app follows its route, and Get URL events sent to `handleGetURLEvent`
  while running are routed URL by URL and not failed closed.
- The launch rule's resolver cases are in `LinkRouteResolverTests`
  ([resolver](./link-routing-resolver.md#tests)).

# Related

- [Link Routes](./link-routing.md): the hub.
- [Link placement](./link-routing-placement.md): which window each URL opens in.
- [Runtime verification](../playbooks/runtime-verification.md): the safe ways to deliver a URL to a Debug build.
- [Quarantine](./quarantine.md): where a failed-closed launch link opens.

[^task-191-2]: TASK-191.2: send links from other apps to the routed space
[^task-304]: Link Routes: a link that launches Detour has no known sending app, so From app routes can't match it
[^harness-2]: TASK-191.2 runtime harness
