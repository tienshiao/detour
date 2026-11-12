---
id: TASK-293.3
title: >-
  Import from Arc: File menu import window, first-run offer, and what is not
  imported
status: Done
assignee:
  - '@claude'
created_date: '2026-11-12T09:23:00Z'
updated_date: '2026-11-12T18:21:00Z'
labels:
  - import
dependencies:
  - TASK-293.2
parent_task_id: TASK-293
ordinal: 386000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Arc users look for an import first (most of the people who try Detour come from Arc). The window has to cover both sources from TASK-293.1 and say plainly what does not come across: logins and cookies (Arc encrypts them with a Keychain key and WebKit cannot bulk-load cookies), passwords, extensions, Easels, Notes, Boosts, Little Arc. Detour has no first-run flow yet.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 File › Import from Arc… opens a window that offers Arc on this Mac (when found) and an Arc Data Export file, lists Arc profiles with a target Detour profile each, and lets the user pick spaces and what to bring (pinned tabs and folders, favourites, Today tabs, history)
- [x] #2 The window lists what is not imported before the import, and after it shows what was imported and what was skipped
- [x] #3 When Arc data is found, Detour offers the import once, at the first launch that has the feature, for new and current users alike (user, Nov 12 2026); declining never asks again
- [x] #4 A missing or unreadable Arc install or file shows a clear message and changes nothing
- [x] #5 Checked at runtime with /verify in an isolated profile against a copy of real Arc data and an exported file
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
1. Pure helpers: ArcImportText (counts, notes, summary, history lines), ArcImportOffer (once, scoped defaults, never in the test host).
2. ArcImportWindowController: programmatic AppKit window (source radio + open panel, per Arc profile a checkbox and an 'into' popup with its spaces, Bring switches, notes, Import), result view with history progress; plans against a fresh existing state.
3. AppDelegate: File › Import from Arc…, and the one-time offer 1.5 s after launch.
4. Tests for the helpers; runtime check in an isolated profile against this Mac's Arc data and the real exports; wiki.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 12 2026, user decisions: the layout as proposed (standalone window like Settings: source radio with Choose… for an export, per Arc profile a checkbox and an 'into' popup with its spaces as checkboxes and counts, Bring switches, a Not imported note, Cancel/Import; after Import the same window shows the result and history progress). The first-run offer is shown once to everyone with Arc data, new and current users.

Nov 12 2026, implementation and checks:
- Runtime pass 1 (DetourVerify2933, System Events, screencapture -l): offer sheet -> window -> direct import of this Mac's Arc 1.172.1 data: 2 profiles, 2 spaces, 4 pinned in 2 folders (nested kept), 3 favourites, 6 Today tabs (split kept, 0.5), history 1,225 + 251 visits; sidebar showed the space with Arc's tint, favourite tile, folder tree, split row. Export 2 through the real open panel into 'Default (Arc)': only new items added, 10 already present. Found and fixed: Arc's hidden system profile listed; an export's top-level pinned tab came in again as a Today tab (Today tabs now skip URLs pinned in the space; reverses the 293.2 'Arc allows both' call); History not disabled for an export; Bring row spread out; 'Arc….' in the offer.
- /code-review medium --fix: 9 findings, 5 fixed by the review (system profile dropped with its spaces; 'not found' text only when Arc is missing; one sidebarFile/isArcDataPresent helper for reader, offer and window; history option needs the box enabled; doc comment). Fixed by me after: a Today tab pinned earlier in the same import is dropped but not counted as already present (+1 test); a deleted target profile refreshes only the popups and keeps the user's other choices; the window swaps its content view between form and result instead of pinning both stacks to one container.
- Runtime pass 2 (DetourVerify2934): Not Now, then two relaunches with no offer; system profile still listed -> its real name is '__ARC_SYSTEM_PROFILE' (no trailing __), rule now 'starts with __', test fixture uses the real name; after the fix not listed; import result view laid out; a non-export .md shows the format message with Import disabled; History disabled for an export; re-opened window preselects the profiles the earlier import made; Bring label moved into the grid (it drifted above its row once).
- Tests: Arc suites 63/0 (ArcImportTextTests 7, ArcImportPlannerTests 19, ArcImportTabStoreTests 9, ArcSidebarReaderTests 19, ArcExportReaderTests 9); with AppDatabase, SessionSave*, HistoryDatabase: 251/0.
- Each run's isolated data folder, defaults keys and defaults suite were removed; WebKit stores created by pages the run opened are left under ~/Library/WebKit/com.detourbrowser.mac (TASK-217).
- Not checked: a Mac without Arc (the 'not found' path) at runtime: it is the same message path as a bad file, and ArcSidebarReader's arcNotFound is unit-tested.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
File › Import from Arc… and a one-time launch offer. The window (programmatic AppKit) offers Arc on this Mac or an Arc Data Export file, lists each Arc profile with an 'into' popup (a new profile by default, or where an earlier import went) and its spaces with counts, the Bring switches, and says what is not imported and what is skipped; after Import the same window lists what was added and each profile's history result. The offer shows once to everyone with Arc's data (user decision), flagged in the data directory's defaults. Runtime checks on this Mac's real Arc data and both exports found and fixed six issues (Arc's hidden system profile, export-after-direct duplicating top-level pinned tabs as Today tabs, history for an export, layout and wording). 63 Arc tests, 251 with the database suites, all passing.
<!-- SECTION:FINAL_SUMMARY:END -->
