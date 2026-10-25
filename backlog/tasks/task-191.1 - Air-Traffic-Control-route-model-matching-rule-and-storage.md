---
id: TASK-191.1
title: 'Air Traffic Control: route model, matching rule and storage'
status: To Do
assignee: []
created_date: '2026-10-24 09:44'
updated_date: '2026-10-25 08:46'
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
- [ ] #1 Route model, store and migration exist, with tests written first
- [ ] #2 resolveLinkRoute is pure and tested: each match kind, ordering, case, subdomains, deleted/Private target spaces, default fallback
- [ ] #3 Deleting a space leaves its routes visibly broken (or removes them; decide) rather than routing into nothing
- [ ] #4 Routes can carry an optional source-app condition (bundle ID); the resolver takes the link's origin (external + app, typed, clicked-in-space) and a source-app route matches only external links from that app
- [ ] #5 The resolver supports the Private window target (one-way: into Private only) and the Quarantine target (external links only), with tests
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-10-24 scope change (see TASK-191): the resolver takes the link's origin — external (with the sending app's bundle ID when known), typed, or clicked in a tab of space S — and a route may carry an optional source-app condition (matches only external links from that app). A route whose target is the space the link is already in resolves to 'stay' (no move). Add tests for the origin and source-app cases.

2026-10-24: add the Private window target. Resolver: a route to Private matches from any origin; from a Private window, routes to normal spaces are skipped (no routing out of Private) but a Private route is a no-op 'stay'. Also the Quarantine target (TASK-194), valid only for the external origin. Tests for both.

User 2026-10-25: deleting a space that routes target is blocked (see TASK-191). AC #3 becomes: TabStore refuses to delete such a space, with a pure, tested check (e.g. routesTargeting(spaceID)) the UI uses to explain why; the resolver still skips a missing space defensively.
<!-- SECTION:NOTES:END -->
