---
type: Feature
title: Link Routes
description: "The Link Routes model (routes with a URL condition, a source-app condition or both, a target, a sort order; one Default target), the pure resolver and every rule it applies (first match wins, domainIs on a dot boundary with www, ports, IDN and IP literals defined, source-app routes external-only, one-way into Private, Quarantine and Quick Detour external-only, the Default for every origin; Quick Detour a visible target since TASK-193.5, opening a new Quick Detour on the front window's profile, never Private), storage in migration v20, why a space a route targets cannot be deleted (also from undo and redo), links from other apps (the pure placement rule, reading the sender from the Get URL Apple Event, delivering test links without reaching the production app), and typed URLs and links clicked in a page: the pure eligibility rule (new-tab opens route, plain clicks only to another host, never redirects, scripts, popups, Option/Shift-clicks, Peeks, subframes; host not site), the WebKit signals that tell a click from a script or a redirect, a route winning over the pinned/favourite Peek intercept, Cmd+L never routing, and the Settings Links pane (TASK-191.3): one row per route (URL, From app, Open in), Any URL and Any App as the 'no condition' choices, drafts and refused edits kept on their rows while the store holds the last valid version, validation in the store (empty or invalid pattern, no condition, a missing or Private space; an unchanged broken target stays editable), broken routes shown, the Default with its caption, live space and store updates, and the blocked-deletion alert's Open Links Settings… button."
tags: [links, spaces, storage, privacy, incognito]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-27T04:55:17Z }
stale_after: 2027-01-31T00:00:00Z
sources:
  - id: model
    resource: ../../Detour/Browser/LinkRouting/LinkRoute.swift
    title: LinkRoute.swift (LinkRoute, LinkRouteMatch, LinkRouteTarget)
  - id: resolver
    resource: ../../Detour/Browser/LinkRouting/LinkRouteResolver.swift
    title: LinkRouteResolver.swift (resolveLinkRoute, linkRouteMatch, linkRouteDomain, linkRoutesTargeting)
  - id: store
    resource: ../../Detour/Browser/LinkRouting/LinkRouteStore.swift
    title: LinkRouteStore.swift
  - id: alert
    resource: ../../Detour/Browser/LinkRouting/SpaceDeletionBlockedAlert.swift
    title: SpaceDeletionBlockedAlert.swift
  - id: record
    resource: ../../Detour/Storage/Models/LinkRouteRecord.swift
    title: LinkRouteRecord.swift
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (migration v20, link route accessors)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (deleteSpace, SpaceDeletionResult, linkRoutes, linkRouteContext)
  - id: task-193-3
    resource: backlog:TASK-193.3
    title: "Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)"
  - id: placement
    resource: ../../Detour/Browser/LinkRouting/LinkPlacement.swift
    title: LinkPlacement.swift (linkPlacement, LinkPlacementWindow, LinkPlacement)
  - id: sender
    resource: ../../Detour/Browser/LinkRouting/LinkSender.swift
    title: LinkSender.swift (linkSenderPID, linkSenderBundleID)
  - id: appdelegate
    resource: ../../Detour/App/AppDelegate.swift
    title: AppDelegate.swift (application(_:open:), openExternalURLs, place)
  - id: placement-tests
    resource: ../../DetourTests/LinkPlacementTests.swift
    title: LinkPlacementTests.swift
  - id: routing-tests
    resource: ../../DetourTests/ExternalLinkRoutingTests.swift
    title: ExternalLinkRoutingTests.swift
  - id: resolver-tests
    resource: ../../DetourTests/LinkRouteResolverTests.swift
    title: LinkRouteResolverTests.swift
  - id: store-tests
    resource: ../../DetourTests/LinkRouteStoreTests.swift
    title: LinkRouteStoreTests.swift
  - id: task-191
    resource: backlog:TASK-191
    title: "TASK-191: rules that route links and typed URLs to a chosen space"
  - id: task-191-1
    resource: backlog:TASK-191.1
    title: "TASK-191.1: route model, matching rule and storage"
  - id: task-191-2
    resource: backlog:TASK-191.2
    title: "TASK-191.2: send links from other apps to the routed space"
  - id: harness
    resource: ../../docs/harness/task191-1-harness.patch
    title: TASK-191.1 runtime harness
  - id: harness-2
    resource: ../../docs/harness/task191-2-harness.patch
    title: TASK-191.2 runtime harness
  - id: eligibility
    resource: ../../Detour/Browser/LinkRouting/LinkRoutingEligibility.swift
    title: LinkRoutingEligibility.swift (linkRoutingEligibility, isSameLinkRoutingHost, inPageLinkOutcome, routedLinkDecision, typedURLIsRoutable)
  - id: window-routing
    resource: ../../Detour/Browser/Window/BrowserWindowController+LinkRouting.swift
    title: BrowserWindowController+LinkRouting.swift (the WebKit signals, routedDecision, routedTypedDecision, openRoutedLink)
  - id: navigation
    resource: ../../Detour/Browser/Window/BrowserWindowController+Navigation.swift
    title: BrowserWindowController+Navigation.swift (decidePolicy)
  - id: ui-delegate
    resource: ../../Detour/Browser/Window/BrowserWindowController+WKUIDelegate.swift
    title: BrowserWindowController+WKUIDelegate.swift (createWebViewWith)
  - id: eligibility-tests
    resource: ../../DetourTests/LinkRoutingEligibilityTests.swift
    title: LinkRoutingEligibilityTests.swift
  - id: in-page-tests
    resource: ../../DetourTests/InPageLinkRoutingTests.swift
    title: InPageLinkRoutingTests.swift
  - id: task-191-4
    resource: backlog:TASK-191.4
    title: "TASK-191.4: route typed URLs and links clicked inside Detour"
  - id: harness-4
    resource: ../../docs/harness/task191-4-harness.patch
    title: TASK-191.4 runtime harness
  - id: validation
    resource: ../../Detour/Browser/LinkRouting/LinkRouteValidation.swift
    title: LinkRouteValidation.swift (LinkRouteProblem, linkRouteProblems, linkRoutePatternIsValid, linkRouteTargetProblem)
  - id: editor
    resource: ../../Detour/Browser/Settings/LinkRouteEditor.swift
    title: LinkRouteEditor.swift (the pane's rules and rows)
  - id: pane
    resource: ../../Detour/Browser/Settings/LinksSettingsViewController.swift
    title: LinksSettingsViewController.swift (the Links pane)
  - id: editor-tests
    resource: ../../DetourTests/LinkRouteEditorTests.swift
    title: LinkRouteEditorTests.swift
  - id: task-191-3
    resource: backlog:TASK-191.3
    title: "TASK-191.3: Settings UI to add, edit, reorder and remove routes"
  - id: harness-3
    resource: ../../docs/harness/task191-3-harness.patch
    title: TASK-191.3 runtime harness
  - id: task-212
    resource: backlog:TASK-212
    title: "TASK-212: rename the feature to Link Routes"
  - id: task-193-5
    resource: backlog:TASK-193.5
    title: "Quick Detour: Opt-Cmd-click entry points, links from other apps, and auto-archive"
---

Link Routes send a link to a chosen space by rule: links opened from other
apps, typed URLs and links clicked in a page.[^task-191] The feature was
modelled on Arc's and first carried Arc's name, Air Traffic Control; it was
renamed Link Routes in TASK-212 (user decision 2026-10-26).[^task-212] The
old Backlog tasks (TASK-191 to TASK-191.4, TASK-193.5) and Arc's screenshots
in `docs/air-traffic-control/` keep the old name. The Settings pane is still
**Links** and each entry is still a route. This page covers the model, the
pure resolver, storage, the rule that a space routes point at cannot be
deleted,[^task-191-1] links from other apps (TASK-191.2,
[below](#links-from-other-apps)),[^task-191-2] and
typed URLs and clicked links (TASK-191.4,
[below](#typed-urls-and-links-clicked-in-a-page)).[^task-191-4] The Settings
Links pane is TASK-191.3 ([below](#the-links-pane)).[^task-191-3]

# Model

| Type | Fields / cases |
|---|---|
| `LinkRoute` | `id`, `match: LinkRouteMatch?`, `sourceApp: String?` (bundle ID), `target`, `sortOrder` |
| `LinkRouteMatch` | `kind` (`isEqualTo`, `contains`, `domainIs`) and `pattern` |
| `LinkRouteTarget` | `.space(UUID)`, `.mostRecentSpace`, `.privateWindow`, `.quarantine` (TASK-194), `.quickDetour` (TASK-193.5) |

- A route needs at least one condition (`hasCondition`): a non-empty pattern
  or a source app. App-only routes are allowed (user, 2026-10-25). The store
  refuses a route with neither (and, since TASK-191.3, any route with a
  problem: [validation](#validation)), and the resolver ignores one.
- With both conditions, both must hold.
- One **Default** target, `.mostRecentSpace` unless set.
- Routes are app-wide, not per profile: spaces are global.

# The resolver

`resolveLinkRoute(url:origin:routes:defaultTarget:context:) -> LinkRouteDecision`
is pure. `LinkOrigin` is `.external(sourceApp:)`, `.typed(fromSpace:isPrivateWindow:)`
or `.clicked(inSpace:isPrivateWindow:)`; `LinkRouteContext` holds the ids of
the normal spaces that exist (`TabStore.linkRouteContext`). The decision is
`.openInSpace(id)`, `.mostRecentSpace`, `.privateWindow`, `.quarantine`,
`.quickDetour` or `.stay`.

## Two layers: whether, then where

A link inside Detour is decided in two steps. **Whether** it is routed at
all is TASK-191.4's pure click rule, `linkRoutingEligibility` (and its
typed-URL rule, `typedURLIsRoutable`: a URL, not a search, from the new-tab
palette; [below](#typed-urls-and-links-clicked-in-a-page)): same-host plain clicks, redirects,
script navigations, popups that keep their opener, Opt-Cmd- (Quick Detour,
TASK-193.5), Option- and Shift-clicks and links in a Peek never get past it. **Where** a routed link goes is
`resolveLinkRoute`, which has no exclusions of its own: every `.typed` or
`.clicked` origin it is handed gets the routes and then the Default. The
contract is written where a caller meets it: the doc comments on
`LinkOrigin.typed`/`.clicked` and on `resolveLinkRoute`, and the header of
`LinkRouteResolver.swift`. The case names were kept (`.clicked`, not
`.routableClick`): the vocabulary matches the task notes, and the comment
on the case states the precondition.

## Rules

| Rule | Why |
|---|---|
| Routes are tried in `sortOrder` (ties by array order); the first that matches **and** can be used from this origin wins. One that matches but cannot be used is skipped and the next is tried. | A deleted space, a normal space from a Private window or Quarantine for a typed URL must never route into nothing. |
| Only `http`/`https` URLs match any route. | A `detour://` page, a file or `data:` URL belongs where it was opened. |
| A source-app route matches only `.external` with that bundle ID (compared without case). An external link with no known sender matches no source-app route. | The sender only exists for an Apple Event; `open` from a shell names none. |
| `.privateWindow` matches from every origin. From a Private window it is `.stay`. | Routing into Private is allowed, from anywhere (user, 2026-10-24). |
| From a Private window, routes to a space or to Most Recent Space (and Quick Detour) are skipped. | Nothing routes out of Private. |
| A route to the space the link is already in is `.stay`, and stops the search. | First match wins; it already is where the route sends it. |
| `.mostRecentSpace` is `.mostRecentSpace` for an external link and `.stay` for a typed URL or click. | A typed URL or click is in the key window, whose space is the most recent one. |
| `.quarantine` and `.quickDetour` apply to external links only; elsewhere they are skipped. | Quarantine is defined for links from other apps (TASK-194). Quick Detour likewise, decided in TASK-193.5 (2026-10-26): links from other apps reach Quick Detour through this target; inside Detour, Opt-Cmd-click opens one. Widening it is one line. |
| A route to a space not in the context is skipped. | Deletion is blocked (below), but a space removed some other way must not route into nothing. A Private window's space is never in the context, so no route can name one. |
| No route: the **Default applies from every origin**, with the same rules as a route's target (below). | User decision 2026-10-25. |
| Default = a normal space: a typed URL or click from another normal space opens there; from that space it is `.stay`. | As a route to that space. |
| Default = Most Recent Space: a typed URL or click is `.stay`; an external link goes to the most recent space. | The key window's space is the most recent one. |
| Default = Private window: `.privateWindow` from every normal origin, `.stay` from a Private window. | As a Private route. |
| Default = Quarantine or Quick Detour: external links only; a typed URL or click is `.stay`. | The user is already in a space, so it stays rather than going to the most recent space. |
| From a Private window, a Default naming a normal space (or Most Recent Space) is ignored: `.stay`. | The one-way Private rule. |
| A Default that cannot be used (a deleted space): an external link goes to `.mostRecentSpace`, a typed URL or click is `.stay`. | An external link needs a window; a typed URL or click already has one. |

**Rejected: the Default for links from other apps only.** The first version
applied the Default to external links and left every unmatched typed URL or
click where it was, reading "Quarantine routes (and the Default) apply only
to external links" from the task notes, so that a Default of "Work" would not
pull every typed URL into Work. The user decided on 2026-10-25 that the
Default is a route like any other, for every origin; which clicks are routed
at all is the click rule's job (above), not the Default's.

## Match text

| Kind | Compared |
|---|---|
| `contains` | The pattern, lowercased, as a substring of `url.absoluteString` lowercased: the whole URL including the query and the **fragment**, in its encoded form (punycode host, percent-encoded path). A hash-routed app's `#/inbox` can be matched. |
| `isEqualTo` | Both sides normalised: lowercased, fragment, user info and a default port dropped, an empty path as `/`. `https://Example.com` equals `https://example.com/#top`; `:8443` does not equal no port. A pattern without a scheme is not a URL and equals nothing. |
| `domainIs` | The URL's host (`authorityHost`, lowercased, trailing dot dropped) equals the pattern's domain or ends with `.` + domain. `example.com` covers `a.example.com`, not `badexample.com` or `example.com.evil.test`. |

How `linkRouteDomain(fromPattern:)` reads a `domainIs` pattern:

- whitespace trimmed; a pasted URL, a path or a port is reduced to the host
  (`https://example.com/x`, `example.com:8080` → `example.com`). **Ports are
  ignored** on both sides: `localhost:3000` covers `localhost:4000`; a rule
  that needs a port uses `contains`.
- a leading `*.` or `.` is dropped (`*.example.com` also covers the apex).
- a leading **`www.` is dropped**: `www.example.com` means the site, so it
  covers `example.com` and all its subdomains. `example.com` covers
  `www.example.com` anyway. A bare `www` stays a host.
- **IDN**: the host is parsed with `URL(string:)`, which IDNA-encodes it, so
  both sides compare in punycode (`münchen.de` → `xn--mnchen-3ya.de`, the form
  WebKit's URLs and `authorityHost` carry).
- **IP literals** match exactly, with no subdomain rule: `0.1` must not
  cover `10.0.0.1`. A bare IPv6 pattern (`::1`) is bracketed to match
  `authorityHost` (`[::1]`); see [IPv6 hosts in URL APIs](../platform/ipv6-url-hosts.md).

# Storage

Migration **v20** of the [session database](../architecture/session-database.md):

| Table | Columns |
|---|---|
| `linkRoute` | `id` (text PK), `matchKind`, `matchPattern`, `sourceApp`, `targetKind` (not null), `targetSpaceID`, `sortOrder` (not null) |
| `linkRouteDefault` | `id` integer PK with `CHECK (id = 1)`, `targetKind`, `targetSpaceID`. No row means Most Recent Space. |

- The target is stored as text: `LinkRouteTarget.storageKind` plus the space
  id for `.space`. A kind (or match kind) a later build adds is a string this
  build does not know: `LinkRouteStore` skips the row on load and leaves it in
  the table; an unknown Default reads as Most Recent Space.
- **No foreign key from `targetSpaceID` to `space`.** Every session save
  deletes and re-inserts all space rows (see the session database page), so a
  cascade would wipe the routes on each save and a restriction would fail the
  save. The test `testRoutesSurviveASessionSave` pins this.
- `LinkRouteStore` (`.shared` over `AppDatabase.shared`; `TabStore.shared.linkRoutes`
  is the same instance, other `TabStore`s get one over their own database)
  loads once and writes through: `add` (appends, refuses a route with any
  [problem](#validation), trims the bundle ID), `update` (keeps the place,
  refuses a problem), `moveRoute(id:to:)` (renumbers 0…n−1 in one
  transaction), `removeRoute`, `setDefaultTarget` (refuses a missing or
  Private space). Each change posts `LinkRouteStore.didChangeNotification`;
  a refused one posts nothing. The resolver's callers read
  `linkRoutes.routes` and `defaultTarget` for every link, so a change applies
  to the next link without a restart.

# A space routes target cannot be deleted

User decision 2026-10-25: deletion is blocked, rather than leaving broken
routes. `linkRoutesTargeting(spaceID:routes:defaultTarget:)` (pure) and
`LinkRouteStore.references(toSpace:)` return `LinkRouteReferences` (the routes
in order, and whether the Default targets it). `TabStore.deleteSpace(id:)`
now returns `SpaceDeletionResult`: `.deleted`, `.notDeleted` (unknown or last
space) or `.blockedByLinkRoutes(references)`, checked before anything is torn
down or any undo registered.

| Caller | What it does on a block |
|---|---|
| Sidebar space menu, Delete Space (`BrowserWindowController.tabSidebarDidRequestDeleteSpace`) | Checks the routes **first**, before "close or move all tabs" and the confirmation, so nobody closes every tab only to be refused; handles a block from `deleteSpace` too. |
| Settings > Spaces "−" (`SpacesSettingsViewController.deleteSpaceClicked`) | Shows the alert and leaves the list and selection alone. |
| Undo of Add Space, redo of Delete Space (`TabStore.deleteSpaceFromUndoStack`) | Post `TabStore.spaceDeletionBlockedNotification` (a `SpaceDeletionBlock`: space id, name, references; read with `TabStore.spaceDeletionBlock(from:)`). Every `BrowserWindowController` observes it; the frontmost browser window in `NSApp.orderedWindows` shows the alert, from the run loop (`RunLoop.main.perform`, default mode) once the undo has returned. Not from a main-queue block: a modal alert run inside one holds the main queue, and every main-queue block and main-actor job with it, until it is dismissed. The entry is put back, so Cmd+Z (or Cmd+Shift+Z) tries again once the routes change. A direct `deleteSpace` posts nothing: its caller reads the result. |

`UndoManager` cannot put an entry back on the stack it is running from:
whatever is registered while undoing lands on the redo stack (and while
redoing on the undo stack), and a plain registration after the undo returns
would land right but clear the redo stack. `reRegisterRunningUndoEntry`
therefore registers a one-step bounce on the opposite stack and runs it from
the main queue straight away (`redo()` after an undo, `undo()` after a redo);
run that way, its registration of the original handler lands where the entry
came from, and neither stack is otherwise changed. It skips the bounce if an
undo group is open by then. Before this, a refused undo or redo did nothing,
showed nothing, and was gone (review finding, 2026-10-25).

`SpaceDeletionBlockedAlert` is an `NSAlert`: "“Work” can’t be deleted", then
one line per route (`linkRouteSummary`: "Domain is …", "URL contains “…”",
"URL is …", "Links from Mail", with the app's name looked up from the bundle
ID) and "The Default route" when it applies. Buttons: **OK** (the default)
and **Open Links Settings…** (TASK-191.3), which opens Settings on the Links
pane with the routes and the Default that target the space highlighted
(`SettingsWindowController.showLinksPane(highlightingSpaceID:)`). The same
`run(spaceName:spaceID:references:)` serves the sidebar, the Spaces pane and
the undo/redo refusal (`SpaceDeletionBlock` carries the space id).

A Private window's space is never a route target, so closing a Private
window (`removeIncognitoSpace`) does not consult the routes.

# Links from other apps

`AppDelegate.application(_:open:)` reads the sender of the Apple Event being
handled, then `openExternalURLs(_:sourceApp:)` takes each http/https URL on
its own: `resolveLinkRoute` with `.external(sourceApp:)`, then the pure
`linkPlacement(for:windows:)` with a snapshot of the browser windows, most
recently active first (`NSApp.browserWindowControllersFrontToBack`, then any
registered window missing from the window list, such as a minimized one).
The snapshot is taken again for every URL: an earlier URL of the same open
may have opened or switched a window. The AppKit side (`place`) only carries
the placement out.[^task-191-2]

| Decision | Placement | Why |
|---|---|---|
| A space a normal window shows | `.openInWindow`: a tab there, selected, the window brought forward (`makeKeyAndOrderFront`). Several show it: the most recent of them. | The space is already on screen; the user goes to it. |
| A space no window shows | `.switchWindow`: the most recent **normal** window switches to it (`setActiveSpace(selectTab: false)`), then as above. No normal window: `.openInNewWindow` (`createNewWindow(showing:)`). | User decision 2026-10-25 (the 191.2 proposal): as a space switch does, rather than a new window per link. A Private window is never switched to a normal space. |
| Private window | `.openInPrivateWindow`: a tab in the most recent Private window; none open: `.openInNewPrivateWindow` (`createNewWindowWithURL(_:incognito: true)`). | Decided 2026-10-24. |
| Most Recent Space (and the resolver's fallbacks to it) | `.mostRecentSpace`: exactly the code from before routes, a tab in the key browser window's active space, else `createNewWindowWithURL`. | Kept as it was. With Detour in the background there is no key window, so that is a new window every time (seen at runtime); unchanged on purpose. |
| Quick Detour | `.openInQuickDetour`: `AppDelegate.openLink` opens a new Quick Detour window with the link (no tab in any space), on `QuickDetour.profileForRoutedLink` — the frontmost Detour window's profile, but never Private (a Private window in front is passed over for the next window's; none: the first normal profile) — its Open in naming the most recent normal window's space of that profile. | TASK-193.5. Never Private: only a Private Window (or Quarantine) target takes a link from another app into Private; see [Quick Detour](./quick-detour.md#links-from-other-apps-the-link-routes-quick-detour-target). The Most Recent Space fallback TASK-191.2 left for it is gone. |
| Quarantine | `.mostRecentSpace` | TASK-194 does not exist yet and the Links pane hides it. |
| `.stay` | `.mostRecentSpace` | The resolver never says stay for an external link; if it did, the link still needs a window. |

A routed placement whose window or space has gone by the time it runs falls
back to the Most Recent Space path (or a new Private window).

The carrying-out is `AppDelegate.placeTab(routedTo:makeTab:didSelect:)`
since TASK-193.3: the same rule, with the tab made by a closure that gets the
receiving space once its window shows it (switched, or opened for it).
`openLink` passes one that opens the URL; Quick Detour's Open in passes one
that hands its own page over (`TabStore.moveQuickDetourTab`), and a
`didSelect` that announces the move to the extension contexts before the
window announces the tab active. A new Private window made for a placement
holds only the placed tab (no empty tab of its own). The placed tab never
shows the collapsed sidebar's "Opened new tab in background" toast, since it
is selected at once.[^task-193-3]

## The sender

`linkSenderPID(of:)` reads `keySenderPIDAttr`, else a `keyAddressAttr` that
is a process ID; `linkSenderBundleID` names it with
`NSRunningApplication(processIdentifier:)`, and treats Detour itself, a PID
of 0 and a process without a bundle ID as no sender. What macOS reported on
2026-10-25 (macOS 26.7, logged by the harness):

| Sender | `keySenderPIDAttr` | Bundle ID |
|---|---|---|
| An app calling `NSWorkspace.open(_:withApplicationAt:)` (LaunchServices) on a running Detour | the calling app's PID (type `'magn'`); `keyAddressAttr` and `keyOriginalAddressAttr` the same PID | the app's (`com.detourbrowser.verify.sender-a`), so its source-app route matched |
| `open -a <app> URL` from a shell | the `open` process | none: no sender |
| A tool sending the event itself (`AESendMessage`) | the tool's PID | none, even when the binary sits inside an `.app` bundle but was not launched by LaunchServices: `NSRunningApplication` knows only LaunchServices-launched processes |
| A sender that has already exited | its PID | none (`NSRunningApplication` returns nil) |
| The URL that cold-launches Detour (`open -n`, or `NSWorkspace` with a new instance) | no current Apple Event at all (`currentAppleEvent` is nil) for the first URL; later URLs of the same open arrive as their own events, from the opener | none for the first URL |

So a source-app route matches links from running apps that open them
through LaunchServices (Mail, Slack and the like do), and never the link
that launches Detour. **Not verified**: Finder (opening a `.webloc` goes to
the default browser, and scripting Finder at the debug PID would need an
Automation grant), Mail, Slack and other real apps (not scripted, on
purpose). The raw-sender `int32Value` trap: a `typeKernelProcessID`
descriptor reads as 0 through `int32Value` (no numeric coercion), so
`linkSenderPID` reads its four bytes; `keySenderPIDAttr` cannot be set on an
event built in process (`setAttribute` ignores it), so only the address path
is unit-tested.

How links arrive: every URL of an `open -a` with several URLs, or of one
`NSWorkspace.open` with several, came as its own Get URL event, one URL per
`application(_:open:)` call. One event whose direct object is a list of
URLs reaches `application(_:open:)` as a single call with all of them; each
is still routed on its own. At a cold launch the URLs arrived after
`applicationDidFinishLaunching` (the session was restored and routes
applied), not in launch order. Activation: `open -a` activated Detour before the event was handled (a key
window existed); `NSWorkspace.open` with `activates = false` and a raw Apple
Event do not, and then the placement only orders the window to the front of
Detour's own windows. (The default `NSWorkspace.open`, which activates, was
not observed.)

## Delivering test links safely

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

# Typed URLs and links clicked in a page

TASK-191.4.[^task-191-4] The window's WebKit delegates and the command
palette describe what happened; the pure `linkRoutingEligibility` and
`typedURLIsRoutable` (`LinkRoutingEligibility.swift`) decide whether it is
routed; `resolveLinkRoute` with `.clicked` or `.typed` decides where; and
`AppDelegate.openLink(_:routedTo:)`, the 191.2 placement code moved out of
`openExternalURLs` so both paths call it, decides which window. A routed link
is therefore placed exactly as a link from another app: the window showing
the space, brought forward, with the tab selected; else the most recent
normal window (normally the one clicked in) switches to the space; Private
into the most recent Private window, else a new one. A decision of `.stay`
(no route, Most Recent Space, a route to the current space, anything out of a
Private window, Quarantine or Quick Detour) changes nothing: the code from
before routes runs.

## Entry points

| Where | What is asked | Routed |
|---|---|---|
| Command palette submit (`paletteLoadURL`) | `typedURLIsRoutable(url, isSearch:, navigatesInPlace:)` | A URL (per `AddressInputClassifier`, which also covers a history row) submitted in new-tab mode (Cmd+T). A search never; Cmd+L or a click on the address bar never. |
| `decidePolicy`, Opt-Cmd branch (TASK-193.5) | not asked: the branch opens a Quick Detour; the rule says `quickDetourClick` | never |
| `decidePolicy`, Cmd+click branch | the rule, before the background tab | Cmd+click (Cmd+Shift too; Cmd+Option only with the Quick Detour click off in Settings, or to a non-web URL) |
| `decidePolicy`, after the download check, before the anchor intercept | the rule for every navigation that gets that far | A `target=_blank` link (nil `targetFrame`, before WebKit would call `createWebViewWith`), and a plain click to another host |
| `createWebViewWith`, a page's own request (not the link menu's) | the rule, before the anchor intercept | A tab-style `window.open` |

A routed click is cancelled (the page's tab stays on its page; a routed
`window.open` returns nil, so the page gets no window) and opened one
main-queue turn later (`openRoutedLink`), so the policy decision returns
before windows switch spaces or come forward. A typed URL is opened at once.

## The rule

`linkRoutingEligibility(InPageLinkRequest) -> .routable(kind) | .notRouted(reason)`.
The request carries the entry (`.navigationAction(isLinkActivation:targetsMainFrame:opensNewWindow:isRedirect:)`,
`.pageWindowRequest(isLinkActivation:wantsPopup:)`, `.linkMenuAction`), the
modifiers, the user-gesture signal, whether it is in a Peek, the page URL
(`webView.url`) and the target. Checked in this order:

| Case | Result | Why |
|---|---|---|
| Target not http/https (`mailto:`, `detour://`, `data:`, `about:`, `blob:`, `file:`, app schemes) | not routed (`notWebURL`) | Routes match web pages only; non-web schemes and downloads are decided by the policy before it asks anyway. |
| Fired by a Peek's page, or while a Peek is presented | `inPeek` | A Peek is a look at a link; its links navigate the Peek (decided 2026-10-25). The overlay is modal, so while it is up a click can only be in it. |
| The link menu's own actions (Open Link in New Tab / Window / Split View) | `linkMenuAction` | The user picked where it opens. Not in the decided list; kept unrouted (see [decisions](#decisions-taken-here)). |
| A `_blank` link reaching `createWebViewWith` | `decidedByNavigationPolicy` | WebKit asked the policy first; it was routed (cancelled) or not there. |
| Popup-style `window.open` (`_wantsPopup`, else explicit x/y/width/height) | `popupWindow` | It must keep its opener (sign-in and payment windows, TASK-168). |
| Tab-style `window.open` without a gesture | `noUserGesture` | WebKit blocks those anyway (`javaScriptCanOpenWindowsAutomatically` is off). |
| Tab-style `window.open` | **routed** (`scriptedWindow`) | A new-tab open. |
| A server redirect (`_isRedirect`) | `redirect` | Never routed: the user clicked the link, not the redirect target. Checked first because WebKit asks the policy again for the redirect with the click's link activation and gesture. |
| Not a link activation (`.other`, `.formSubmitted`, `.backForward`, `.reload`, `.formResubmitted`) | `notLinkActivation` | Script navigations (`location.href = …`, also inside a click handler), client redirects (`location.replace` on load, meta refresh), forms, history, app loads. |
| A link activation without a user gesture | `noUserGesture` | A page's own `a.click()` from a timer or a load script. |
| Opt-Cmd (Shift or not), to a web URL, with Settings' switch on (`quickDetourClickEnabled`) | `quickDetourClick` | TASK-193.5: a Quick Detour, which the user chose. |
| Cmd | **routed** (`commandClick`) | A new-tab open, whatever the host or frame. |
| Shift | `shiftClickPeek` | Shift-click Peeks; Shift before Option, as the branches. |
| Option | `optionClickSplit` | Option-click splits. |
| `target=_blank` (nil `targetFrame`), any frame | **routed** (`blankTarget`) | A new-tab open, same host included. |
| Target a subframe | `subframe` | An iframe navigating is not the page leaving. A `target=_top` link in an iframe targets the main frame and counts as a plain click. |
| Same host as the page | `sameHost` | Decided 2026-10-25: moving within a site stays in the tab. |
| Plain click to another host | **routed** (`crossHostClick`) | The tab stays on its page; the link opens in the routed destination. |

**Host, not site.** `isSameLinkRoutingHost` compares hosts without case,
trailing dot or a leading `www.` (dropped only when a dot remains, so
`www.com` is not `com`); ports are ignored (host, not origin). There is no
public-suffix list in the codebase, so it cannot compare registrable domains:
`mail.example.com` is another host than `example.com`, and a click between
them is routed (a route that matches it decides; with none, nothing moves).
A page without a host (`about:blank`, a `data:` page) has no host to stay on,
so a click from it to a web URL is cross-host. The History page's rows are
plain links on `detour://history`, so a click on one is a cross-host click
like any other.

Typed: `typedURLIsRoutable` is `!isSearch && !navigatesInPlace && http(s)`.
`isSearch` is the palette's own classification (a submission
`AddressInputClassifier` does not read as a URL, or a search suggestion row),
so a search URL whose host a route names (`google.com`) is still a search.

## Signals from WebKit

Measured 2026-10-25 on macOS 26.7 with a standalone `WKWebView` against a
loopback fixture server (two hosts: `127.0.0.1` and `localhost`), logging
every `decidePolicyFor` and `createWebViewWith`:

| Action | `navigationType` | `targetFrame` | `_isUserInitiated` | `_isRedirect` | `_hasOpener` |
|---|---|---|---|---|---|
| Real Cmd+click (posted mouse event) | link | main | true | false | false |
| `a.click()` from `evaluateJavaScript` | link | main | true | false | false |
| A page's own timer `a.click()` (no gesture) | link | main | **false** | false | false |
| Timer `location.href = …` | other | main | false | false | false |
| A click handler's `location.href = …` | other | main | **true** | false | false |
| A click handler's `setTimeout(() => a.click(), 0)` | link | main | true | false | false |
| Same-host link, then a 302 to another host | link, then **link again** for the redirect target | main | true, true | false, **true** | false |
| Same-host link to a page that `location.replace`s on load | link, then other | main | true, false | false | false |
| `<a target=_blank>` | link (policy), then link (`createWebViewWith`) | nil | true | false | false |
| `window.open(url)` from a click | other (`createWebViewWith` only) | nil | true | false | true |
| `window.open(url, 'p', 'popup,…')` | other (`createWebViewWith` only), `_wantsPopup` true | nil | true | false | true |
| `dispatchEvent(new MouseEvent('click', {metaKey: true}))` | link, modifier flags **0** | main | true | false | false |

So: `navigationType == .linkActivated` separates link clicks from script
navigations and client redirects; `_isUserInitiated` separates a user's click
from a page's own `a.click()`; `_isRedirect` is the only thing that separates
a server redirect (which keeps the click's type and gesture) from the click.
Both are SPI on `WKNavigationAction`, read by key behind a `responds(to:)`
guard (`BrowserWindowController+LinkRouting.swift`); without them every
action counts as a gesture and nothing as a redirect. Anything the app runs
with `evaluateJavaScript` carries a gesture, which is why the earlier
spike saw `_isUserInitiated` true for every call (see
[WKWebView delegate order](../platform/wkwebview-delegate-order.md)), and why
the unit tests can drive real clicks that way. A synthetic click carries no
modifiers into the navigation action, so a page cannot fake a Cmd+click.

A click handler's own `a.click()` (directly or a `setTimeout(…, 0)` later)
inherits the user's gesture and is routed like the click: WebKit reports it
exactly as a real click.

## The Peek intercept and other branches

- **A route elsewhere wins over the pinned/favourite anchor intercept**
  (decided 2026-10-25). `inPageLinkOutcome(routed:anchorPeeks:)`: a routed
  decision → open it there; `nil` or `.stay` → the intercept as before (Peek,
  or nothing). On an anchored tab a routed cross-host click or `_blank` link
  or tab-style `window.open` therefore goes to its space instead of a Peek.
- Policy order is unchanged around it: internal URL, Opt-Cmd (Quick Detour,
  TASK-193.5), **Cmd+click (route, else background tab)**, Shift (Peek),
  Option (split), back/forward into an error
  page, non-web scheme, download, **route, then the anchor intercept**, allow
  ([tab lifecycle](../tabs/tab-lifecycle.md)).
- A redirect is never routed, but the anchor intercept still sees it: WebKit
  reports a server redirect as a link activation, so on a pinned tab or
  favourite a same-host link that redirects to another host **opens the
  redirect target in a Peek** (seen at runtime, below). That is how the
  intercept behaved before this task; [Peek](../tabs/peek.md) said otherwise
  and was corrected.

## Decisions taken here

Cases the task's decisions did not name, decided while implementing (to
confirm):

- **The link menu's actions are not routed** (Open Link in New Tab, in New
  Window, in Split View): the user chose where the link opens. Routing Open
  Link in New Tab like Cmd+click would be one line in `createWebViewWith`.
- **Cmd+L (or a click on the address bar) while a Peek is open routes.**
  `focusAddressBar` and the faux address bar open the palette in new-tab mode
  then (it shows the Peek's URL but opens a new tab), and the rule keys on the
  palette's mode, not on the key that opened it.
- **A routed Cmd+click opens selected, in front**, as a link from another
  app does, not as a background tab in the other space: a tab that appeared
  silently in a space not on screen would look like a click that did nothing.
- **Cmd+click and `_blank` in an iframe route**: they open a new tab whichever
  frame the link is in; "subframe navigations" are an iframe navigating
  itself.
- **`window.open()` then `w.location = …`** (xterm.js's pattern) is not
  routed: the open has no web URL and the later navigation is the child's,
  type `.other`.

# Runtime check: typed URLs and clicks

Harness `docs/harness/task191-4-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1914`, 2026-10-25, screen unlocked.[^harness-4]
A loopback fixture page of links reached as `127.0.0.1` (the page),
`localhost` (routed to Work) and `[::1]` (no route); window B on Work, window
A on Personal with a pinned tab; real mouse and key events posted with
`NSApp.postEvent`. Every routing question and placement was logged:

| Case | Logged | Result |
|---|---|---|
| Plain same-host click | `notRouted(sameHost)` | navigated in place |
| Plain click to `localhost` | `routable(crossHostClick)` → Work → `openInWindow(B)` | B in front with the tab selected; A's tab stayed on its page |
| Cmd+click to `localhost` / same host | `commandClick` → Work / decision none | Work window / background tab in A, as before |
| `_blank` (routed path) / unrouted | `blankTarget` → Work / none | Work window / a tab in A (its `createWebViewWith` logs `decidedByNavigationPolicy`) |
| `window.open` tab-style / popup | `scriptedWindow` → Work / `popupWindow` | Work window / a tab in A whose opener received its `postMessage` |
| Option-click, Shift-click | not asked: their branches run first | a split; a Peek |
| In a Peek: `_blank`, cross-host click to a Private-routed URL | `inPeek` | a tab in A as before; the Peek navigated |
| Server redirect to `localhost` | `sameHost`, then `redirect` (`_isRedirect`, still a link activation with a gesture) | the tab followed the redirect |
| Client redirect, `onclick` `location.href`, page timer `a.click()` | `notLinkActivation`, `notLinkActivation` (gesture true), `noUserGesture` | in place |
| `onclick` → `a.click()` | `crossHostClick`, gesture true | routed to Work, like the click |
| Cross host with no route (`[::1]`) | routable, decision none | in place |
| Pinned tab: to `localhost` / to `[::1]` / same-host link redirecting to `localhost` | Work / none / `redirect` | Work window, no Peek / Peek / **Peek of the redirect target** |
| Cmd+T `localhost:8714/b?kind=typed` | `TYPED routable` → Work → `openInWindow(B)` | in B |
| Cmd+L, a search (route `contains "routeme"`) | `navigatesInPlace`, `isSearch`: not routable | in place; a search tab in A |
| Private route from A, twice | `privateWindow` → `openInNewPrivateWindow`, then `openInPrivateWindow(P)` | a new Private window, then a tab in it |
| From the Private window: click and typed URL to `localhost` | routable, decision none (normal routes ignored) | in place; a tab in P |

Captures by window number in the session scratchpad (`task191-4/out`).
Input trap: a plain click posted to a window of an **inactive** app is
swallowed while a Cmd-click goes through (macOS's click-without-activating),
so a first run made while the user was in another app routed only the
Cmd-clicks; the harness now activates Detour and makes the window key before
each input. Even then the first plain click after a window became key
occasionally produced no navigation action at all and was re-posted.

**Not verified at runtime:** a favourite's tab (the pinned tab stands in for
the anchor intercept; both go through `PeekAnchor.anchorURL`), a split pane
clicking (the eligibility does not look at panes), a link in an iframe
(subframe, `target=_top`), the History page's links, and real sites.

# Runtime check

Harness `docs/harness/task191-1-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1911`, 2026-10-25.[^harness] On a fresh data
directory v20 ran; the sidebar's own `deleteSpaceClicked:` action and the
Settings pane's "−" both raised the alert naming the route, and the space
survived; with a source-app route and the Default on another space the alert
listed "Links from Mail" and "The Default route"; after removing the route,
the sidebar asked "Delete “Routed”?" and the space went. A relaunch read the
route and the Default back and still refused. A database taken back to v19
by hand (tables dropped, the `v20` migration row deleted) was migrated at
launch with its spaces kept.

Second run, same day, screen unlocked, light and dark (`NSApp.appearance`
pinned by `DETOUR_VERIFY_APPEARANCE`): the alert captured by its own window
number from the sidebar and from the Settings pane, and an undo step: add a
space, route to it, Edit > Undo Add Space (the menu item's own action) shows
the alert, the space stays and the stacks read as before (Undo Add Space,
nothing to redo); after the route is removed the same undo deletes it. The
redo path (delete, undo, Default to the space, Redo) behaves the same. With
Detour in the background the Edit menu's items are disabled (no key window),
so the harness then sends the item's action to the window controller.

**Harness trap: never end an automatic undo group by hand.** A first
version of the undo step called `endUndoGrouping` on the `groupsByEvent`
group (the harness posts no events, so AppKit never closes it). NSUndoManager
then refused the next registration with an ObjC exception ("must begin a
group before registering undo"); thrown through the harness's Swift task and
caught by AppKit, it left a stale executor in thread-local storage, and the
next `MainActor.assumeIsolated` outside a task (the GPU reapers' 30 s timers,
`RecentTabSwitcher`'s observer) crashed in `swift_task_isCurrentExecutor`
seconds later, far from the cause. Turning event grouping off and grouping
each step by hand, as the unit tests do, fixed it; the exception shows in the
unified log as `_registerUndoObject:: NSUndoManager ... is in invalid state`.

# Runtime check: links from other apps

Harness `docs/harness/task191-2-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1912`, 2026-10-25.[^harness-2] With windows on
Home, Work and Personal (Personal in front) and Detour in the background:
`work.test` opened in the Work window and brought it to the front of
Detour's windows; `other.test` switched that (most recent) window to Other;
a `secret` link opened a new Private window, and a second one, with a normal
window in front, a tab in it; an unmatched link and a Most Recent Space
route with Detour inactive opened a new window each (today's path, no key
window); with Detour active, a tab in the key window's space; with the
Default set to Personal, the Personal window. A list of four URLs in one
event went to four places (Work by switching the most recent window, the
Personal window, an Other window, the Private window). Through
LaunchServices on a renamed copy: an app-only route matched the app it
names and not another app, a URL route listed first won over it, and two
URLs from one open routed separately. `open -n` with three URLs cold-launched
the build and routed all three after launch. Captures (window number) for
phase 1; later LaunchServices steps ran into a screen
lock and have text logs only.

# The Links pane

TASK-191.3.[^task-191-3] Settings has its own **Links** pane (toolbar item
`arrow.triangle.branch`, after Spaces; user decision 2026-10-25: not a
section of the Spaces pane), after Arc's sheet in `docs/air-traffic-control/`.

| Part | What it shows |
|---|---|
| Description | What Link Routes do ("Link Routes open links in the space you choose: …"), that routes are tried from the top and the first match decides, and that rows drag. |
| Routes | A "Routes" title with **New Route** at the trailing edge, then a bordered list: one row per route, three lines (`URL [kind ▾] [pattern] ⊖`, `From app [app ▾]`, `↳ Open in [target ▾]`), a drag handle at the left, and, when the row has a problem, a fourth line: an orange triangle and the whole warning, wrapping, under Open in. No routes: one centred line in the box. |
| Default | "Open other links in [target ▾]" and a caption: it applies to every link no route matches (from other apps, typed in a new tab, clicked to another site), and Most Recent Space opens a link from another app in the space in front and leaves a typed or clicked link where it is. |

The route list fills the pane's height and scrolls its own rows; the Default
and its caption stay at the bottom (TASK-211). The Quick Detour section that
followed the caption (TASK-193.2, TASK-193.5) is a pane of its own since
TASK-211; see [Settings](./settings.md#quick-detour).

- **Match kind pop-up**: Domain is, Contains, Is equal to, then **Any URL**
  (`match == nil`). The pattern carries over when the kind changes; Any URL
  hides the field. Placeholders: `example.com`, `text in the address`,
  `https://example.com/page`.
- **From app pop-up**: **Any App** (no source condition), the regular apps
  running now (icon and name; Detour itself left out; rebuilt as the menu
  opens), the route's own app first when it is not running (name and icon
  from where it is installed, else the bundle ID), then **Choose…**: an
  `NSOpenPanel` sheet on `/Applications` for any `.app`, whose bundle ID is
  stored (an app without one beeps and changes nothing).
- **Target pop-up** (`linkRouteTargetMenu`): the normal spaces in order
  (emoji and name), Most Recent Space, Private Window, Quick Detour
  (TASK-193.5; links from other apps only, as the resolver rules).
  Quarantine is hidden until TASK-194, but a route (or Default) that
  already holds it shows it rather than changing it silently. A space
  that is not offered (deleted, or a Private window's) is listed first as
  "Space deleted" (or "Private space") with the warning image.
- Fixed widths (kind 120, the pop-ups 220) so the controls line up from row to
  row; a long name truncates.
- **Drag to reorder**: an NSTableView drag of the route's id
  (`com.detour.link-route`); `linkRouteMoveIndex` turns the drop row into the
  store index. Saved routes move among themselves only: a drop below the
  drafts is retargeted to the end of the saved routes, and a draft has no
  handle and does not drag.
- **⊖** removes at once, as in Arc (no confirmation).
- **Live**: the pane observes `LinkRouteStore.didChangeNotification` and
  `TabStoreObserver.tabStoreDidUpdateSpaces` (a space added, renamed,
  re-emojied, reordered or deleted elsewhere) and refreshes: rows whose order
  did not change are reconfigured in place, so a field being edited keeps its
  editor; otherwise the table reloads.
- **Warnings get their own line, and rows their own height.** A first
  version put the warning beside the target pop-up on one truncating line
  (the full text in a tooltip); "Enter a full address starting with
  https://. Not saved: links follow the saved route." was cut off. Now the
  warning is a line under Open in, from the controls' column to the row's
  edge (552 pt at the default width), wrapping, and the row grows by that
  line (`tableView(_:heightOfRow:)` = the measured base height plus
  `LinkRouteCellView.warningLineHeight`; 104 → 124 pt for one line).
  Chosen over keeping one line and shortening the messages (the "not saved"
  half is what tells the user links still follow the saved route) and over
  a fixed fourth line on every row (empty space on most). Heights are noted
  after every refresh without animation, re-measured when the table's width
  changes (legacy scroll bars), and the list box is the sum of the rows.
  While typing, a warning that appears gets its line at once, but one that
  goes keeps its (empty) line until the field is committed, so the window
  does not resize with every keystroke. The Default's warning wraps under
  its pop-up the same way. Drag and the drop gap work with the variable
  heights (NSTableView handles them).
- **The list never takes focus** (`acceptsFirstResponder` false): its rows
  are not selectable, and with it in the key loop Tab out of a pattern field
  went to the table.
- **Edits are committed before anything else acts** (`commitPendingEdit`,
  from the code review): a click on New Route, a pop-up, ⊖ or a drop first
  ends the field editor, so a pattern typed without Return is saved (or kept
  on its draft) rather than lost to a reload.
- **Height**: a list pane (400 minimum); the list box is as tall as its rows,
  so the pane grows with the routes up to the screen cap and then scrolls
  (the list's own scroll view passes the wheel to the pane's). See
  [Settings window](./settings.md).

## The two "no condition" choices and incomplete routes

- **App-only routes (user decision): "Any URL" in the match kind pop-up.**
  Chosen over an empty pattern field meaning "any URL" (which reads as an
  unfinished field and would make an emptied field silently widen a route)
  and over a separate checkbox. Symmetrically, **Any App** is the From app
  pop-up's "no condition", so the From app line is always shown: the
  condition is discoverable without an "add condition" button, and rows
  differ in height only by a warning line. Rejected: a From app line
  shown only when set (needs a separate add/remove control).
- **Nothing incomplete is saved; drafts stay on their rows, marked.** New
  Route adds a draft (Domain is, empty, Most Recent Space) after the saved
  routes, with the cursor in its field and the warning "Enter a domain, such
  as example.com. Not saved yet." The store takes it the moment it is
  complete (on Return, Tab or a click elsewhere, or a pop-up change). An edit
  the store refuses on a saved route (an emptied pattern, Any URL plus Any
  App) stays on the row with "… Not saved: links follow the saved route.",
  and the store keeps routing by the saved version until the row is valid
  again. Chosen over refusing the edit outright (reverting what the user
  typed). Drafts and refused edits live in `LinkRouteEditor` for the app's
  session; a refused edit goes when its route is removed anywhere. While
  typing, the warning follows the text (`problems(previewing:)`) without
  saving.

## Validation

In the store, test-first (`linkRouteProblems`, pure, in
`LinkRouteValidation.swift`; `LinkRouteStore.problems(for:)` applies it with
the current spaces):

| Problem | When |
|---|---|
| `noCondition` | Any URL and Any App (`match == nil`, no source app). |
| `emptyPattern` | A URL condition with an empty or blank pattern, **even with an app**: the URL part of an app-only route is `nil`, never an empty match. |
| `invalidPattern` | Domain is: whitespace inside, or `linkRouteDomain` finds no host (`*.`, `https://`). Is equal to: not an `http(s)` URL with a host (`example.com`, `ftp://…`, `https:///path`). Contains: any non-blank text is valid. |
| `missingSpace` | A `.space` target not among the normal spaces. |
| `privateSpace` | A `.space` target that is a Private window's space: Private Window is its own target. |

- `add` refuses any problem; `update` refuses a condition problem, and a
  target problem only when the update **changes** the target, so a route
  whose space went some other way stays editable (its pattern can change)
  and is repaired by picking a space; `setDefaultTarget` refuses a missing or
  Private space; `defaultTargetProblem` reports a broken Default.
- The spaces come from `LinkRouteStore.spaceContext`, which the owning
  `TabStore` sets (`linkRouteContext`, now with `privateSpaceIDs`); a store
  on its own (tests) does not check spaces.
- The pane never decides validity itself: each row shows the store's
  problems, and `linkRouteProblemMessage` words the first one.

## Broken routes

Deletion is blocked while routes target a space ([above](#a-space-routes-target-cannot-be-deleted)),
so a broken route only comes from a space removed some other way. Its row
keeps its pattern and app, shows "Space deleted" in the target pop-up and
"Its space was deleted. Choose where these links open."; it stays editable
and removable, and the resolver skips it. A broken Default shows the same
warning beside its pop-up.

## Opened from the blocked-deletion alert

**Open Links Settings…** calls `showLinksPane(highlightingSpaceID:)`: the
rows whose target is that space, and the Default row if it targets it, are
tinted with the accent colour (0.14 alpha), and the first is scrolled into
view once the window has its height (`paneDidFit`). A row is tinted by its
**saved** route's target, which is what blocks the deletion: a row showing a
refused edit to another space is still tinted, and a draft never is. The
highlight clears when the pane is left.

## Runtime check: the Links pane

Harness `docs/harness/task191-3-harness.patch`,
`DETOUR_DATA_DIR=DetourVerify1913`, 2026-10-25, screen unlocked, light and
dark.[^harness-3] Seeded: a URL-only, an app-only (Mail), a URL-and-app
(Safari), a Private Window route, a broken route (its space never existed)
and a Default. Driven with posted clicks and keys (pop-ups through their real
menus), each step logging the store and the resolver's decision from the
live store: New Route put the cursor in a marked draft; typing a domain and
Return saved it, and the next decision for that host changed (Most Recent
Space, then Work after the target pop-up); a pattern edit applied to the next
link, and a link delivered through `openExternalURLs` opened in Work; an
invalid kind change was refused and marked while the saved route kept
routing; Finder as From app matched only links from Finder; ⊖ and the
Default pop-up applied at once; renaming a space elsewhere updated every
pop-up; Choose… showed the open panel on `/Applications`; the alert's Open
Links Settings… from the sidebar, the Spaces pane and an Undo Add Space each
opened the pane with the right rows (and the Default) tinted; the empty
state is one line in a 400 pt pane; 20 routes reach the cap (1242 on a
1410 pt screen) and the pane scrolls to the last.

**Reorder at runtime: a posted drag cannot be aimed.** Posted mouse-down and
drag events on a handle start a real drag session, but the session follows
the real pointer: in a first run it outlived the posted mouse-up, swallowed
the next posted click and then dropped wherever the pointer was (it did move
a route through `acceptDrop`, so the real path works), and later pop-ups no
longer opened. The reorder was checked through a stub `NSDraggingInfo`
handed to `validateDrop`/`acceptDrop`, and the unit tests cover the index
rule. **Not verified at runtime:** a person's drag with the gap animation,
choosing an app in the open panel (shown and cancelled only), and a real
link from Mail or Safari through a source-app route (TASK-191.2 covers the
sender).

Second pass the same evening, after the code review's fixes and the warning
moved to its own line (captures `task191-3/out/light2` and `dark2`): every
warning shown whole (the label measured against its row: fits in each
case, including a broken Default); a pattern typed into a draft without
Return was saved by the next New Route click, and one typed before an Open
in change was saved with that target; Tab out of a completed draft left one
row with the cursor still in its field; a saved route emptied and pointed at
another space (both refused) still blocked deleting its saved space, and
Open Links Settings… tinted that row.

# Tests

`LinkRouteEditorTests` (TASK-191.3: the target menu with hidden Quarantine,
Quick Detour offered (TASK-193.5) and an unavailable space, the drag destination, the warnings,
drafts saved once complete, an app-only draft, a refused edit kept on its
row while the store keeps the saved route, previews, a broken saved route
repaired from the pop-up, removing, moving saved routes with drafts last,
rows following changes made elsewhere). `LinkRouteStoreTests` also covers
validation (patterns per kind, the problem list, add/update/Default
refusals, a broken route edited and repaired, refused changes posting
nothing, a `TabStore` checking targets against its spaces) and the alert's
two buttons.
`LinkRoutingEligibilityTests` (TASK-191.4: every case of the rule above,
`www.`, ports, subdomains, hostless pages, the modifier order, redirects with
each entry, Peek, the precedence over the anchor intercept, `.stay` as no
route, the typed rule, and both layers with the resolver: Private both ways,
Quarantine, the Default, a route to the current space).
`InPageLinkRoutingTests` (real windows against a loopback server reached as
`127.0.0.1` and `localhost`, clicks made with `evaluateJavaScript`, which
carries a gesture: a cross-host click opens in the Work window and the tab
stays, with no Work window the clicking window switches, `_blank` and
tab-style `window.open` routed (the page gets null), a Private route opens a
Private window; same-host, a server redirect, a click handler's
`location.href`, a page timer's `a.click()`, a popup (opener kept), a click in
a Peek and a click in a Private window not routed; on a pinned tab the route
wins over the Peek and with no route it peeks; typed: Cmd+T routed, in place
not, a search not, no route and a route to the current space open here, a
Private window ignores normal routes, a Private route opens a Private window).
Cmd+click is not in the unit tests: a script's event carries no modifiers
into the navigation action, so it is checked at runtime only.
`LinkPlacementTests` (every placement rule, several windows showing a space,
recency, Private in front, no windows; the sender's PID from the address,
Detour itself, no PID or bundle ID), `ExternalLinkRoutingTests` (real
windows in the test host driven through `application(_:open:)` and
`openExternalURLs(_:sourceApp:)`: the routed window comes forward, an
unshown space switches the most recent normal window, never a Private one,
Private reuse, source-app routes, the Default, Most Recent Space and
Quarantine as before, multi-URL opens, non-web URLs ignored).
`LinkRouteResolverTests` (every rule above, each match kind, `www.`, ports,
IDN, IP literals, the Default from each origin), `LinkRouteStoreTests` (store
operations, unknown rows, notifications, migration v20 on a v19 database,
one-row Default table, routes surviving a session save, blocked and allowed
deletion, a refused undo of Add Space and redo of Delete Space posting the
notification and keeping the entry with the other stack untouched, the alert
text).

# Related

- [Session database](../architecture/session-database.md): the v20 tables.
- [Profiles and spaces](../architecture/profiles-and-spaces.md): space deletion.
- [Incognito](../architecture/incognito.md): the one-way Private boundary.
- [Site settings](../architecture/site-settings.md): the host-or-parent rule `domainIs` shares in spirit.

[^task-191]: TASK-191: rules that route links and typed URLs to a chosen space
[^task-191-1]: TASK-191.1: route model, matching rule and storage
[^task-191-2]: TASK-191.2: send links from other apps to the routed space
[^harness]: TASK-191.1 runtime harness
[^harness-2]: TASK-191.2 runtime harness
[^task-191-4]: TASK-191.4: route typed URLs and links clicked inside Detour
[^harness-4]: TASK-191.4 runtime harness
[^task-191-3]: TASK-191.3: Settings UI to add, edit, reorder and remove routes
[^harness-3]: TASK-191.3 runtime harness
[^task-212]: TASK-212: rename the feature to Link Routes
[^task-193-3]: Quick Detour: Open in <Space> moves the page into a tab of a space (Cmd+O)
