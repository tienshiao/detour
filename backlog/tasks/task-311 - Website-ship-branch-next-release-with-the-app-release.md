---
id: TASK-311
title: 'Website: ship branch next-release with the app release'
status: In Progress
assignee: []
created_date: '2026-11-08T19:54:00Z'
updated_date: '2026-11-08T21:25:00Z'
labels:
  - website
dependencies: []
priority: medium
ordinal: 372000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The website page updates for app changes merged after v0.4.0 are written on website branch next-release (worktree ../dw-next) and held until the app release that ships them (user decision, Nov 8 2026). Commits: 128af13 TASK-302 (app-only route, no Any URL step), 86f8ad3 + 0dc0a28 TASK-304 (launch link routed by its app; narrowed fail-closed rule), ef26356 TASK-300 (Open Link in Quick Detour), 3e3a2cb TASK-309 (Dock menu Hide/Show All Quick Detour Windows), f7488e4 TASK-299 (Quick Detour bar icon order), 3db4d97 TASK-298 (Private data cleared when the last Private window closes; Private Browsing, Quarantine comparison, Web Extensions, home grid line), 65b076e TASK-305 (audible tabs never archived), e41442e TASK-306 (Peek visits in History), 909c9ba TASK-307 (Cmd+O Peek in tab, Peek setting, reopen closed Peek; Keyboard Shortcuts), 1fe0664 TASK-308 (Control+W in the Control+Tab switcher; Keyboard Shortcuts).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 next-release is rebased onto the website main and builds
- [x] #2 Every page change is checked against the release build before it goes live (menu titles, shortcuts, settings paths)
- [ ] #3 The Link Routes still is re-captured without the v0.4.0 Any URL workaround (TASK-302), and the Peek page gets a capture showing the new behavior if useful
- [x] #4 Merged and pushed to the website main together with the release (publish-release.sh), and checked live
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Nov 8 2026, released with Detour 0.4.1 (build 9, app commit 71240af, tag v0.4.1): next-release rebased onto website main (11 commits) and fast-forwarded; publish-release.sh committed release.json ('Update to 0.4.1'), built and deployed; checked live (home shows 0.4.1, /features/peek/ has Open Peek in New Tab). Page wording checked against the released code (Open Peek in New Tab, Settings › General Peek checkbox title, Quick Detour menu titles built from QuickDetour.displayName; the per-task /verify runs read the real menus). Worktree ../dw-next and branch next-release removed. Open: #3 re-capture the Link Routes still (still shows the v0.4.0 Any URL workaround).
<!-- SECTION:NOTES:END -->
