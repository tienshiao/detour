---
id: TASK-412
title: 'Quick Detour launcher: the window opens behind Chrome instead of in front'
status: Done
assignee: []
created_date: '2026-11-19T21:45:00Z'
updated_date: '2026-11-19T22:35:00Z'
labels:
  - quick-detour
  - bug
dependencies: []
priority: medium
ordinal: 493000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Reported by the user 2026-11-19. Pressing the Quick Detour hotkey and then submitting a URL or a suggestion in the launcher brings the new Quick Detour window to the front when Detour, Ghostty or Messages was in front, but not when Google Chrome was: the window opens behind Chrome's front window and Detour does not become the active app.

Reproduced on the user's Mac (macOS 26.7) with real HID key events and CGWindowList (docs/harness/task412). The window server refuses the cooperative NSApp.activate() whenever Chrome is frontmost (0/7) or was in front just before the frontmost app (Ghostty after Chrome: 0/2); over Ghostty without Chrome before it is granted (3/3). The refusal is not logged. Opening the window before closing the panel, and keeping the panel key until activation, made no difference. NSApp.activate(ignoringOtherApps: true) was granted every time (5/5 over Chrome, 2/2 Ghostty after Chrome, 3/3 Ghostty) with only the new window forward.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Submitting in the launcher shown by the hotkey over Chrome activates Detour with the new Quick Detour window in front
- [x] #2 Over Ghostty, with or without Chrome in front just before, the same
- [x] #3 Only the new window comes forward: Detour's other windows stay behind the other app
- [x] #4 The wiki's launcher page records why the cooperative request is not used
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Fix: QuickDetourLauncher.defaultOpenWindow calls NSApp.activate(ignoringOtherApps: true) instead of the cooperative NSApp.activate(). Branch qd-front-over-chrome (worktree .claude/worktrees/qd-front), not committed yet.

Runtime (debug build, isolated profile DetourVerifyQDFront, real HID keys, CGWindowList; docs/harness/task412): shipped call 0/7 over Chrome, 0/2 over Ghostty right after Chrome, 3/3 over Ghostty otherwise; with the fix 5/5, 2/2, 3/3, only the new window forward (earlier Quick Detour windows and the browser window stayed behind). Rejected: open-then-close-panel order (0/4 over Chrome), holding the panel key until activation (0/2). The refusal is not logged by WindowServer.

Tests: QuickDetourLauncherTests 16/16 passed. No unit test for the activation itself: whether the window server grants activation can't be observed in the test host; covered by the runtime harness instead.
/code-review medium: no important findings; harness nits fixed (fixture page created by run.sh, production pid found at run time, trap cleanup of processes and defaults), wiki wording fixed. Deprecation warning for activate(ignoringOtherApps:) accepted (same call as Settings and the WKUIDelegate path).
Not covered: links from other apps routed to a Quick Detour (AppDelegate.openInQuickDetour) and Dock menu Show All still use the activation that comes with the event / the cooperative call; not measured over Chrome.

Follow-up check (user asked, 2026-11-19): the two other ways a Quick Detour comes forward, measured on the current code over Chrome (docs/harness/task412/run-paths.sh, opener.swift, dockclick.swift). Link from another app routed to Quick Detour (LaunchServices open, activating): 2/2 over Chrome, 1/1 Ghostty right after Chrome, 2/2 Ghostty. Dock menu Show All (real right-click on the debug build's Dock tile, then the item): 2/2 over Chrome, 2/2 Ghostty right after Chrome, 1/1 Ghostty. Both left unchanged: LaunchServices activates Detour for a delivered link, and a Dock menu choice grants the cooperative activate(). Wiki launcher page records it.

/verify (2026-11-19, build 14:34, DETOUR_DATA_DIR=DetourVerify412, DETOUR_MCP=1): launched cleanly; with Detour frontmost, File > New Quick Detour Window, a URL typed (real keys) and Return opened the Quick Detour window in front, key and main, the browser window behind; no errors in the app log.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
The Quick Detour launcher now activates Detour with NSApp.activate(ignoringOtherApps: true) instead of the cooperative NSApp.activate(), which the window server refused (silently) whenever Chrome was frontmost or had been in front just before, so the window opened behind Chrome. Measured on the user's Mac with real HID input: 0/7 → 5/5 over Chrome, 0/2 → 2/2 over Ghostty right after Chrome, only the new window forward. Links routed to Quick Detour from other apps and the Dock menu's Show All were measured over Chrome too and work unchanged. QuickDetourLauncherTests 16/16; /code-review medium clean apart from harness nits (fixed); /verify passed. Harness and counts: docs/harness/task412. Risk: activate(ignoringOtherApps:) is deprecated since macOS 14; a later macOS could stop honouring it (Settings and the WKUIDelegate path depend on it too).
<!-- SECTION:FINAL_SUMMARY:END -->
