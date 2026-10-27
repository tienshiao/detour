---
id: TASK-217
title: >-
  Tooling: runtime-check launches write window autosave keys into the real
  defaults and WebKit data into the production WebKit folder
status: To Do
assignee: []
created_date: '2026-10-27 22:21'
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
