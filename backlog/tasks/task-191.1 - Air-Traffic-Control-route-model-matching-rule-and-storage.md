---
id: TASK-191.1
title: 'Air Traffic Control: route model, matching rule and storage'
status: Done
assignee:
  - '@claude'
created_date: '2026-10-24 09:44'
updated_date: '2026-10-25 19:05'
labels:
  - links
  - storage
  - feature
dependencies: []
parent_task_id: TASK-191
priority: medium
ordinal: 219000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
First part of TASK-191. A route = (id, match kind, pattern, target, sortOrder); target = a space id or Most Recent Space; one Default target. Stored in the session database (spaces are global, so routes are app-wide, not per profile), with a migration.

A pure resolver, test-first: `resolveLinkRoute(url:routes:defaultTarget:spaces:mostRecentSpaceID:) -> destination space`: first matching route in order; case-insensitive; host match covers subdomains; a route whose space was deleted or is Private is skipped (and reported to the UI as broken), falling through to the next route and finally the default; the default falls back to Most Recent Space when its space is gone.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Route model, store and migration exist, with tests written first
- [x] #2 resolveLinkRoute is pure and tested: each match kind, ordering, case, subdomains, deleted/Private target spaces, default fallback
- [x] #3 Deleting a space leaves its routes visibly broken (or removes them; decide) rather than routing into nothing
- [x] #4 Routes can carry an optional source-app condition (bundle ID); the resolver takes the link's origin (external + app, typed, clicked-in-space) and a source-app route matches only external links from that app
- [x] #5 The resolver supports the Private window target (one-way: into Private only) and the Quarantine target (external links only), with tests
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24 scope change (see TASK-191): the resolver takes the link's origin — external (with the sending app's bundle ID when known), typed, or clicked in a tab of space S — and a route may carry an optional source-app condition (matches only external links from that app). A route whose target is the space the link is already in resolves to 'stay' (no move). Add tests for the origin and source-app cases.

2026-10-24: add the Private window target. Resolver: a route to Private matches from any origin; from a Private window, routes to normal spaces are skipped (no routing out of Private) but a Private route is a no-op 'stay'. Also the Quarantine target (TASK-194), valid only for the external origin. Tests for both.

User 2026-10-25: deleting a space that routes target is blocked (see TASK-191). AC #3 becomes: TabStore refuses to delete such a space, with a pure, tested check (e.g. routesTargeting(spaceID)) the UI uses to explain why; the resolver still skips a missing space defensively.

2026-10-25 implementation:
- Route model (LinkRoute, LinkRouteRecord), LinkRouteStore, migration v20 (tables linkRoute, linkRouteDefault; no foreign key on targetSpaceID). Pure resolver resolveLinkRoute in Detour/Browser/LinkRouting/LinkRouteResolver.swift. Tests written first.
- AC #3 per the user decision: TabStore.deleteSpace returns SpaceDeletionResult (.deleted / .notDeleted / .blockedByLinkRoutes); the sidebar and Settings > Spaces show SpaceDeletionBlockedAlert listing the routes. The resolver still skips a missing space.
- User 2026-10-25: the Default applies to all links (typed, clicked, external) when no route matches. Default = normal space S: typed/clicked from another normal space opens in S, from S stays. Most Recent Space: typed/clicked stay. Private window: from every normal origin; stay from Private. Quarantine / Quick Detour: external only. Missing Default space: external -> most recent, typed/clicked stay. Rejected: an external-only Default (recorded in wiki/features/link-routing.md). 191.4's click/typed exclusions decide whether a link is routed; the resolver decides where.
- User: Domain-is patterns drop a leading www. (only when a dot remains).
- Undo of Add Space and redo of Delete Space go through deleteSpaceFromUndoStack: when blocked, TabStore posts spaceDeletionBlockedNotification, the frontmost browser window shows the alert, and the entry is put back on its stack via a one-step bounce on the opposite stack (UndoManager cannot re-push the running entry without clearing redo).
- /code-review --fix on the first pass: fixed 'www.' stripped from a bare 'www.' host pattern (now only when a dot remains); fixed the last normal space being deletable while a Private window is open (guard isIncognito || nonIncognitoSpaces.count > 1). The follow-up diff (Default semantics, undo bounce) I reviewed by hand rather than with a second /code-review.
- Red/green (follow-up): 66 tests in the two link-route suites, 6 failing (18 assertions), all new; then 66/66.
- Final run, 250 tests, 0 failures, 1 skipped (benchmark by design): LinkRouteResolverTests 38, LinkRouteStoreTests 28, UndoAfterDeleteSpaceTests 8, TabStoreTests 40, AppDatabaseTests 28, SidebarLayoutTests 41, ProfileDeletionUndoTests 13, MoveTabToSpaceTests 31, SessionSaveAtomicityTests 10, SessionSaveFailureTests 12, SessionSaveBenchmarkTests 1 skipped.
- Runtime (docs/harness/task191-1-harness.patch, screen unlocked, light + dark): alert from the sidebar, from Settings '−' (route only; Mail route + Default), from a refused undo and a refused redo; space survived each time; stacks unchanged after each refusal; removing the route let the same Undo/Redo delete. Routes and Default persisted across relaunch and still blocked. A v19 database migrated to v20 with spaces kept. 40 s idle, no crash, no NSUndoManager exceptions.
- Not verified: physical Cmd+Z / Cmd+Shift+Z (final runs sent the menu action to the window controller because Detour was in the background; the first light run used the enabled Undo Add Space item); the two-window case (which window shows the alert).
- Found, not fixed: the Redo menu reads 'Redo Add Space' for a redo that deletes a space (deleteSpace's restore closure names its re-delete 'Add Space'). Pre-existing; candidate follow-up, not filed without approval.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Air Traffic Control's data layer: routes (match kind, pattern, optional source app, target) and a Default, stored app-wide in the session database (migration v20), and a pure, tested resolver that takes the link's origin (external from an app, typed, clicked in a space) and returns a space, Most Recent Space, a Private window, Quarantine or stay. The Default covers every link no route matches. Spaces that routes target can't be deleted: the sidebar, Settings > Spaces and the undo/redo of Add/Delete Space all refuse with an alert listing the routes, and a refused undo or redo stays on its stack. 250 tests pass; verified at runtime in light and dark, across relaunch and the v19 -> v20 migration.
<!-- SECTION:FINAL_SUMMARY:END -->
