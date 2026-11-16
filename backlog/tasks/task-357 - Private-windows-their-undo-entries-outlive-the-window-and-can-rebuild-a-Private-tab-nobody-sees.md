---
id: TASK-357
title: >-
  Private windows: their undo entries outlive the window and can rebuild a
  Private tab nobody sees
status: Done
assignee:
  - '@claude'
created_date: '2026-11-16T05:53:00Z'
updated_date: '2026-11-16T06:39:00Z'
labels:
  - incognito
  - undo
  - privacy
dependencies: []
references:
  - Detour/Browser/TabStore.swift
  - wiki/architecture/browser-undo.md
  - wiki/architecture/incognito.md
priority: medium
type: bug
ordinal: 438000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found 2026-11-15 while writing wiki/architecture/browser-undo.md (read from the code, not run). TabStore's one undo stack is app-wide. Closing a Private window removes its space (removeIncognitoSpace) and tears its tabs down, but leaves that window's undo entries on the stack, so a later Undo Close Tab in a normal window could rebuild a live tab on the Private profile's store into the removed space, which no window shows. Privacy-relevant: Private browsing should leave nothing reachable after its window closes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Whether a closed Private window's undo entries can still run is established at runtime and recorded
- [x] #2 After a Private window closes, no undo or redo action can recreate or reference its tabs, spaces or profile data
- [x] #3 A test covers closing a Private window with undoable actions on the stack, then undoing from a normal window
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Establish the premise: a test against unmodified code, and the running app through the automation endpoint (docs/harness/task357-private-undo-checks.py) against a build of the old code.
2. Register every undo entry acting in a Private space against its own target object (PrivateUndoEntry) via registerUndo(actionName:in:handler:), with the spaces passed at every call site (the compiler forces it).
3. removeIncognitoSpace drops that space's entries first: empties their handlers and takes them off both stacks with removeAllActions(withTarget:); while a group is open or an undo runs, removal waits for the group-close notification (+ main hop) or willUndo/willRedo.
4. Guards: no registration for a Private space already gone; a Private entry's handler runs only while its spaces are open.
5. Tests: PrivateWindowUndoTests (store level) + PrivateWindowUndoWindowTests (real windows, Undo from a normal window); rerun undo-related suites; runtime harness against the fix.
6. Wiki: browser-undo (open question resolved), incognito; log line; code review; commit.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Premise CONFIRMED (2026-11-15), two ways:
- Test against the unmodified TabStore (probe, then the new suite run against HEAD's TabStore.swift: all 13 new tests fail there): Private tab closed in an undo group, removeIncognitoSpace, then undo() -> the tab came back as a new BrowserTab with a live BrowserWebView whose websiteDataStore is the Private profile's (non-persistent) store, inserted into the removed space (not in store.spaces), .tabRestoredByUndo posted with that space id, and a 'Redo Close Tab' entry left on the redo stack. restoreArchivedPage calls load(fallbackURL), so the page is fetched on the Private store after the session reset already ran: its data would stay in the store the next Private session reuses.
- Running app, old code (docs/harness/task357-private-undo-checks.py through the automation endpoint, isolated data dir, -AutomationAllowPrivate YES): normal page closed in window 1, Private window opened /secret.html and closed it, Private window closed; Cmd+Z in window 1 re-requested /secret.html from the local server (hits 1 -> 2) and did not bring the normal tab back; the second Cmd+Z did.

Fix: registerUndo(actionName:in:handler:) (spaces required at every call site). Entries acting in a Private space get their own target object (PrivateUndoEntry, tracked weakly); removeIncognitoSpace first drops that space's entries: empties their handlers (releases captured URL/title/interaction state) and removes them from both stacks with removeAllActions(withTarget:). While an undo group is open or an undo/redo runs, removal waits for NSUndoManagerDidCloseUndoGroup (+ one main-queue hop) or NSUndoManagerWillUndo/WillRedoChange (Undo closes the open group itself and runs it at once). Guards: no registration for a Private space already gone; a Private entry's handler runs only while its spaces are in store.spaces. Normal windows' entries keep the store as target and are untouched.

Measured along the way (standalone UndoManager probes): removeAllActions(withTarget:) removes groups it empties; called on an OPEN group it leaves an empty group that a later undo spends doing nothing; UndoManager does not retain the target of registerUndo(withTarget:handler:); an empty group counts for canUndo; removal in the didClose notification itself misses the closing group. A first cut that polled for 2 s failed the runtime check (endpoint-driven app: no events, so the group stayed open; first Cmd+Z did nothing) -> replaced by the notifications.

Verification:
- New tests: PrivateWindowUndoTests (12) + PrivateWindowUndoWindowTests (1) = 13, all pass; all 13 fail against HEAD's TabStore.swift (mutation check).
- Affected suites (21 suites incl. ArchivedTabRestore, ClosedPeek, ClosedTabOpener, ExtensionPageUndo, LinkRouteStore, MoveTabToSpace, PageUndoRouting, PrivateSessionReset, ProfileDeletionUndo, Split*, TabStore, UndoAfterDeleteSpace, WindowCloseRelease, DownloadManager, PaletteTabScope, AutomationStaging/PrivateAccess, FavoriteSpaceHandoff): 414 tests, 0 failures (after the review fixes).
- Runtime (/verify via the automation endpoint, docs/harness/task357-private-undo-checks.py, isolated data dirs DetourVerify-357-*, cleaned up): old build FAILS (Private page re-requested, first Cmd+Z spent on the invisible tab); fixed build ALL PASS (first Cmd+Z brings the normal tab back, no request for the Private page, Undo then disabled).
- Not verified: real keyboard Cmd+Z by a person (the endpoint's run_menu_item drives Edit > Undo without events); the case where removeIncognitoSpace runs during an undo/redo (no code path does today).
- /code-review medium --fix: applied a single-pass dropUndoEntries, a corrected registerUndo doc comment, a clearer harness failure. Not fixed (out of scope, reported): Move Space's undo stores indices into spaces, which include Private spaces, so opening/closing a Private window shifts them (pre-existing); reRegisterRunningUndoEntry re-registers with in: [] (only Add/Delete Space use it, never Private).
Chosen by Claude (not yet confirmed by the user): per-window removal (other Private windows and normal windows keep their entries) rather than clearing the whole stack; alternative: removeAllActions() on every Private window close (simpler, loses normal history).

Follow-up commit: test for an Undo whose open group holds only the dropped Private entry (no exception, nothing restored, canUndo/canRedo false) — PrivateWindowUndoTests now 13 + 1 window test, all pass; wiki/architecture/tabstore.md mutation shape updated to registerUndo(actionName:in:).
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Confirmed (test + running app on the old build): after a Private window closed, Undo Close Tab from a normal window rebuilt the Private tab live on the Private store in the removed space and re-requested its page. Fix: entries acting in a Private space are registered against their own PrivateUndoEntry target (registerUndo(actionName:in:handler:), spaces required at every call site); removeIncognitoSpace drops them (handlers emptied, removeAllActions(withTarget:), deferred to group close / willUndo / willRedo while a group is open); guards refuse registration for a gone Private space and skip handlers whose spaces are gone. Normal and other Private windows keep their entries. 13 new tests, 414 tests across 21 affected suites pass; runtime harness passes on the fix and fails on the old build. Wiki browser-undo and incognito updated. Follow-up candidates: Move Space undo index drift across Private space add/remove (pre-existing).
<!-- SECTION:FINAL_SUMMARY:END -->
