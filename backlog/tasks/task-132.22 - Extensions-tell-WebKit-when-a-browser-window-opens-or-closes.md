---
id: TASK-132.22
title: 'Extensions: tell WebKit when a browser window opens or closes'
status: To Do
assignee: []
created_date: '2026-10-04 00:10'
labels: []
dependencies: []
parent_task_id: TASK-132
priority: medium
ordinal: 154000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found during TASK-132.2 (2026-10-03). Detour calls context.didOpenWindow only while loading a context (ExtensionManager, about line 1186) and didFocusWindow when a window becomes or stops being key; nothing calls didOpenWindow for a window created later or didCloseWindow when one closes. WebKit therefore learns of a new window only when it becomes key, so windows.onCreated does not fire for a window opened in the background and windows.onRemoved may never fire. The Claude extension opens its own windows (windows.create for MCP sessions and scheduled tasks) and listens to windows.onRemoved to clean up its session state. Announce window open and close to every loaded context of the window's profile, in the order WebKit expects relative to the tab announcements (ExtensionTabLifecycle placement rule), including Private windows for contexts allowed in Private only.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 windows.onCreated fires once in each loaded context of the profile when a browser window opens, whether or not it becomes key
- [ ] #2 windows.onRemoved fires once when it closes, and the window and its tabs are no longer returned by windows.getAll or tabs.query afterwards
- [ ] #3 A window opened by windows.create is announced once, not twice
- [ ] #4 A window that changes profile (its active space switches to a space of another profile) is reported closed to the old profile's contexts and opened to the new one's, or the existing behaviour is documented if that is already handled
- [ ] #5 Private windows are announced only to contexts loaded in the Private profile
- [ ] #6 Tests cover open, close and background-open; API Explorer logs windows.onCreated and onRemoved
<!-- AC:END -->
