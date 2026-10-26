---
id: TASK-193.5
title: >-
  Quick Detour: Opt-Cmd-click entry points, links from other apps, and
  auto-archive
status: To Do
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-26 18:12'
labels:
  - window
  - links
  - feature
dependencies:
  - TASK-193.1
parent_task_id: TASK-193
priority: low
ordinal: 229000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Fifth part of TASK-193.
- Opt-Cmd-click a link in a page, or a tab in the sidebar, opens it in a quick window (check against the existing modifier precedence: Cmd = background tab, Shift = Peek, Option = split; wiki/tabs/tab-lifecycle.md).
- A setting to open links from other apps in quick windows; with Air Traffic Control (TASK-191) the quick window becomes a route target instead of a separate switch (decide how the two fit).
- Quick windows not used for a configurable time (Arc default 6 h) close automatically and go to the archive, marked auto-closed (wiki/tabs/closed-tabs-and-archive.md); closing by hand also archives.
- Settings > Links gets a switch per entry point (hotkey, Opt-Cmd-click, links from other apps).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Opt-Cmd-click on a link and on a sidebar tab opens a quick window without breaking the other modifiers
- [ ] #2 Links from other apps can be sent to quick windows (via a setting or an Air Traffic Control target, as decided)
- [ ] #3 Idle quick windows auto-close into the archive after the configured time; the timing rule is a pure function with an injected clock and tests
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-26):
1. Links from other apps reach Quick Detour through Air Traffic Control: 'Quick Detour' becomes a visible Open in target in Settings > Links, for routes and the Default (external links only, as the resolver already rules). No separate switch.
2. Opt-Cmd-click on a sidebar tab opens a copy: the tab's current URL in a new Quick Detour; the tab stays in the sidebar.
3. Closed and auto-closed Quick Detour windows go to the sidebar archive page (all spaces), labelled Quick Detour (and 'auto-closed' when idle-closed); restoring reopens a Quick Detour window on that profile. Quitting archives open ones (TASK-193.1 decision).
4. Idle auto-close default 6 hours, configurable in the Quick Detour settings section: Never, 1 h, 6 h, 12 h, 1 day.
<!-- SECTION:NOTES:END -->
