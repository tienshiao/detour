---
id: TASK-193.5
title: >-
  Quick Detour: Opt-Cmd-click entry points, links from other apps, and
  auto-archive
status: Done
assignee: []
created_date: '2026-10-24 10:11'
updated_date: '2026-10-26 19:11'
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
- [x] #1 Opt-Cmd-click on a link and on a sidebar tab opens a quick window without breaking the other modifiers
- [x] #2 Links from other apps can be sent to quick windows (via a setting or an Air Traffic Control target, as decided)
- [x] #3 Idle quick windows auto-close into the archive after the configured time; the timing rule is a pure function with an injected clock and tests
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Decisions (user, 2026-10-26):
1. Links from other apps reach Quick Detour through Air Traffic Control: 'Quick Detour' becomes a visible Open in target in Settings > Links, for routes and the Default (external links only, as the resolver already rules). No separate switch.
2. Opt-Cmd-click on a sidebar tab opens a copy: the tab's current URL in a new Quick Detour; the tab stays in the sidebar.
3. Closed and auto-closed Quick Detour windows go to the sidebar archive page (all spaces), labelled Quick Detour (and 'auto-closed' when idle-closed); restoring reopens a Quick Detour window on that profile. Quitting archives open ones (TASK-193.1 decision).
4. Idle auto-close default 6 hours, configurable in the Quick Detour settings section: Never, 1 h, 6 h, 12 h, 1 day.

2026-10-26 implementation:
- ATC: Quick Detour is a visible Open in target for routes and the Default (resolver keeps it external-only); linkPlacement .openInQuickDetour opens a new Quick Detour window, Most Recent Space fallback removed. Profile: the frontmost Detour window's, but never Private (a Private window in front is skipped; only Private Window/Quarantine targets take external links into Private) - a departure from the 193.4 rule, flagged to the user.
- Opt-Cmd-click on a page link (any frame, _blank, inside a Peek) opens a Quick Detour on the page's profile (Private page -> Private Quick Detour); never routed (.notRouted(.quickDetourClick)); needs a user gesture; switch off or non-web URL -> Cmd as before. Precedence: Opt-Cmd(±Shift) = Quick Detour; Cmd/Cmd-Shift = background tab or route; Shift/Shift-Option = Peek; Option = split (pure inPageLinkClickBranch).
- Opt-Cmd-click on a sidebar row opens a copy without selecting/moving/waking: normal tab current URL, sleeping tab stored URL, split row the clicked half, pinned entry live URL else pinnedURL, favourite live URL else saved URL; folders/New Tab normal click.
- Archive: closedTab rows with spaceID = the profile's Quick Detour scope (no migration); archivedAt set = auto-closed. Labels 'Quick Detour · <address>' / 'Quick Detour · auto-closed · …'. Restore consumes the record and reopens with back/forward list, title, favicon. Quit archives every open normal Quick Detour once. Never archived: Private, Open in moves, profile switches, pages with no address. Profile deletion deletes them; Clear Archive covers them; the space filter hides them. No undo on close.
- Idle auto-close: pure rule now - lastUsedAt >= interval; never while key or Detour's front visible window, audible, a sheet is up, or Private. Use = open/restore, key changes, key/mouse/scroll/magnify/swipe in the window, sound start/stop (navigation alone does not count). 60 s repeating check + wake check (sleep counts as unused). DEBUG override DETOUR_QUICK_DETOUR_IDLE_SECONDS.
- Settings > Links > Quick Detour: hotkey row, 'Open links and sidebar tabs in Quick Detour with ⌥⌘-click' (on), 'Close Quick Detour windows not used for' Never/1 h/6 h/12 h/1 day (6 h), caption pointing links from other apps to routes/Default.
- TDD: 68 new/changed tests written first, 44 red (24 negative cases passed), then green; a cross-profile Open in being archived caught by a new assertion and fixed (reopen discards). QuickDetourSidebarCopyTests (6) after the code (UI hand-off; rule tested first).
- /code-review high --fix: 8 findings, 4 fixed: Opt-Cmd branch lacked the user-gesture check (scripted clicks could open windows); per-record dictionary rebuild in archiveEntries; duplicated profile filter; placeholder UUID lookup. Skipped: duplicated modifier predicate (different input types); repeated summary reads on restore (needed to tell disabled-extension pages apart); unused profileID on the entry kind (asserted by tests); case-sensitive scope match (all writes use uuidString).
- Tests: before review 850 pass + 1 gated skip across 40 suites (AppDatabase, ArchiveListLayout, ArchivedTabRestore, ExternalLinkRouting, HotKey*, InPageLinkRouting, LinkPlacement, LinkRoute*, LinkRoutingEligibility, NowPlayingTab, PeekAnchor, ProfileDataRemoval, all QuickDetour*, SessionSave*, Sidebar*, SplitOpening, SplitTab, TabStore, UserDefaultsScope); after review 362 pass across 16 (InPageLinkRouting, LinkRoutingEligibility, QuickDetourEntryPoints, QuickDetourArchive, QuickDetourArchiveWindow, QuickDetourSidebarCopy, QuickDetourOpenInWindow, ArchiveListLayout, ArchivedTabRestore, ExternalLinkRouting, LinkPlacement, TabStore, SidebarLayout, PeekAnchor, SplitOpening, ProfileDataRemoval).
- Runtime (docs/harness/task193-5-harness.patch, 12 s HID idle before inputs, external links via openExternalURLs in-process): routed links (URL, app-only, Default) open Quick Detours with no space tab; Opt-Cmd on a routed link opens a Quick Detour while Cmd routes; iframe Opt-Cmd; Private Opt-Cmd; sidebar copy without selection change; switch off/on; archive listing, restore consuming the record, Private not archived; quit archives two normal ones; idle close with a 15 s override (scroll reset the timer; frontmost and Private stayed); dark archive page and Links pane. Runtime ran before the review fixes. Not verified: a person's clicks, a real sending app, Opt-Cmd inside a Peek / pinned / favourite / split at runtime, sleep/wake, sound keeping a window, multiple displays.
<!-- SECTION:NOTES:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Quick Detour's other entry points: Opt-Cmd-click on a link or a sidebar tab (a copy) opens a Quick Detour, and Air Traffic Control can send links from other apps to it. Closed, quit-time and idle auto-closed Quick Detours go to the archive page, labelled, and restore with their history; idle close defaults to 6 hours. Settings > Links has a switch per entry point. Tests pass (850 before, 362 after the review fixes); checked at runtime in light and dark.
<!-- SECTION:FINAL_SUMMARY:END -->
