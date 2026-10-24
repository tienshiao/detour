---
id: TASK-193
title: 'Little Detour: a minimal one-page window opened by a global hotkey'
status: To Do
assignee: []
created_date: '2026-10-24 10:10'
updated_date: '2026-10-24 10:15'
labels:
  - window
  - feature
  - epic
dependencies: []
priority: medium
ordinal: 224000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Requested by the user 2026-10-24, modelled on Arc's Little Arc (https://blog.warrenweb.net/arc-little-arc/; screenshot docs/little-window/arc-little-arc.png). Working name "quick window"; the product name is a decision (not "Little Arc").

**What it is.** A small floating window for a quick lookup without disturbing your spaces: a system-wide hotkey (Arc: Opt-Cmd-N, from any app) opens it with the command palette; the chosen URL or search opens in a single web view with minimal chrome. From the screenshot, the title bar holds: traffic lights, a **profile selector** pill ("Default"), the page's host (centre), extension and copy-link buttons, and **Open in <Space> ⌘O** with a dropdown to pick another space, which moves the page into a tab of that space.

**Arc's other behaviour** (from the blog post): Opt-Cmd-click on a link or a sidebar tab opens it in a quick window; a setting opens links from other apps in quick windows; several can be open at once; unused ones are archived automatically after a configurable time (default 6 h) and show in the archive as auto-closed; Settings > Links has a switch per entry point.

**Detour pieces it builds on.** Peek already keeps a page in a BrowserTab that is in no space list (wiki/tabs/peek.md) and hands its web view to a normal tab (`expandPeekToNewTab`); the archive stream (wiki/tabs/closed-tabs-and-archive.md); Air Traffic Control (TASK-191) can gain the quick window as a target, as Arc's does.

**Cross-cutting questions** (to settle in the subtasks): history is recorded per *space* today (visits carry a spaceID), and a quick window belongs to a profile but no space; moving a page into a space whose profile differs from the window's cannot hand over the web view (different data store) and must reload instead; session restore of open quick windows; Private (a quick window in the Private profile?).

Subtasks: .1 window and tab model; .2 global hotkey; .3 Open in Space; .4 profile selector; .5 other entry points and auto-archive.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Name (user, 2026-10-24): Little Detour, or Small Detour; "quick window" in these tasks was a working name only. Titles use Little Detour; settle between the two before any UI text ships.

Name, 2026-10-24: "a quick detour" and "a short detour" are the most common English phrasings; "little detour" is natural but rarer. Recommendation: Quick Detour (also says what it is for). Pending the user's choice. Quarantine (TASK-194) opens links from other apps in a Private Quick Detour window.
<!-- SECTION:NOTES:END -->
