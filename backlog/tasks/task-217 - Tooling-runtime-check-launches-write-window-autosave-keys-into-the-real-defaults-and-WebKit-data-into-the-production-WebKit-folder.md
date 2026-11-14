---
id: TASK-217
title: >-
  Tooling: runtime-check launches write window autosave keys into the real
  defaults and WebKit data into the production WebKit folder
status: To Do
assignee: []
created_date: 2026-10-27 22:21
updated_date: '2026-11-14T23:17:00Z'
labels:
  - tests
  - tooling
dependencies: []
references:
  - .claude/skills/verify/SKILL.md
priority: low
ordinal: 253000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A Debug launch with DETOUR_DATA_DIR=X writes NSWindow Frame BrowserWindow-X, NSSplitView Subview Frames BrowserSplitView-X and sometimes ExtensionSidePanelWidth-X into the real com.detourbrowser.mac defaults; 179 such keys had piled up by 2026-10-27 and were deleted by hand. The same runs leave WebKit data folders under ~/Library/WebKit/com.detourbrowser.mac that cannot be told apart from the installed app's (TASK-209). TASK-41 and TASK-36 fixed the same leaks for the test host; runtime-check launches need the equivalent: autosave names off or kept in the isolated defaults suite, and WebKit data under the isolated data directory.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A launch with DETOUR_DATA_DIR set adds no keys to the real com.detourbrowser.mac defaults (checked by diffing defaults export before and after)
- [ ] #2 A launch with DETOUR_DATA_DIR set writes no WebKit data under ~/Library/WebKit/com.detourbrowser.mac
- [ ] #3 Window frames still restore across relaunches of the same isolated data directory, and the installed app's own window frames are unaffected
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-14 measurement (user asked to record the test-host side). ~/Library/WebKit/com.detourbrowser.mac/WebsiteDataStore held 958 folders mid-run: 3 named with version 4 UUIDs (the installed app's profiles, created Apr 3, Apr 4 and Sep 15) and 955 with version 5 UUIDs, which WebKitStorageScope derives only for a non-default data directory (test host or DETOUR_DATA_DIR launch), so none of them can be a production store. The test host is NOT the leak: a full DetourTests run on main (358c562) created several hundred stores and the count fell to 678 once it ended (TestEnvironmentSetup removes recorded storage at bundle start/end, TASK-36); stores left by a crashed host are removed at the next bundle start. What remains (675 v5 folders, Sep 13 to today) is from runtime-check launches with DETOUR_DATA_DIR, which record their identifiers in their own data directory's database but never run removeRecordedStorage: this task's AC #2. Four such folders from TASK-325's /verify runs (12:29-12:31 today) were removed by hand. A one-off cleanup rule for the backlog of leftovers: remove a v5-named folder that nothing has open (lsof) and whose id is not in the production database; the same applies to ~/Library/WebKit/com.detourbrowser.mac/WebExtensions.
<!-- SECTION:NOTES:END -->
