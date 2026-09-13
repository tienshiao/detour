---
id: TASK-35
title: >-
  Spaces: undo of Delete Space / Edit Space after its profile was deleted
  crashes
status: To Do
assignee:
  - '@claude'
created_date: '2026-09-13 02:15'
labels:
  - spaces
  - profiles
  - bug
  - crash
dependencies: []
priority: medium
ordinal: 35000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found by the TASK-32 work. TabStore.deleteProfile requires that no space references the profile, so the usual sequence is: delete (or re-profile) a space, then delete its profile. The undo registered by deleteSpace (and Edit Space, which can change a space's profile) is still on the undo stack and rebuilds the space with the old profileID. Space.profile then resolves to nil and Space.dataStore force-unwraps it, crashing on the first web view configuration. The same stale-profile hazard applies to any other undo that captured a profileID (favourites are per profile). Decide the behaviour: either make those undos no-ops (or re-home the space onto an existing profile, e.g. the default one) when the captured profile no longer exists, or clear/invalidate undo actions referencing a profile when it is deleted. Never recreate the deleted profile's data store (TASK-32 removes it from disk).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Deleting a space, deleting its profile, then Undo does not crash; the chosen behaviour (skip, re-home, or undo stack invalidated) is implemented and documented in the task notes
- [ ] #2 Edit Space that changed the profile, followed by deleting the old profile and undo, does not crash or resurrect the deleted profile
- [ ] #3 No code path force-unwraps Space.profile for a space restored by undo; tests cover both sequences
<!-- AC:END -->
