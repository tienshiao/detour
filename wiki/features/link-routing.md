---
type: Feature
title: Link routing (Air Traffic Control)
description: "Air Traffic Control's model (routes with a URL condition, a source-app condition or both, a target, a sort order; one Default target), the pure resolver and every rule it applies (first match wins, domainIs on a dot boundary with www, ports, IDN and IP literals defined, source-app routes external-only, one-way into Private, Quarantine and Quick Detour external-only, the Default for every origin, layered after TASK-191.4's click rule), storage in migration v20, and why a space a route targets cannot be deleted (also from undo and redo)."
tags: [links, spaces, storage, privacy, incognito]
status: draft
generated: { by: claude-code/claude-opus-5-5, at: 2026-10-25T10:20:00Z }
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
  - id: resolver-tests
    resource: ../../DetourTests/LinkRouteResolverTests.swift
    title: LinkRouteResolverTests.swift
  - id: store-tests
    resource: ../../DetourTests/LinkRouteStoreTests.swift
    title: LinkRouteStoreTests.swift
  - id: task-191
    resource: backlog:TASK-191
    title: "Air Traffic Control: rules that route links and typed URLs to a chosen space"
  - id: task-191-1
    resource: backlog:TASK-191.1
    title: "Air Traffic Control: route model, matching rule and storage"
  - id: harness
    resource: ../../docs/harness/task191-1-harness.patch
    title: TASK-191.1 runtime harness
---

Air Traffic Control, modelled on Arc's, sends a link to a chosen space by
rule: links opened from other apps, typed URLs and links clicked in a
page.[^task-191] This page covers the part that exists so far: the model, the
pure resolver, storage, and the rule that a space routes point at cannot be
deleted.[^task-191-1] Nothing calls the resolver yet; the entry points are
TASK-191.2 (links from other apps) and TASK-191.4 (typed URLs and clicks),
and the Settings Links pane is TASK-191.3.

# Model

| Type | Fields / cases |
|---|---|
| `LinkRoute` | `id`, `match: LinkRouteMatch?`, `sourceApp: String?` (bundle ID), `target`, `sortOrder` |
| `LinkRouteMatch` | `kind` (`isEqualTo`, `contains`, `domainIs`) and `pattern` |
| `LinkRouteTarget` | `.space(UUID)`, `.mostRecentSpace`, `.privateWindow`, `.quarantine` (TASK-194), `.quickDetour` (TASK-193.5) |

- A route needs at least one condition (`hasCondition`): a non-empty pattern
  or a source app. App-only routes are allowed (user, 2026-10-25). The store
  refuses a route with neither, and the resolver ignores one.
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
all is TASK-191.4's pure click rule (and its typed-URL rule: a URL, not a
search, from a palette mode that routes): same-host plain clicks, redirects,
script navigations, popups that keep their opener, Option- and Shift-clicks
and links in a Peek never get past it. **Where** a routed link goes is
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
| `.quarantine` and `.quickDetour` apply to external links only; elsewhere they are skipped. | Quarantine is defined for links from other apps (TASK-194). Quick Detour is held to the same until TASK-193.5 decides; widening it is one line. |
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
  loads once and writes through: `add` (appends, refuses a route without a
  condition, trims the bundle ID), `update` (keeps the place), `moveRoute(id:to:)`
  (renumbers 0…n−1 in one transaction), `removeRoute`, `setDefaultTarget`.
  Each change posts `LinkRouteStore.didChangeNotification`.

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

`SpaceDeletionBlockedAlert` is a plain `NSAlert` with OK: "“Work” can’t be
deleted", then one line per route (`linkRouteSummary`: "Domain is …",
"URL contains “…”", "URL is …", "Links from Mail", with the app's name looked
up from the bundle ID) and "The Default route" when it applies. It has **no
button to the Links pane yet**: the pane is TASK-191.3, and a button opening
the Spaces pane would show none of the routes.

A Private window's space is never a route target, so closing a Private
window (`removeIncognitoSpace`) does not consult the routes.

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

# Tests

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

[^task-191]: Air Traffic Control: rules that route links and typed URLs to a chosen space
[^task-191-1]: Air Traffic Control: route model, matching rule and storage
[^harness]: TASK-191.1 runtime harness
