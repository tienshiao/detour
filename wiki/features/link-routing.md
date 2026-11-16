---
type: Overview
title: Link Routes
description: Link Routes (formerly Air Traffic Control) send links from other apps, URLs typed in a new tab and links clicked to another site to a chosen space, Private window, Quick Detour or Quarantine by rule; this hub summarises the feature and links its pages.
tags: [links, spaces, privacy]
status: stable
generated: { by: claude-code/claude-opus-5-5, at: 2026-11-16T05:59:43Z }
sources:
  - id: linkrouting-dir
    resource: ../../Detour/Browser/LinkRouting
    title: Detour/Browser/LinkRouting (model, resolver, store, validation, eligibility, placement, sender)
  - id: task-191
    resource: backlog:TASK-191
    title: "TASK-191: rules that route links and typed URLs to a chosen space"
  - id: task-191-1
    resource: backlog:TASK-191.1
    title: "TASK-191.1: route model, matching rule and storage"
  - id: task-191-2
    resource: backlog:TASK-191.2
    title: "TASK-191.2: send links from other apps to the routed space"
  - id: task-191-3
    resource: backlog:TASK-191.3
    title: "TASK-191.3: Settings UI to add, edit, reorder and remove routes"
  - id: task-191-4
    resource: backlog:TASK-191.4
    title: "TASK-191.4: route typed URLs and links clicked inside Detour"
  - id: task-212
    resource: backlog:TASK-212
    title: "TASK-212: rename the feature to Link Routes"
  - id: task-356
    resource: backlog:TASK-356
    title: "Link Routes: Open Link in New Tab and Open Link in New Window go through Link Routes"
---

Link Routes send a link to a chosen space by rule: links opened from other
apps, typed URLs and links clicked in a page.[^task-191] A route has a URL
condition, a source-app condition or both, and a target; routes are tried in
order and the first usable match wins, and a Default target takes every link
no route matches. Routes are app-wide (spaces are global), stored in the
session database, and edited in Settings > **Links**.

# Summary

The feature was modelled on Arc's and first carried Arc's name, Air Traffic
Control; it was renamed Link Routes in TASK-212 (user decision
2026-10-26).[^task-212] The old Backlog tasks (TASK-191 to TASK-191.4,
TASK-193.5) and Arc's screenshots in `docs/air-traffic-control/` keep the
old name. The Settings pane is still **Links** and each entry is still a
route.

A link is decided in up to three steps, each a pure function the AppKit side
only carries out:

| Step | Function | Page |
|---|---|---|
| **Whether** a link inside Detour is routed at all (new-tab opens and plain clicks to another host; never redirects, scripts, popups, Peeks, Option/Shift/Opt-Cmd-clicks; typed URLs only from the new-tab palette) | `linkRoutingEligibility`, `typedURLIsRoutable` | [Typed URLs and links clicked in a page](./link-routing-in-page.md) |
| **Where** it goes: a space, Most Recent Space, a Private window, Quick Detour, Quarantine, or stay | `resolveLinkRoute`, `resolveExternalLinkRoute` | [Link Routes resolver](./link-routing-resolver.md) |
| **Which window** it opens in | `linkPlacement` | [Link placement](./link-routing-placement.md) |

Links from other apps skip the first step (every http/https link is routed)
and are the only origin a From app route, the Quick Detour target or a
Default of Quarantine applies to. Nothing routes out of a Private window.

The targets: a normal space; **Most Recent Space** (the space in front);
**Private Window**; **Quick Detour** (TASK-193.5: a new Quick Detour window
on the front window's profile, never Private, for links from other apps
only); **Quarantine** (TASK-194: a throwaway window with a fresh store, for
links from other apps and the clicks a route to it matches, never typed
URLs). See [Quick Detour](./quick-detour.md) and [Quarantine](./quarantine.md).

# Pages

- [Link Routes resolver](./link-routing-resolver.md) — the model (`LinkRoute`, `LinkRouteMatch`, `LinkRouteTarget`, the Default), every rule `resolveLinkRoute` applies and why, the rejected external-only Default, and how `contains`, `isEqualTo` and `domainIs` compare a URL (`www.`, ports, IDN, IP literals).
- [Link Routes store](./link-routing-store.md) — migration v20 (`linkRoute`, `linkRouteDefault`, no foreign key to `space`), `LinkRouteStore`'s operations and notification, and validation (`linkRouteProblems`).
- [Space deletion blocked by Link Routes](./link-routing-space-deletion.md) — `SpaceDeletionResult.blockedByLinkRoutes`, the sidebar, Spaces pane and undo/redo refusals, the one-step undo bounce, the alert, and the TASK-191.1 runtime check.
- [Link placement](./link-routing-placement.md) — `linkPlacement` and `AppDelegate.openLink`/`placeTab`, shared by both paths, and what a routed link that becomes a download puts back (TASK-205).
- [Links from other apps](./link-routing-external-links.md) — Detour's Get URL handler, reading the sending app (what macOS 26.7 reports), multi-URL opens, the link that launched Detour and its fail-closed rule (TASK-304), delivering test links safely, and the runtime checks.
- [Typed URLs and links clicked in a page](./link-routing-in-page.md) — the entry points, the eligibility rule case by case, host not site, the WebKit signals that tell a click from a script or a redirect, a route winning over the Peek intercept, the decisions the user made on 2026-11-15 (Open Link in New Tab and New Window to be routed, planned in TASK-356), and the TASK-191.4 runtime check.[^task-356]
- [The Links pane](./link-routing-links-pane.md) — the Settings pane (TASK-191.3): rows, pop-ups, the "no condition" choices, drafts and refused edits, broken routes, the alert's highlighting, and its runtime checks.

# How they connect

- Every link reads `TabStore.shared.linkRoutes` (the store) for the routes
  and the Default, and `TabStore.linkRouteContext` for the spaces that
  exist, so a change in the pane applies to the next link.
- The store refuses an invalid route, so the resolver only skips routes
  whose space went some other way; deletion of a routed space is refused
  ([space deletion](./link-routing-space-deletion.md)), and its alert opens
  the Links pane on the routes that block it.
- Routed clicks and typed URLs reuse the placement written for links from
  other apps; Quick Detour's Open in reuses it too (`placeTab`).

# Related

- [Session database](../architecture/session-database.md): the v20 tables.
- [Profiles and spaces](../architecture/profiles-and-spaces.md): space deletion.
- [Incognito](../architecture/incognito.md): the one-way Private boundary.
- [Site settings](../architecture/site-settings.md): the host-or-parent rule `domainIs` shares in spirit.
- [Quarantine](./quarantine.md): the Quarantine target's window, isolation and Open in.
- [Quick Detour](./quick-detour.md): the Quick Detour target and Opt-Cmd-click.
- [Settings panes](./settings-panes.md#links): the Links pane in the Settings window.

[^task-191]: TASK-191: rules that route links and typed URLs to a chosen space
[^task-212]: TASK-212: rename the feature to Link Routes
[^task-356]: TASK-356: Link Routes: Open Link in New Tab and Open Link in New Window go through Link Routes
