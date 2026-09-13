---
id: TASK-35
title: >-
  Spaces: undo of Delete Space / Edit Space after its profile was deleted
  crashes
status: Done
assignee:
  - '@claude'
created_date: '2026-09-13 02:15'
updated_date: '2026-09-13 04:27'
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
- [x] #1 Deleting a space, deleting its profile, then Undo does not crash; the chosen behaviour (skip, re-home, or undo stack invalidated) is implemented and documented in the task notes
- [x] #2 Edit Space that changed the profile, followed by deleting the old profile and undo, does not crash or resurrect the deleted profile
- [x] #3 No code path force-unwraps Space.profile for a space restored by undo; tests cover both sequences
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. TabStore has one UndoManager (TabStore.undoManager; BrowserWindowController.undoManager and BrowserWebView forward to it). TabStore.deleteProfile clears it with removeAllActions() once the delete passes its guards: undo closures capture spaces (and so profiles) strongly, and those that captured a profileID would restore onto a deleted profile. Clearing also releases the Profile so TASK-32's removal is not blocked.
2. Defence in depth: the Delete Space undo and the Edit Space undo (and so their redos) check the captured profile still exists; if not, log and do nothing, registering no redo.
3. Remove the force unwrap in Space.dataStore: a space whose profile is missing or deleted gets a non-persistent store and no extension controller, with a logged error. Profile gets an isDeleted flag set by deleteProfile, so a Profile object still retained somewhere never lazily creates identifier storage (WKWebsiteDataStore(forIdentifier:) / persistent extension controller) after deletion.
4. Audit other per-profile captures (favourites resolve by profileID with guards and have no undo).
5. Tests (ProfileDeletionUndoTests, fake remover): delete space + delete profile + undo; Edit Space profile change + delete old profile + undo; canUndo false after deleteProfile; the deleted Profile deallocates; closure guards via forceRemoveProfile; Space config fallback for a deleted profile records no storage identifier; ordinary undo still works.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decision: invalidate the undo stack on profile deletion (option 'clear/invalidate'), plus fail-safe guards.
- Undo managers: one. TabStore.undoManager is the only browsing UndoManager; BrowserWindowController.undoManager returns it and BrowserWebView forwards Cmd+Z to it. Settings' own text-field undo is unrelated.
- TabStore.deleteProfile calls undoManager.removeAllActions() once its guards pass (a refused delete keeps the stack). UndoManager cannot drop only the closures that reference one profile (all are registered on the TabStore target), and profile deletion happens in Settings outside the browsing undo flow. Beyond Delete Space / Edit Space (captured profileIDs), closures such as Add Space and Close Tab capture Space objects, which hold their Profile strongly; clearing releases them. testTheDeletedProfileIsDeallocated fails without the clear (Add Space's undo kept the Profile alive, so TASK-32's removal would log 'still retained' and could hit an in-use store) and passes with it.
- Guards: the Delete Space undo and the Edit Space undo (and so their redos) return early, logging, when the captured profile no longer exists; nothing is restored and no redo is registered. updateSpace refuses to move a space onto a profile id that does not exist.
- Force unwraps: the only one was Space.dataStore (profile!.dataStore). New Space.usableProfile is nil for a missing or deleted profile; Space.dataStore logs and returns .nonPersistent() then, and makeWebViewConfiguration attaches no extension controller and no content-blocker lists for it. Profile.isDeleted (set by deleteProfile) makes a retained Profile's lazy dataStore/extensionController non-persistent, so a deleted profile never gets WKWebsiteDataStore(forIdentifier:) or a persistent controller again.
- Other per-profile captures: favourites have no undo actions and every favourite API resolves the profile by id with a guard; closedTabStack records are per space and purged with the space. Edit Space both directions covered (undo back to a deleted old profile; redo onto a deleted new profile).
- Tests: DetourTests/ProfileDeletionUndoTests (13): both crash sequences through deleteProfile with a fake remover (no space restored, profile not back in memory or DB, no WebKit identifier recorded for it), redo direction, canUndo/canRedo false after deleteProfile, refused delete keeps the stack, deallocation, closure guards via forceRemoveProfile, updateSpace refusal, orphan/deleted-profile Space configurations non-persistent, and ordinary Delete Space / Edit Space undo still working.
- Validation: ProfileDeletionUndoTests 13/13; with the removeAllActions line disabled the deallocation and clear-stack tests fail (2/2), restored. Full DetourTests (DetourTests-task35): 879 tests, 0 failures; end cleanup 157 recorded / 157 removed / 0 kept; production WebsiteDataStore still lists 2 stores.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Undo after deleting a profile no longer crashes. TabStore.deleteProfile clears the (single) TabStore undo manager, which also releases the deleted Profile that undo closures retained. As defence in depth the Delete Space and Edit Space undos are no-ops without redo when their captured profile is gone, updateSpace refuses unknown profiles, Space.dataStore no longer force-unwraps (non-persistent store and no extension controller for a missing or deleted profile), and Profile.isDeleted stops a retained deleted profile from lazily creating persistent WebKit storage. Covered by ProfileDeletionUndoTests (13); full DetourTests 879 tests, 0 failures.
<!-- SECTION:FINAL_SUMMARY:END -->
