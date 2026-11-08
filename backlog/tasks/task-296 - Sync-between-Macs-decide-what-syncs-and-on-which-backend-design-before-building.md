---
id: TASK-296
title: >-
  Sync between Macs: decide what syncs and on which backend (design before
  building)
status: To Do
assignee: []
created_date: '2026-11-08T07:52:00Z'
labels:
  - sync
  - design
dependencies: []
references:
  - docs/data-model.md
priority: medium
ordinal: 357000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Users with more than one Mac want the same setup on each: spaces, pinned tabs and folders, favorites, maybe open tabs. Detour has no sync today. The user (Nov 7 2026) asked what to sync, what Arc synced, and whether to build on iCloud or, since Detour may go cross-platform later, on another backend of their own.

What Arc did (Arc's help center "Arc Sync", Wayback capture Oct 14 2026):
- Synced: the sidebar: Spaces, folders, pinned and open ("Today") tabs. Arc Search on iOS could read them; tabs made there did not sync back.
- Did not sync: browsing history, passwords, extensions, Favorites, Profiles, custom keyboard shortcuts, Air Traffic Control (link routing) settings.
- Backend: started on iCloud sync, deprecated on macOS in v1.48.0 (June 20 2024) for its own end-to-end encrypted Arc Sync (Argon2 key derivation, libsodium sealed boxes, an account and a recovery card). Arc for Windows and Arc Search only ever supported the new one: going cross-platform is what moved them off iCloud. Arc and its servers shut down on Dec 22 2026.

Things the decision has to weigh:
- The website promises "One download. No account. No cloud." A Detour-run sync server means accounts and a cloud; the user's own iCloud (CloudKit private database) needs no Detour account or server, and can be end-to-end encrypted (encrypted record fields; Advanced Data Protection). CloudKit is reachable off Apple platforms only through CloudKit JS / web services.
- A transport-neutral design (stable IDs already used for spaces, tabs, pinned entries and folders; a change log or per-record versions; explicit merge rules) would let a later backend replace the first one without redoing the model.
- Merge rules are the hard part: sort orders and folder nesting edited on two Macs, split pairs that must stay adjacent (TabStore invariants), pinned entries that reset to a home URL, favorites per profile, and open tabs that change every few seconds (sync them, mirror them read-only like Arc Search, or leave them out).
- Profiles hold WebKit data stores (cookies, logins) that cannot be synced through WebKit; a synced space must land on a profile that exists on the other Mac.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A design document in docs/ states what syncs in a first version and what doesn't (spaces, pinned tabs and folders, favorites, open tabs, link routes, site searches, settings, history), with reasons, compared against what Arc synced
- [ ] #2 The backend decision (iCloud/CloudKit, a Detour-run service, or a transport-neutral layer starting on one of them) is made with the user and recorded with its trade-offs: accounts, cost and operations, encryption, cross-platform reach, and the website's no-account/no-cloud promise
- [ ] #3 Merge rules are specified for concurrent edits: ordering, folder moves, split pairs, deletes vs edits, and a space whose profile is missing on the other Mac
- [ ] #4 Implementation is broken into Backlog tasks only after the design is agreed
<!-- AC:END -->
