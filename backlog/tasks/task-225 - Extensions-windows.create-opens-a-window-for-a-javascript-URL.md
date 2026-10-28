---
id: TASK-225
title: 'Extensions: windows.create opens a window for a javascript: URL'
status: To Do
assignee: []
created_date: '2026-10-28T07:56:00Z'
updated_date: '2026-10-28T07:56:00Z'
labels:
  - extensions
  - security
dependencies: []
references:
  - wiki/extensions/tab-and-window-bridge.md
  - TASK-214
priority: low
ordinal: 261000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found in TASK-214 (2026-10-28) while reviewing the URL checks in openNewWindowUsing: the installed WebKit (seen on Darwin 25.6) passes javascript: URLs in windows.create's url list through to the delegate, and Detour opens a window for them. WebKit's current source refuses javascript: URLs in windows.create, so this may go away with an OS update, but until then Detour should refuse them itself, as Chrome does. tabs.create and tabs.update may have the same gap; check them too.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 windows.create with a javascript: URL (alone or among other URLs) is refused with an error and opens no window, as a promise rejection and as runtime.lastError
- [ ] #2 tabs.create and tabs.update are checked for the same gap and, if they have it, refuse javascript: URLs too, with tests
- [ ] #3 wiki/extensions/tab-and-window-bridge.md records the behaviour and which WebKit versions pass the URL through
<!-- AC:END -->
