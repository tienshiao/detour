---
type: Component
title: Link Routes store
description: "How Link Routes are stored and kept valid: migration v20's two tables with no foreign key to space, LinkRouteStore's write-through operations and change notification, and the validation every add, update and Default change goes through (no condition, an empty pattern with no app, an invalid pattern, a missing or Private space; a broken target an update leaves alone stays editable)."
resource: ../../Detour/Browser/LinkRouting/LinkRouteStore.swift
tags: [links, storage, spaces]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:00:20Z }
sources:
  - id: store
    resource: ../../Detour/Browser/LinkRouting/LinkRouteStore.swift
    title: LinkRouteStore.swift
  - id: validation
    resource: ../../Detour/Browser/LinkRouting/LinkRouteValidation.swift
    title: LinkRouteValidation.swift (LinkRouteProblem, linkRouteProblems, linkRoutePatternIsValid, linkRouteTargetProblem)
  - id: record
    resource: ../../Detour/Storage/Models/LinkRouteRecord.swift
    title: LinkRouteRecord.swift
  - id: database
    resource: ../../Detour/Storage/Database.swift
    title: Database.swift (migration v20, link route accessors)
  - id: tabstore
    resource: ../../Detour/Browser/TabStore.swift
    title: TabStore.swift (linkRoutes, linkRouteContext)
  - id: store-tests
    resource: ../../DetourTests/LinkRouteStoreTests.swift
    title: LinkRouteStoreTests.swift
  - id: task-191-1
    resource: backlog:TASK-191.1
    title: "TASK-191.1: route model, matching rule and storage"
  - id: task-191-3
    resource: backlog:TASK-191.3
    title: "TASK-191.3: Settings UI to add, edit, reorder and remove routes"
  - id: task-302
    resource: backlog:TASK-302
    title: "Link Routes: an app-only route is flagged invalid until its URL condition is switched to Any URL"
  - id: harness
    resource: ../../docs/harness/task191-1-harness.patch
    title: TASK-191.1 runtime harness
---

`LinkRouteStore` holds the routes and the Default, writes every change
through to the [session database](../architecture/session-database.md), and
refuses any route that has a problem, so the
[resolver](./link-routing-resolver.md) only ever sees valid routes and the
[Links pane](./link-routing-links-pane.md) never decides validity itself.
Part of [Link Routes](./link-routing.md).

# Storage

Migration **v20** of the [session database](../architecture/session-database.md):[^task-191-1]

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
  save. The test `testRoutesSurviveASessionSave` pins this. Deletion of a
  routed space is refused in `TabStore` instead:
  [space deletion](./link-routing-space-deletion.md).
- At runtime (2026-10-25, `DETOUR_DATA_DIR=DetourVerify1911`): v20 ran on a
  fresh data directory; a relaunch read the route and the Default back; a
  database taken back to v19 by hand (tables dropped, the `v20` migration
  row deleted) was migrated at launch with its spaces kept.[^harness]

# The store

`LinkRouteStore` (`.shared` over `AppDatabase.shared`;
`TabStore.shared.linkRoutes` is the same instance, other `TabStore`s get one
over their own database) loads once and writes through:

| Operation | What it does |
|---|---|
| `add` | Appends; refuses a route with any [problem](#validation); trims the bundle ID. |
| `update` | Keeps the place; refuses a problem (with the target exception below). |
| `moveRoute(id:to:)` | Renumbers 0…n−1 in one transaction. |
| `removeRoute` | Removes the route. |
| `setDefaultTarget` | Refuses a missing or Private space. |
| `references(toSpace:)` | The routes and Default that target a space ([space deletion](./link-routing-space-deletion.md)). |

Each change posts `LinkRouteStore.didChangeNotification`; a refused one
posts nothing. The resolver's callers read `linkRoutes.routes` and
`defaultTarget` for every link, so a change applies to the next link without
a restart.

# Validation

In the store, test-first (TASK-191.3; `linkRouteProblems`, pure, in
`LinkRouteValidation.swift`; `LinkRouteStore.problems(for:)` applies it with
the current spaces):[^task-191-3]

| Problem | When |
|---|---|
| `noCondition` | Any URL and Any App (`match == nil`, no source app). |
| `emptyPattern` | A URL condition with an empty or blank pattern **and no app** (a blank bundle ID counts as none): "Enter a domain, such as example.com, or choose an app." (per kind). With an app it is no problem: the route is app-only (TASK-302).[^task-302] |
| `invalidPattern` | A pattern that is there but means nothing, with or without an app. Domain is: whitespace inside, or `linkRouteDomain` finds no host (`*.`, `https://`). Is equal to: not an `http(s)` URL with a host (`example.com`, `ftp://…`, `https:///path`). Contains: any non-blank text is valid. |
| `missingSpace` | A `.space` target not among the normal spaces. |
| `privateSpace` | A `.space` target that is a Private window's space: Private Window is its own target. |

- `add` refuses any problem; `update` refuses a condition problem, and a
  target problem only when the update **changes** the target, so a route
  whose space went some other way stays editable (its pattern can change)
  and is repaired by picking a space; `setDefaultTarget` refuses a missing or
  Private space; `defaultTargetProblem` reports a broken Default.
- The spaces come from `LinkRouteStore.spaceContext`, which the owning
  `TabStore` sets (`linkRouteContext`, with `privateSpaceIDs`); a store on
  its own (tests) does not check spaces.
- The pane never decides validity itself: each row shows the store's
  problems, and `linkRouteProblemMessage` words the first one (see
  [the Links pane](./link-routing-links-pane.md)).

# Tests

`LinkRouteStoreTests`: store operations, unknown rows, notifications,
migration v20 on a v19 database, the one-row Default table, routes surviving
a session save; validation (patterns per kind, the problem list, app-only
with an empty pattern of every kind saved and round-tripping, URL-only,
both, neither (TASK-302), add/update/Default refusals, a broken route edited
and repaired, refused changes posting nothing, a `TabStore` checking targets
against its spaces). The same suite covers blocked deletion and the alert;
see [space deletion](./link-routing-space-deletion.md#tests).

# Related

- [Link Routes](./link-routing.md): the hub.
- [Session database](../architecture/session-database.md): the v20 tables and the no-FK pattern.
- [Link Routes resolver](./link-routing-resolver.md): what the stored routes mean.

[^task-191-1]: TASK-191.1: route model, matching rule and storage
[^task-191-3]: TASK-191.3: Settings UI to add, edit, reorder and remove routes
[^task-302]: Link Routes: an app-only route is flagged invalid until its URL condition is switched to Any URL
[^harness]: TASK-191.1 runtime harness
